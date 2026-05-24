#!/usr/bin/env bash
# 03-docker.sh — install Docker, move data-root to $DATA_MOUNT/docker,
# make docker.service wait for the encrypted mount.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
announce_script "03-docker.sh"

require_root
require_done 02-luks-volume
load_config

mountpoint -q "$DATA_MOUNT" || die "$DATA_MOUNT is not mounted."

step "Installing Docker"
apt-get update
apt-get install -y docker.io docker-compose-v2

step "Adding invoking user to docker group"
TARGET_USER="${SUDO_USER:-${USER:-root}}"
if [ "$TARGET_USER" != "root" ]; then
    usermod -aG docker "$TARGET_USER" || true
    info "User '$TARGET_USER' added to 'docker' group (re-login required for it to take effect)"
fi

DOCKER_DATA="$DATA_MOUNT/docker"
step "Configuring data-root → $DOCKER_DATA"
mkdir -p "$DOCKER_DATA"

if [ -f /etc/docker/daemon.json ] && grep -q "$DOCKER_DATA" /etc/docker/daemon.json; then
    info "daemon.json already points to $DOCKER_DATA"
else
    systemctl stop docker docker.socket 2>/dev/null || true
    if [ -d /var/lib/docker ] && [ ! -L /var/lib/docker ] && [ "$(ls -A /var/lib/docker 2>/dev/null)" ]; then
        info "Migrating existing /var/lib/docker contents to $DOCKER_DATA"
        rsync -aP /var/lib/docker/ "$DOCKER_DATA/"
        mv /var/lib/docker "/var/lib/docker.OLD.$(date +%s)"
    fi
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<EOF
{
  "data-root": "$DOCKER_DATA"
}
EOF
fi

step "Configuring docker.service to wait for $DATA_MOUNT"
mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/wait-for-data.conf <<EOF
[Unit]
RequiresMountsFor=$DATA_MOUNT
EOF
systemctl daemon-reload

step "Starting Docker"
systemctl enable --now docker
docker info | grep "Docker Root Dir"

for old in /var/lib/docker.OLD.*; do
    if [ -d "$old" ]; then
        warn "Old data root left at $old — remove it manually when satisfied."
    fi
done

mark_done 03-docker
ok "Next: sudo scripts/04-nvidia-toolkit.sh"
