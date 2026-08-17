#!/usr/bin/env bash
# 99-ufw.sh — OPTIONAL host firewall via UFW.
#
# Why it's optional: most VPS providers already give you a firewall at the
# edge. Running UFW *inside* the VM is belt-and-suspenders.
#
# Gotchas handled here:
#   1. `ufw enable` flushes iptables and wipes Docker's DOCKER-USER chain.
#      We restart docker after enabling UFW to recreate it.
#   2. UFW ships with DEFAULT_FORWARD_POLICY="DROP", which breaks outbound
#      traffic from containers (apt, go get, etc.). We flip it to ACCEPT.
#      Host INPUT remains DROP, so the host stays protected.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
announce_script "99-ufw.sh"

require_root

step "Installing ufw"
apt-get update
apt-get install -y ufw

step "Allowing SSH, HTTP, HTTPS"
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp   # HTTP/3

step "Default policies"
ufw default deny incoming
ufw default allow outgoing

step "Flipping DEFAULT_FORWARD_POLICY to ACCEPT (required for Docker)"
sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

step "Enabling UFW (non-interactive)"
ufw --force enable
ufw reload

step "Restarting Docker to recreate iptables chains flushed by UFW"
systemctl restart docker

ufw status verbose
ok "UFW configured. INPUT is restrictive, FORWARD is delegated to Docker."
