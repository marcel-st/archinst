# desc: Switch to linux-lts (for hosts not installed by archinst, GRUB only)

[[ -f /boot/grub/grub.cfg ]] || die "GRUB not found; switch kernels manually for this bootloader"

pkg linux-lts
if pacman -Q linux-headers &>/dev/null; then pkg linux-lts-headers; fi
grub-mkconfig -o /boot/grub/grub.cfg

if pacman -Q linux &>/dev/null && confirm "Remove the regular 'linux' kernel?"; then
	pacman -Rns --noconfirm linux $(pacman -Qq linux-headers 2>/dev/null)
	grub-mkconfig -o /boot/grub/grub.cfg
fi
log "Reboot to start linux-lts"
