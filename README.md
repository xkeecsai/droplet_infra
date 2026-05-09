# droplet_infra

> Meta-repo orchestrating macro dashboards on a single DigitalOcean Droplet.
> **Private-by-default**: only your Tailscale-connected devices can reach the dashboards.
> Real Let's Encrypt HTTPS via Cloudflare DNS-01. No public exposure of the apps.

```
                     Internet
                        │
                  (only port 22 / SSH open)
                        │
                  ╔═════▼═════╗
                  ║  Droplet  ║   tailscale0 interface (100.x.x.x) ──► your devices only
                  ║           ║
                  ║   ┌───────┴───────┐
                  ║   │     Caddy     │  443 reachable only on tailnet
                  ║   │   (auto SSL   │  certs via Cloudflare DNS-01
                  ║   │   via DNS-01) │
                  ║   └────────┬──────┘
                  ║   ┌────────┼────────┬───────────┬─────────────┐
                  ║   ▼        ▼        ▼           ▼             ▼
                  ║ liquidity growth inflation  seasonality   bbg-gateway
                  ║  (8050)  (8051)  (8052)     (8501)        (future)
                  ║                                                       
                  ║   ┌───────────────────────┐
                  ║   │  Postgres (internal)  │  daily backup → pg_backup/
                  ║   └───────────────────────┘
                  ╚═══════════════════════════════════════════════════════
```

---

## What this gives you

- **Private by default** — only your Tailscale-connected devices reach the dashboards
- One Droplet runs **N dashboards + Postgres + Bloomberg gateway** (when ready)
- **Real Let's Encrypt HTTPS** via Cloudflare DNS-01 challenge (no public HTTP needed)
- **Push-to-deploy**: `make deploy` rebuilds dashboards from their GitHub repos
- **Single `.env`** carries every secret/API key
- **Postgres internal-only** — never exposed to anyone, even on the tailnet
- **UFW + fail2ban** baseline security
- **Daily backup** script — wire to cron

---

## One-time setup

### 0. Prereqs (10 min)

- A domain on **Cloudflare** (~$10/yr — Cloudflare Registrar sells at-cost). Required for the DNS-01 cert flow.
- A **Tailscale** account ([free for personal use](https://tailscale.com/pricing/)). Install Tailscale on your laptop, phone, or any device that should access the dashboards.
- A **DigitalOcean** account
- An SSH key on your laptop

### 1. Provision the Droplet

DO web UI:
- **Region:** London (LON1) recommended for Capula proximity
- **OS:** Ubuntu 24.04 (LTS) x64
- **Plan:** Premium AMD, **4 GB RAM / 2 vCPU / $24 mo**
- **Authentication:** SSH key (paste your public key)
- **Hostname:** `kx-macro` or whatever
- Optional: enable backups (+20%; weekly snapshots)

### 2. Generate a Tailscale auth key

[tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys) → **Generate auth key** → "Reusable: no, Ephemeral: no, Pre-approved: yes" → copy the `tskey-...` string.

### 3. Generate a Cloudflare API token

[dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens) → **Create Token** → use template "Edit zone DNS" → restrict to your specific domain → copy the token.

### 4. Bootstrap the Droplet

```bash
ssh root@<droplet-ipv4>

# One-shot remote bootstrap with Tailscale auth
curl -fsSL https://raw.githubusercontent.com/xkeecsai/droplet_infra/main/bootstrap.sh \
  | TS_AUTHKEY=tskey-YOUR-AUTH-KEY bash
```

Bootstrap does:
1. apt update + safe upgrade
2. 2 GB swap
3. **Tailscale install + join your tailnet** (using the auth key)
4. UFW: only SSH on public, everything open on `tailscale0`
5. fail2ban + unattended-upgrades
6. Docker + Compose plugin

When it finishes you'll see the Droplet's **Tailscale IP** (`100.x.x.x`). Note it.

### 5. Cloudflare DNS — point your subdomains at the Tailscale IP

In Cloudflare for your domain, add A records:

| Type | Name | Content | Proxy |
|---|---|---|---|
| A | `liquidity` | `100.x.x.x` (Tailscale IP from step 4) | DNS only (grey cloud) |
| A | `growth` | `100.x.x.x` | DNS only |
| A | `inflation` | `100.x.x.x` | DNS only |
| A | `seasonality` | `100.x.x.x` | DNS only |

The IP is publicly visible in DNS but only routable on your tailnet — anyone trying to connect from the public internet will time out. Cloudflare proxy stays **off** because we're not using public HTTP.

### 6. Clone & configure on the Droplet

```bash
# (still SSHed into the droplet)
cd /opt/kx
git clone https://github.com/xkeecsai/droplet_infra.git
cd droplet_infra

cp .env.example .env
nano .env       # set POSTGRES_PASSWORD + CLOUDFLARE_API_TOKEN; paste any API keys
nano Caddyfile  # replace kxmacro.com with your real domain (4-5 places)
```

### 7. Up

```bash
docker compose up -d --build
```

First build takes ~3-5 minutes (clones + builds 4 dashboards + custom Caddy with Cloudflare plugin). Caddy then provisions Let's Encrypt certs via DNS-01 — wait ~30 seconds.

### 8. Test from your laptop (must be on Tailscale)

```
https://liquidity.your-domain.com   ✅
https://growth.your-domain.com      ✅
https://inflation.your-domain.com   ✅
https://seasonality.your-domain.com ✅
```

From a device **not** on your tailnet: the connection times out. The dashboards are invisible.

---

## Day-to-day operations

```bash
make help              # list targets
make deploy            # pull all dashboard repos, rebuild, redeploy
make logs              # tail combined logs
make ps                # docker compose ps
make psql              # psql shell into the database
make backup            # one-off Postgres dump → pg_backup/
make shell-liquidity   # bash into a specific container
make reload-caddy      # reload Caddy config without restarting
```

### Schedule daily backups

```bash
# crontab -e
0 3 * * *  cd /opt/kx/droplet_infra && ./backup.sh > /var/log/kx-backup.log 2>&1
```

### Add a new dashboard

1. Create the dashboard repo with a `Dockerfile` (port `808N`)
2. Add to `docker-compose.yml`:
   ```yaml
   newdash:
     build:
       context: https://github.com/xkeecsai/newdash.git#main
     container_name: newdash
     restart: unless-stopped
     environment:
       PORT: "8053"
     expose: ["8053"]
     networks: [kx]
   ```
3. Add to `Caddyfile`:
   ```
   newdash.your-domain.com {
       reverse_proxy newdash:8053
   }
   ```
4. Add the Cloudflare A record `newdash → 100.x.x.x`
5. `make deploy` — Caddy auto-provisions a cert via DNS-01

### Add a new device to your tailnet

Install Tailscale on the device → log in to the same account → done. The device immediately can reach `https://liquidity.your-domain.com` etc.

### Share access with a colleague (optional)

Tailscale → Admin → **Users** → invite their email. They install Tailscale, join your tailnet, and now the dashboards work for them too. Revoke instantly by removing them.

### Wire up Bloomberg

When Capula gives you a B-PIPE allocation:

1. Build a `bbg_gateway` repo — small Python service exposing a REST/gRPC API in front of `blpapi`. Pulls on a schedule, writes to Postgres.
2. Get the Droplet's public IP whitelisted by Capula's network team (the Droplet still has an outbound public IP — the firewall just blocks inbound)
3. Uncomment the `bbg-gateway` block in `docker-compose.yml`, point at your repo
4. `make deploy`
5. Dashboards now read from Postgres; Bloomberg complexity is contained in one container

---

## Cost summary

| Component | Cost/mo |
|---|---|
| DO Droplet (4GB Premium AMD) | $24 |
| DO weekly backups (optional, +20%) | +$5 |
| Cloudflare DNS + domain | ~$1 (annual ~$10) |
| Tailscale Personal | $0 (free up to 3 users / 100 devices) |
| **Subtotal** | **$25–30** |
| + paid data feeds (when you subscribe) | varies |

This handles 3-10 dashboards comfortably. Bump to 8GB ($48/mo) if you go heavy on background jobs.

---

## Migration & disaster recovery

### Resize the Droplet

DO **resize** flow keeps the same machine (same Tailscale ID, same IP, same DNS) — just gives it more RAM/CPU. Simplest path to scale up.

### Move to a fresh Droplet

```bash
# On old droplet
docker compose down
tar czf /tmp/pg_data.tar.gz -C /var/lib/docker/volumes pg_data

# scp to new droplet, extract, run bootstrap.sh + docker compose up
# Volume names match → Postgres data is preserved
# Update Cloudflare DNS A records to point at the new Tailscale IP
```

### Restore from backup

```bash
make psql
# DROP DATABASE macro;
# CREATE DATABASE macro;
# \q
docker compose exec -T postgres pg_restore \
    --username kx \
    --dbname macro \
    < pg_backup/macro_YYYYMMDD_HHMMSS.dump
```

---

## Security notes

- Tailscale provides end-to-end WireGuard encryption — no need to trust the network between you and the Droplet
- SSH on port 22 by default; consider changing to a high port + adding it to `bootstrap.sh`'s UFW rules
- Postgres is **never** exposed — only reachable from inside the `kx` Docker network
- `.env` is gitignored — never commit secrets
- Cloudflare API token is scoped to one domain's DNS only (no other permissions)
- For maximum paranoia: enable Tailscale **node attestation** + **device-posture checks** on the admin console

---

*Sister repos:*
- [liquidity_indicators](https://github.com/xkeecsai/liquidity_indicators)
- [growth_indicators_dash](https://github.com/xkeecsai/growth_indicators_dash)
- [inflation_indicators](https://github.com/xkeecsai/inflation_indicators)
- [seasonality](https://github.com/xkeecsai/seasonality)
