# shellcheck shell=bash
# Common helpers sourced by every step script.

set -euo pipefail

# --- paths ---------------------------------------------------------------
SCRIPT_NAME="$(basename "${BASH_SOURCE[1]:-$0}")"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_ROOT/config.env}"
STATE_DIR="${STATE_DIR:-$PROJECT_ROOT/.state}"
mkdir -p "$STATE_DIR"

# --- colors --------------------------------------------------------------
if [ -t 1 ]; then
    C_RESET="$(printf '\033[0m')"
    C_BLUE="$(printf '\033[1;34m')"
    C_GREEN="$(printf '\033[1;32m')"
    C_YELLOW="$(printf '\033[1;33m')"
    C_RED="$(printf '\033[1;31m')"
    C_DIM="$(printf '\033[2m')"
else
    C_RESET=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_DIM=""
fi

step()  { printf '\n%s==>%s %s%s%s\n' "$C_BLUE" "$C_RESET" "$C_BLUE" "$*" "$C_RESET"; }
info()  { printf '%s[i]%s %s\n'        "$C_DIM"   "$C_RESET" "$*"; }
ok()    { printf '%s[ok]%s %s\n'       "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%s[!]%s %s\n'        "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()   { printf '%s[x]%s %s\n'        "$C_RED"   "$C_RESET" "$*" >&2; }
die()   { err "$*"; exit 1; }

# Announce the script that is running (the user asked for this explicitly).
announce_script() {
    local name="${1:-$SCRIPT_NAME}"
    printf '\n%s┌─────────────────────────────────────────────────────────────┐%s\n' "$C_BLUE" "$C_RESET"
    printf '%s│%s Running: %-50s %s│%s\n' "$C_BLUE" "$C_RESET" "$name" "$C_BLUE" "$C_RESET"
    printf '%s└─────────────────────────────────────────────────────────────┘%s\n' "$C_BLUE" "$C_RESET"
}

# --- prompts -------------------------------------------------------------
# prompt_default VAR_NAME "prompt text" "default value"
prompt_default() {
    local __var="$1" __msg="$2" __def="${3:-}" __ans
    if [ -n "${!__var:-}" ]; then
        info "$__var already set: ${!__var}"
        return 0
    fi
    if [ -n "$__def" ]; then
        read -r -p "$__msg [$__def]: " __ans || true
        __ans="${__ans:-$__def}"
    else
        read -r -p "$__msg: " __ans || true
    fi
    printf -v "$__var" '%s' "$__ans"
    # shellcheck disable=SC2163  # intentional dynamic export
    export "${__var?}"
}

prompt_yesno() {
    local __var="$1" __msg="$2" __def="${3:-n}" __ans __defprompt
    if [ -n "${!__var:-}" ]; then return 0; fi
    case "$__def" in y|Y|yes) __defprompt="Y/n";; *) __defprompt="y/N";; esac
    read -r -p "$__msg [$__defprompt]: " __ans || true
    __ans="${__ans:-$__def}"
    case "$__ans" in y|Y|yes|YES) printf -v "$__var" 'yes';; *) printf -v "$__var" 'no';; esac
    # shellcheck disable=SC2163
    export "${__var?}"
}

prompt_secret() {
    local __var="$1" __msg="$2" __ans
    if [ -n "${!__var:-}" ]; then return 0; fi
    read -r -s -p "$__msg: " __ans || true; echo
    printf -v "$__var" '%s' "$__ans"
    # shellcheck disable=SC2163
    export "${__var?}"
}

# --- config persistence --------------------------------------------------
load_config() {
    [ -f "$CONFIG_FILE" ] || die "config.env not found. Run scripts/00-preflight.sh first."
    set -a
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
    set +a
}

# write_config KEY VALUE — upsert into config.env
write_config() {
    local key="$1" val="$2"
    touch "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    if grep -qE "^${key}=" "$CONFIG_FILE"; then
        # escape & and / for sed replacement
        local esc; esc="$(printf '%s' "$val" | sed -e 's/[&/\]/\\&/g')"
        sed -i "s|^${key}=.*|${key}=${esc}|" "$CONFIG_FILE"
    else
        printf '%s=%s\n' "$key" "$val" >> "$CONFIG_FILE"
    fi
}

# --- state ---------------------------------------------------------------
mark_done()   { touch "$STATE_DIR/$1.done"; ok "step '$1' marked complete"; }
is_done()     { [ -f "$STATE_DIR/$1.done" ]; }
require_done() {
    local s="$1"
    is_done "$s" || die "Prerequisite step '$s' not completed. Run scripts/${s}.sh first."
}

# --- guards --------------------------------------------------------------
require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        die "This script must run as root (try: sudo $0)"
    fi
}

require_not_root() {
    if [ "$(id -u)" -eq 0 ]; then
        die "Do NOT run this script as root."
    fi
}

confirm() {
    local msg="${1:-Continue?}" ans
    read -r -p "$msg [type 'YES' to continue]: " ans || true
    [ "$ans" = "YES" ] || die "Aborted by user."
}
