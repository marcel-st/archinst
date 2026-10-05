#!/usr/bin/env bash
# Fetch archinst onto a machine and link it as /usr/local/bin/archinst. As root:
#   bash <(curl -fsSL https://raw.githubusercontent.com/marcel-st/archinst/main/bootstrap.sh) [command]
set -euo pipefail

REPO=${ARCHINST_REPO:-https://github.com/marcel-st/archinst.git}
DIR=/opt/archinst

[[ $EUID -eq 0 ]] || { echo "Run as root" >&2; exit 1; }

command -v git >/dev/null || pacman -Sy --needed --noconfirm git

if [[ -d $DIR/.git ]]; then
	git -C "$DIR" pull --ff-only
else
	git clone "$REPO" "$DIR"
fi
ln -sf "$DIR/archinst" /usr/local/bin/archinst

echo "archinst installed. Next:"
if [[ -d /run/archiso ]]; then
	echo "  archinst install"
else
	echo "  archinst base"
fi

[[ $# -gt 0 ]] && exec "$DIR/archinst" "$@"
exit 0
