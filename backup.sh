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

# ---------------------------------------------------------------------------
# NOTE: this script covers POSTGRES ONLY. Docker volumes are NOT backed up.
#
# That is fine for anything re-fetchable, but korea-leverage (MRP-148) keeps a
# leveraged-ETF series whose upstream endpoint serves TODAY ONLY -- there is no
# history to re-download, so every snapshot exists in exactly one place and a
# lost volume is a permanently lost series.
#
# It is synced off-site to its own git repo instead, which also gives version
# history (a second copy on this droplet would not survive losing the droplet):
#
#   python scripts/sync_droplet_archive.py     # in korea_equity_positioning
#
# Any future dashboard that accumulates un-refetchable data needs the same
# treatment. Check before assuming a volume is disposable.
# ---------------------------------------------------------------------------
