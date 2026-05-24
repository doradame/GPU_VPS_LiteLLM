# Disaster recovery

When the VPS dies, or you shelve/unshelve and something breaks, the recovery
procedure is essentially "attach the disk to a new VM and replay the host-side
setup". The encrypted volume already contains:

- The compose project (`${DATA_MOUNT}/stack/`)
- The Docker data-root (`${DATA_MOUNT}/docker/`) — images and volumes
- The PostgreSQL data (`${DATA_MOUNT}/stack/pgdata/`)
- Ollama models (`${DATA_MOUNT}/ollama/`)
- vLLM HF cache (`${DATA_MOUNT}/vllm/hf-cache/`)
- Let's Encrypt certs (Docker named volumes — also under the data-root)

What does NOT come with the volume:

- The NVIDIA driver
- Docker itself
- The NVIDIA Container Toolkit
- The LUKS keyfile (`/root/${LUKS_BASENAME}.key`) — back this up off the VPS
- The systemd drop-in `/etc/systemd/system/docker.service.d/wait-for-data.conf`
- `/etc/docker/daemon.json` pointing to the new data-root
- `/etc/crypttab` and `/etc/fstab` entries

## Procedure

1. **Spawn a new Ubuntu VPS** and attach the existing data disk.
   Verify the device name with `lsblk` (it may not be `/dev/sdb` on the new VM).

2. **Clone this repo** onto the new VM and copy your saved `config.env`
   (or run `./scripts/00-preflight.sh` again to recreate it — same answers).

3. **Restore the LUKS keyfile** from your offline backup:

   ```bash
   # If you saved it as base64:
   base64 -d > /root/${LUKS_BASENAME}.key < your-backup.b64
   sudo chmod 0400 /root/${LUKS_BASENAME}.key
   ```

   Without the keyfile you can still open the volume manually with the
   passphrase (`cryptsetup open /dev/sdb1 ${LUKS_NAME}` will prompt).

4. **Re-run the host-side scripts.** Skip the destructive parts:

   ```bash
   sudo ./scripts/01-nvidia-driver.sh       # then REBOOT
   sudo ./scripts/02-luks-volume.sh         # detects existing LUKS, skips wipe
   sudo ./scripts/03-docker.sh              # daemon.json + wait-for-mount
   sudo ./scripts/04-nvidia-toolkit.sh
   ```

   Step 02 is idempotent: it detects an existing LUKS volume and only
   re-adds the keyfile / crypttab / fstab entries.

   Step 03 is idempotent: if `/var/lib/docker` is empty (fresh install) and
   the data-root on the encrypted volume already has content, Docker picks
   up the existing images and volumes.

5. **Skip the config and model steps** — they're already on the disk:

   ```bash
   # The compose project is intact. Just bring it up:
   cd ${DATA_MOUNT}/stack
   docker compose --env-file .env up -d
   ./scripts/08-test.sh
   ```

6. **Optional**: rerun `99-ufw.sh` if you used UFW originally.

## Time budget

- First time: 30-45 minutes (driver install dominates).
- Second time: 15-20 minutes.
- After three rehearsals: 10-15 minutes.

## Backup checklist (off the VPS)

Keep these in a password manager / offline storage:

- `LUKS_KEYFILE` (base64-encoded, plus the original LUKS passphrase as fallback)
- `config.env` (or at least `LITELLM_MASTER_KEY` and `POSTGRES_PASSWORD`)
- The contents of `${DATA_MOUNT}/stack/.env` (same secrets, different file)

A `tar -czf` of `${DATA_MOUNT}/stack/` (excluding `pgdata/` if you prefer a
dedicated DB dump) is a complete backup of the routing layer.
