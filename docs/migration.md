# Migrating from the old repositories

archinst replaces three repositories on the old Gitea server
(`git.xo.nl`, being decommissioned):

| Old | New |
|-----|-----|
| `archlinux` (`preinst.sh`, `postinst.sh`, archinstall config) | `archinst install` + `archinst base` |
| `deploy` (`deploy.sh` and its per-application folders) | `archinst <module>` |
| `secrets` | `marcel-st/secrets` on GitHub, same idea, slightly different layout |

## What changed and why

- **No archinstall.** Its JSON config format changes between releases, which
  broke the unattended install. archinst calls `pacstrap` directly, which has
  been stable for years.
- **No credentials typed per command.** The old scripts asked for the git
  username and password on every run and downloaded files with `curl -u`.
  Now the secrets repo is cloned once with a short device login code.
- **No encrypted `users.crypt`.** The root password is asked during install
  (or set as a hash with `ROOT_PASSWORD_HASH`). The admin user has no password
  at all; it logs in with SSH keys and has passwordless sudo.
- **Same result on every host.** The old `postinst.sh` only worked right after
  an archinstall install. `base` works on any Arch system and is safe to re-run.
- **LTS kernel from the start** instead of installing `linux` and swapping it
  for `linux-lts` afterwards. Existing hosts can use the `lts-kernel` module.
- **ZFS through DKMS** from the AUR instead of self-maintained
  `zfs-linux-lts` packages, which broke on every kernel update and were built
  with checksum and signature checks disabled.
- **Kopia from the AUR** (`kopia-bin`) instead of a self-maintained package,
  plus a backup timer; the old setup never scheduled backups.
- **Mirrors from reflector** with a weekly timer instead of a mirrorlist file
  in git.
- **sshd and firewall changes are guarded** against lockouts (see
  [deploy.md](deploy.md)).

## Bugs in the old scripts

Worth knowing if any host was set up with them:

- **Firewall did not restrict SSH.** In `iptables.rules`, the rule
  `-A INPUT -p tcp -m state --state NEW -m limit --limit 50/second ... -j ACCEPT`
  comes before the SSH rule with `-s <your IP>`, so every new TCP connection
  to any port was accepted (up to 50 per second). The SSH source restriction
  never took effect.
- **Firewall dropped local traffic.** `-A INPUT -s 127.0.0.0/8 -j DROP` comes
  before `-A INPUT -i lo -j ACCEPT`, so connections to `127.0.0.1` were dropped.
- `preinst.sh`: `REPO=https:/git.xo.nl/...` misses a slash.
- `postinst.sh`: writes `MAKEFLAGs` instead of `MAKEFLAGS`, so parallel
  builds were never enabled.
- `kopia/setup.sh`: uses `$KEEP_ANNUAL` while `setup.env` defines
  `BACKUP_ANNUAL`, and never sets a repository password.
- `pacman/install.sh`: downloads from another server (`git.xoservice.nl`).
- `docker/setup.sh`: `mkdir /etc/docker` fails when it exists; Docker was
  enabled but not started.

## Moving the secrets repository

Starting from the old `secrets` repository:

| Old file | New file | Action |
|----------|----------|--------|
| `users/ansible.pub` | `users/ansible.pub` | keep |
| `users/users.crypt` | | delete, no longer used |
| `arch/config.json` | | delete, archinstall is no longer used |
| `docker/setup.env` | `docker/daemon.json` | rename (old name still works) |
| `kopia/setup.env` | `kopia/setup.env` | keep; add `KOPIA_PASSWORD`, check `BACKUP_ANNUAL` |
| `iptables/iptables.rules` | `archinst.conf` | **replace** with `SSH_ALLOW_V4=(...)`, see below |
| `iptables/ip6tables.rules` | `archinst.conf` | **replace** with `SSH_ALLOW_V6=(...)` |
| `iptables/iptables.default` | | delete |
| `readme.md` | `readme.md` | keep |

The old iptables files contain the bugs above. Instead of fixing them, delete
them and let archinst generate the rules. Put the SSH source address from the
old file into `archinst.conf` in the secrets repo:

```bash
SSH_ALLOW_V4=("<address from the old iptables.rules>")
SSH_ALLOW_V6=("<address from the old ip6tables.rules>")
```

Be careful with IPv6: the old rule allowed a single home address, and home
IPv6 addresses change often. Allowing your whole prefix (e.g. `/56` or `/48`)
is more practical.

## Moving existing hosts

On a host set up with the old scripts:

```bash
sudo -i
bash <(curl -fsSL https://raw.githubusercontent.com/marcel-st/archinst/main/bootstrap.sh)
archinst secrets
archinst base
```

`base` takes over: same admin user and group (`sysadmin` / `admins`), keys
from the secrets repo, its own sudoers file. Afterwards remove the leftovers
of the old setup:

```bash
rm -f /usr/local/bin/deploy /usr/local/bin/deploy.bck   # old deploy script
rm -f /etc/sudoers.d/admins                             # replaced by 10-archinst
rm -f /etc/profile.d/mymotd.sh                          # old neofetch motd
```

If the host had Docker or Kopia, re-run `archinst docker` / `archinst kopia`.
For Kopia, an existing repository at `$BACKUP_STORAGE/<hostname>` is connected
to, not recreated; you need its existing password.

For ZFS, remove the old self-built packages first, then install the DKMS
version (pools are not affected):

```bash
pacman -Rdd zfs-linux-lts
archinst zfs
```
