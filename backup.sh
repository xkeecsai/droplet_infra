#!/usr/bin/env bash
# Daily Postgres dump → ./pg_backup/ and rotates older than N days.
# Wire to cron with e.g.:
#   0 3 * * *  /opt/kx/droplet_infra/backup.sh > /var/log/kx-backup.log 2>&1

set -euo pipefail

cd "$(dirname "$0")"

KEEP_DAYS=14
TS=$(date +%Y%m%d_%H%M%S)
OUT_DIR="./pg_backup"
mkdir -p "$OUT_DIR"

# Use compose to exec inside the postgres container
docker compose exec -T postgres pg_dump \
    --username "${POSTGRES_USER:-kx}" \
    --dbname "${POSTGRES_DB:-macro}" \
    --format=custom \
    > "${OUT_DIR}/macro_${TS}.dump"

# Rotate
find "$OUT_DIR" -name 'macro_*.dump' -mtime +${KEEP_DAYS} -delete

echo "[backup] wrote ${OUT_DIR}/macro_${TS}.dump"

# Optional: upload to DO Spaces / S3 if you've configured `s3cmd` or `aws cli`
# s3cmd put "${OUT_DIR}/macro_${TS}.dump" s3://kx-backups/postgres/
