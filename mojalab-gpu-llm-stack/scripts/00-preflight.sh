#!/usr/bin/env bash
# 00-preflight.sh — collect configuration, write config.env, sanity checks.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

announce_script "00-preflight.sh"
step "Collecting configuration"

# If config.env already exists, load it so prompts skip filled values.
if [ -f "$CONFIG_FILE" ]; then
    info "Existing config.env found — values already set will be kept."
    set -a
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
    set +a
fi

# OS sanity
if ! grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null; then
    warn "This stack is tested on Ubuntu/Debian. You appear to be on something else."
fi

step "Volume and mountpoint"
prompt_default DATA_DEVICE  "Raw block device for the encrypted data volume"  "/dev/sdb"
prompt_default DATA_MOUNT   "Mountpoint for the unlocked volume"               "/srv/llm"
LUKS_BASENAME="$(basename "$DATA_MOUNT")"
prompt_default LUKS_NAME    "LUKS mapper name"                                 "${LUKS_BASENAME}_crypt"
prompt_default LUKS_KEYFILE "Root-owned keyfile path"                          "/root/${LUKS_BASENAME}.key"

step "Public endpoint"
prompt_default DOMAIN       "Public FQDN (A record must point to this VPS)"    "llm.example.com"
prompt_default ACME_EMAIL   "Email for Let's Encrypt notifications"            "admin@example.com"
prompt_default ALLOWED_IPS  "Space-separated allowed IPs/CIDRs"                "1.2.3.4 5.6.7.8/32"

step "Engines"
prompt_yesno ENABLE_OLLAMA "Enable Ollama (containerized)?" "y"
prompt_yesno ENABLE_VLLM   "Enable vLLM (containerized)?"   "n"
if [ "$ENABLE_OLLAMA" = "no" ] && [ "$ENABLE_VLLM" = "no" ]; then
    die "At least one engine must be enabled."
fi

if [ "$ENABLE_OLLAMA" = "yes" ]; then
    prompt_default OLLAMA_IMAGE_TAG   "Ollama image tag (PIN to a release!)" "0.32.6"
    prompt_default OLLAMA_MODELS_PULL "Ollama models to pull (space-separated tags)" "gemma4:31b"
    prompt_default OLLAMA_KEEP_ALIVE  "OLLAMA_KEEP_ALIVE"        "24h"
    prompt_default OLLAMA_MAX_LOADED_MODELS "OLLAMA_MAX_LOADED_MODELS" "2"
    prompt_default OLLAMA_NUM_PARALLEL "OLLAMA_NUM_PARALLEL"     "1"
fi

if [ "$ENABLE_VLLM" = "yes" ]; then
    prompt_default VLLM_IMAGE_TAG     "vLLM image tag (PIN to a release!)" "v0.8.5"
    prompt_default VLLM_MODEL         "HF model id"                        "Qwen/Qwen2.5-7B-Instruct-AWQ"
    prompt_default VLLM_SERVED_NAME   "Name exposed to LiteLLM"            "qwen2.5-7b"
    prompt_default VLLM_GPU_MEM_UTIL  "GPU memory utilization (0.0-1.0)"   "0.85"
    prompt_default VLLM_MAX_MODEL_LEN "Max model context length"           "8192"
    prompt_default HF_TOKEN           "HF token (empty if model is public)" ""
fi

step "NVIDIA driver"
prompt_default NVIDIA_DRIVER_PKG "NVIDIA driver apt package" "nvidia-driver-580-server"

step "LiteLLM image"
prompt_default LITELLM_IMAGE "LiteLLM container image (PIN!)" "ghcr.io/berriai/litellm:v1.83.14-stable.patch.3"

# Persist everything
step "Writing $CONFIG_FILE"
mkdir -p "$(dirname "$CONFIG_FILE")"
touch "$CONFIG_FILE"; chmod 600 "$CONFIG_FILE"
for v in DATA_DEVICE DATA_MOUNT LUKS_NAME LUKS_KEYFILE \
         DOMAIN ACME_EMAIL ALLOWED_IPS \
         ENABLE_OLLAMA ENABLE_VLLM \
         OLLAMA_IMAGE_TAG OLLAMA_MODELS_PULL OLLAMA_KEEP_ALIVE OLLAMA_MAX_LOADED_MODELS OLLAMA_NUM_PARALLEL \
         VLLM_IMAGE_TAG VLLM_MODEL VLLM_SERVED_NAME VLLM_GPU_MEM_UTIL VLLM_MAX_MODEL_LEN HF_TOKEN \
         NVIDIA_DRIVER_PKG LITELLM_IMAGE; do
    write_config "$v" "${!v:-}"
done

step "Summary"
echo "  Device:     $DATA_DEVICE"
echo "  Mount:      $DATA_MOUNT"
echo "  Domain:     $DOMAIN"
echo "  Allowed:    $ALLOWED_IPS"
echo "  Ollama:     $ENABLE_OLLAMA  (models: ${OLLAMA_MODELS_PULL:-none})"
echo "  vLLM:       $ENABLE_VLLM   (model: ${VLLM_MODEL:-none})"
echo
warn "Review $CONFIG_FILE before proceeding."
mark_done 00-preflight
echo
ok "Next: sudo scripts/01-nvidia-driver.sh"
