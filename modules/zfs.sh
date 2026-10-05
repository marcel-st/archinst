# desc: OpenZFS via DKMS (AUR zfs-utils + zfs-dkms); survives kernel updates

# DKMS needs headers for every installed kernel
for k in linux linux-lts linux-zen linux-hardened; do
	if pacman -Q "$k" &>/dev/null; then pkg "$k-headers"; fi
done
pkg dkms

aur zfs-utils zfs-dkms

echo zfs >/etc/modules-load.d/zfs.conf
enable_units zfs.target zfs-import-cache.service zfs-mount.service zfs-zed.service
if systemd_live; then modprobe zfs; fi

cat <<'MSG'
ZFS installed. Pools are not created automatically (that wipes disks). Example:
  zpool create -o ashift=12 data raidz1 /dev/disk/by-id/...   # new pool
  zpool import data                                           # existing pool
  zpool set cachefile=/etc/zfs/zpool.cache data               # auto-import at boot
  systemctl enable --now zfs-scrub-monthly@data.timer
MSG
