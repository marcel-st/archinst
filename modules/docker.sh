# desc: Docker engine + compose; daemon.json from secrets/docker/daemon.json

pkg "${DOCKER_PACKAGES[@]}"

if f=$(secret docker/daemon.json) || f=$(secret docker/setup.env); then
	log "Installing daemon.json from secrets"
	install -d /etc/docker
	install -m 644 "$f" /etc/docker/daemon.json
fi

usermod -aG docker "$ADMIN_USER"
install -d -o "$ADMIN_USER" -g "$ADMIN_GROUP" /opt/docker
enable_units docker.service
# Pick up a changed daemon.json on re-runs
if systemd_live; then systemctl restart docker; fi
