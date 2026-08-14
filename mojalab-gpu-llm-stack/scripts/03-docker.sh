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
# Remove any pre-existing Docker CE packages (from docker.com repo) that would
# conflict with Ubuntu's docker.io / docker-compose-v2 on file paths like
# /usr/libexec/docker/cli-plugins/docker-compose.
CE_PKGS=(docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin docker-ce-rootless-extras)
CE_INSTALLED=()
for p in "${CE_PKGS[@]}"; do
    if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed"; then
        CE_INSTALLED+=("$p")
    fi
done
if [ "${#CE_INSTALLED[@]}" -gt 0 ]; then
    info "Removing conflicting Docker CE packages: ${CE_INSTALLED[*]}"
    systemctl stop docker docker.socket 2>/dev/null || true
    apt-get purge -y "${CE_INSTALLED[@]}"
fi
# Disable docker.com apt source if present, so apt picks Ubuntu's docker.io.
if [ -f /etc/apt/sources.list.d/docker.list ]; then
    info "Disabling /etc/apt/sources.list.d/docker.list"
    mv /etc/apt/sources.list.d/docker.list /etc/apt/sources.list.d/docker.list.disabled
fi

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

step "Configuring containerd image store → $DATA_MOUNT/containerd"
# Docker 28+ uses the containerd image store by default: data-root then only
# holds containers and volumes, while IMAGES live under containerd's root
# (default /var/lib/containerd — the OS disk). Point containerd at the
# encrypted volume too, or images fill the OS disk and die with the VM.
CONTAINERD_ROOT="$DATA_MOUNT/containerd"
mkdir -p "$CONTAINERD_ROOT" /etc/containerd
systemctl stop containerd 2>/dev/null || true
if [ ! -s /etc/containerd/config.toml ]; then
    containerd config default > /etc/containerd/config.toml
fi
if grep -qE '^root = ' /etc/containerd/config.toml; then
    sed -i "s|^root = .*|root = \"$CONTAINERD_ROOT\"|" /etc/containerd/config.toml
else
    sed -i "1i root = \"$CONTAINERD_ROOT\"" /etc/containerd/config.toml
fi
if [ -d /var/lib/containerd ] && [ -n "$(ls -A /var/lib/containerd 2>/dev/null)" ] \
        && [ -z "$(ls -A "$CONTAINERD_ROOT" 2>/dev/null)" ]; then
    info "Migrating existing /var/lib/containerd contents to $CONTAINERD_ROOT"
    rsync -a /var/lib/containerd/ "$CONTAINERD_ROOT/"
    mv /var/lib/containerd "/var/lib/containerd.OLD.$(date +%s)"
fi

step "Making docker and containerd wait for $DATA_MOUNT"
for svc in docker containerd; do
    mkdir -p "/etc/systemd/system/${svc}.service.d"
    cat > "/etc/systemd/system/${svc}.service.d/wait-for-data.conf" <<EOF
[Unit]
RequiresMountsFor=$DATA_MOUNT
EOF
done
systemctl daemon-reload

step "Starting containerd and Docker"
systemctl enable --now containerd
systemctl enable --now docker

step "Verifying that images and containers land on $DATA_MOUNT"
ROOT_DIR="$(docker info -f '{{ .DockerRootDir }}')"
[ "$ROOT_DIR" = "$DOCKER_DATA" ] \
    || die "Docker Root Dir is '$ROOT_DIR', expected '$DOCKER_DATA'. Check /etc/docker/daemon.json."
if docker info 2>/dev/null | grep -q 'io.containerd.snapshotter'; then
    grep -q "^root = \"$CONTAINERD_ROOT\"" /etc/containerd/config.toml \
        || die "Docker uses the containerd image store but containerd root is not $CONTAINERD_ROOT."
fi
ok "Docker Root Dir: $ROOT_DIR — containerd root: $CONTAINERD_ROOT"

for old in /var/lib/docker.OLD.* /var/lib/containerd.OLD.*; do
    if [ -d "$old" ]; then
        warn "Old data left at $old — remove it manually when satisfied."
    fi
done

mark_done 03-docker
ok "Next: sudo scripts/04-nvidia-toolkit.sh"
