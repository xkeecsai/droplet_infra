#!/usr/bin/env bash
# Idempotent first-time setup for a fresh Ubuntu 24.04 droplet.
# PRIVATE-BY-DEFAULT: installs Tailscale, closes public ports 80/443.
# Only your tailnet devices will be able to reach the dashboards.
#
# Run as root via DO console:
#   curl -fsSL https://raw.githubusercontent.com/xkeecsai/droplet_infra/main/bootstrap.sh | TS_AUTHKEY=tskey-... bash
#
# Or copy the file over and run manually.
#
# Required env vars when running:
#   TS_AUTHKEY          (recommended) — generate at tailscale.com/admin/settings/keys
#                       Without this, you'll need to authenticate Tailscale interactively.

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

# ---- Tailscale ----
if ! command -v tailscale >/dev/null 2>&1; then
    log "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
fi

systemctl enable --now tailscaled

if [[ -n "${TS_AUTHKEY:-}" ]]; then
    log "Joining tailnet via auth key..."
    tailscale up \
        --authkey="${TS_AUTHKEY}" \
        --ssh \
        --hostname="kx-macro" \
        --accept-routes
else
    log "No TS_AUTHKEY provided — bringing up Tailscale interactively."
    log "Open the URL printed below on any device, then re-run bootstrap.sh."
    tailscale up --ssh --hostname="kx-macro" --accept-routes || true
fi

# Show tailnet IP
TS_IP=$(tailscale ip -4 || echo "<not-yet-joined>")
log "Tailscale IPv4: ${TS_IP}"

# ---- Firewall: only SSH on public, full open on tailscale0 ----
log "Configuring UFW (public: SSH only; tailnet: everything)..."
apt-get install -y ufw fail2ban
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH

# Open all ports on the tailscale0 interface (for tailnet-only ingress)
ufw allow in on tailscale0

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

if ! docker compose version >/dev/null 2>&1; then
    log "Docker compose plugin missing — installing..."
    apt-get install -y docker-compose-plugin
fi

# ---- Project dir ----
mkdir -p /opt/kx
chown root:root /opt/kx

log "Done."
cat <<EOF

╔══════════════════════════════════════════════════════════════════╗
║  Bootstrap complete. Tailscale IPv4: ${TS_IP}
║                                                                  ║
║  Public surface: only SSH (port 22) reachable from the internet. ║
║  Dashboards will be reachable ONLY from your tailnet.            ║
║                                                                  ║
║  Next steps:                                                     ║
║                                                                  ║
║    cd /opt/kx                                                    ║
║    git clone https://github.com/xkeecsai/droplet_infra.git       ║
║    cd droplet_infra                                              ║
║    cp .env.example .env                                          ║
║    nano .env                                                     ║
║      # set POSTGRES_PASSWORD                                     ║
║      # set CLOUDFLARE_API_TOKEN (Zone:DNS:Edit on your domain)   ║
║      # paste any other API keys you have                         ║
║    nano Caddyfile     # replace kxmacro.com with your domain     ║
║                                                                  ║
║  In Cloudflare DNS, add A records pointing at ${TS_IP}:
║      liquidity   A    ${TS_IP}
║      growth      A    ${TS_IP}
║      inflation   A    ${TS_IP}
║      seasonality A    ${TS_IP}
║                                                                  ║
║  Set Cloudflare proxy = "DNS only" (grey cloud). The IP is in    ║
║  the Tailscale 100.x.x.x range so only tailnet devices can       ║
║  actually connect. Cloudflare DNS-01 still works because it      ║
║  validates via the DNS TXT record, not HTTP on the IP.           ║
║                                                                  ║
║  Then:  docker compose up -d --build                             ║
╚══════════════════════════════════════════════════════════════════╝
EOF
