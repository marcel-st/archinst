# desc: Kopia backups to WebDAV with a scheduled snapshot timer (secrets/kopia/setup.env)

env_file=$(secret kopia/setup.env) || die "missing secrets/kopia/setup.env (run 'archinst secrets')"
# shellcheck source=/dev/null
source "$env_file"
: "${BACKUP_STORAGE:?} ${BACKUP_USER:?} ${BACKUP_PASS:?}"

aur kopia-bin

# Repository encryption password; asked once, kopia remembers it after connecting
if [[ -n ${KOPIA_PASSWORD:-} ]]; then export KOPIA_PASSWORD; fi

if kopia repository status &>/dev/null; then
	log "Kopia repository already connected"
else
	repo_args=(webdav --url "$BACKUP_STORAGE/$(cat /etc/hostname)"
		--webdav-username "$BACKUP_USER" --webdav-password "$BACKUP_PASS")
	log "Connecting to kopia repository (creating it when it does not exist)"
	kopia repository connect "${repo_args[@]}" || kopia repository create "${repo_args[@]}"
fi

kopia policy set --global \
	--keep-latest "${BACKUP_LATEST:-10}" --keep-hourly "${BACKUP_HOURLY:-0}" \
	--keep-daily "${BACKUP_DAILY:-7}" --keep-weekly "${BACKUP_WEEKLY:-4}" \
	--keep-monthly "${BACKUP_MONTHLY:-6}" --keep-annual "${BACKUP_ANNUAL:-1}" \
	--compression "${BACKUP_COMPRESS:-zstd}"
kopia policy set /etc --add-ignore pacman.d/gnupg

cat >/etc/systemd/system/kopia-backup.service <<UNIT
[Unit]
Description=Kopia snapshot of ${BACKUP_PATHS[*]}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/kopia snapshot create ${BACKUP_PATHS[*]}
UNIT
cat >/etc/systemd/system/kopia-backup.timer <<UNIT
[Unit]
Description=Scheduled kopia snapshot

[Timer]
OnCalendar=$BACKUP_SCHEDULE
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
UNIT
if systemd_live; then systemctl daemon-reload; fi
enable_units kopia-backup.timer
log "Run a first backup now with: systemctl start kopia-backup"
