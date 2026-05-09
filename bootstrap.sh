#!/usr/bin/env bash
# Idempotent first-time setup for a fresh Ubuntu 24.04 droplet.
# PRIVATE-BY-DEFAULT: dashboards are reachable only via your Tailscale tailnet.
# Each dashboard has its own Tailscale sidecar with auto-HTTPS.
#
# Run as root via DO console:
#   curl -fsSL https://raw.githubusercontent.com/xkeecsai/droplet_infra/main/bootstrap.sh | TS_AUTHKEY=tskey-... bash
#
# Required env var:
#   TS_AUTHKEY  Reusable + non-ephemeral auth key from
#               https://login.tailscale.com/admin/settings/keys
#               (used here for the host AND by sidecar containers later)

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

# ---- Tailscale on host ----
if ! command -v tailscale >/dev/null 2>&1; then
    log "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
fi

systemctl enable --now tailscaled

if [[ -n "${TS_AUTHKEY:-}" ]]; then
    log "Joining tailnet via auth key (host)..."
    tailscale up \
        --authkey="${TS_AUTHKEY}" \
        --ssh \
        --hostname="kx-macro" \
        --accept-routes
else
    log "No TS_AUTHKEY provided — bringing up Tailscale interactively."
    log "After auth completes, re-run with TS_AUTHKEY for sidecars."
    tailscale up --ssh --hostname="kx-macro" --accept-routes || true
fi

TS_IP=$(tailscale ip -4 || echo "<not-yet-joined>")
log "Tailscale IPv4 (host): ${TS_IP}"

# ---- Firewall: only SSH on public ----
log "Configuring UFW (public: SSH only)..."
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

╔══════════════════════════════════════════════════════════════════════╗
║  Bootstrap complete.                                                 ║
║                                                                      ║
║  Host on tailnet: kx-macro (${TS_IP})
║  Public surface: only SSH (port 22).                                 ║
║                                                                      ║
║  Next steps:                                                         ║
║                                                                      ║
║    cd /opt/kx                                                        ║
║    git clone https://github.com/xkeecsai/droplet_infra.git           ║
║    cd droplet_infra                                                  ║
║    cp .env.example .env                                              ║
║    nano .env                                                         ║
║      # set POSTGRES_PASSWORD                                         ║
║      # paste TS_AUTHKEY (same key, REUSABLE non-ephemeral)           ║
║      # paste any optional API keys                                   ║
║                                                                      ║
║    docker compose up -d --build                                      ║
║                                                                      ║
║  Once up, your dashboards will appear in your Tailscale admin as     ║
║  separate devices: liquidity, growth, inflation, seasonality.        ║
║                                                                      ║
║  Access from any tailnet-connected device at:                        ║
║                                                                      ║
║    https://liquidity.<your-tailnet>.ts.net                           ║
║    https://growth.<your-tailnet>.ts.net                              ║
║    https://inflation.<your-tailnet>.ts.net                           ║
║    https://seasonality.<your-tailnet>.ts.net                         ║
║                                                                      ║
║  (Real Let's Encrypt certs, auto-issued by Tailscale. No domain      ║
║   purchase, no DNS config, no Caddy needed.)                         ║
║                                                                      ║
║  Find your tailnet's name in the Tailscale admin sidebar.            ║
╚══════════════════════════════════════════════════════════════════════╝
EOF
