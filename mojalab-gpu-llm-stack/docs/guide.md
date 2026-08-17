# GPU VPS LLM Stack — Full Guide

> **Status: untested / work in progress.** This guide describes the intended
> procedure; the scripts that implement it have been linted but not yet run
> end-to-end on a real VPS. Treat every command as a draft until you have
> verified it in your own environment.

A reproducible procedure for setting up a production-grade local LLM proxy on a
GPU VPS. Designed for ephemeral VMs that you shelve, unshelve, and occasionally
lose entirely. All persistent state lives on a LUKS-encrypted secondary volume
so that disaster recovery is "attach the disk to a new VM, run a handful of
scripts, done".

This guide explains *what* each step does and *why*. The actual work is done by
the numbered scripts under [`scripts/`](../scripts/); each script announces
itself on startup and refuses to run out of order, so you can follow along
without re-deriving anything.

## What you get

- **NVIDIA GPU** exposed to Docker containers via the NVIDIA Container Toolkit
- **Ollama** and/or **vLLM**, both running in containers with GPU passthrough
- **LiteLLM** providing a single OpenAI-compatible HTTP API in front of every
  enabled engine
- **PostgreSQL** backing LiteLLM's key management and usage tracking
- **Caddy** terminating HTTPS with automatic Let's Encrypt certificates and
  enforcing an IP whitelist
- **All persistent data** on a LUKS-encrypted external volume that survives VM
  rebuilds
- **Disaster recovery** in ~15 minutes by attaching the volume to a fresh VPS

## Architecture

```
Internet ──HTTPS──► Caddy ──► LiteLLM ──► Ollama  (container, GPU)
                       │         │   ╲
                       │         │    ╲─► vLLM    (container, GPU)
                       │         │
                       │         └──► PostgreSQL  (container)
                       │
            ${DATA_MOUNT} (LUKS-encrypted volume)
            ├── stack/             compose project, configs, certs, DB
            ├── docker/            Docker data-root
            ├── ollama/            Ollama models
            └── vllm/hf-cache/     HuggingFace model cache
```

The host runs only the OS, the NVIDIA driver, and Docker. Everything else is
containerized and lives under `${DATA_MOUNT}`. When the VM dies, the host is
disposable — the data on the encrypted volume is what matters.

## Prerequisites

- **Ubuntu/Debian** (this guide is developed on recent Ubuntu; paths may vary
  slightly on Debian)
- **NVIDIA GPU** — any modern data-center or consumer card
- **Two block devices** — a primary OS disk and a secondary disk for data.
  This guide assumes `/dev/sda` and `/dev/sdb` but the device name is asked at
  configuration time.
- **A registered domain name** with an A record pointing to the VPS public IP
- **Console access** to the VPS provider's web UI, in case fstab/crypttab
  misconfiguration prevents normal boot
- **Open inbound ports**: 22 (SSH), 80 and 443 (HTTPS/ACME). Block everything
  else at the provider firewall.

Throughout this guide, substitute these placeholders with your real values:

| Placeholder | Meaning | Example |
|---|---|---|
| `llm.example.com` | Your FQDN | `proxy.mycompany.io` |
| `admin@example.com` | Email for Let's Encrypt | `ops@mycompany.io` |
| `/srv/llm` | Mountpoint for the encrypted volume | `/var/data`, `/mnt/secure`, etc. |
| `1.2.3.4 5.6.7.8/32` | Whitelisted client IPs | Your office IP, home IP, etc. |

---

## Scripts at a glance

| # | Script | What it does | Idempotent? |
|---|---|---|---|
| 00 | `00-preflight.sh` | Collects configuration → `config.env` | Yes |
| 01 | `01-nvidia-driver.sh` | Installs NVIDIA driver (then **REBOOT**) | Yes |
| 02 | `02-luks-volume.sh` | Creates the encrypted volume | Yes (detects existing LUKS) |
| 03 | `03-docker.sh` | Installs Docker, moves data-root | Yes |
| 04 | `04-nvidia-toolkit.sh` | NVIDIA Container Toolkit + GPU smoke test | Yes |
| 05 | `05-stack-config.sh` | Renders compose project from templates | Yes (regenerates) |
| 06 | `06-pull-models.sh` | Pre-pulls Ollama and HF models | Yes |
| 07 | `07-stack-up.sh` | `docker compose up -d` | Yes |
| 08 | `08-test.sh` | Smoke-tests the public endpoint | Yes |
| 99 | `99-ufw.sh` | Optional host firewall (UFW) | Yes |

Each script writes a marker into `.state/NN.done`; later scripts refuse to run
until earlier ones are complete.

---

## Part 1 — Configuration

Everything starts with `scripts/00-preflight.sh`, which asks a series of
questions and writes the answers (mode `600`) to `config.env` at the repo root.
Subsequent scripts source this file and never prompt again.

```bash
./scripts/00-preflight.sh
```

What you'll be asked:

- **Data device and mountpoint** — typically `/dev/sdb` and `/srv/llm`
- **Public FQDN and ACME email** — for Caddy + Let's Encrypt
- **Allowed IPs / CIDRs** — space-separated, enforced by Caddy
- **Engine toggles** — Ollama and/or vLLM (at least one required)
- **Models** — Ollama tags to pre-pull; HF model id for vLLM
- **NVIDIA driver package** — pick what `ubuntu-drivers devices` recommends
- **Pinned image tags** for LiteLLM and vLLM

`config.env.example` documents every variable. Read it before running 00 if
you'd rather review than answer prompts cold.

> **Don't commit `config.env`.** It's in `.gitignore`. It contains the LUKS
> mountpoint, the LiteLLM master key (once generated), and the Postgres
> password.

---

## Part 2 — NVIDIA driver on the host

Even though the engines run in containers, the **driver** must be on the host
kernel. The toolkit (Part 5) wires up `/dev/nvidia*` passthrough; the driver
itself is what talks to the silicon.

```bash
sudo ./scripts/01-nvidia-driver.sh
sudo reboot
```

What the script does:

1. Installs `build-essential`, `dkms`, kernel headers
2. Blacklists the open-source `nouveau` driver (it conflicts with the
   proprietary one)
3. Updates the initramfs
4. Installs the apt package you chose in 00 (e.g. `nvidia-driver-580-server`)
5. Enables `nvidia-persistenced` so the driver stays loaded between jobs

**Reboot is mandatory.** After reboot, verify:

```bash
nvidia-smi
sudo nvidia-smi -pm 1   # persistence mode on
```

You should see your GPU listed with the driver version.

> **Secure Boot.** If Secure Boot is enabled, the install prompts you to set a
> MOK password and you must enroll the key from the console at next boot.
> On a headless server without console access, disable Secure Boot in the BIOS
> first.

---

## Part 3 — Encrypted external volume

This is what makes the whole setup portable. The secondary disk holds all
persistent data and is encrypted with LUKS; if the VM dies, you attach the
disk to a new VM and you're back online.

```bash
sudo ./scripts/02-luks-volume.sh
```

The script is **idempotent**: if it detects an existing LUKS volume on the
target device, it skips the destructive format and only re-adds the keyfile,
crypttab and fstab entries. On a first run, it asks for a `YES` confirmation
before wiping.

Steps performed:

1. **Verify** the target is a real block device.
2. **Wipe + partition** (`parted` GPT, single partition spanning the disk).
3. **`luksFormat`** the partition. You'll be prompted for a passphrase —
   **save it in a password manager**. Without it (or the keyfile below) the
   data is unrecoverable.
4. **Create a root-owned keyfile** at the path you chose (e.g. `/root/llm.key`)
   and add it as a LUKS keyslot, so the volume can auto-unlock at boot
   without an interactive prompt.
5. **Open** the volume, **mkfs.ext4** it, **mount** it under
   `${DATA_MOUNT}`.
6. **Persist** the auto-unlock in `/etc/crypttab`:
   ```
   llm_crypt UUID=<…> /root/llm.key luks,nofail
   ```
7. **Persist** the mount in `/etc/fstab`:
   ```
   /dev/mapper/llm_crypt /srv/llm ext4 defaults,nofail 0 2
   ```
8. **Update initramfs**.

The `nofail` option is critical: if the disk is missing at boot, the VM still
finishes booting and remains reachable for repair.

> **Back up the keyfile off the VPS.** If you lose `${LUKS_KEYFILE}` *and* the
> passphrase, the data is gone. One simple way:
>
> ```bash
> sudo base64 /root/llm.key
> ```
>
> Copy the output to your offline password manager. To restore on a new VM,
> decode it back to a binary file and `chmod 0400`.

---

## Part 4 — Docker on the encrypted volume

Putting Docker's data directory on the encrypted volume means images,
volumes, and container state all follow the disk. When you rebuild the VM,
you don't have to re-pull images or restore volumes.

```bash
sudo ./scripts/03-docker.sh
```

What the script does:

1. **Installs** `docker.io` and `docker-compose-v2` from the distro repos.
2. **Adds your user** to the `docker` group (re-login required for the
   group to take effect in your current shell).
3. **Moves the data-root** to `${DATA_MOUNT}/docker`. If `/var/lib/docker` is
   non-empty, it stops Docker, `rsync`s the content over, and renames the old
   directory to `/var/lib/docker.OLD.<timestamp>` so you can verify the move
   before deleting.
4. **Writes `/etc/docker/daemon.json`** pointing to the new data-root:
   ```json
   { "data-root": "/srv/llm/docker" }
   ```
5. **Drops in a systemd override** at
   `/etc/systemd/system/docker.service.d/wait-for-data.conf`:
   ```ini
   [Unit]
   RequiresMountsFor=/srv/llm
   ```
   This makes `docker.service` refuse to start before `${DATA_MOUNT}` is
   mounted — otherwise, on a boot where the LUKS volume failed to open,
   Docker would happily create a fresh empty data-root on the root
   filesystem and silently lose access to everything.
6. **Moves containerd's root too** (`${DATA_MOUNT}/containerd`, via
   `/etc/containerd/config.toml`). Docker 28+ uses the *containerd image
   store*: `data-root` then only holds containers and volumes, while
   **images** live under containerd's root — which by default is
   `/var/lib/containerd` on the OS disk. Without this step, a 17 GB vLLM
   image quietly fills the root filesystem and disappears with the VM.
   The same `RequiresMountsFor` drop-in is applied to `containerd.service`.
7. **Starts both services and dies loudly** if `docker info` reports a
   `Docker Root Dir` different from `${DATA_MOUNT}/docker`, or if the
   containerd image store is active but its root is not on the volume.

Verify:

```bash
docker info | grep -E "Docker Root Dir|Storage Driver"
# Docker Root Dir: /srv/llm/docker
grep '^root' /etc/containerd/config.toml
# root = "/srv/llm/containerd"
```

---

## Part 5 — NVIDIA Container Toolkit

The driver on the host is not enough; containers need the toolkit to expose
the GPU.

```bash
sudo ./scripts/04-nvidia-toolkit.sh
```

What it does:

1. **Adds NVIDIA's apt repo**. The URL hard-codes `ubuntu22.04`, even on
   newer Ubuntu releases — NVIDIA publishes one repo per LTS base, and the
   packages are forward-compatible. This is intentional, not a typo.
2. **Installs `nvidia-container-toolkit`**.
3. **Configures the Docker runtime**: `nvidia-ctk runtime configure
   --runtime=docker` patches `daemon.json` to add the `nvidia` runtime.
4. **Restarts Docker**.
5. **Smoke-tests GPU passthrough** by running
   `nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi`. If the GPU appears
   inside the container, you're done with the GPU plumbing.

Expected `docker info` snippet after this step:

```
Runtimes: io.containerd.runc.v2 nvidia runc
Docker Root Dir: /srv/llm/docker
```

---

## Part 6 — Engine choice: Ollama and/or vLLM

Both engines run in containers wired up by Compose profiles. You enable one
or both at configuration time (Part 1), and `05-stack-config.sh` writes
`COMPOSE_PROFILES=ollama,vllm` (or a subset) into the rendered `.env` so
`docker compose up` only starts what you asked for.

### Which one to choose

- **Ollama** is best when you want "few users, many models, frequent
  swaps". GGUF quantization, integrated registry (`ollama pull`), hot
  loading of multiple models in VRAM (`OLLAMA_MAX_LOADED_MODELS`).
- **vLLM** is best when you want "one or two pinned models, many concurrent
  requests". PagedAttention + continuous batching deliver 3-10× higher
  throughput under load. One process per served model, so each costs you a
  container.
- **Both together** is a legitimate pattern: keep Ollama for the
  experimentation pool, dedicate vLLM to the one or two hot models that
  serve real traffic.

LiteLLM is what makes this seamless: clients see a single API, and routing
is decided by the `model` field in each request.

### Ollama in production: two gotchas the stack pre-empts

- **Context length.** Ollama's default context is 4096 tokens and it
  **silently truncates** anything longer — a prompt cut in half doesn't
  error, it produces confident nonsense. The stack sets
  `OLLAMA_CONTEXT_LENGTH` (default 8192) on the engine; raise it in
  `config.env` if your prompts are bigger (mind VRAM: KV cache grows
  with it).
- **Structured output.** Ollama enforces JSON schemas natively via
  constrained sampling, but the schema has to *reach* it: the stack
  routes Ollama models through LiteLLM's `ollama_chat/` provider
  (the `/api/chat` path that maps `response_format: json_schema` onto
  Ollama's `format` parameter), because the plain `ollama/` route can
  silently drop it. Translation layers have had bugs here — if your
  pipeline depends on strict schemas, **verify with a real request**
  after any LiteLLM upgrade: send a `json_schema` request and check the
  response actually validates, don't assume.

### Why containerized (and not Ollama on the host)?

The "Ollama on host for low-overhead GPU" argument is folklore. With
NVIDIA Container Toolkit the overhead is <1% — it's a device passthrough,
not virtualization. The reasons to containerize are pragmatic:

- Pinned versions and trivial rollback
- Persistent model caches via bind mounts to `${DATA_MOUNT}` — models
  survive VM rebuilds
- No systemd drop-ins to remember during disaster recovery
- One networking model instead of the `host.docker.internal` /
  `OLLAMA_HOST=172.17.0.1` mess

The one trade-off is that the `ollama` CLI on the host is gone; use
`docker compose exec ollama ollama list` instead.

### Serving two vLLM models (teacher/critic pattern)

One vLLM process serves exactly one model. For a second model
(e.g. a large "teacher" and a small "critic"), enable the optional
`vllm2` service: `ENABLE_VLLM2=yes` plus the `VLLM2_*` variables in
`config.env`. Each container has its own HF model, served name and
GPU memory fraction; LiteLLM routes to both by name.

Two caveats when both share one GPU:

- **How `--gpu-memory-utilization` is interpreted depends on the vLLM
  version** — both behaviors found the hard way on the same deployment:
  - *Older engines (e.g. the v0.8.x era)*: the fraction is a cap on
    **total** GPU memory *including other processes*. The second
    instance needs a **cumulative** cap (teacher `0.55`, critic
    `0.55 + 0.35 = 0.90`), otherwise it finds its budget already
    exhausted and dies with **"No available memory for the cache
    blocks"**.
  - *Newer engines (≥ ~0.19)*: the fraction is the instance's **own
    share**, and startup requires that much memory to be *free*. Each
    instance declares just its slice (teacher `0.55`, critic `0.35`);
    a cumulative value now dies with **"Free memory on startup is less
    than desired GPU memory utilization"**.
  - The error message tells you which world you're in — adjust the
    second instance's fraction accordingly. Startup order matters in
    both worlds, so the compose file starts `vllm2` only once `vllm`
    is healthy.
- Extra `vllm serve` flags (`--max-num-seqs`, `--enable-prefix-caching`,
  ...) go in `VLLM_EXTRA_ARGS` / `VLLM2_EXTRA_ARGS`, appended verbatim
  to the command line. Mind that flags appear, become defaults and get
  removed across versions — after an engine bump, an instance dying
  with `unrecognized arguments` means an EXTRA_ARGS flag needs to go.

### vLLM-specific notes

vLLM in containers needs two non-obvious settings, both already baked into
the Compose template:

- **`ipc: host`** — vLLM uses PyTorch's shared-memory allocator
- **`shm_size: "8gb"`** — without this NCCL and tensor-parallel paths
  fail with cryptic errors about `/dev/shm`

Also: the first model load downloads gigabytes from HuggingFace. The HF
cache lives under `${DATA_MOUNT}/vllm/hf-cache/`, bind-mounted into the
container, so the download happens once. Pre-populate it with
`06-pull-models.sh`.

### GPU sizing

On a single GPU, the two engines share VRAM. Plan accordingly:

- Set `VLLM_GPU_MEM_UTIL` (default `0.85`) to reserve a slice for vLLM;
  Ollama consumes the rest dynamically.
- If they OOM each other, drop `OLLAMA_MAX_LOADED_MODELS` to 1 or lower
  `VLLM_GPU_MEM_UTIL`.
- On older GPUs (e.g. Volta), AWQ/Marlin and FP8 are unavailable in vLLM;
  pick GGUF + Ollama or AWQ models with bitsandbytes fallback.

---

## Part 7 — Stack configuration

```bash
sudo ./scripts/05-stack-config.sh
```

This script renders the actual compose project under
`${DATA_MOUNT}/stack/` from the templates in `stack/`:

```
${DATA_MOUNT}/stack/
├── docker-compose.yml          # rendered from docker-compose.yml.tmpl
├── .env                        # secrets and runtime config
├── litellm-config.yaml         # rendered with one block per enabled model
├── caddy/Caddyfile             # rendered from Caddyfile.tmpl
└── pgdata/                     # Postgres data directory (bind mount)
```

Notable points:

- **Secrets are generated lazily**: if `LITELLM_MASTER_KEY` or
  `POSTGRES_PASSWORD` are empty in `config.env`, the script generates them
  with `openssl rand` and writes them back. Re-running the script is
  safe — existing secrets are preserved.
- **`litellm-config.yaml` is rebuilt every run**, with one entry per
  Ollama tag from `OLLAMA_MODELS_PULL` and one entry for the vLLM model
  (when enabled). This is why you re-run 05 after editing model lists.
- **Caddy uses `{$VAR}` interpolation** — these are resolved by Caddy
  itself at startup from the container environment, not by shell
  substitution at render time. This keeps the rendered Caddyfile a
  template that adapts to env changes on container restart.
- **`pgdata` as a bind mount** keeps the database files inside the
  project directory, so `tar -czf` of `${DATA_MOUNT}/stack/` is a
  complete backup.

The rendered `docker-compose.yml` design:

- **Caddy** exposes ports 80/443 to the host. **LiteLLM, Postgres,
  Ollama, vLLM** only `expose` to the internal Docker network. Only
  Caddy is reachable from outside.
- **Compose profiles** (`profiles: ["ollama"]`, `profiles: ["vllm"]`)
  on the two engine services. `COMPOSE_PROFILES` in `.env` decides
  which start.
- **GPU access** declared via `deploy.resources.reservations.devices`
  with `driver: nvidia` on both engines.
- **Named volumes** for `caddy_data` and `caddy_config` — these hold
  the Let's Encrypt certs. Losing them triggers a fresh ACME
  challenge, which has a 5-cert-per-week rate limit per domain, so
  back them up if you can.

---

## Part 8 — Pre-pulling models

Engines don't need to be up yet — this script spins up transient
containers to populate `${DATA_MOUNT}/ollama/` and
`${DATA_MOUNT}/vllm/hf-cache/`.

```bash
sudo ./scripts/06-pull-models.sh
```

For Ollama, the script starts an ephemeral `ollama/ollama` container
with the persistent models directory mounted, waits for the API to be
ready, then runs `ollama pull <tag>` for every tag in
`OLLAMA_MODELS_PULL`.

For vLLM, it runs an ephemeral container with the HF cache mounted
and calls `huggingface_hub.snapshot_download()` for the configured
model. If the model is gated, set `HF_TOKEN` in `config.env`.

Both downloads can take a while; the script is safe to interrupt and
re-run.

---

## Part 9 — Bringing up the stack

```bash
sudo ./scripts/07-stack-up.sh
```

The script `cd`s into `${DATA_MOUNT}/stack`, pulls images, and runs
`docker compose --env-file .env up -d`. It then tails logs for 20
seconds so you can see Caddy obtain the certificate and Prisma apply
the LiteLLM schema.

Things to look for in the logs:

- `db`: `database system is ready to accept connections`
- `litellm`: `Uvicorn running on http://0.0.0.0:4000` (after Prisma
  applies the schema, which takes ~30s on first run)
- `caddy`: `certificate obtained successfully`
- `ollama` (if enabled): `Listening on [::]:11434`
- `vllm` (if enabled): `Uvicorn running on http://0.0.0.0:8000`
  (after model load — can take minutes the first time)

### How long startup takes (what's normal)

The stack is **not** up when `07-stack-up.sh` returns — it's up when
`docker compose ps` shows every service `healthy`. Expected times:

| Service | Typical | What it's doing |
|---|---|---|
| `db` | seconds | opening the existing data dir |
| `litellm` | ~1 min | Prisma migrations (first run), then serving |
| `vllm` / `vllm2` | **3–10 min** | reading tens of GB of weights from disk into VRAM, allocating the KV cache, compiling CUDA graphs |
| `caddy` | last | waits for LiteLLM to be healthy; the very first start also requests the certificate (needs DNS pointing here) |

A 30B-class model is ~20 GB of weights that must physically travel
disk → RAM → VRAM: minutes are physics, not a hang. With two vLLM
instances, the second starts only after the first is healthy, so the
waits add up — budget ~10 minutes for a two-model cold start.

How to tell "loading" from "stuck":

```bash
watch docker compose --env-file .env ps    # health column
docker compose --env-file .env logs -f vllm  # shard loading progress bars
nvidia-smi                                  # VRAM climbing = it's working
```

Worry only if a service shows a short uptime that keeps resetting
(`Up 40 seconds`, again and again): that's a crash loop, not a slow
load — read its logs. The vLLM healthchecks allow a 10-minute grace
period before declaring failure.

---

## Part 10 — Testing

Before testing, make sure everything is actually up — the previous
section explains why this takes minutes:

```bash
cd ${DATA_MOUNT}/stack && docker compose --env-file .env ps
# every service must show (healthy)
```

Then:

```bash
sudo ./scripts/08-test.sh
```

The script performs the same check itself and refuses to probe while
anything is still `starting` — better an explicit "not yet" than a
misleading connection error.

The script gates on every service being healthy, then probes: liveness,
the model list, **a chat completion for every model in the rendered
`litellm-config.yaml`** (engine-agnostic — vLLM and Ollama models alike;
the first request to an Ollama model also loads it into VRAM), and the
Caddy IP gate. In detail:

1. **Liveness**: `GET /health/liveliness` on the public URL — confirms
   Caddy → LiteLLM → DB are all up.
2. **Models list**: `GET /v1/models` with the master key — confirms the
   `litellm-config.yaml` was parsed and engines are reachable.
3. **Chat completion**: a one-shot prompt against the first enabled
   model. This actually exercises the GPU.

While the chat completion runs, in another terminal:

```bash
watch -n 0.5 nvidia-smi
```

`GPU-Util` should climb to 70-90% and VRAM usage should match the
loaded model.

The admin UI is at `https://${DOMAIN}/ui` — log in with the master
key from `config.env`.

---

## Part 11 — Day-to-day operations

### Common commands

```bash
cd ${DATA_MOUNT}/stack

docker compose --env-file .env ps             # status
docker compose --env-file .env logs -f        # tail logs (Ctrl+C detaches)
docker compose --env-file .env logs -f caddy  # certificate issues
docker compose --env-file .env logs -f vllm   # model load issues
docker compose --env-file .env restart litellm
docker compose --env-file .env down           # stop everything (data preserved)
docker compose --env-file .env up -d          # start everything

# Caddyfile-only changes can be reloaded without restart:
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile
```

### Database backups

Step 05 installs `/etc/cron.d/llm-db-backup`, which runs
`${DATA_MOUNT}/stack/backup-db.sh` nightly at 03:17: a `pg_dump` of the
LiteLLM database, gzipped into `${DATA_MOUNT}/stack/backups/` with a
14-dump retention. The dumps live on the encrypted volume, so they follow
the disk through VM rebuilds.

```bash
sudo ${DATA_MOUNT}/stack/backup-db.sh     # manual backup
# restore into the running db container:
gunzip -c backups/litellm-<stamp>.sql.gz | \
    docker compose --env-file .env exec -T db psql -U litellm litellm
```

### Health checks

Every service has a Docker healthcheck (`docker compose ps` shows
`healthy`/`unhealthy`). Caddy only starts once LiteLLM is healthy; vLLM
has a 10-minute grace period on first start to allow for model download
and weight loading.

### Changing allowed IPs

```bash
nano config.env                        # edit ALLOWED_IPS
sudo ./scripts/05-stack-config.sh      # re-render
cd ${DATA_MOUNT}/stack && docker compose --env-file .env up -d caddy
```

Environment variables are read at container start, not at Caddy
reload, so `up -d caddy` is required (≈2 seconds of downtime for
Caddy only).

### Adding an Ollama model

1. Append the tag to `OLLAMA_MODELS_PULL` in `config.env`. By default
   the API name is derived from the tag (`gemma4:31b` → `gemma4-31b`);
   append `=alias` to pin it instead (`gemma4:26b-a4b-it-qat=critic`) —
   useful to keep the client-facing name stable while the underlying
   model changes.
2. `sudo ./scripts/06-pull-models.sh` — only the new tag is downloaded.
3. `sudo ./scripts/05-stack-config.sh` — re-renders
   `litellm-config.yaml` with the new model.
4. `docker compose --env-file .env restart litellm`.

### Switching the vLLM model

1. Edit `VLLM_MODEL` (and, if you want a new API name, `VLLM_SERVED_NAME`)
   in `config.env` — or the `VLLM2_*` equivalents for the second instance.
   Keeping the served name means clients don't notice the swap.
2. `sudo ./scripts/06-pull-models.sh` (downloads the new weights) and
   `sudo ./scripts/05-stack-config.sh` (re-renders the routing).
3. `cd ${DATA_MOUNT}/stack && docker compose --env-file .env up -d vllm`
   (or `vllm2`) — recreates the container with the new args.

**If the new model is newer than the pinned vLLM release**, the engine
won't know its architecture and dies at startup (typically an
"architecture not supported" / unknown `model_type` error). Model cards
usually state the minimum vLLM version. In that case:

1. Bump `VLLM_IMAGE_TAG` in `config.env` to a release that supports it
   (<https://github.com/vllm-project/vllm/releases>) — and check the
   card's CUDA requirement against your driver.
2. Mind that the image is **shared**: `vllm` and `vllm2` jump versions
   together. The other model almost always works on the newer engine,
   but re-test both.
3. CLI flags evolve between releases: if a container dies with
   `unrecognized arguments`, review your `VLLM_EXTRA_ARGS` — flags get
   renamed, and some become defaults you can simply drop.
4. `docker compose --env-file .env pull vllm vllm2 && docker compose
   --env-file .env up -d vllm vllm2`, then re-run `08-test.sh`.

### Reclaiming disk space after swaps

**Do the space math BEFORE swapping, not after.** A swap temporarily
holds *both* generations on the volume: old + new engine image (~20 GB
each) and old + new model weights. If free space is less than the size
of the incoming generation, the download dies mid-flight with the disk
at 100% — and PostgreSQL on a full disk stops accepting writes. On a
tight volume, invert the order: commit to the swap first —
`docker compose rm -sf vllm vllm2`, remove the old engine image and the
old model directory — *then* download the new generation. Rollback is
still possible (revert `config.env`, re-run 06), it just costs a
re-download.

Old engine images and old model weights otherwise stay on the volume
until you remove them — by design, so a rollback is just reverting
`config.env` and re-running step 05. Once the new setup is validated:

```bash
docker image prune -a          # drops images no longer referenced
# Ollama models:
docker compose --env-file .env exec ollama ollama rm <tag>
# vLLM / HF models: each model is a directory under
# ${DATA_MOUNT}/vllm/hf-cache/hub/models--<Org>--<Name> — delete it.
```

### Adding a new service behind Caddy

1. Add the service to `stack/docker-compose.yml.tmpl` with `expose:`
   (not `ports:`).
2. Append a new site block to `stack/Caddyfile.tmpl`:
   ```caddyfile
   webui.example.com {
       reverse_proxy open-webui:8080
   }
   ```
3. Add the DNS A record for the new subdomain.
4. `sudo ./scripts/05-stack-config.sh` then
   `docker compose --env-file .env up -d`.

Caddy obtains the new certificate automatically.

### Updating LiteLLM

1. Edit `LITELLM_IMAGE` in `config.env` (always pin to a specific
   stable tag — check
   <https://github.com/BerriAI/litellm/releases>).
2. `sudo ./scripts/05-stack-config.sh` propagates it.
3. `cd ${DATA_MOUNT}/stack && docker compose --env-file .env pull litellm && docker compose --env-file .env up -d litellm`.

> **Never use `:latest` in production.** A March 2026 supply-chain
> incident affected users on floating tags.

---

## Part 12 — Disaster recovery

The whole point of this setup. See
[`disaster-recovery.md`](disaster-recovery.md) for the full procedure;
the short version:

1. Spawn a fresh VPS, attach the existing data disk.
2. Clone this repo, restore `config.env` from your offline backup (or
   re-run `00-preflight.sh` with the same answers).
3. Restore the LUKS keyfile from your offline backup.
4. Run `01` → `04` again. Step 02 detects the existing LUKS volume
   and skips the wipe; step 03 picks up the existing Docker data-root.
5. Skip 05 and 06 — the compose project and the models are already on
   the disk.
6. `cd ${DATA_MOUNT}/stack && docker compose --env-file .env up -d`.
7. `sudo ./scripts/08-test.sh`.

Time budget after two or three rehearsals: 10-15 minutes.

What does NOT come with the volume:

- The NVIDIA driver (rerun 01)
- Docker itself (rerun 03)
- The NVIDIA Container Toolkit (rerun 04)
- The LUKS keyfile (`/root/<basename>.key`) — back this up off the VPS
- `/etc/crypttab` and `/etc/fstab` entries (rerun 02)
- `/etc/docker/daemon.json` and the systemd drop-in (rerun 03)

---

## Part 13 — Optional host firewall

```bash
sudo ./scripts/99-ufw.sh
```

Whether to enable UFW is a judgement call: most VPS providers already
give you a firewall at the edge, and running UFW *inside* the VM is
belt-and-suspenders. The script is here because if you do enable UFW,
two gotchas need to be handled:

1. **`ufw enable` flushes iptables**, including Docker's `DOCKER-USER`
   chain. The script restarts Docker afterwards to recreate the
   chains.
2. **UFW ships with `DEFAULT_FORWARD_POLICY="DROP"`** in
   `/etc/default/ufw`, which causes outbound traffic from containers
   (e.g. `apt-get` inside a container) to fail. The script flips this
   to `ACCEPT`. Host INPUT remains restrictive, so the host stays
   protected; Docker enforces container-level forwarding rules itself.

If you skip this script, make sure your provider firewall enforces the
same policy: only 22, 80, 443 inbound; nothing else.

---

## Part 14 — Threat model

The LUKS setup uses a keyfile sitting next to the encrypted volume on
the same host. This is a deliberate trade-off:

- ✅ Protects against the provider, an attacker, or an accidental
  recipient obtaining the raw secondary disk in isolation
- ✅ Protects against snapshots of the data device alone
- ❌ Does NOT protect against root access on the running VM (keyfile
  is readable by root)
- ❌ Does NOT protect against full VM snapshots (which contain both
  the keyfile and the volume)

If your threat model requires more, use a passphrase prompted at boot
or a remote unlock mechanism such as Clevis + Tang. Both require more
operational machinery and break the "unattended reboot" property of
the current setup.

Other defenses already in place:

- **IP whitelist at Caddy** — LiteLLM's API is never reachable from
  arbitrary IPs.
- **No engine ports exposed to the host** — only Caddy listens on 80
  and 443.
- **Master key + per-user API keys** managed by LiteLLM — never use
  the master key from end-user clients.

---

## Part 15 — Troubleshooting

### LiteLLM responds but the model never gets called / generates nothing

Almost always one of:

1. **Model name mismatch**. The `model` field in your request must
   match an entry in `litellm-config.yaml`. Check:
   ```bash
   curl https://${DOMAIN}/v1/models -H "Authorization: Bearer $KEY" | jq
   ```
2. **The engine container can't reach the model** (vLLM still loading,
   Ollama tag never pulled). Check engine logs:
   ```bash
   docker compose logs -f vllm
   docker compose logs -f ollama
   ```
3. **GPU not visible in the engine container**. Confirm with
   `docker compose exec vllm nvidia-smi` or
   `docker compose exec ollama nvidia-smi`. If it fails, rerun
   `04-nvidia-toolkit.sh` and restart Docker.

### Caddy can't get a certificate

- **DNS not propagated** — `dig +short ${DOMAIN}` should return the
  VPS IP.
- **Firewall blocking port 80 or 443** — Let's Encrypt needs 80
  inbound for the HTTP-01 challenge.
- **Rate limited** — 5 certs per week per registered domain. If
  you've been rebuilding a lot, wait or use Let's Encrypt's staging
  environment first.

### `nvidia-ctk: command not found` after installing the toolkit

The `apt update` didn't pick up the NVIDIA repo. Verify:

```bash
cat /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt-cache policy nvidia-container-toolkit
```

If the file is empty or apt sees no package, rerun the `curl` commands
inside `04-nvidia-toolkit.sh`. The URL must be the `ubuntu22.04` one,
regardless of your actual Ubuntu version.

### vLLM OOMs on startup

- Lower `VLLM_GPU_MEM_UTIL` (default `0.85`).
- Lower `VLLM_MAX_MODEL_LEN` — KV cache cost grows with context length.
- Pick a more aggressively quantized variant (AWQ, GPTQ) of the same
  model.

### `--shm-size` errors / NCCL failures in vLLM

The Compose template already sets `ipc: host` and `shm_size: "8gb"`.
If you copy the service definition elsewhere, keep both.

### Containers can't reach the network after enabling UFW

UFW flushed iptables on enable. Restart Docker:

```bash
sudo systemctl restart docker
```

If outbound from containers is still broken (apt failing inside
containers), check `/etc/default/ufw` — it must contain
`DEFAULT_FORWARD_POLICY="ACCEPT"`. `99-ufw.sh` does this for you; if
you ran `ufw enable` manually, you bypassed the fix.

### Slow inference (low tok/s)

Sanity checks during a request:

1. `nvidia-smi` shows `GPU-Util` 70%+. If it's near zero, the model
   fell back to CPU — check the engine logs for "no CUDA device" or
   "falling back".
2. For Ollama: `OLLAMA_KEEP_ALIVE=24h` is set (default in
   `config.env`) — otherwise every idle gap costs you a cold load.
3. For Ollama: the model is actually quantized (`ollama show <tag>`
   shows the quantization). Pulling `model:31b` without a quant suffix
   can land you on fp16, which is much slower.
4. For vLLM: `--gpu-memory-utilization` is high enough; KV cache
   thrashing tanks throughput.

---

## Part 16 — Quick reference

```bash
# Locations
${DATA_MOUNT}/                            # encrypted volume mount
${DATA_MOUNT}/stack/                      # compose project
${DATA_MOUNT}/stack/.env                  # runtime secrets (chmod 600)
${DATA_MOUNT}/stack/litellm-config.yaml   # LiteLLM model list (regenerated)
${DATA_MOUNT}/stack/caddy/Caddyfile       # Caddy config
${DATA_MOUNT}/stack/pgdata/               # PostgreSQL data
${DATA_MOUNT}/docker/                     # Docker data-root
${DATA_MOUNT}/ollama/                     # Ollama models
${DATA_MOUNT}/vllm/hf-cache/              # vLLM model cache
config.env                                # SOURCE of all configuration
${LUKS_KEYFILE}                           # LUKS keyfile (chmod 400)
/etc/crypttab                             # auto-unlock entry
/etc/fstab                                # auto-mount entry
/etc/docker/daemon.json                   # Docker data-root
/etc/systemd/system/docker.service.d/
  wait-for-data.conf                      # Docker waits for the volume

# Inspection
nvidia-smi                                # GPU status
sudo cryptsetup status <luks_name>        # LUKS status
sudo cryptsetup luksDump <device>         # LUKS keyslots
docker info                               # Docker config
docker compose ps                         # service status
docker compose exec ollama ollama list    # Ollama models

# Critical things to back up off the VPS
${LUKS_KEYFILE}                            # LUKS keyfile
config.env                                 # all secrets + config
${DATA_MOUNT}/stack/.env                   # generated secrets
${DATA_MOUNT}/stack/caddy/Caddyfile        # routing rules
# (the LUKS passphrase, stored in a password manager)
# (the LiteLLM master key, stored in a password manager)
```
