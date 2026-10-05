# desc: SSHGuard brute-force protection (own nftables table, works next to the firewall)

pkg sshguard

cat >/etc/sshguard.conf <<CONF
# sshd-session is the log tag of OpenSSH >= 9.8
LOGREADER="LANG=C /usr/bin/journalctl -afb -p info -n1 -t sshd -t sshd-session -o cat"
BACKEND="/usr/lib/sshguard/sshg-fw-nft-sets"
THRESHOLD=30
BLOCK_TIME=120
DETECTION_TIME=1800
IPV4_SUBNET=32
IPV6_SUBNET=64
BLACKLIST_FILE=120:/var/db/sshguard/blacklist.db
WHITELIST_FILE=/etc/sshguard.whitelist
CONF
install -d /var/db/sshguard
printf '%s\n' 127.0.0.0/8 ::1 "${SSHGUARD_WHITELIST[@]}" >/etc/sshguard.whitelist

enable_units sshguard.service
if systemd_live; then systemctl restart sshguard; fi
