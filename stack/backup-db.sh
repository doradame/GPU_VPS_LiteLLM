#!/usr/bin/env bash
# backup-db.sh — dump the LiteLLM PostgreSQL database into ./backups/,
# keeping the 14 most recent dumps. Copied to ${DATA_MOUNT}/stack by
# 05-stack-config.sh and run nightly via /etc/cron.d/llm-db-backup.
#
# Manual run:    sudo ${DATA_MOUNT}/stack/backup-db.sh
# Restore:       gunzip -c backups/litellm-<stamp>.sql.gz \
#                  | docker compose --env-file .env exec -T db psql -U litellm litellm
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p backups
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="backups/litellm-$STAMP.sql.gz"

docker compose --env-file .env exec -T db pg_dump -U litellm litellm | gzip > "$OUT"

# Retention: drop everything beyond the 14 most recent dumps.
# (filenames are machine-generated, safe to parse)
ls -1t backups/litellm-*.sql.gz | tail -n +15 | xargs -r rm -f --

echo "backup written: $OUT ($(du -h "$OUT" | cut -f1))"
