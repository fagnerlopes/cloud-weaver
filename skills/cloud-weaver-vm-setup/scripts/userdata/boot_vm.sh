#!/bin/bash
# Userdata (cloud-init) bootstrap for a cloud-weaver VM.
# Installs Docker, mounts the attached data disk at /data, hardens SSH
# (fail2ban) and pins DNS to the CloudStack virtual router so .internal
# hostnames resolve reliably.
set -euo pipefail

# --- Use the global Ubuntu mirror to avoid regional mirror sync issues ---
sed -i 's|br\.archive\.ubuntu\.com|archive.ubuntu.com|g' /etc/apt/sources.list.d/*.sources 2>/dev/null || \
  sed -i 's|br\.archive\.ubuntu\.com|archive.ubuntu.com|g' /etc/apt/sources.list 2>/dev/null || true

# --- fail2ban: block SSH brute-force attempts ---
apt-get update -qq
apt-get install -y -qq fail2ban jq curl
cat > /etc/fail2ban/jail.local << 'F2BEOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3

[sshd]
enabled = true
mode = aggressive
F2BEOF
systemctl restart fail2ban

# --- Docker (recipes deploy with `docker compose up` directly) ---
apt-get install -y -qq docker.io docker-compose-plugin
systemctl enable --now docker

# --- Wait for the attached data disk and format/mount it at /data ---
DEVICE="/dev/vdb"
MOUNT_POINT="/data"

echo "Waiting for $DEVICE..."
TIMEOUT=600
INTERVAL=5
ELAPSED=0
while [ ! -b "$DEVICE" ]; do
  if [ $ELAPSED -ge $TIMEOUT ]; then
    echo "ERROR: $DEVICE not found after ${TIMEOUT}s"
    exit 1
  fi
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done
echo "$DEVICE found after ${ELAPSED}s"

if ! blkid "$DEVICE" >/dev/null 2>&1; then
  echo "Formatting $DEVICE as ext4..."
  mkfs.ext4 -q "$DEVICE"
fi

mkdir -p "$MOUNT_POINT"
mount "$DEVICE" "$MOUNT_POINT"

if ! grep -q "$DEVICE" /etc/fstab; then
  echo "$DEVICE $MOUNT_POINT ext4 defaults,nofail 0 2" >> /etc/fstab
fi

# --- Force all DNS queries through the CloudStack virtual router ---
# The virtual router resolves .internal hostnames directly and forwards
# external queries upstream, avoiding systemd-resolved failover to public
# DNS servers that return NXDOMAIN for .internal names.
GATEWAY=$(ip -4 -json route show default | jq -r '.[0].gateway')
IFACE=$(ip -4 -json route show default | jq -r '.[0].dev')

NETFILE=$(networkctl status "$IFACE" --json=short | jq -r '.NetworkFile // empty')
if [ -n "$NETFILE" ]; then
  DROPIN_DIR="/etc/systemd/network/$(basename "$NETFILE").d"
  mkdir -p "$DROPIN_DIR"
  cat > "$DROPIN_DIR/dns-override.conf" << EOF
[DHCPv4]
UseDNS=false

[Network]
DNS=${GATEWAY}
EOF
  networkctl reload && networkctl reconfigure "$IFACE"
fi

echo "Bootstrap complete: Docker ready, /data mounted."