#!/usr/bin/env bash
# 08-test.sh — smoke-test the public endpoint.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
announce_script "08-test.sh"

# The stack dir is root-owned and .env is mode 600, and docker compose reads
# .env automatically — so this script needs root like the others.
require_root
require_done 07-stack-up
load_config

STACK_DIR="$DATA_MOUNT/stack"
cd "$STACK_DIR"

step "Checking service health first"
docker compose --env-file .env ps
# Every service has a healthcheck; don't probe until they all pass.
# (model loading into VRAM takes minutes — that's normal, not a hang)
if STATUS="$(docker compose --env-file .env ps --format '{{.Service}} {{.Health}}' 2>/dev/null)"; then
    NOT_HEALTHY="$(printf '%s\n' "$STATUS" | awk '$2 != "healthy" {print $1}')"
    if [ -n "$NOT_HEALTHY" ]; then
        die "Not healthy yet: $(printf '%s' "$NOT_HEALTHY" | tr '\n' ' '). Retry when 'docker compose --env-file .env ps' shows every service healthy."
    fi
    ok "all services healthy"
else
    warn "could not read health status (old compose?) — proceeding anyway"
fi

# Caddy blocks anything outside ALLOWED_IPS with 403, so probing the public
# URL from the VPS itself would fail. Run probes from inside the litellm
# container instead, hitting the app directly on localhost:4000.
dex() {
    docker compose exec -T litellm "$@"
}

# Use python (always present in the LiteLLM image) to avoid depending on curl.
http_get() {
    local url="$1" auth="${2:-}"
    dex python -c '
import sys, urllib.request
req = urllib.request.Request(sys.argv[1])
if len(sys.argv) > 2 and sys.argv[2]:
    req.add_header("Authorization", "Bearer " + sys.argv[2])
sys.stdout.write(urllib.request.urlopen(req, timeout=30).read().decode())
' "$url" "$auth"
}

http_post_json() {
    local url="$1" auth="$2" body="$3"
    dex python -c '
import sys, urllib.request
data = sys.argv[3].encode()
req = urllib.request.Request(sys.argv[1], data=data, method="POST")
req.add_header("Content-Type", "application/json")
req.add_header("Authorization", "Bearer " + sys.argv[2])
sys.stdout.write(urllib.request.urlopen(req, timeout=120).read().decode())
' "$url" "$auth" "$body"
}

BASE="http://localhost:4000"

step "Liveness probe (internal)"
http_get "$BASE/health/liveliness" && echo

step "Models list (internal)"
http_get "$BASE/v1/models" "$LITELLM_MASTER_KEY" | head -c 2000
echo

step "Chat completion (first enabled model)"
MODEL=""
if [ "$ENABLE_OLLAMA" = "yes" ] && [ -n "${OLLAMA_MODELS_PULL:-}" ]; then
    first_tag="$(echo "$OLLAMA_MODELS_PULL" | awk '{print $1}')"
    MODEL="$(echo "$first_tag" | tr ':' '-' | tr '[:upper:]' '[:lower:]')"
elif [ "$ENABLE_VLLM" = "yes" ]; then
    MODEL="$VLLM_SERVED_NAME"
fi
[ -n "$MODEL" ] || die "No model available to test."

info "Using model: $MODEL"
http_post_json "$BASE/v1/chat/completions" "$LITELLM_MASTER_KEY" \
    "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in one short sentence.\"}]}"
echo

if [ "${ENABLE_VLLM2:-no}" = "yes" ] && [ -n "${VLLM2_SERVED_NAME:-}" ]; then
    step "Chat completion (second vLLM model)"
    info "Using model: $VLLM2_SERVED_NAME"
    http_post_json "$BASE/v1/chat/completions" "$LITELLM_MASTER_KEY" \
        "{\"model\":\"$VLLM2_SERVED_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in one short sentence.\"}]}"
    echo
fi

step "Caddy public endpoint (expect 403 from this host unless its IP is in ALLOWED_IPS)"
HTTP_CODE="$(curl -ksS -o /dev/null -w '%{http_code}' "https://$DOMAIN/health/liveliness" || true)"
case "$HTTP_CODE" in
    200) info "Public endpoint reachable from this host (its IP is in ALLOWED_IPS)." ;;
    403) info "Caddy is up and gating correctly (403 from non-allowlisted IP)." ;;
    *)   warn "Unexpected status from https://$DOMAIN: $HTTP_CODE" ;;
esac

ok "All probes returned 2xx. Admin UI: https://$DOMAIN/ui (master key required to log in)."
mark_done 08-test
