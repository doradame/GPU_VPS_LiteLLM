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

step "Sweeping containers of disabled services"
# Disabling a profile (e.g. ENABLE_VLLM2=no) does NOT stop a container that
# is already running, and --remove-orphans ignores it because the service is
# still defined in the compose file. Compare running containers against the
# services active under the current profiles and remove the leftovers.
PROJECT="$(basename "$STACK_DIR")"
ACTIVE_SERVICES="$(docker compose --env-file .env config --services)"
docker ps -a --filter "label=com.docker.compose.project=$PROJECT" \
    --format '{{.ID}} {{.Label "com.docker.compose.service"}}' \
| while read -r cid svc; do
    if ! printf '%s\n' "$ACTIVE_SERVICES" | grep -qx "$svc"; then
        warn "service '$svc' is disabled in the current profiles — removing its container"
        docker rm -f "$cid" >/dev/null
    fi
done

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
