#!/usr/bin/env bash
# 06-pull-models.sh — pre-pull Ollama and HF models into persistent storage.
# Runs ephemeral containers so the engines don't need to be up yet.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
announce_script "06-pull-models.sh"

require_root
require_done 05-stack-config
load_config

if [ "$ENABLE_OLLAMA" = "yes" ] && [ -n "${OLLAMA_MODELS_PULL:-}" ]; then
    OLLAMA_DATA="$DATA_MOUNT/ollama"
    mkdir -p "$OLLAMA_DATA"
    step "Starting transient ollama container to pull models"
    docker rm -f ollama-puller 2>/dev/null || true
    docker run -d --name ollama-puller --gpus all \
        -v "$OLLAMA_DATA":/root/.ollama \
        ollama/ollama:latest >/dev/null
    info "Waiting for ollama API to be ready..."
    for _ in $(seq 1 30); do
        if docker exec ollama-puller ollama list >/dev/null 2>&1; then break; fi
        sleep 1
    done
    for tag in $OLLAMA_MODELS_PULL; do
        info "ollama pull $tag (this may take a while)"
        docker exec ollama-puller ollama pull "$tag" || warn "pull failed for $tag"
    done
    docker exec ollama-puller ollama list || true
    docker rm -f ollama-puller >/dev/null
    ok "Ollama models stored in $OLLAMA_DATA"
fi

if [ "$ENABLE_VLLM" = "yes" ] && [ -n "${VLLM_MODEL:-}" ]; then
    step "Pre-downloading vLLM model into HF cache"
    HF_CACHE="$DATA_MOUNT/vllm/hf-cache"
    mkdir -p "$HF_CACHE"
    HF_ARGS=()
    [ -n "${HF_TOKEN:-}" ] && HF_ARGS+=(-e "HF_TOKEN=$HF_TOKEN" -e "HUGGING_FACE_HUB_TOKEN=$HF_TOKEN")
    docker run --rm \
        -v "$HF_CACHE":/root/.cache/huggingface \
        "${HF_ARGS[@]}" \
        --entrypoint python3 \
        "vllm/vllm-openai:$VLLM_IMAGE_TAG" \
        -c "from huggingface_hub import snapshot_download; snapshot_download('$VLLM_MODEL')" \
        || warn "HF download failed — vLLM will try again at runtime."
    ok "vLLM model cached in $HF_CACHE"
fi

mark_done 06-pull-models
ok "Next: sudo scripts/07-stack-up.sh"
