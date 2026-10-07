# desc: Baseline for every host: packages, admin user, SSH hardening, firewall
# Safe to re-run; every step converges to the same state.

set_hostname() {
	ask HOST_NAME "Hostname" "$(cat /etc/hostname 2>/dev/null || echo archlinux)"
	[[ -n $HOST_NAME ]] || return 0
	echo "$HOST_NAME" >/etc/hostname
	systemd_live && hostnamectl set-hostname "$HOST_NAME"
	return 0
}

# Replaces e.g. a provider's temporary root password; empty = leave as is
set_root_password() {
	[[ -n $ROOT_PASSWORD_HASH ]] || return 0
	[[ $ROOT_PASSWORD_HASH == \$* ]] || die "ROOT_PASSWORD_HASH is not a crypt hash; generate with: openssl passwd -6"
	[[ $(getent shadow root | cut -d: -f2) == "$ROOT_PASSWORD_HASH" ]] && return 0
	log "Setting root password from ROOT_PASSWORD_HASH"
	echo "root:$ROOT_PASSWORD_HASH" | chpasswd -e
}

setup_pacman() {
	log "Configuring pacman and mirrors"
	sed -i 's/^#\(Color\|ParallelDownloads\)/\1/' /etc/pacman.conf
	pacman -Sy --needed --noconfirm reflector archlinux-keyring
	cat >/etc/xdg/reflector/reflector.conf <<-EOF
	--save /etc/pacman.d/mirrorlist
	--country $MIRROR_COUNTRIES
	--protocol https
	--latest 20
	--sort rate
	EOF
	reflector @/etc/xdg/reflector/reflector.conf || warn "reflector failed, keeping current mirrorlist"
	pacman -Syu --noconfirm
	pkg "${BASE_PACKAGES[@]}"
	if systemd-detect-virt -q --vm; then pkg qemu-guest-agent; fi
}

setup_admin() {
	log "Setting up admin user $ADMIN_USER"
	getent group "$ADMIN_GROUP" >/dev/null || groupadd "$ADMIN_GROUP"
	if ! id "$ADMIN_USER" &>/dev/null; then
		useradd -m -g "$ADMIN_GROUP" -c "System administrator" "$ADMIN_USER"
		# '*' = no password login, but not "locked", so SSH keys still work
		usermod -p '*' "$ADMIN_USER"
	fi

	echo "%$ADMIN_GROUP ALL=(ALL:ALL) NOPASSWD: ALL" >/etc/sudoers.d/10-archinst
	chmod 440 /etc/sudoers.d/10-archinst
	visudo -cqf /etc/sudoers.d/10-archinst || die "invalid sudoers drop-in"

	local keys=("${ADMIN_SSH_KEYS[@]}") f home
	for f in "$SECRETS_DIR"/users/*.pub; do
		[[ -r $f ]] && keys+=("$(<"$f")")
	done
	home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
	if ((${#keys[@]})); then
		install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_GROUP" "$home/.ssh"
		printf '%s\n' "${keys[@]}" >"$home/.ssh/authorized_keys"
		chown "$ADMIN_USER:$ADMIN_GROUP" "$home/.ssh/authorized_keys"
		chmod 600 "$home/.ssh/authorized_keys"
	fi
}

setup_sshd() {
	local home
	home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
	if [[ ! -s $home/.ssh/authorized_keys ]]; then
		warn "no SSH keys for $ADMIN_USER; leaving sshd untouched to avoid a lockout"
		warn "add a key to secrets/users/*.pub or ADMIN_SSH_KEYS and re-run 'archinst base'"
		return 0
	fi
	log "Hardening sshd (key-only, no root login)"
	grep -q '^Include /etc/ssh/sshd_config.d/\*.conf' /etc/ssh/sshd_config ||
		sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
	install -d /etc/ssh/sshd_config.d
	cat >/etc/ssh/sshd_config.d/10-archinst.conf <<-EOF
	PermitRootLogin no
	PasswordAuthentication no
	KbdInteractiveAuthentication no
	EOF
	ssh-keygen -A >/dev/null
	sshd -t || die "sshd config test failed"
	enable_units sshd
	systemd_live && systemctl reload-or-restart sshd
	return 0
}

# Writes rules for iptables-restore; $1 = 4 or 6
generate_rules() {
	local v=$1 port src
	local -n allow=SSH_ALLOW_V$v
	echo "*filter"
	echo ":INPUT DROP [0:0]"
	echo ":FORWARD DROP [0:0]"
	echo ":OUTPUT ACCEPT [0:0]"
	echo "-A INPUT -i lo -j ACCEPT"
	echo "-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
	echo "-A INPUT -m conntrack --ctstate INVALID -j DROP"
	if [[ $v == 4 ]]; then
		echo "-A INPUT -p icmp --icmp-type echo-request -m limit --limit 5/second -j ACCEPT"
	else
		# Neighbour discovery and router adverts are required for IPv6 to work
		echo "-A INPUT -p ipv6-icmp -j ACCEPT"
		echo "-A INPUT -s fe80::/10 -p udp --dport 546 -j ACCEPT"
	fi
	if ((${#allow[@]})); then
		for src in "${allow[@]}"; do
			echo "-A INPUT -p tcp --dport 22 -s $src -m conntrack --ctstate NEW -j ACCEPT"
		done
	else
		echo "-A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT"
	fi
	for port in "${OPEN_TCP_PORTS[@]}"; do
		echo "-A INPUT -p tcp --dport $port -m conntrack --ctstate NEW -j ACCEPT"
	done
	for port in "${OPEN_UDP_PORTS[@]}"; do
		echo "-A INPUT -p udp --dport $port -j ACCEPT"
	done
	echo "-A INPUT -p tcp -j REJECT --reject-with tcp-reset"
	echo "-A INPUT -p udp -j REJECT"
	echo "COMMIT"
}

setup_firewall() {
	[[ $FIREWALL == yes ]] || { log "Firewall disabled (FIREWALL=$FIREWALL)"; return 0; }
	log "Configuring firewall"
	local v name custom
	install -d /etc/iptables
	for v in 4 6; do
		name=iptables; [[ $v == 6 ]] && name=ip6tables
		if custom=$(secret "iptables/$name.rules"); then
			log "Using $name rules from secrets"
			cp "$custom" "/etc/iptables/$name.rules"
		else
			generate_rules "$v" >"/etc/iptables/$name.rules"
		fi
		"$name-restore" --test "/etc/iptables/$name.rules" || die "$name.rules is invalid"
	done

	systemctl enable iptables ip6tables
	systemd_live || return 0
	if [[ -n ${SSH_CONNECTION:-} ]] && interactive; then
		# Rolls back automatically unless you confirm SSH still works
		iptables-apply -t 30 /etc/iptables/iptables.rules || die "firewall rolled back; fix rules and re-run"
		systemctl start iptables ip6tables
	else
		systemctl restart iptables ip6tables
	fi
	# Reloading iptables flushes Docker's chains; let Docker recreate them
	if systemctl is-active -q docker; then systemctl restart docker; fi
	return 0
}

setup_misc() {
	log "System tweaks"
	install -d /etc/makepkg.conf.d
	echo 'MAKEFLAGS="-j$(nproc)"' >/etc/makepkg.conf.d/10-archinst.conf
	# Keep /tmp on disk: large AUR builds do not fit in a RAM-backed /tmp
	systemctl mask tmp.mount
	: >/etc/motd
	echo '[[ $- == *i* ]] && fastfetch' >/etc/profile.d/fastfetch.sh
	[[ -e /usr/bin/vi ]] || ln -s /usr/bin/nvim /usr/bin/vi
	enable_units cronie.service systemd-timesyncd.service fstrim.timer reflector.timer
}

set_hostname
set_root_password
setup_pacman
setup_admin
setup_sshd
setup_firewall
setup_misc
