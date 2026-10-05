# Shared helpers for archinst. Sourced by the archinst CLI and every module.

set -Eeuo pipefail
trap 'die "failed at ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}"' ERR

STATE_DIR=/etc/archinst/state

if [[ -t 1 ]]; then
	C_OK=$'\e[1;32m' C_WARN=$'\e[1;33m' C_ERR=$'\e[1;31m' C_OFF=$'\e[0m'
else
	C_OK='' C_WARN='' C_ERR='' C_OFF=''
fi

log()  { printf '%s==>%s %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%s==> WARNING:%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()  { printf '%s==> ERROR:%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }

load_config() {
	local f
	for f in "$ARCHINST_DIR/archinst.conf" "${SECRETS_DIR:-/etc/archinst/secrets}/archinst.conf" /etc/archinst/archinst.conf; do
		# shellcheck source=/dev/null
		[[ -r $f ]] && source "$f"
	done
	return 0
}

interactive() { [[ -t 0 ]]; }

# ask VAR "question" [default] - only prompts when VAR is empty
ask() {
	local -n _var=$1
	[[ -n ${_var:-} ]] && return 0
	interactive || { _var=${3:-}; return 0; }
	read -rp "$2${3:+ [$3]}: " _var
	_var=${_var:-${3:-}}
}

confirm() {
	[[ ${ASSUME_YES:-no} == yes ]] && return 0
	interactive || return 1
	local reply
	read -rp "$1 [y/N] " reply
	[[ $reply == [yY]* ]]
}

# True on a booted system; false inside arch-chroot or a container without systemd
systemd_live() { [[ -d /run/systemd/system ]] && ! systemd-detect-virt -q --chroot; }

# Enable units, and start them too when systemd is running
enable_units() {
	if systemd_live; then
		systemctl enable --now "$@"
	else
		systemctl enable "$@"
	fi
}

pkg() { pacman -S --needed --noconfirm "$@"; }

# Path of a file in the secrets repo, fails when it does not exist
secret() {
	local f="$SECRETS_DIR/$1"
	[[ -r $f ]] && printf '%s\n' "$f"
}

# Value of a key in a form-encoded GitHub response (a=1&b=2), URL-decoded
form_value() {
	local kv v IFS='&'
	for kv in $2; do
		[[ ${kv%%=*} == "$1" ]] || continue
		v=${kv#*=}
		v=${v//+/ }
		printf '%b' "${v//%/\\x}"
		return 0
	done
}

# GitHub device flow: prints a short code to enter at github.com/login/device
# on any logged-in device, so no token has to be typed on the console.
# The token only lives in this process and expires after 8 hours.
github_login() {
	[[ -n ${GITHUB_TOKEN:-} || -z ${GITHUB_APP_CLIENT_ID:-} ]] && return 0
	local resp device_code interval token err
	resp=$(curl -fsS -X POST -d "client_id=$GITHUB_APP_CLIENT_ID" https://github.com/login/device/code) ||
		die "GitHub device login request failed"
	device_code=$(form_value device_code "$resp")
	interval=$(form_value interval "$resp")

	printf '\n  Open   %s\n  Enter  %s%s%s\n\n' "$(form_value verification_uri "$resp")" \
		"$C_OK" "$(form_value user_code "$resp")" "$C_OFF"
	log "Waiting for approval..."
	while sleep "${interval:-5}"; do
		resp=$(curl -fsS -X POST -d "client_id=$GITHUB_APP_CLIENT_ID" -d "device_code=$device_code" \
			-d "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
			https://github.com/login/oauth/access_token) || continue
		token=$(form_value access_token "$resp")
		[[ -n $token ]] && break
		err=$(form_value error "$resp")
		case $err in
			authorization_pending) ;;
			slow_down) interval=$((interval + 5)) ;;
			*) die "GitHub login failed: ${err:-unknown error}" ;;
		esac
	done
	export GITHUB_TOKEN=$token
	log "GitHub login approved"
}

# git with the GitHub token as a header, so it is never written to .git/config.
# Without a token git prompts for username + password/token itself.
git_gh() {
	if [[ -n ${GITHUB_TOKEN:-} ]]; then
		git -c "http.https://github.com/.extraheader=Authorization: Basic $(printf 'x-access-token:%s' "$GITHUB_TOKEN" | base64 -w0)" "$@"
	else
		git "$@"
	fi
}

fetch_secrets() {
	[[ -n ${SECRETS_REPO:-} ]] || die "SECRETS_REPO is not set"
	pkg git >/dev/null
	github_login
	if [[ -d $SECRETS_DIR/.git ]]; then
		log "Updating secrets in $SECRETS_DIR"
		git_gh -C "$SECRETS_DIR" pull --ff-only
	else
		log "Cloning $SECRETS_REPO"
		install -d -m 700 "$(dirname "$SECRETS_DIR")"
		git_gh clone "$SECRETS_REPO" "$SECRETS_DIR"
	fi
	chmod 700 "$SECRETS_DIR"
	load_config
}

require_base() {
	[[ -f $STATE_DIR/base ]] || die "run 'archinst base' first"
}

# Build and install AUR packages as $ADMIN_USER. Re-running pulls updates
# and only rebuilds when the AUR version differs from the installed one.
aur() {
	require_base
	pkg base-devel git >/dev/null
	local name dir want have key
	install -d -o "$ADMIN_USER" -g "$ADMIN_GROUP" /opt/build
	for name in "$@"; do
		dir=/opt/build/$name
		if [[ -d $dir/.git ]]; then
			sudo -u "$ADMIN_USER" git -C "$dir" pull --ff-only
		else
			sudo -u "$ADMIN_USER" git clone "https://aur.archlinux.org/$name.git" "$dir"
		fi
		want=$(awk -F' = ' '/^\tepoch/{e=$2":"} /^\tpkgver/{v=$2} /^\tpkgrel/{r=$2} END{print e v "-" r}' "$dir/.SRCINFO")
		have=$(pacman -Q "$name" 2>/dev/null | awk '{print $2}') || true
		if [[ $want == "$have" ]]; then
			log "$name $have is up to date"
			continue
		fi
		for key in $(awk -F' = ' '/^\tvalidpgpkeys/{print $2}' "$dir/.SRCINFO"); do
			sudo -u "$ADMIN_USER" -H gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "$key" ||
				warn "could not import PGP key $key"
		done
		log "Building $name $want from AUR"
		sudo -u "$ADMIN_USER" -H bash -c "cd '$dir' && makepkg -sicf --noconfirm"
	done
}
