#!/usr/bin/env bash
# Clone or update each dashboard repo into /opt/kx/repos/.
# Uses SSH so it works with private repos (no tokens, no PATs).
# Prereq: ~/.ssh/id_ed25519 (or similar) added to your GitHub account.
#
# Run:   ./pull-dashboards.sh
# Or:    make pull

set -euo pipefail

REPOS_DIR="/opt/kx/repos"
mkdir -p "$REPOS_DIR"

# repo name -> branch
declare -A REPOS=(
    [liquidity_indicators]=main
    [growth_indicators_dash]=main
    [inflation_indicators]=main
    [seasonality]=master
)

log() { printf "\033[1;32m[pull]\033[0m %s\n" "$*"; }

# Quick auth probe — fail fast with a useful message if SSH isn't set up
log "Checking GitHub SSH auth..."
if ! ssh -o BatchMode=yes -o ConnectTimeout=10 -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
    cat <<EOF >&2

[!] GitHub SSH auth not working from this Droplet.

Set it up with:
    ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "kx-droplet"
    cat ~/.ssh/id_ed25519.pub

Then paste the public key at:
    https://github.com/settings/ssh/new
    (give it a name like "kx-droplet")

Then re-run this script.
EOF
    exit 1
fi
log "SSH auth OK."

for repo in "${!REPOS[@]}"; do
    branch="${REPOS[$repo]}"
    target="$REPOS_DIR/$repo"

    if [[ -d "$target/.git" ]]; then
        log "Updating $repo ($branch)..."
        git -C "$target" fetch --quiet origin "$branch"
        git -C "$target" checkout --quiet "$branch"
        git -C "$target" reset --quiet --hard "origin/$branch"
    else
        log "Cloning $repo ($branch)..."
        git clone --quiet --branch "$branch" "git@github.com:xkeecsai/$repo.git" "$target"
    fi
done

log "All dashboards in $REPOS_DIR"
ls -la "$REPOS_DIR"
