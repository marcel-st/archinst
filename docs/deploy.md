# Step 2: deploying hosts

Step 2 works on every Arch Linux system: one installed with
[`archinst install`](install.md), or an existing machine such as a VPS where
you cannot install the OS yourself.

## Getting started on an existing system

Log in, become root and fetch archinst:

```bash
sudo -i
bash <(curl -fsSL https://raw.githubusercontent.com/marcel-st/archinst/main/bootstrap.sh)
```

`sudo bash <(curl ...)` does not work: sudo closes the file descriptor that
`<(...)` creates. Become root first.

The bootstrap installs git if needed, clones archinst to `/opt/archinst` and
links `/usr/local/bin/archinst`. Then:

```bash
archinst secrets     # once per host, see secrets.md
archinst base        # always first
archinst docker      # any modules you need
```

Hosts installed by `archinst install` already have archinst, the secrets and
`base`; only add modules.

## Running modules

```bash
archinst base                 # one module
archinst docker kopia zfs     # several, in this order
archinst list                 # what exists and when it was applied here
```

- Modules run as root. Each runs in its own subshell; if one fails, archinst
  stops and later modules are not run.
- `base` must have been applied once before any other module.
- Every module is safe to re-run. It overwrites the files it manages and
  converges to the same state, so applying changed configuration is simply
  running the module again.
- `archinst list` shows the time each module was last applied, stored in
  `/etc/archinst/state/<module>`.

### Keeping hosts up to date

```bash
archinst update     # git pull archinst and the secrets repo
archinst base       # re-apply after config or code changes
```

Regular package updates are plain `pacman -Syu`. AUR packages installed by a
module (kopia, zfs) are updated by running that module again.

## base

The baseline every host gets. In order:

1. **Hostname**: set from `HOST_NAME`, or asked with the current hostname as
   default.
2. **Root password**: when `ROOT_PASSWORD_HASH` is set (best in the secrets
   repo's `archinst.conf`), root gets that password, replacing for example
   the temporary password a VPS provider hands out. Empty = left as is.
3. **pacman**: enables `Color` and `ParallelDownloads`, writes
   `/etc/xdg/reflector/reflector.conf` (HTTPS mirrors in `MIRROR_COUNTRIES`,
   sorted by speed), refreshes the mirrorlist and enables the weekly
   `reflector.timer`. Then a full system upgrade and `BASE_PACKAGES`.
   Virtual machines also get `qemu-guest-agent`.
4. **Admin user** (`ADMIN_USER`, group `ADMIN_GROUP`): created when missing,
   without a usable password. The group gets passwordless sudo through
   `/etc/sudoers.d/10-archinst`. `~/.ssh/authorized_keys` is **replaced** by
   all keys from `secrets/users/*.pub` plus `ADMIN_SSH_KEYS`; keys added by
   hand are removed on the next run, so add them to the secrets repo instead.
5. **sshd**: `/etc/ssh/sshd_config.d/10-archinst.conf` disables root login,
   password and keyboard-interactive login. This step is **skipped with a
   warning when the admin user has no SSH key**, so you cannot lock yourself
   out. The config is validated with `sshd -t` before sshd is reloaded.
6. **Firewall**: see below.
7. **Tweaks**:
   - `MAKEFLAGS="-j$(nproc)"` in `/etc/makepkg.conf.d/10-archinst.conf`
   - `tmp.mount` masked, so `/tmp` is on disk; large AUR builds do not fit in RAM
   - empty `/etc/motd` and `fastfetch` on interactive login
   - `vi` linked to `nvim` when no `vi` exists
   - `cronie`, `systemd-timesyncd`, `fstrim.timer` and `reflector.timer` enabled

### Firewall

With `FIREWALL="yes"` (default), `base` writes `/etc/iptables/iptables.rules`
and `/etc/iptables/ip6tables.rules` and enables the `iptables` and `ip6tables`
services. The rules are generated from the configuration:

- incoming traffic is dropped by default, outgoing traffic is allowed
- loopback, established/related connections and limited ping are allowed
- IPv6: ICMPv6 (needed for neighbour discovery) and DHCPv6 replies are allowed
- SSH (port 22) from `SSH_ALLOW_V4` / `SSH_ALLOW_V6`, or from anywhere when empty
- `OPEN_TCP_PORTS` and `OPEN_UDP_PORTS`
- everything else is rejected

Example for a web server that only allows SSH from home:

```bash
SSH_ALLOW_V4=("203.0.113.10")
OPEN_TCP_PORTS=(80 443)
```

To use a completely custom ruleset instead, put `iptables/iptables.rules`
and/or `iptables/ip6tables.rules` in the secrets repo. Rules are always
checked with `iptables-restore --test` before they are installed.

**Lockout protection:** when `base` runs over SSH, the IPv4 rules are applied
with `iptables-apply`. Open a *second* SSH session to check you can still get
in, then answer `y`. Without an answer within 30 seconds the old rules are
restored and archinst stops.

Restarting the firewall flushes Docker's iptables chains, so Docker is
restarted afterwards when it is running. If you reload the firewall by hand,
run `systemctl restart docker` too.

Set `FIREWALL="no"` on hosts where the provider already filters traffic (for
example an Azure network security group) and you do not want a host firewall.

## docker

- Installs `DOCKER_PACKAGES` (docker, docker-compose, docker-buildx, ducker).
- Copies `secrets/docker/daemon.json` to `/etc/docker/daemon.json` when it exists.
- Adds the admin user to the `docker` group and creates `/opt/docker` for
  compose projects.
- Enables and (re)starts Docker, so a changed `daemon.json` takes effect.

## kopia

Backups with [Kopia](https://kopia.io) to a WebDAV server, one repository per
host at `$BACKUP_STORAGE/<hostname>`.

- Requires `secrets/kopia/setup.env` (see [secrets.md](secrets.md)).
- Builds `kopia-bin` from the AUR.
- Connects to the repository, or creates it when it does not exist yet. The
  repository encryption password comes from `KOPIA_PASSWORD`, or is asked
  once. **Keep this password safe; without it the backups cannot be restored.**
- Sets the global retention policy and compression from `setup.env`.
- Installs `kopia-backup.service` and `kopia-backup.timer`, which snapshot
  `BACKUP_PATHS` on `BACKUP_SCHEDULE` (default daily, randomly delayed up to
  an hour).

Useful commands:

```bash
systemctl start kopia-backup       # back up now
journalctl -u kopia-backup         # last backup runs
kopia snapshot list                # existing snapshots
kopia restore <snapshot-id> /tmp/restore
```

## zfs

- Installs headers for every installed kernel and `dkms`.
- Builds `zfs-utils` and `zfs-dkms` from the AUR. DKMS rebuilds the kernel
  module on every kernel update, so ZFS keeps working after upgrades. Stay on
  `linux-lts`: OpenZFS often lags behind the newest mainline kernel.
- Loads the module at boot and enables `zfs.target`, `zfs-import-cache`,
  `zfs-mount` and `zfs-zed`.

Pools are never created automatically, because that wipes disks:

```bash
zpool create -o ashift=12 data raidz1 /dev/disk/by-id/...   # new pool
zpool import data                                           # existing pool
zpool set cachefile=/etc/zfs/zpool.cache data               # import at boot
systemctl enable --now zfs-scrub-monthly@data.timer
```

Use `/dev/disk/by-id/` paths, not `/dev/sdX`, so pools survive device
renumbering.

## sshguard

- Installs SSHGuard and writes `/etc/sshguard.conf`. It reads sshd logs from
  the journal (both `sshd` and the `sshd-session` tag used by OpenSSH 9.8+).
- Blocks offenders in its own nftables table, so it works next to the
  firewall without changing its rules.
- Never blocks localhost or `SSHGUARD_WHITELIST`.

Check blocked addresses with `nft list table ip sshguard`.

## lts-kernel

For existing GRUB systems that were not installed by archinst. Installs
`linux-lts` (and its headers when `linux-headers` is installed), regenerates
the GRUB config and, after confirmation, removes the regular `linux` kernel.
Reboot afterwards. Systems using another bootloader must switch by hand.

## Writing a module

Create `modules/<name>.sh`. The first line is the description shown by
`archinst list`:

```bash
# desc: Nginx reverse proxy

pkg nginx
if f=$(secret nginx/site.conf); then
	install -m 640 "$f" /etc/nginx/conf.d/site.conf
fi
enable_units nginx.service
if systemd_live; then systemctl reload nginx; fi
```

The script is sourced as root with `set -Eeuo pipefail`, the configuration
loaded and these helpers from `lib/common.sh` available:

| Helper | Use |
|--------|-----|
| `pkg <pkgs...>` | `pacman -S --needed --noconfirm` |
| `aur <pkgs...>` | build and install from the AUR as the admin user; rebuilds only when the AUR version changed |
| `secret <path>` | prints the path of a file in the secrets repo, fails when it is missing |
| `enable_units <units...>` | `systemctl enable`, plus start when systemd is running |
| `systemd_live` | true on a booted system, false inside `arch-chroot` (during step 1) |
| `ask VAR "Question" default` | prompt, but only when `VAR` is empty |
| `confirm "Question?"` | yes/no, automatically yes with `ASSUME_YES="yes"` |
| `log`, `warn`, `die` | output; `die` stops the module |

Guidelines:

- Make the module idempotent: running it twice must give the same result.
- Remember it may run inside `arch-chroot` during step 1 (via
  `INSTALL_MODULES`): use `enable_units` and guard restarts with `systemd_live`.
- Put defaults for new settings in `archinst.conf`, secrets in the secrets repo.
