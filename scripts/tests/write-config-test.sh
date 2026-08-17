#!/usr/bin/env bash
# write-config-test.sh — round-trip test for write_config in lib/common.sh:
# values with spaces, quotes, $, |, & and backslashes must survive
# write → source (set -u) → compare. Run by CI; safe to run locally.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
export CONFIG_FILE="$SCRATCH/config.env"
export STATE_DIR="$SCRATCH/.state"

# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

# The stack targets Ubuntu (GNU sed). On macOS/BSD, sed -i needs an explicit
# suffix — shim it so the identical sed expression is exercised locally too.
if ! sed --version >/dev/null 2>&1; then
    sed() { if [ "${1:-}" = "-i" ]; then shift; command sed -i '' "$@"; else command sed "$@"; fi; }
fi

KEYS=(ALLOWED_IPS OLLAMA_MODELS_PULL PASSWORD SIMPLE EMPTY)
# Exported because they are only read via indirect expansion (${!ref}),
# which shellcheck cannot see (would flag SC2034 otherwise).
export VAL_ALLOWED_IPS="1.2.3.4 5.6.7.8/32"
export VAL_OLLAMA_MODELS_PULL="gemma4:31b llama3.1:8b qwen2.5:14b"
export VAL_PASSWORD='p$a`s|s&w\o'\''rd"x'
export VAL_SIMPLE="plain"
export VAL_EMPTY=""

for k in "${KEYS[@]}"; do
    ref="VAL_$k"
    write_config "$k" "${!ref}"
done

# Upsert path: overwrite an existing key with another tricky value.
VAL_ALLOWED_IPS="9.9.9.9 10.0.0.0/8 fe80::1/64"
write_config ALLOWED_IPS "$VAL_ALLOWED_IPS"

# Source it exactly the way load_config does, under set -u.
set -a
# shellcheck source=/dev/null
. "$CONFIG_FILE"
set +a

rc=0
for k in "${KEYS[@]}"; do
    ref="VAL_$k"
    if [ "${!k}" = "${!ref}" ]; then
        ok "round-trip $k"
    else
        err "round-trip $k: got '${!k}' want '${!ref}'"
        rc=1
    fi
done
exit $rc
