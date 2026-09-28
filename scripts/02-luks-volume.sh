#!/usr/bin/env bash
# 02-luks-volume.sh — create the encrypted data volume: LUKS on a raw block
# device (default), or on a loopback file when DATA_DEVICE is not a block
# device ("single-disk mode", for providers that only give you the OS disk).
# Creates keyfile, crypttab and fstab entries.
# DESTRUCTIVE on first run against a block device. Idempotent afterwards.
#
# Automation hook: if LUKS_PASSPHRASE is set in the environment, format and
# key enrollment run non-interactively (used by CI; for humans the
# interactive prompt is safer — env vars leak into logs and process lists).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
announce_script "02-luks-volume.sh"

require_root
require_done 00-preflight
load_config

apt-get install -y cryptsetup parted

step "Sanity checks"
if [ -b "$DATA_DEVICE" ]; then
    MODE='block'
    # Devices whose name ends in a digit (nvme0n1, mmcblk0) get a 'p' separator
    # before the partition number; classic sdX devices do not.
    case "$DATA_DEVICE" in
        *[0-9]) PART="${DATA_DEVICE}p1" ;;
        *)      PART="${DATA_DEVICE}1"  ;;
    esac
    CRYPT_SRC="$PART"
    info "Block-device mode: LUKS on $PART"
else
    MODE='file'
    # Single-disk mode trade-offs (see docs/guide.md): if the VM dies the
    # file dies with it — off-site backups become the only safety net — and
    # a keyfile stored on the SAME disk makes at-rest encryption against
    # disk disposal mostly decorative; prefer a passphrase-only setup there.
    [ -n "${DATA_IMG_SIZE:-}" ] \
        || die "DATA_DEVICE ($DATA_DEVICE) is not a block device. For single-disk mode set DATA_IMG_SIZE (e.g. 300G) in config.env."
    # An explicit unit is mandatory: 'fallocate -l 300' means 300 BYTES and
    # cryptsetup only tells you much later ("Device is too small").
    case "$DATA_IMG_SIZE" in
        *[0-9][MGTmgt]) : ;;
        *) die "DATA_IMG_SIZE='$DATA_IMG_SIZE' needs a unit suffix (e.g. 300G)." ;;
    esac
    CRYPT_SRC="$DATA_DEVICE"
    if [ ! -f "$DATA_DEVICE" ]; then
        warn "Single-disk mode: the encrypted volume will be a $DATA_IMG_SIZE file on the system disk."
        warn "If this VM is terminated, the file is gone with it: keep off-site backups."
        confirm "Create backing file $DATA_DEVICE ($DATA_IMG_SIZE)?"
        fallocate -l "$DATA_IMG_SIZE" "$DATA_DEVICE"
        chmod 600 "$DATA_DEVICE"
    fi
    # Guard existing files too: a botched earlier run may have left a tiny one.
    IMG_BYTES="$(stat -c%s "$DATA_DEVICE")"
    [ "$IMG_BYTES" -ge $((64 * 1024 * 1024)) ] \
        || die "$DATA_DEVICE is only $IMG_BYTES bytes — too small for LUKS2 (min ~64M). Remove it, fix DATA_IMG_SIZE, and re-run."
    info "Single-disk mode: LUKS directly on $DATA_DEVICE"
fi

# Detect if already a LUKS volume
if cryptsetup isLuks "$CRYPT_SRC" 2>/dev/null; then
    info "$CRYPT_SRC is already a LUKS volume — skipping format."
else
    if [ "$MODE" = block ]; then
        warn "About to WIPE $DATA_DEVICE and create a new LUKS volume."
        echo "  Device: $DATA_DEVICE"
        lsblk -no NAME,SIZE,MOUNTPOINT "$DATA_DEVICE" || true
        confirm "Wipe and format $DATA_DEVICE ?"

        step "Wiping signatures and partitioning"
        wipefs -a "$DATA_DEVICE"
        parted "$DATA_DEVICE" --script mklabel gpt mkpart primary 0% 100%
        # Wait for partition device node to appear
        udevadm settle
        [ -b "$PART" ] || die "Partition $PART did not appear after parted."
    fi

    step "LUKS format"
    if [ -n "${LUKS_PASSPHRASE:-}" ]; then
        info "Using LUKS_PASSPHRASE from the environment (non-interactive)."
        printf '%s' "$LUKS_PASSPHRASE" | cryptsetup luksFormat --type luks2 -q --key-file=- "$CRYPT_SRC"
    else
        info "You will be asked for a passphrase. SAVE IT in a password manager."
        cryptsetup luksFormat --type luks2 "$CRYPT_SRC"
    fi
fi

step "Keyfile"
if [ ! -f "$LUKS_KEYFILE" ]; then
    dd if=/dev/urandom of="$LUKS_KEYFILE" bs=4096 count=1 status=none
    chmod 0400 "$LUKS_KEYFILE"
    if [ -n "${LUKS_PASSPHRASE:-}" ]; then
        info "Created $LUKS_KEYFILE — enrolling it via LUKS_PASSPHRASE"
        printf '%s' "$LUKS_PASSPHRASE" | cryptsetup luksAddKey --key-file=- "$CRYPT_SRC" "$LUKS_KEYFILE"
    else
        info "Created $LUKS_KEYFILE — adding to LUKS keyslots (you'll be prompted for the passphrase)"
        cryptsetup luksAddKey "$CRYPT_SRC" "$LUKS_KEYFILE"
    fi
else
    info "$LUKS_KEYFILE already exists; checking it can open the volume"
    cryptsetup --test-passphrase --key-file "$LUKS_KEYFILE" open "$CRYPT_SRC" 2>/dev/null \
        || die "Existing keyfile cannot open $CRYPT_SRC. Remove $LUKS_KEYFILE or fix manually."
fi

step "Opening volume"
if [ ! -e "/dev/mapper/$LUKS_NAME" ]; then
    cryptsetup open --key-file "$LUKS_KEYFILE" "$CRYPT_SRC" "$LUKS_NAME"
else
    info "/dev/mapper/$LUKS_NAME already open"
fi

step "Filesystem and mount"
if ! blkid "/dev/mapper/$LUKS_NAME" | grep -q TYPE=; then
    mkfs.ext4 -L "$(basename "$DATA_MOUNT")" "/dev/mapper/$LUKS_NAME"
fi
mkdir -p "$DATA_MOUNT"
mountpoint -q "$DATA_MOUNT" || mount "/dev/mapper/$LUKS_NAME" "$DATA_MOUNT"

step "Persisting in /etc/crypttab"
if [ "$MODE" = block ]; then
    UUID="$(blkid -s UUID -o value "$PART")"
    LINE="$LUKS_NAME UUID=$UUID $LUKS_KEYFILE luks,nofail"
else
    # crypttab accepts a plain file path as source; systemd-cryptsetup
    # attaches the loop device by itself at boot.
    LINE="$LUKS_NAME $DATA_DEVICE $LUKS_KEYFILE luks,nofail"
fi
if ! grep -qE "^${LUKS_NAME}[[:space:]]" /etc/crypttab 2>/dev/null; then
    echo "$LINE" >> /etc/crypttab
else
    info "/etc/crypttab already has an entry for $LUKS_NAME"
fi

step "Persisting in /etc/fstab"
FSTAB_LINE="/dev/mapper/$LUKS_NAME $DATA_MOUNT ext4 defaults,nofail 0 2"
if ! grep -qE "[[:space:]]${DATA_MOUNT}[[:space:]]" /etc/fstab; then
    cp /etc/fstab "/etc/fstab.bak.$(date +%s)"
    echo "$FSTAB_LINE" >> /etc/fstab
else
    info "/etc/fstab already has an entry for $DATA_MOUNT"
fi

if [ "$MODE" = file ]; then
    step "Installing boot-time fallback unit (single-disk mode)"
    # systemd's crypttab generator does support file-backed sources, but it
    # has proven unreliable across reboots in the field (volume left locked
    # after boot, twice). This oneshot is belt-and-suspenders: an idempotent
    # unlock+mount ordered before the container runtimes, which already wait
    # on the mountpoint via their RequiresMountsFor drop-ins.
    cat > "/etc/systemd/system/luks-file-${LUKS_NAME}.service" <<EOF
[Unit]
Description=Unlock and mount ${DATA_MOUNT} (single-disk LUKS fallback)
After=local-fs.target systemd-cryptsetup@${LUKS_NAME}.service
Before=containerd.service docker.service
ConditionPathExists=${DATA_DEVICE}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'cryptsetup status ${LUKS_NAME} >/dev/null 2>&1 || cryptsetup open --key-file ${LUKS_KEYFILE} ${DATA_DEVICE} ${LUKS_NAME}; mountpoint -q ${DATA_MOUNT} || mount /dev/mapper/${LUKS_NAME} ${DATA_MOUNT}'

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "luks-file-${LUKS_NAME}.service"
    ok "fallback unit luks-file-${LUKS_NAME}.service installed and enabled"
fi

step "Updating initramfs"
update-initramfs -u

df -h "$DATA_MOUNT"
mark_done 02-luks-volume
warn "Back up $LUKS_KEYFILE OFF this VPS (e.g. base64 → password manager). Without it AND the passphrase, data is gone."
if [ "$MODE" = file ]; then
    warn "Single-disk mode: schedule OFF-SITE backups (DB dumps + config.env) — this volume dies with the VM."
fi
ok "Next: sudo scripts/03-docker.sh"
