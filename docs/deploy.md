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

`update` only refreshes the secrets when it runs in a terminal (for the
device login) or with `GITHUB_TOKEN` set; otherwise it skips them with a
warning instead of waiting for a login nobody sees.

Regular package updates are plain `pacman -Syu`. AUR packages installed by a
module (kopia, zfs) are updated by running that module again.

## base

The baseline every host gets. In order:

1. **Hostname**: set from `HOST_NAME`, or asked with the current hostname as
   default.
2. **Root password**: when `ROOT_PASSWORD_HASH` is set (best in the secrets
   repo's `archinst.conf`), root gets that password, replacing for example
   the temporary password a VPS provider hands out. Empty = left as is.
3. **pacman**: enables `Color` and `ParallelDownloads`, updates
   `archlinux-keyring` and installs `kernel-modules-hook`, then does a full
   system upgrade. Writes `/etc/xdg/reflector/reflector.conf` (HTTPS mirrors
   in `MIRROR_COUNTRIES`, the 20 most recently synced, sorted by their
   mirror status score), refreshes the mirrorlist and
   enables the weekly `reflector.timer`. Then `BASE_PACKAGES`.
   Virtual machines also get `qemu-guest-agent`.

   `kernel-modules-hook` keeps the running kernel's modules when the kernel
   is upgraded, so the firewall and other modules keep working until the
   next reboot. When the running kernel has no modules at all (some VPS
   images upgrade the kernel without rebooting), `base` stops right away and
   asks you to reboot first.
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

With `FIREWALL="yes"` (default), `base` generates one nftables table,
`inet archinst`, for IPv4 and IPv6 alike, stores it in
`/etc/archinst/firewall.nft` and loads it at boot with
`archinst-firewall.service`. Only this table is ever replaced: Docker's and
sshguard's tables are left alone, so changing the firewall does not restart
Docker or its containers.

- incoming traffic is dropped by default, outgoing traffic is allowed
- loopback, established/related connections and limited ping are allowed
- ICMPv6 (needed for neighbour discovery) and DHCPv6 replies are allowed
- SSH (port 22) from `SSH_ALLOW`, or from anywhere when it is empty
- `OPEN_TCP_PORTS` and `OPEN_UDP_PORTS`, for host services **and** ports
  published by Docker (see [docker](#docker))
- rules from `/etc/archinst/nftables.d/*.nft`
- everything else is rejected

`SSH_ALLOW` takes IPv4 and IPv6 addresses and networks in one list. A protocol
without entries gets no SSH at all, so listing only IPv4 sources closes SSH
over IPv6. Example for a web server reached through a jump host:

```bash
SSH_ALLOW=("203.0.113.10" "2001:db8:1::10")
OPEN_TCP_PORTS=(80 443)
```

The old `SSH_ALLOW_V4`/`SSH_ALLOW_V6` still work (merged into `SSH_ALLOW`,
with a warning).

**Host-specific rules** go in `/etc/archinst/nftables.d/*.nft` on that host.
They are added to the generated ruleset and checked with it. Add rules to the
`custom_input` chain (host services) or `custom_forward` (Docker published
ports), for example a metrics port only for the LAN:

```
add rule inet archinst custom_input tcp dport 9100 ip saddr 10.100.0.0/16 accept
```

Run `archinst firewall apply` after changing ports or snippets; a full `base`
is not needed. Rules are checked with `nft -c` before they are loaded, and
nothing is reloaded when the generated ruleset did not change.

**Lockout protection.** Every change is loaded *on trial*: unless it is
confirmed within `FIREWALL_CONFIRM_TIMEOUT` seconds (120), a timer restores
the previous rules. Until it is confirmed, a reboot also boots with the
previous rules.

- In a terminal, archinst asks. Over SSH, first open a **new** SSH session to
  the host to prove you can still get in, then answer `y`.
- Without a terminal (Ansible, `ssh host sudo archinst base </dev/null`)
  archinst prints a warning and continues. Confirm from a **new** SSH
  connection: `ssh host sudo archinst firewall confirm`. For Ansible, run that
  step with a fresh connection (not a reused ControlPersist socket).
- `archinst firewall` shows the loaded table, a change on trial and Docker
  ports that are blocked; `archinst firewall rollback` restores the previous
  rules right away.

**Hosts on the old iptables firewall** switch over on the next `base` (or
`archinst firewall apply`): on trial only the old INPUT rules are cleared,
Docker's iptables chains stay untouched. Confirming disables the `iptables`
and `ip6tables` services and renames their rules files to
`*.rules.archinst-old`; a rollback restores the old INPUT rules.

Set `FIREWALL="no"` on hosts where something else filters traffic (an Azure
network security group, a hardware firewall) and you do not want a host
firewall. The `inet archinst` table is then removed.

## docker

- Installs `DOCKER_PACKAGES` (docker, docker-compose, docker-buildx, ducker).
- Copies `secrets/docker/daemon.json` to `/etc/docker/daemon.json` when it exists.
- Adds the admin user to the `docker` group and creates `/opt/docker` for
  compose projects.
- Enables and (re)starts Docker, so a changed `daemon.json` takes effect.

**Published ports follow `OPEN_TCP_PORTS`.** Docker forwards published ports
(`-p 8080:80`, `ports:` in compose) with its own NAT rules, past the input
chain. The archinst firewall filters them in its forward chain instead: a
published port is reachable from outside only when the *published* port
(8080 here) is in `OPEN_TCP_PORTS`/`OPEN_UDP_PORTS`. Traffic between
containers, from containers to the internet and from the host itself is not
affected.

So on a reverse-proxy host set `OPEN_TCP_PORTS=(80 443)` in
`/etc/archinst/archinst.conf`. An admin UI that is published only now and
then (81, 8000) stays closed; reach it through a proxy rule or an SSH tunnel
via the jump host (`ssh -L 8081:localhost:81 host`).
`archinst firewall` (and every apply) warns about published ports that are
blocked.

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
