#!/usr/bin/env bash
# Idempotent first-time setup for a fresh Ubuntu 24.04 droplet.
# Run as root via DO console or `ssh root@<ip> 'bash -s' < bootstrap.sh`.
#
# What this does:
#   1. apt update + safe upgrade
#   2. 2 GB swap (helps small droplets when builds run hot)
#   3. UFW firewall: only ssh / 80 / 443 inbound
#   4. fail2ban (SSH brute-force protection)
#   5. Docker + Docker Compose plugin
#   6. Unattended-upgrades for security patches
#   7. Creates /opt/kx and tells you what to do next

set -euo pipefail

log() { printf "\033[1;36m[bootstrap]\033[0m %s\n" "$*"; }

if [[ $EUID -ne 0 ]]; then
    echo "Run as root." >&2
    exit 1
fi

log "Updating apt..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"

# ---- Swap ----
if ! swapon --show | grep -q '/swapfile'; then
    log "Creating 2 GB swap..."
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# ---- Firewall ----
log "Installing & configuring UFW..."
apt-get install -y ufw fail2ban
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw --force enable
systemctl enable --now fail2ban

# ---- Auto security patches ----
log "Enabling unattended-upgrades..."
apt-get install -y unattended-upgrades
dpkg-reconfigure -f noninteractive unattended-upgrades

# ---- Docker ----
if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
fi

# Verify compose plugin
if ! docker compose version >/dev/null 2>&1; then
    log "Docker compose plugin missing — installing..."
    apt-get install -y docker-compose-plugin
fi

# ---- Project dir ----
mkdir -p /opt/kx
chown root:root /opt/kx

log "Done."
cat <<EOF

╔════════════════════════════════════════════════════════════════╗
║  Bootstrap complete. Next steps:                               ║
║                                                                ║
║    cd /opt/kx                                                  ║
║    git clone https://github.com/xkeecsai/droplet_infra.git     ║
║    cd droplet_infra                                            ║
║    cp .env.example .env                                        ║
║    nano .env             # set POSTGRES_PASSWORD etc.          ║
║    nano Caddyfile        # replace kxmacro.com with your domain║
║                                                                ║
║    # Point your domain DNS A records at this droplet IP first  ║
║    # then bring services up:                                   ║
║                                                                ║
║    docker compose up -d --build                                ║
║                                                                ║
║  Caddy will auto-provision Let's Encrypt certs once DNS is OK. ║
╚════════════════════════════════════════════════════════════════╝
EOF
