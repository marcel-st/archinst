# Secrets

archinst is public. Everything that must stay private lives in the private
repository `marcel-st/secrets`, which archinst clones to
`/etc/archinst/secrets` (owned by root, mode 700).

```bash
archinst secrets    # clone the first time, git pull afterwards
archinst update     # also pulls the secrets
```

During `archinst install` the secrets are fetched on the live ISO and copied
into the new system.

## Logging in without typing a token

Installs often happen through a console that cannot paste: Proxmox noVNC, a
cloud provider's web console, a physical keyboard. Typing a 90-character
GitHub token there is error-prone, so archinst uses GitHub's *device login*.
The console shows:

```
  Open   https://github.com/login/device
  Enter  62E7-71D5
```

Open the link on your phone or laptop, where you are already logged in to
GitHub, enter the code and approve. archinst continues by itself.

The token it receives:

- can only **read** the repositories the GitHub App is installed on (only `secrets`)
- is kept in memory of the running archinst process, never written to disk
  or to `.git/config`
- expires after 8 hours

### One-time setup: create the GitHub App

1. GitHub → **Settings** → **Developer settings** → **GitHub Apps** →
   **New GitHub App**.
   - **GitHub App name**: anything unique, e.g. `archinst-marcel-st`
   - **Homepage URL**: `https://github.com/marcel-st/archinst`
   - **Callback URL**: leave empty
   - **Expire user authorization tokens**: keep checked
   - **Enable Device Flow**: **check**
   - **Webhook → Active**: **uncheck**
   - **Repository permissions → Contents**: **Read-only**. Leave everything
     else at *No access* (Metadata read-only is added automatically).
   - **Where can this GitHub App be installed?**: *Only on this account*
   - **Create GitHub App**.
2. On the app page note the **Client ID** (starts with `Iv`). A client secret
   and private key are *not* needed.
3. **Install App** (left menu) → your account → **Only select repositories** →
   `secrets` → **Install**.
4. Put the Client ID in [`archinst.conf`](../archinst.conf) in this repository
   and push:

   ```bash
   GITHUB_APP_CLIENT_ID="Iv23li..."
   ```

   The Client ID is a public identifier, not a secret; anyone who has it can
   only start a login that *you* still have to approve. It must be in this
   repository (or `/etc/archinst/archinst.conf`), not in the secrets repo,
   because it is needed to fetch the secrets repo.

Test it on any machine with archinst: `sudo archinst secrets`.

### Alternatives

- **Token in the environment**: `export GITHUB_TOKEN=github_pat_...` before
  running archinst. Handy over SSH, where you can paste.
- **No app configured** (`GITHUB_APP_CLIENT_ID=""`): git asks for a username
  and password; use a personal access token as the password.

To revoke access, uninstall or delete the GitHub App, or revoke the
authorization under GitHub → Settings → Applications → Authorized GitHub Apps.

## Repository layout

Every file is optional. A module that needs a missing file stops with a clear
message. Templates are in [`examples/secrets/`](../examples/secrets).

```
secrets/
├── archinst.conf              config overrides for all hosts
├── users/
│   └── *.pub                  SSH public keys for the admin user
├── iptables/
│   ├── iptables.rules         complete custom IPv4 ruleset (optional)
│   └── ip6tables.rules        complete custom IPv6 ruleset (optional)
├── docker/
│   └── daemon.json            /etc/docker/daemon.json
└── kopia/
    └── setup.env              backup target, credentials and retention
```

### archinst.conf

Same format as the main [configuration](configuration.md); loaded after the
defaults and before the host's `/etc/archinst/archinst.conf`. Good place for
settings you want on every host but not in public, such as:

```bash
SSH_ALLOW_V4=("203.0.113.10")
SSH_ALLOW_V6=("2001:db8:1234::/48")
```

### users/*.pub

One OpenSSH public key per file (for example `ansible.pub`, `laptop.pub`).
All of them, plus `ADMIN_SSH_KEYS`, become the admin user's
`authorized_keys`. Removing a file and re-running `archinst base` removes
that key from the host.

### iptables/*.rules

Only needed when the generated firewall is not enough. The file is used as-is
with `iptables-restore` / `ip6tables-restore` and must be a complete ruleset
(`*filter` ... `COMMIT`). It replaces the generated rules for that protocol;
`SSH_ALLOW_*` and `OPEN_*_PORTS` no longer apply to it. Always keep a rule
accepting SSH from somewhere you can reach.

### docker/daemon.json

Copied to `/etc/docker/daemon.json`. Must be valid JSON; Docker refuses to
start otherwise. The old name `docker/setup.env` is still accepted.

### kopia/setup.env

Shell variables read by the `kopia` module:

| Variable | Required | Default | Meaning |
|----------|----------|---------|---------|
| `BACKUP_STORAGE` | yes | | WebDAV base URL; the host's hostname is appended |
| `BACKUP_USER` | yes | | WebDAV username |
| `BACKUP_PASS` | yes | | WebDAV password |
| `KOPIA_PASSWORD` | no | asked | repository encryption password |
| `BACKUP_LATEST` | no | 10 | snapshots to keep regardless of age |
| `BACKUP_HOURLY` | no | 0 | hourly snapshots to keep |
| `BACKUP_DAILY` | no | 7 | daily snapshots to keep |
| `BACKUP_WEEKLY` | no | 4 | weekly snapshots to keep |
| `BACKUP_MONTHLY` | no | 6 | monthly snapshots to keep |
| `BACKUP_ANNUAL` | no | 1 | yearly snapshots to keep |
| `BACKUP_COMPRESS` | no | zstd | kopia compression algorithm |

Use single quotes around values with special characters.

## Security notes

- Secrets are stored in plain text on every host in `/etc/archinst/secrets`,
  readable by root only. Anyone with root on one host can read all secrets.
  Keep per-host credentials (e.g. a WebDAV user per host) where that matters.
- The secrets repo should contain only what hosts need. Do not keep a private
  key there that grants access to other machines.
- Remove the secrets from a host with `rm -rf /etc/archinst/secrets`; modules
  that need them will then ask you to run `archinst secrets` again.
