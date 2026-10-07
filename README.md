# archinst

Two-step Arch Linux setup for all my machines: Proxmox VMs, physical hardware
and VPSes (Contabo, Azure).

| Step | Command | Where |
|------|---------|-------|
| 1. Install the OS | `archinst install` | Proxmox VM or physical machine, booted from the Arch ISO |
| 2. Deploy | `archinst base`, then `archinst <module>...` | Every Arch host, including VPSes where step 1 is impossible |

Step 1 ends by running step 2 (`base`) inside the new system, so a machine
installed from the ISO and a VPS end up in the same state.

This repository is public and contains no secrets. Passwords, keys and
host-specific settings live in the private `marcel-st/secrets` repository,
which is fetched with a short login code instead of a typed token
(see [docs/secrets.md](docs/secrets.md)).

## Quick start

### Fresh install (ISO / USB)

Boot the Arch ISO, make sure there is network, then type:

```bash
pacman -Sy --noconfirm git
git clone https://github.com/marcel-st/archinst
archinst/archinst install
```

Answer the questions (secrets login code, hostname, root password, disk),
confirm the disk wipe, reboot. Details: [docs/install.md](docs/install.md).

### Existing system (VPS)

As root (`sudo -i` first):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/marcel-st/archinst/main/bootstrap.sh)
archinst secrets
archinst base
archinst docker kopia
```

Details: [docs/deploy.md](docs/deploy.md).

## Commands

```
archinst install        step 1: partition, install Arch, apply base (Arch ISO only)
archinst base           baseline for every host, required before other modules
archinst <module>...    apply modules in the given order
archinst list           modules and when they were last applied on this host
archinst secrets        clone or update the secrets repo in /etc/archinst/secrets
archinst update         git pull archinst (and the secrets repo)
```

Every command is safe to re-run. Change the configuration, run the module
again, and the host converges to the new state.

## Modules

| Module | What it does |
|--------|--------------|
| `base` | Packages, mirrors, admin user with SSH keys and sudo, sshd hardening, firewall, system tweaks |
| `docker` | Docker, compose, buildx, ducker and `daemon.json` from secrets |
| `kopia` | Kopia backups to WebDAV with retention policy and a daily timer |
| `zfs` | OpenZFS through DKMS, rebuilt automatically on kernel updates |
| `sshguard` | Blocks SSH brute-force attempts |
| `lts-kernel` | Switches an existing GRUB host to `linux-lts` |

## Documentation

| Document | Contents |
|----------|----------|
| [docs/install.md](docs/install.md) | Step 1: ISO install, disk layout, unattended installs, troubleshooting |
| [docs/deploy.md](docs/deploy.md) | Step 2: what `base` and every module do, writing new modules |
| [docs/configuration.md](docs/configuration.md) | Every setting in `archinst.conf` and where to override it |
| [docs/secrets.md](docs/secrets.md) | Secrets repository layout, GitHub device login setup |
| [docs/migration.md](docs/migration.md) | Moving from the old `archlinux` / `deploy` / `secrets` repositories |

## Repository layout

```
archinst              CLI entry point
archinst.conf         default configuration
bootstrap.sh          clones archinst to /opt/archinst and links /usr/local/bin/archinst
lib/common.sh         shared helpers (logging, pacman, AUR, secrets, GitHub login)
lib/install.sh        step 1 installer
modules/*.sh          step 2 modules
examples/secrets/     templates for the private secrets repository
docs/                 documentation
```
