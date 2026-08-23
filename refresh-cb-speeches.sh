#!/usr/bin/env bash
# Foreground daily refresh for cb-speeches. The lock prevents overlapping public-data runs.
#
# Why this exists: nothing on the droplet ever scheduled a cb-speeches refresh, so on
# 2026-08-22 the corpus was found **45 days stale** while the app still served HTTP 200.
# Stale-but-200 is the dangerous failure mode for a tool that serves the 07:00 Dubai slot
# ("what's priced today / is the reaction function right") — a frozen speech monitor looks
# identical to a working one.
#
# Data safety: the corpus lives on the named volume droplet_infra_cb-speeches-cache
# (-> /app/data/processed/cb_speeches), so restarting the container does NOT lose data.
# The restart IS required — the app reads its corpus at process start.
#
# Expect status "partial", always: the cb_speeches refresh pipeline also tries to refresh
# g10_cb_intel, which is not packaged in this image (and is retired from this droplet, see
# commit 1bd1ffc). That step fails on every droplet run and pins the reported status at
# "partial" permanently. It is cosmetic — the speech data all lands. **Judge freshness by
# source_health.json -> latest_content_at, NOT by refresh_status.json -> status.**
# Consequently the restart below must NOT be gated on the refresh exit code.

set -uo pipefail

cd "$(dirname "$0")"
exec 9>/var/lock/cb-speeches-refresh.lock
if ! flock -n 9; then
    echo "[cb-speeches-refresh] another refresh is already running"
    exit 0
fi

started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "[cb-speeches-refresh] started_at=$started_at"

docker exec cb-speeches python -m cb_speeches.refresh all --delay 0.5
refresh_status=$?
echo "[cb-speeches-refresh] refresh exit=$refresh_status (non-zero/partial is expected — see header)"

# Restart regardless of refresh_status so the app picks up whatever DID land.
docker restart cb-speeches
service_status=$?

finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "[cb-speeches-refresh] finished_at=$finished_at restart_exit=$service_status"

# Surface the per-source freshness in the log so a quiet upstream feed is visible
# without opening the dashboard. BOE/BOC/SNB are genuinely low-frequency publishers.
docker exec cb-speeches python3 -c "
import json
d = json.load(open('/app/data/processed/cb_speeches/source_health.json'))
for k, v in sorted(d.items()):
    if isinstance(v, dict) and v.get('latest_content_at'):
        print(f'[cb-speeches-refresh]   {k:22} {v[\"latest_content_at\"][:10]}')
" 2>/dev/null || echo "[cb-speeches-refresh] (freshness readout unavailable)"

exit 0
