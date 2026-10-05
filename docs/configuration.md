# Configuration

All settings are bash variables. Defaults are in [`archinst.conf`](../archinst.conf)
in this repository. Two files can override them; each one loaded later wins:

| Order | File | Use for |
|-------|------|---------|
| 1 | `archinst.conf` (this repo) | defaults, public |
| 2 | `archinst.conf` in the secrets repo | my settings for all hosts that should not be public (SSH source addresses, ...) |
| 3 | `/etc/archinst/archinst.conf` | settings for one host (open ports, extra modules, ...) |

Only set what you want to change, for example in `/etc/archinst/archinst.conf`:

```bash
OPEN_TCP_PORTS=(80 443)
FIREWALL="yes"
```

Lists are bash arrays: `(a b c)`, with quotes around items containing spaces.
To extend a default list instead of replacing it, use `+=`:

```bash
BASE_PACKAGES+=(tmux jq)
```

`GITHUB_APP_CLIENT_ID`, `SECRETS_REPO` and `SECRETS_DIR` are needed *before*
the secrets repo is fetched, so they only take effect from this repository or
`/etc/archinst/archinst.conf`, not from the secrets repo.

## Repositories

| Variable | Default | Meaning |
|----------|---------|---------|
| `ARCHINST_REPO` | `https://github.com/marcel-st/archinst.git` | this repository (`bootstrap.sh` reads it from the environment) |
| `SECRETS_REPO` | `https://github.com/marcel-st/secrets.git` | private secrets repository |
| `SECRETS_DIR` | `/etc/archinst/secrets` | where the secrets are cloned (mode 700) |
| `GITHUB_APP_CLIENT_ID` | empty | Client ID of the GitHub App for device login, see [secrets.md](secrets.md). Empty: git asks for username + token |

## System

| Variable | Default | Meaning |
|----------|---------|---------|
| `HOST_NAME` | empty | hostname; empty means ask (current hostname as default) |
| `TIMEZONE` | `Europe/Amsterdam` | path below `/usr/share/zoneinfo` (install only) |
| `LOCALE` | `en_US.UTF-8` | system locale (install only) |
| `KEYMAP` | `us` | console keymap (install only) |
| `MIRROR_COUNTRIES` | `NL,DE` | comma-separated countries for reflector |
| `BASE_PACKAGES` | see `archinst.conf` | packages installed by `base` |

## Admin user

| Variable | Default | Meaning |
|----------|---------|---------|
| `ADMIN_USER` | `sysadmin` | user for SSH access, Ansible and AUR builds |
| `ADMIN_GROUP` | `admins` | primary group, gets passwordless sudo |
| `ADMIN_SSH_KEYS` | `()` | extra public keys, added to `secrets/users/*.pub` |

## Firewall

| Variable | Default | Meaning |
|----------|---------|---------|
| `FIREWALL` | `yes` | `no` leaves the firewall alone |
| `SSH_ALLOW_V4` | `()` | IPv4 addresses/networks allowed to SSH; empty = anywhere |
| `SSH_ALLOW_V6` | `()` | same for IPv6 |
| `OPEN_TCP_PORTS` | `()` | TCP ports open to everyone, e.g. `(80 443)` |
| `OPEN_UDP_PORTS` | `()` | UDP ports open to everyone |

These are ignored for a protocol when the secrets repo contains
`iptables/iptables.rules` (IPv4) or `iptables/ip6tables.rules` (IPv6).

## Installer (step 1)

| Variable | Default | Meaning |
|----------|---------|---------|
| `INSTALL_DISK` | empty | target disk, e.g. `/dev/vda`; empty = auto-detect, ask when there are several |
| `ROOT_FS` | `xfs` | `xfs` or `ext4` |
| `ROOT_PASSWORD_HASH` | empty | SHA-512 hash from `openssl passwd -6`; empty = ask |
| `INSTALL_MODULES` | `()` | modules applied after `base`, e.g. `(docker sshguard)` |
| `ASSUME_YES` | `no` | `yes` answers every yes/no question with yes, including the disk wipe |

## Modules

| Variable | Default | Used by | Meaning |
|----------|---------|---------|---------|
| `DOCKER_PACKAGES` | `(docker docker-compose docker-buildx ducker)` | docker | packages to install |
| `BACKUP_PATHS` | `(/etc /opt /root)` | kopia | directories to snapshot |
| `BACKUP_SCHEDULE` | `daily` | kopia | systemd `OnCalendar` value, e.g. `*-*-* 02:00` |
| `SSHGUARD_WHITELIST` | `()` | sshguard | addresses/networks never blocked |

Backup credentials and retention are not configured here but in
`secrets/kopia/setup.env`, see [secrets.md](secrets.md).
