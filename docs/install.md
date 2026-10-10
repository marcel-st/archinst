# Step 1: installing Arch Linux

`archinst install` turns an empty disk into a bootable Arch system and then
applies the `base` module inside it. It only runs from the Arch ISO; on a
system that is already installed (such as a VPS) start at
[step 2](deploy.md).

## Requirements

- The current [Arch Linux ISO](https://archlinux.org/download/), booted in UEFI
  or BIOS mode (both work, archinst detects which one).
- Network access. Wired DHCP works out of the box on the ISO. For Wi-Fi use
  `iwctl` first.
- A disk that may be wiped completely.

## Running the installer

```bash
pacman -Sy --noconfirm git
git clone https://github.com/marcel-st/archinst
archinst/archinst install
```

The ISO does not include git, hence the first line; `-Sy` is fine on the
live system because it is thrown away after the install. These three short
lines are deliberately all you need to type on a console that
cannot paste (Proxmox noVNC, an iDRAC/IPMI web console, a physical keyboard).
If you can reach the live system over SSH instead, you can also use the
bootstrap one-liner from the README.

The installer asks, in this order:

1. **Fetch secrets?** Answer `y`. You get a short code to enter at
   <https://github.com/login/device> on your phone or laptop
   (see [secrets.md](secrets.md)). Without secrets the install still works,
   but the admin user gets no SSH keys and sshd is left unhardened.
2. **Hostname** (default `archlinux`).
3. **Root password**, twice. Used for the local console only; root cannot log
   in over SSH once `base` has hardened sshd.
4. **Disk**, only when more than one disk is found. The USB stick the ISO was
   booted from is never offered.
5. **Confirmation** that all data on the disk will be erased.

After that it runs unattended and finally offers to reboot. Remove the install
media (or detach the ISO in Proxmox) before the machine boots again.

## What gets installed

### Disk layout (GPT)

| Boot mode | Partition 1 | Partition 2 |
|-----------|-------------|-------------|
| UEFI | 1 GiB FAT32 ESP, mounted on `/boot` | root, rest of the disk |
| BIOS | 1 MiB BIOS boot partition (for GRUB) | root, rest of the disk |

The root filesystem is xfs by default; set `ROOT_FS="ext4"` for ext4. There is
no swap partition.

### Packages

`base linux-lts grub openssh sudo git reflector` plus:

- `efibootmgr` on UEFI systems
- `xfsprogs` or `e2fsprogs` for the root filesystem
- physical hardware: `linux-firmware` and `intel-ucode` or `amd-ucode`
- virtual machines: `qemu-guest-agent` (enable the guest agent option in Proxmox)

The `base` module installs everything else.

### System configuration

- Timezone, locale and console keymap from `TIMEZONE`, `LOCALE`, `KEYMAP`.
- Hostname in `/etc/hostname` and `/etc/hosts`.
- Networking: systemd-networkd with DHCP on every wired interface
  (`/etc/systemd/network/20-wired.network`) and systemd-resolved for DNS.
  For a static address, edit that file after the first boot, for example:

  ```ini
  [Match]
  Name=en*

  [Network]
  Address=192.0.2.10/24
  Gateway=192.0.2.1
  DNS=192.0.2.1
  ```

- GRUB with a 2 second timeout. On UEFI it is installed twice: once with a
  normal boot entry, and once to the fallback path `EFI/BOOT/BOOTX64.EFI`, so
  the disk still boots on firmware that loses its boot entries (common on
  cheap mainboards and after moving a disk to another machine).
- sshd, systemd-networkd, systemd-resolved and systemd-timesyncd enabled.
- archinst copied to `/opt/archinst` (linked as `/usr/local/bin/archinst`),
  the secrets to `/etc/archinst/secrets`.

Finally `archinst base` runs inside the new system, followed by every module in
`INSTALL_MODULES`.

## Unattended installs

Every question can be answered from configuration. Put the values in
`/etc/archinst/archinst.conf` on the live system before running the installer
(this is mostly useful when you are connected over SSH):

```bash
mkdir -p /etc/archinst
cat >/etc/archinst/archinst.conf <<'EOF'
HOST_NAME="web01"
INSTALL_DISK="/dev/vda"
ROOT_PASSWORD_HASH='$6$...'        # openssl passwd -6
INSTALL_MODULES=(docker sshguard)
ASSUME_YES="yes"
EOF
archinst/archinst install
```

The file is copied to the new system with mode 600, so host-specific settings
such as `OPEN_TCP_PORTS` stay in effect for later runs of `archinst`.

Fetching the secrets still needs the device login (or `GITHUB_TOKEN` exported
in the shell). Without a terminal and without a token the installer skips the
secrets with a warning; run `archinst secrets` first in that case, as the
existing secrets directory is then simply copied into the new system.

## Proxmox tips

- Machine type q35 with OVMF (UEFI) or SeaBIOS both work.
- Use VirtIO SCSI or VirtIO Block; the disk is then `/dev/sda` or `/dev/vda`
  and is detected automatically.
- Enable *QEMU Guest Agent* in the VM options; the package is already installed.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `'install' only runs from the Arch ISO` | You are on an installed system. Use `archinst base`. |
| `no installable disk found` | Check `lsblk`. Only `sd*`, `vd*`, `xvd*`, `nvme*` and `mmcblk*` disks are offered. Set `INSTALL_DISK` to override. |
| `pacstrap` fails on signatures | The ISO is old; run `pacman -Sy archlinux-keyring` and retry, or use a newer ISO. |
| Machine does not boot after install | Check the boot order in the firmware/Proxmox and that the ISO is detached. The UEFI fallback loader should be picked up automatically. |
| No network after reboot | `networkctl` shows the interface state. Interfaces not named `en*`/`eth*` need their own `.network` file. |

The installer can be run again at any time; it wipes the selected disk and
starts over.
