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
service_status=0
docker compose up -d --no-deps ts-g10-cb-intel || service_status=$?
docker compose up -d --no-deps --force-recreate g10-cb-intel || service_status=$?

final_status=$refresh_status
if [[ $final_status -eq 0 && $service_status -ne 0 ]]; then
    final_status=$service_status
fi

completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "[g10-cb-intel-refresh] completed_at=$completed_at refresh_status=$refresh_status service_status=$service_status status=$final_status"
exit "$final_status"
