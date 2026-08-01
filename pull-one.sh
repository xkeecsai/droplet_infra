#!/usr/bin/env bash
# Clone or fast-forward a single dashboard repo into /opt/kx/repos/<name>.
# Usage: ./pull-one.sh <repo-name>
#
# Same auth logic as pull-dashboards.sh: SSH first, HTTPS+token fallback.

set -euo pipefail

REPOS_DIR="/opt/kx/repos"
mkdir -p "$REPOS_DIR"

# Branch per repo — keep in sync with pull-dashboards.sh
declare -A REPOS=(
    [liquidity_indicators]=main
    [growth_indicators_dash]=main
    [inflation_indicators]=main
    [seasonality]=master
    [polymarket_analysis]=main
    [momentum_screener_assets]=codex/trend-following-dashboard
    [usd-funding-plumbing-cockpit]=main
    [dealer-repo-fragility-monitor]=main
    [jgb-demand]=main
    [g10_cb_intel]=main
    [g10_ois_meeting_pricer]=main
    [es_nq_session_monitor]=main
)

log()  { printf "\033[1;32m[pull]\033[0m %s\n" "$*"; }
fail() { printf "\033[1;31m[pull]\033[0m %s\n" "$*" >&2; }

if [[ $# -ne 1 ]]; then
    fail "Usage: $0 <repo-name>"
    fail "Known repos: ${!REPOS[*]}"
    exit 1
fi

repo="$1"
if [[ -z "${REPOS[$repo]:-}" ]]; then
    fail "Unknown repo: $repo"
    fail "Known repos: ${!REPOS[*]}"
    exit 1
fi
branch="${REPOS[$repo]}"
target="$REPOS_DIR/$repo"

# Source .env for GITHUB_TOKEN
if [[ -f "$(dirname "$0")/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$(dirname "$0")/.env"
    set +a
fi

# Choose method
ssh_output=$(ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 \
                 -T git@github.com 2>&1 || true)

if echo "$ssh_output" | grep -q "successfully authenticated"; then
    url="git@github.com:xkeecsai/$repo.git"
elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
    url="https://${GITHUB_TOKEN}@github.com/xkeecsai/$repo.git"
else
    fail "No working auth method (SSH failed and no GITHUB_TOKEN). See pull-dashboards.sh for setup."
    exit 1
fi

if [[ -d "$target/.git" ]]; then
    log "Updating $repo ($branch)..."
    git -C "$target" remote set-url origin "$url"
    git -C "$target" fetch --quiet origin "$branch"
    git -C "$target" checkout --quiet "$branch"
    git -C "$target" reset --quiet --hard "origin/$branch"
else
    log "Cloning $repo ($branch)..."
    git clone --quiet --branch "$branch" "$url" "$target"
fi

log "$repo: $(git -C "$target" log -1 --format='%h %s')"
