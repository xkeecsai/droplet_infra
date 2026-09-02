#!/usr/bin/env bash
# Refresh the cb-speeches corpus, then restart the app so it actually SERVES it.
#
# Two non-obvious reasons this wrapper exists rather than a bare cron line:
#
#  1. cb-speeches loads every artifact at MODULE IMPORT (app.py has
#     `FEED_ITEMS = artifacts.load_feed_items(...)` etc. as module-level
#     globals). Gunicorn holds a startup snapshot, so a refresh is INVISIBLE
#     until the container restarts. A naive refresh cron would update the disk
#     and leave the dashboard serving the old vintage forever.
#
#  2. The refresh's own exit code is useless here. `main()` returns 0 for both
#     "ok" and "partial", and status is "partial" if ANY single step succeeded.
#     On this droplet `g10_cb_intel_real_snapshot` ALWAYS fails (it reaches for
#     a monorepo path that only exists on the MacMini), so status can never be
#     "ok" and the exit code is pinned at 0 — a total feed collapse would look
#     exactly like success. So we judge per-step ourselves, allowlisting only
#     that one known-impossible step.
#
# Usage: ./refresh-cb-speeches.sh
# Exit:  0 = refreshed and serving, 1 = something real failed.

set -uo pipefail
cd "$(dirname "$0")"

LOCK=/var/lock/cb-speeches-refresh.lock
TAILNET="${TAILNET_DOMAIN:-tail284e0d.ts.net}"

# Steps that cannot succeed on the droplet. Keep this list SHORT and justified —
# every entry here is a step whose failure we have chosen to stop looking at.
EXPECTED_FAILURES="g10_cb_intel_real_snapshot"

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

# Serialise: a refresh can run ~15 min, well past a second cron tick.
exec 9>"$LOCK" || { log "FATAL: cannot open $LOCK"; exit 1; }
if ! flock -n 9; then
  log "another refresh is already running — exiting"
  exit 0
fi

if ! docker ps --format '{{.Names}}' | grep -qx cb-speeches; then
  log "FATAL: cb-speeches container is not running"
  exit 1
fi

log "starting refresh"
# Keep the full JSON in the log — it is the only forensic record of which feeds
# fetched what, and it is what you want when a source starts quietly returning
# zero rows. The condensed verdict below is for alerting, not diagnosis.
docker exec -i cb-speeches python -m cb_speeches.refresh all --delay 0.5 2>&1
log "refresh command returned $? (not trusted — see header)"

# ---- judge the run per-step -------------------------------------------------
verdict=$(docker exec -i cb-speeches python - "$EXPECTED_FAILURES" <<'PY' 2>&1
import json, sys
expected = set(filter(None, sys.argv[1].split()))
try:
    d = json.load(open("/app/data/processed/cb_speeches/refresh_status.json"))
except Exception as e:
    print(f"FAIL unreadable refresh_status.json: {e}"); raise SystemExit
bad, allowed = [], []
for s in d.get("steps", []):
    if s.get("status") == "ok":
        continue
    (allowed if s.get("step") in expected else bad).append(
        f"{s.get('step')}: {(s.get('failure_reason') or '')[:120]}")
print(f"INFO started={d.get('started_at')} finished={d.get('finished_at')} raw_status={d.get('status')}")
for a in allowed:
    print(f"INFO expected-failure (ignored) {a}")
for b in bad:
    print(f"FAIL {b}")
if not bad:
    print("PASS all steps ok apart from known-impossible ones")
PY
)
printf '%s\n' "$verdict" | while IFS= read -r l; do log "$l"; done

# ---- restart so the new data is actually served -----------------------------
log "restarting cb-speeches so it re-imports the refreshed artifacts"
docker compose restart cb-speeches >/dev/null 2>&1 || {
  log "FATAL: restart failed"; exit 1; }

# ---- verify end-to-end ------------------------------------------------------
ok=""
for _ in $(seq 1 12); do
  sleep 5
  code=$(curl -s -o /dev/null -m 20 -w '%{http_code}' "https://cb-speeches.${TAILNET}/healthz" 2>/dev/null)
  if [ "$code" = "200" ]; then ok=1; break; fi
done
if [ -z "$ok" ]; then
  log "FATAL: cb-speeches did not return 200 after restart"
  exit 1
fi
log "verified https://cb-speeches.${TAILNET}/healthz -> 200"

# Report the freshest source so the log carries evidence, not just a claim.
docker exec -i cb-speeches python - <<'PY' 2>/dev/null | while IFS= read -r l; do log "$l"; done
import json, datetime
d = json.load(open("/app/data/processed/cb_speeches/source_health.json"))
now = datetime.datetime.now(datetime.timezone.utc)
ages = {}
for k, v in d.items():
    c = (v.get("latest_content_at") or "")[:10]
    try:
        ages[k] = (now - datetime.datetime.fromisoformat(c).replace(tzinfo=datetime.timezone.utc)).days
    except Exception:
        pass
if ages:
    k = min(ages, key=ages.get)
    print(f"freshest source: {k} ({ages[k]}d old); {sum(1 for a in ages.values() if a > 14)}/{len(ages)} sources >14d")
PY

if printf '%s' "$verdict" | grep -q '^FAIL'; then
  log "DONE with failures — see FAIL lines above"
  exit 1
fi
log "DONE ok"
exit 0
