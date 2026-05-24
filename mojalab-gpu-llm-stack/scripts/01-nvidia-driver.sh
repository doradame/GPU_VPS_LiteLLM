#!/usr/bin/env bash
# 01-nvidia-driver.sh — install NVIDIA driver on the host.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
announce_script "01-nvidia-driver.sh"

require_root
require_done 00-preflight
load_config

step "Installing build prerequisites"
apt-get update
apt-get install -y build-essential dkms "linux-headers-$(uname -r)"

step "Blacklisting nouveau"
cat > /etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
update-initramfs -u

step "Installing $NVIDIA_DRIVER_PKG"
if ! dpkg -l "$NVIDIA_DRIVER_PKG" >/dev/null 2>&1; then
    apt-get install -y "$NVIDIA_DRIVER_PKG"
else
    info "$NVIDIA_DRIVER_PKG already installed"
fi

step "Enabling persistence daemon"
systemctl enable --now nvidia-persistenced || warn "nvidia-persistenced not installed yet (will be available after reboot)"

mark_done 01-nvidia-driver
warn "REBOOT REQUIRED. After reboot, run: nvidia-smi  — then continue with 02-luks-volume.sh"
