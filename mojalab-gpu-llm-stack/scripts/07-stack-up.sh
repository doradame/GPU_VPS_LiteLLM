#!/usr/bin/env bash
# 07-stack-up.sh — bring up the compose stack.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
announce_script "07-stack-up.sh"

require_root
require_done 05-stack-config
load_config

STACK_DIR="$DATA_MOUNT/stack"
cd "$STACK_DIR"

step "Pulling images"
docker compose --env-file .env pull --ignore-buildable || \
    docker compose --env-file .env pull

step "Building local images (litellm + Pillow)"
docker compose --env-file .env build

step "Starting services"
# After a disaster recovery the surviving containers reference the compose
# network of the previous host, which no longer exists ("network ... not
# found"). If a plain up fails, recreate everything: data lives in bind
# mounts and named volumes, so this is safe.
if ! docker compose --env-file .env up -d; then
    warn "up failed — recreating containers (stale state from a previous host?)"
    docker compose --env-file .env down --remove-orphans
    docker compose --env-file .env up -d
fi

step "Status"
docker compose --env-file .env ps

info "Tailing logs for 20s (Ctrl+C to detach earlier)..."
timeout 20 docker compose --env-file .env logs -f || true

mark_done 07-stack-up
ok "Next: scripts/08-test.sh"
