#!/usr/bin/env bash
# Pull latest from each dashboard repo and roll the stack.
# Run on the droplet from /opt/kx/droplet_infra: `./deploy.sh`
# Or trigger from your laptop: `ssh kx-droplet 'cd /opt/kx/droplet_infra && ./deploy.sh'`

set -euo pipefail

log() { printf "\033[1;32m[deploy]\033[0m %s\n" "$*"; }

cd "$(dirname "$0")"

log "Pulling droplet_infra..."
git pull --ff-only

log "Pulling each dashboard repo..."
./pull-dashboards.sh

log "Rebuilding services..."
docker compose build --pull

log "Bringing services up..."
docker compose up -d --remove-orphans

log "Pruning old images & dangling layers..."
docker system prune -af --volumes=false

log "Status:"
docker compose ps
