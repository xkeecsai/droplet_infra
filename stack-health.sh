#!/usr/bin/env bash
# Health check for the kx-infra dashboard stack.
#
# Catches the two failure modes that `docker ps` cannot:
#   1. ORPHANED NETNS — an app using `network_mode: service:ts-<x>` whose sidecar
#      was recreated under it. The app keeps running and reports (healthy) while
#      its URL 502s. This took cb-speeches down for ~1 month unnoticed.
#   2. STALE DATA — a dashboard serving 200 with a frozen corpus.
#
# NOTE: do NOT try to detect (1) via the container's SandboxKey. EVERY
# network_mode:service container reports an empty SandboxKey, healthy ones
# included — it owns no sandbox of its own. The authoritative test is to probe
# the app's port from INSIDE the sidecar's namespace, which is what we do here.
#
# Usage:  ./stack-health.sh            # check everything
#         ./stack-health.sh cb-speeches growth
# Exit:   0 = all good, 1 = at least one problem found.

set -uo pipefail
cd "$(dirname "$0")"

TAILNET="${TAILNET_DOMAIN:-tail284e0d.ts.net}"
CURL_TIMEOUT="${CURL_TIMEOUT:-25}"
STALE_WARN_HOURS="${STALE_WARN_HOURS:-48}"

problems=0
warnings=0

note()  { printf '       %s\n' "$*"; }
bad()   { printf '       \033[1;31m%s\033[0m\n' "$*"; problems=$((problems+1)); }
warn()  { printf '       \033[1;33m%s\033[0m\n' "$*"; warnings=$((warnings+1)); }

# Resolve the app container sharing a sidecar's network namespace.
app_for_sidecar() {
  local sid; sid=$(docker inspect -f '{{.Id}}' "$1" 2>/dev/null) || return 1
  [ -z "$sid" ] && return 1
  docker ps -q 2>/dev/null | while read -r c; do
    local mode; mode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$c" 2>/dev/null)
    if [ "$mode" = "container:$sid" ]; then
      docker inspect -f '{{.Name}}' "$c" 2>/dev/null | sed 's|^/||'
    fi
  done | head -1
}

targets=("$@")
if [ ${#targets[@]} -eq 0 ]; then
  for f in tailscale/*-serve.json; do
    targets+=("$(basename "$f" -serve.json)")
  done
fi

printf '%s\n' "kx-infra stack health — $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf '%s\n' "-------------------------------------------------------------"

for name in "${targets[@]}"; do
  serve="tailscale/${name}-serve.json"
  sidecar="ts-${name}"

  # No sidecar running. Either the service is retired (fine), or its APP is
  # running with no way in — a dark app, which is worth shouting about.
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$sidecar"; then
    # Prefer an exact container name; fall back to prefixed siblings (e.g. a
    # "<name>-refresh" batch job) only if the app itself isn't named plainly.
    running=$(docker ps --format '{{.Names}}' 2>/dev/null)
    darkapp=$(printf '%s\n' "$running" | grep -xF "$name" | head -1)
    [ -z "$darkapp" ] && darkapp=$(printf '%s\n' "$running" \
                          | grep -xE "${name}[-_].*" | grep -vE -- '-(refresh|migrate|scheduler)$' | head -1)
    [ -z "$darkapp" ] && darkapp=$(printf '%s\n' "$running" | grep -xE "${name}[-_].*" | head -1)
    if [ -n "$darkapp" ]; then
      # A parked sidecar is NOT automatically a fault. While TS_AUTHKEY is dead,
      # the established workaround (see commit 6c7874f) is to bind the app to
      # the droplet's own tailnet IP instead — tailnet-only, no new credential.
      # If it publishes such a port and answers there, it is reachable: OK.
      bind=$(docker port "$darkapp" 2>/dev/null | awk -F' -> ' '{print $2}' | head -1)
      if [ -n "$bind" ] && curl -s -o /dev/null -m "$CURL_TIMEOUT" \
           -w '' "http://${bind}/" 2>/dev/null; then
        printf '%-16s \033[1;32mOK\033[0m     http://%s (tailnet-IP bind; %s parked)\n' \
               "$name" "$bind" "$sidecar"
      elif [ -n "$bind" ]; then
        printf '%-16s \033[1;31mFAIL\033[0m   bound to %s but not answering\n' "$name" "$bind"
        problems=$((problems+1))
      else
        printf '%-16s \033[1;33mDARK\033[0m   app "%s" is running, %s is not, and no port is published — nothing serves it\n' \
               "$name" "$darkapp" "$sidecar"
        warnings=$((warnings+1))
      fi
    else
      printf '%-16s SKIP   (no %s running — retired or not deployed)\n' "$name" "$sidecar"
    fi
    continue
  fi

  code=$(curl -s -o /dev/null -m "$CURL_TIMEOUT" -w '%{http_code}' "https://${name}.${TAILNET}/" 2>/dev/null)
  [ -z "$code" ] && code="000"

  if [ "$code" = "200" ]; then
    printf '%-16s \033[1;32mOK\033[0m     HTTP 200\n' "$name"
  else
    printf '%-16s \033[1;31mFAIL\033[0m   HTTP %s\n' "$name" "$code"
    problems=$((problems+1))

    # Classify: is the app reachable inside the sidecar's own namespace?
    port=$(grep -oE '127\.0\.0\.1:[0-9]+' "$serve" 2>/dev/null | head -1 | cut -d: -f2)
    if [ -n "$port" ]; then
      if docker exec "$sidecar" wget -q -O /dev/null -T 5 "http://127.0.0.1:${port}/" 2>/dev/null; then
        note "app answers on :$port inside $sidecar -> proxy/cert/DNS layer, not the app"
      else
        app=$(app_for_sidecar "$sidecar")
        if [ -z "$app" ]; then
          note "NO container shares $sidecar's netns -> app stopped, or ORPHANED NETNS"
          note "fix: docker compose up -d --no-deps --force-recreate <app>"
        else
          note "app '$app' is running but NOT listening on :$port in $sidecar's netns"
          note "=> ORPHANED NETNS (sidecar recreated under it)"
          note "fix: docker compose restart $app"
        fi
      fi
    fi
  fi

  # Early warning: app older than its sidecar means the sidecar was recreated
  # under a still-running app — the orphaned-netns setup, even if it still works.
  app=$(app_for_sidecar "$sidecar")
  if [ -n "$app" ]; then
    a=$(docker inspect -f '{{.State.StartedAt}}' "$app" 2>/dev/null)
    s=$(docker inspect -f '{{.State.StartedAt}}' "$sidecar" 2>/dev/null)
    if [ -n "$a" ] && [ -n "$s" ] && [[ "$a" < "$s" ]]; then
      warn "app '$app' started BEFORE $sidecar — netns may be orphaned; restart the app"
    fi
  fi
done

# ---- data freshness ---------------------------------------------------------
# cb-speeches has no scheduled refresh by default and loads data at import, so
# it is the most likely thing on the box to be quietly serving a stale corpus.
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx cb-speeches; then
  printf '%s\n' "-------------------------------------------------------------"
  printf '%s\n' "cb-speeches corpus freshness (source_health.json):"
  docker exec -i cb-speeches python - <<'PY' 2>/dev/null || note "could not read source_health.json"
import json, datetime
p = "/app/data/processed/cb_speeches/source_health.json"
try:
    d = json.load(open(p))
except Exception as e:
    raise SystemExit(f"       unreadable: {e}")
now = datetime.datetime.now(datetime.timezone.utc)
worst = None
for k, v in sorted(d.items()):
    c = (v.get("latest_content_at") or "")[:10]
    try:
        age = (now - datetime.datetime.fromisoformat(c).replace(tzinfo=datetime.timezone.utc)).days
    except Exception:
        age = None
    flag = "" if age is None or age <= 14 else "  <-- stale"
    print(f"       {k:22s} latest={c or '?':10s} age={age if age is not None else '?':>4} d{flag}")
    if age is not None and (worst is None or age < worst):
        worst = age
print(f"       freshest source is {worst} days old" if worst is not None else "")
PY
fi

printf '%s\n' "-------------------------------------------------------------"
if [ "$problems" -gt 0 ]; then
  printf 'RESULT: \033[1;31m%d problem(s)\033[0m, %d warning(s)\n' "$problems" "$warnings"
  exit 1
fi
printf 'RESULT: \033[1;32mall reachable\033[0m, %d warning(s)\n' "$warnings"
exit 0
