# droplet_infra

> Meta-repo orchestrating the macro dashboards on a single DigitalOcean Droplet.
> Each dashboard lives in its own repo. Caddy + Docker Compose + Postgres on top.

```
                    Internet
                       │
                  ┌────▼────┐  Let's Encrypt auto-renewal
                  │  Caddy  │  ports 80/443
                  └────┬────┘
       ┌──────────┬────┼────┬───────────┬──────────────┐
       ▼          ▼    ▼    ▼           ▼              ▼
  liquidity    growth inflation seasonality  bbg-gateway  ingestor
   (8050)      (8051)  (8052)    (8501)      (future)     (future)
       │          │      │          │             │           │
       └──────────┴──────┴──────────┴─────────────┴───────────┘
                              │
                       ┌──────▼──────┐
                       │  Postgres   │  named volume, daily dump → pg_backup/
                       └─────────────┘
```

---

## What this gives you

- One Droplet runs **N dashboards + Postgres + Bloomberg gateway** (when ready)
- **Auto-HTTPS** via Caddy (no certbot dance)
- **Push-to-deploy**: dashboard repos rebuild on demand via `make deploy`
- **Single `.env`** carries every secret/API key
- **Postgres internal-only** — never exposed to the internet
- **UFW + fail2ban** baseline security
- **Daily backup** script — wire to cron

---

## One-time setup

### 0. Prereqs (5 min)

- A domain you control (Cloudflare/Namecheap, ~$10/yr)
- A DO account
- An SSH key on your laptop

### 1. Provision the Droplet

DO web UI:
- **Region:** London (LON1) recommended for Capula proximity
- **OS:** Ubuntu 24.04 (LTS) x64
- **Plan:** Premium AMD, **4 GB RAM / 2 vCPU / $24 mo** (right-size as you grow)
- **Authentication:** SSH key (paste your public key)
- **Hostname:** `kx-macro-1` or whatever
- Optional: enable backups (+20% on the price; 4-week weekly snapshots)

Or via `doctl`:

```bash
doctl compute droplet create kx-macro-1 \
    --image ubuntu-24-04-x64 \
    --size s-2vcpu-4gb-amd \
    --region lon1 \
    --ssh-keys <your-key-id>
```

### 2. DNS — point your domain at the Droplet

In Cloudflare (or your registrar), add **A records** for each subdomain pointing at the Droplet's IPv4:

| Type | Name | Content | Proxy |
|---|---|---|---|
| A | `liquidity` | `<droplet-ipv4>` | DNS-only first time (orange→grey) |
| A | `growth` | `<droplet-ipv4>` | DNS-only |
| A | `inflation` | `<droplet-ipv4>` | DNS-only |
| A | `seasonality` | `<droplet-ipv4>` | DNS-only |

Set Cloudflare proxy to **DNS-only** for the first deploy — Caddy needs to talk to Let's Encrypt directly. Once cert provisioning succeeds you can flip to "Proxied" if you want CDN/DDoS protection (with Caddy in `trusted_proxies cloudflare` mode).

### 3. Bootstrap the Droplet

```bash
ssh root@<droplet-ipv4>

# (one-shot remote bootstrap)
curl -fsSL https://raw.githubusercontent.com/xkeecsai/droplet_infra/main/bootstrap.sh | bash
```

Or copy `bootstrap.sh` over and run it manually. It's idempotent — safe to re-run.

### 4. Clone & configure

Still on the droplet:

```bash
cd /opt/kx
git clone https://github.com/xkeecsai/droplet_infra.git
cd droplet_infra

cp .env.example .env
nano .env       # set POSTGRES_PASSWORD; paste any API keys you have
nano Caddyfile  # replace kxmacro.com with your real domain (4 places)
```

### 5. Up

```bash
docker compose up -d --build
```

First build takes ~3-5 minutes (clones each dashboard repo + builds image). Subsequent builds are cached.

Caddy provisions Let's Encrypt certs in the background — give it 30-60 seconds, then:

```
https://liquidity.<your-domain>.com   ✅
https://growth.<your-domain>.com      ✅
https://inflation.<your-domain>.com   ✅
https://seasonality.<your-domain>.com ✅
```

---

## Day-to-day operations

```bash
make help           # list targets
make deploy         # pull all dashboard repos, rebuild, redeploy
make logs           # tail combined logs
make ps             # docker compose ps
make psql           # psql shell into the database
make backup         # one-off Postgres dump → pg_backup/
make shell-liquidity   # bash into a specific container
```

### Schedule daily backups

```bash
# Add to root crontab (`crontab -e`)
0 3 * * *  cd /opt/kx/droplet_infra && ./backup.sh > /var/log/kx-backup.log 2>&1
```

Optional — push dumps off-droplet to DO Spaces or S3 for true durability:

```bash
apt-get install s3cmd
# Configure once, then uncomment the s3cmd line at the bottom of backup.sh
```

### Add a new dashboard

1. Create the dashboard repo with a `Dockerfile` (port `808N`, follows the same template)
2. Add to `docker-compose.yml`:
   ```yaml
   newdash:
     build:
       context: https://github.com/<you>/newdash.git#main
     container_name: newdash
     restart: unless-stopped
     environment:
       PORT: "8053"
     expose: ["8053"]
     networks: [kx]
   ```
3. Add to `Caddyfile`:
   ```
   newdash.<your-domain>.com {
       reverse_proxy newdash:8053
   }
   ```
4. Add the DNS A record
5. `make up` — Caddy provisions a cert for the new subdomain on the fly

### Rotate the Postgres password

```bash
# Inside postgres
make psql
# \password kx    -- change password
# \q
nano .env       # update POSTGRES_PASSWORD to match
docker compose up -d  # restarts services with new env
```

### Wire up Bloomberg

When Capula gives you a B-PIPE allocation:

1. Build a `bbg_gateway` repo — small Python service exposing a REST/gRPC API in front of `blpapi`. Pulls on a schedule, writes to Postgres.
2. Get the Droplet's egress IP whitelisted by Capula's network team
3. Uncomment the `bbg-gateway` block in `docker-compose.yml`, point at your repo
4. `make deploy`
5. Dashboards now read from Postgres; Bloomberg complexity is contained in one container

---

## Cost summary

| Component | Cost/mo |
|---|---|
| DO Droplet (4GB Premium AMD) | $24 |
| DO weekly backups (optional, +20%) | +$5 |
| Cloudflare DNS + domain | $1 (annual ~$10) |
| **Subtotal** | **$25–30** |
| + paid data feeds (when you subscribe) | varies |

This handles 3-10 dashboards comfortably. Bump to 8GB ($48/mo) if you go heavy on background jobs.

---

## Migration & disaster recovery

### Move to a bigger Droplet

```bash
# On old droplet
docker compose down
tar czf /tmp/pg_data.tar.gz -C /var/lib/docker/volumes pg_data

# scp /tmp/pg_data.tar.gz to new droplet, extract, run bootstrap.sh + compose up.
# Volume names match → Postgres data is preserved.
```

Or use DO's **resize** flow — keeps the same machine, just gives it more RAM/CPU. Simpler.

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

- SSH on port 22 by default; consider changing to a high port + adding it to `bootstrap.sh`'s UFW rules
- Postgres is **never** exposed to the internet — only reachable from inside the `kx` Docker network
- `.env` is gitignored — never commit secrets
- Caddy logs are inside the `caddy_data` volume; rotate manually if they grow large
- For zero-public-exposure setups, install Tailscale on the Droplet and remove the UFW 80/443 rules — only Tailscale-connected devices can hit it

---

*Sister repos:*
- [liquidity_indicators](https://github.com/xkeecsai/liquidity_indicators)
- [growth_indicators_dash](https://github.com/xkeecsai/growth_indicators_dash)
- [inflation_indicators](https://github.com/xkeecsai/inflation_indicators)
- [seasonality](https://github.com/xkeecsai/seasonality)
