#!/usr/bin/env bash
# 02-luks-volume.sh — create LUKS volume, keyfile, crypttab, fstab entries.
# DESTRUCTIVE: this wipes ${DATA_DEVICE}. Idempotent on subsequent runs.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
announce_script "02-luks-volume.sh"

require_root
require_done 00-preflight
load_config

step "Sanity checks"
[ -b "$DATA_DEVICE" ] || die "$DATA_DEVICE is not a block device. Check lsblk."
PART="${DATA_DEVICE}1"

apt-get install -y cryptsetup parted

# Detect if already a LUKS volume
if cryptsetup isLuks "$PART" 2>/dev/null; then
    info "$PART is already a LUKS volume — skipping format."
else
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

    step "LUKS format"
    info "You will be asked for a passphrase. SAVE IT in a password manager."
    cryptsetup luksFormat --type luks2 "$PART"
fi

step "Keyfile"
if [ ! -f "$LUKS_KEYFILE" ]; then
    dd if=/dev/urandom of="$LUKS_KEYFILE" bs=4096 count=1 status=none
    chmod 0400 "$LUKS_KEYFILE"
    info "Created $LUKS_KEYFILE — adding to LUKS keyslots (you'll be prompted for the passphrase)"
    cryptsetup luksAddKey "$PART" "$LUKS_KEYFILE"
else
    info "$LUKS_KEYFILE already exists; checking it can open the volume"
    cryptsetup --test-passphrase --key-file "$LUKS_KEYFILE" open "$PART" 2>/dev/null \
        || die "Existing keyfile cannot open $PART. Remove $LUKS_KEYFILE or fix manually."
fi

step "Opening volume"
if [ ! -e "/dev/mapper/$LUKS_NAME" ]; then
    cryptsetup open --key-file "$LUKS_KEYFILE" "$PART" "$LUKS_NAME"
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
UUID="$(blkid -s UUID -o value "$PART")"
LINE="$LUKS_NAME UUID=$UUID $LUKS_KEYFILE luks,nofail"
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

step "Updating initramfs"
update-initramfs -u

df -h "$DATA_MOUNT"
mark_done 02-luks-volume
warn "Back up $LUKS_KEYFILE OFF this VPS (e.g. base64 → password manager). Without it AND the passphrase, data is gone."
ok "Next: sudo scripts/03-docker.sh"
