#!/usr/bin/env bash
# 04-nvidia-toolkit.sh — install NVIDIA Container Toolkit and configure
# the Docker runtime for GPU passthrough.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
announce_script "04-nvidia-toolkit.sh"

require_root
require_done 03-docker

step "Adding NVIDIA Container Toolkit apt repo"
# NOTE: the ubuntu22.04 path is intentional — NVIDIA publishes one repo per
# LTS base; packages are forward-compatible with newer Ubuntu releases.
install -d -m 0755 /usr/share/keyrings
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -fsSL https://nvidia.github.io/libnvidia-container/ubuntu22.04/libnvidia-container.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list

step "Installing nvidia-container-toolkit"
apt-get update
apt-get install -y nvidia-container-toolkit

step "Configuring Docker runtime"
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker
docker info | grep -E "Runtimes|Docker Root Dir"

step "Smoke test: GPU visible from a container"
if docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi; then
    ok "GPU is visible inside containers."
else
    die "GPU smoke test failed. Check 'docker info' Runtimes and 'nvidia-smi' on host."
fi

mark_done 04-nvidia-toolkit
ok "Next: sudo scripts/05-stack-config.sh"
