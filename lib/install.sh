# Step 1: install Arch Linux from the live ISO onto an empty disk.
# Sourced by 'archinst install'.

MNT=/mnt

part() { [[ $1 == *[0-9] ]] && echo "${1}p$2" || echo "$1$2"; }

list_disks() {
	local live
	# Never offer the USB stick we booted from
	live=$(lsblk -no PKNAME "$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null)" 2>/dev/null) || true
	lsblk -dnpo NAME,TYPE,RO | awk -v live="/dev/$live" \
		'$2 == "disk" && $3 == 0 && $1 ~ /^\/dev\/(sd|vd|xvd|nvme|mmcblk)/ && $1 != live {print $1}'
}

pick_disk() {
	[[ -n $INSTALL_DISK ]] && return 0
	local disks
	mapfile -t disks < <(list_disks)
	case ${#disks[@]} in
		0) die "no installable disk found" ;;
		1) INSTALL_DISK=${disks[0]} ;;
		*)
			interactive || die "multiple disks found, set INSTALL_DISK"
			lsblk -dpo NAME,SIZE,MODEL "${disks[@]}"
			ask INSTALL_DISK "Install to disk" "${disks[0]}"
			;;
	esac
}

ask_root_password() {
	[[ -n $ROOT_PASSWORD_HASH ]] && return 0
	interactive || die "set ROOT_PASSWORD_HASH for unattended installs"
	local p1 p2
	while true; do
		read -rsp "Root password: " p1; echo
		read -rsp "Repeat root password: " p2; echo
		[[ -n $p1 && $p1 == "$p2" ]] && break
		warn "passwords empty or different, try again"
	done
	ROOT_PASSWORD_HASH=$(openssl passwd -6 -stdin <<<"$p1")
}

partition_disk() {
	log "Partitioning $INSTALL_DISK ($BOOT_MODE)"
	umount -R "$MNT" 2>/dev/null || true
	wipefs -af "$INSTALL_DISK"
	if [[ $BOOT_MODE == uefi ]]; then
		sfdisk --wipe always "$INSTALL_DISK" <<-EOF
		label: gpt
		size=1GiB, type=U
		type=L
		EOF
	else
		sfdisk --wipe always "$INSTALL_DISK" <<-EOF
		label: gpt
		size=1MiB, type=21686148-6449-6E6F-744E-656564454649
		type=L
		EOF
	fi
	udevadm settle

	local root
	root=$(part "$INSTALL_DISK" 2)
	if [[ $ROOT_FS == xfs ]]; then mkfs.xfs -f "$root"; else mkfs.ext4 -F "$root"; fi
	mount "$root" "$MNT"
	if [[ $BOOT_MODE == uefi ]]; then
		mkfs.fat -F 32 "$(part "$INSTALL_DISK" 1)"
		mount --mkdir "$(part "$INSTALL_DISK" 1)" "$MNT/boot"
	fi
}

install_packages() {
	local pkgs=(base linux-lts grub openssh sudo git reflector)
	[[ $ROOT_FS == xfs ]] && pkgs+=(xfsprogs) || pkgs+=(e2fsprogs)
	[[ $BOOT_MODE == uefi ]] && pkgs+=(efibootmgr)
	if ! systemd-detect-virt -q --vm; then
		pkgs+=(linux-firmware)
		grep -q GenuineIntel /proc/cpuinfo && pkgs+=(intel-ucode)
		grep -q AuthenticAMD /proc/cpuinfo && pkgs+=(amd-ucode)
	else
		pkgs+=(qemu-guest-agent)
	fi
	log "Installing: ${pkgs[*]}"
	pacstrap -K "$MNT" "${pkgs[@]}"
	genfstab -U "$MNT" >>"$MNT/etc/fstab"
}

configure_system() {
	log "Configuring $HOST_NAME"
	ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$MNT/etc/localtime"
	sed -i "s/^#\(${LOCALE//./\\.} \)/\1/" "$MNT/etc/locale.gen"
	echo "LANG=$LOCALE" >"$MNT/etc/locale.conf"
	echo "KEYMAP=$KEYMAP" >"$MNT/etc/vconsole.conf"
	echo "$HOST_NAME" >"$MNT/etc/hostname"
	printf '127.0.0.1 localhost\n::1 localhost\n127.0.1.1 %s\n' "$HOST_NAME" >"$MNT/etc/hosts"

	# DHCP on every wired interface; static setups can edit this file later
	cat >"$MNT/etc/systemd/network/20-wired.network" <<-EOF
	[Match]
	Name=en* eth*

	[Network]
	DHCP=yes
	EOF

	arch-chroot "$MNT" bash -e <<-EOF
	hwclock --systohc
	locale-gen
	echo 'root:$ROOT_PASSWORD_HASH' | chpasswd -e
	systemctl enable sshd systemd-networkd systemd-resolved systemd-timesyncd
	EOF

	log "Installing GRUB"
	sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=2/' "$MNT/etc/default/grub"
	if [[ $BOOT_MODE == uefi ]]; then
		arch-chroot "$MNT" grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
		# Fallback path too, for firmware that forgets NVRAM entries
		arch-chroot "$MNT" grub-install --target=x86_64-efi --efi-directory=/boot --removable
	else
		arch-chroot "$MNT" grub-install --target=i386-pc "$INSTALL_DISK"
	fi
	arch-chroot "$MNT" grub-mkconfig -o /boot/grub/grub.cfg
}

install_main() {
	[[ -d /run/archiso ]] || die "'install' only runs from the Arch ISO; use 'archinst base' on installed systems"
	[[ $ROOT_FS == xfs || $ROOT_FS == ext4 ]] || die "ROOT_FS must be xfs or ext4"
	[[ -d /sys/firmware/efi ]] && BOOT_MODE=uefi || BOOT_MODE=bios

	if [[ -n $SECRETS_REPO && ! -d $SECRETS_DIR/.git ]] && confirm "Fetch secrets from $SECRETS_REPO?"; then
		fetch_secrets
	fi

	ask HOST_NAME "Hostname" "archlinux"
	ask_root_password
	pick_disk
	[[ -b $INSTALL_DISK ]] || die "$INSTALL_DISK is not a block device"

	lsblk -po NAME,SIZE,FSTYPE,MOUNTPOINTS "$INSTALL_DISK"
	confirm "ALL DATA ON $INSTALL_DISK WILL BE ERASED. Continue?" || die "aborted"

	timedatectl set-ntp true
	partition_disk
	install_packages
	configure_system

	log "Copying archinst and secrets into the new system"
	cp -a "$ARCHINST_DIR" "$MNT/opt/archinst"
	ln -sf /opt/archinst/archinst "$MNT/usr/local/bin/archinst"
	install -d -m 700 "$MNT/etc/archinst" "$(dirname "$MNT$SECRETS_DIR")"
	if [[ -d $SECRETS_DIR ]]; then cp -a "$SECRETS_DIR" "$MNT$SECRETS_DIR"; fi
	if [[ -f /etc/archinst/archinst.conf ]]; then install -m 600 /etc/archinst/archinst.conf "$MNT/etc/archinst/"; fi

	arch-chroot "$MNT" env HOST_NAME="$HOST_NAME" /opt/archinst/archinst base "${INSTALL_MODULES[@]}"

	# Done last: arch-chroot bind-mounts resolv.conf while it runs
	ln -sf ../run/systemd/resolve/stub-resolv.conf "$MNT/etc/resolv.conf"
	umount -R "$MNT"
	log "Installation finished. Remove the install media and reboot."
	confirm "Reboot now?" && reboot
	return 0
}
