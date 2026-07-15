#!/usr/bin/env bash
# Foreground daily refresh. The lock prevents overlapping public-data runs.

set -uo pipefail

cd "$(dirname "$0")"
exec 9>/var/lock/g10-cb-intel-refresh.lock
if ! flock -n 9; then
    echo "[g10-cb-intel-refresh] another refresh is already running"
    exit 0
fi

started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "[g10-cb-intel-refresh] started_at=$started_at"
docker compose --profile refresh run --rm --no-deps g10-cb-intel-refresh
refresh_status=$?

# The app loads its immutable runtime context at process start. Restart even on
# a failed refresh so Runtime Status surfaces the scheduler's failure record.
docker compose up -d --no-deps --force-recreate g10-cb-intel

completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "[g10-cb-intel-refresh] completed_at=$completed_at status=$refresh_status"
exit "$refresh_status"
