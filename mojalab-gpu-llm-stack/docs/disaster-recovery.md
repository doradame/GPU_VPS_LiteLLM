# Disaster recovery

When the VPS dies, or you shelve/unshelve and something breaks, the recovery
procedure is essentially "attach the disk to a new VM and replay the host-side
setup". The encrypted volume already contains:

- The compose project (`${DATA_MOUNT}/stack/`)
- The Docker data-root (`${DATA_MOUNT}/docker/`) — containers and volumes
- The containerd image store (`${DATA_MOUNT}/containerd/`) — images (Docker 28+)
- The PostgreSQL data (`${DATA_MOUNT}/stack/pgdata/`)
- Nightly DB dumps (`${DATA_MOUNT}/stack/backups/`, 14 most recent)
- Ollama models (`${DATA_MOUNT}/ollama/`)
- vLLM HF cache (`${DATA_MOUNT}/vllm/hf-cache/`)
- Let's Encrypt certs (Docker named volumes — also under the data-root)

What does NOT come with the volume:

- The NVIDIA driver
- Docker itself
- The NVIDIA Container Toolkit
- The LUKS keyfile (`/root/${LUKS_BASENAME}.key`) — back this up off the VPS
- The systemd drop-in `/etc/systemd/system/docker.service.d/wait-for-data.conf`
- The backup cron `/etc/cron.d/llm-db-backup` (re-created by step 05)
- `/etc/docker/daemon.json` pointing to the new data-root
- `/etc/containerd/config.toml` pointing containerd's root at the volume
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
   sudo ./scripts/08-test.sh
   ```

6. **Optional**: rerun `99-ufw.sh` if you used UFW originally.

## Recovering onto a different GPU

Nothing on the encrypted volume is GPU-specific — models are just files,
images are generic, the DB doesn't care. What matters on the new card is
**total VRAM** and **architecture age**:

| New GPU | What to do |
|---|---|
| Same VRAM class as before | Nothing — bring the stack up as-is |
| More VRAM | Works as-is (fractions become conservative). Optionally raise `VLLM_MAX_MODEL_LEN` or `--max-num-seqs` to use the headroom |
| Less VRAM | Recompute the `GPU_MEM_UTIL` fractions (below). Model weights are absolute GB: a model whose weights exceed its budget cannot load at any fraction — swap it for a smaller one |
| Architecture newer than the pinned vLLM release | vLLM may lack kernels for it (`no kernel image available for execution on the device`): bump `VLLM_IMAGE_TAG` (and possibly `NVIDIA_DRIVER_PKG`) in `config.env`, re-run step 05, `up -d` |

Rule of thumb: `GPU_MEM_UTIL = needed_budget_GB / total_VRAM_GB`, where a
model's budget is its weights plus a few GB of KV cache. On a shared GPU,
remember the second instance's cap is **cumulative** (first instance's
fraction + its own share) — see the guide's two-model section.

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
