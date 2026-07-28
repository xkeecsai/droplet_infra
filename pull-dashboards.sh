#!/usr/bin/env bash
# Clone or update each dashboard repo into /opt/kx/repos/.
# Tries SSH first; falls back to HTTPS-with-token if GITHUB_TOKEN is set.
#
# To use SSH: add the droplet's public key (~/.ssh/id_ed25519.pub) to
#             https://github.com/settings/keys (account: xkeecsai).
# To use HTTPS+token: set GITHUB_TOKEN=ghp_... in /opt/kx/droplet_infra/.env
#                     (token needs `repo` scope; create at
#                      https://github.com/settings/tokens?type=beta or classic).

set -euo pipefail

REPOS_DIR="/opt/kx/repos"
mkdir -p "$REPOS_DIR"

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
)

log()  { printf "\033[1;32m[pull]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[pull]\033[0m %s\n" "$*"; }
fail() { printf "\033[1;31m[pull]\033[0m %s\n" "$*" >&2; }

# Source .env if it exists (for GITHUB_TOKEN fallback)
if [[ -f "$(dirname "$0")/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$(dirname "$0")/.env"
    set +a
fi

# ---------------------------------------------------------------------------
# Determine clone method
# ---------------------------------------------------------------------------
METHOD=""

# Probe SSH (accept host key on first run, no interactive prompts)
log "Trying SSH auth to GitHub..."
ssh_output=$(ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 \
                 -T git@github.com 2>&1 || true)

if echo "$ssh_output" | grep -q "successfully authenticated"; then
    METHOD="ssh"
    log "SSH auth OK."
elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
    warn "SSH auth failed. GITHUB_TOKEN is set — trying HTTPS+token instead."
    METHOD="https"
else
    fail "Neither SSH nor GITHUB_TOKEN works. Set up one of these:"
    fail ""
    fail "  Option A — SSH (preferred):"
    fail "    cat ~/.ssh/id_ed25519.pub"
    fail "    # paste at https://github.com/settings/ssh/new"
    fail "    # MUST be the xkeecsai account; check the avatar top-right!"
    fail ""
    fail "  Option B — Personal Access Token (faster to debug):"
    fail "    Generate at https://github.com/settings/tokens"
    fail "    (classic token with 'repo' scope, or fine-grained with read access"
    fail "     to the 4 dashboard repos)"
    fail "    Then add to /opt/kx/droplet_infra/.env :"
    fail "      GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx"
    fail ""
    fail "Diagnostic — what GitHub saw from your SSH attempt:"
    fail "$(echo "$ssh_output" | head -5 | sed 's/^/    /')"
    exit 1
fi

# ---------------------------------------------------------------------------
# Clone or fast-forward each repo
# ---------------------------------------------------------------------------
for repo in "${!REPOS[@]}"; do
    branch="${REPOS[$repo]}"
    target="$REPOS_DIR/$repo"

    if [[ "$METHOD" == "ssh" ]]; then
        url="git@github.com:xkeecsai/$repo.git"
    else
        url="https://${GITHUB_TOKEN}@github.com/xkeecsai/$repo.git"
    fi

    if [[ -d "$target/.git" ]]; then
        log "Updating $repo ($branch)..."
        # Update remote URL in case method changed (ssh <-> https)
        git -C "$target" remote set-url origin "$url"
        git -C "$target" fetch --quiet origin "$branch"
        git -C "$target" checkout --quiet "$branch"
        git -C "$target" reset --quiet --hard "origin/$branch"
    else
        log "Cloning $repo ($branch)..."
        git clone --quiet --branch "$branch" "$url" "$target"
    fi
done

log "All dashboards in $REPOS_DIR"
ls -la "$REPOS_DIR"
