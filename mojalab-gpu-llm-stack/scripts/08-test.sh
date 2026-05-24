#!/usr/bin/env bash
# 08-test.sh — smoke-test the public endpoint.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
announce_script "08-test.sh"

require_done 07-stack-up
load_config

URL="https://$DOMAIN"

step "Liveness probe"
curl -fsS "$URL/health/liveliness" && echo

step "Models list"
curl -fsS "$URL/v1/models" -H "Authorization: Bearer $LITELLM_MASTER_KEY" | head -c 2000
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
curl -fsS "$URL/v1/chat/completions" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in one short sentence.\"}]}"
echo

ok "All probes returned 2xx. Admin UI: $URL/ui (master key required to log in)."
mark_done 08-test
