# droplet_infra

> Personal macro dashboards on a single DigitalOcean Droplet, accessible only from your Tailscale network.
> No custom domain, no Cloudflare, no Caddy. Each dashboard gets its own auto-HTTPS URL via Tailscale Serve.

```
                     Internet
                        │
                  (only port 22 / SSH open)
                        │
                  ╔═════▼═════════════════════════════════════╗
                  ║  Droplet (Ubuntu 24.04)                   ║
                  ║                                           ║
                  ║   Postgres ◄──── kx network               ║
                  ║      ▲                                    ║
                  ║      │                                    ║
                  ║   ┌──┴────────────────────────────┐       ║
                  ║   │ Dashboards (Dash + Streamlit) │       ║
                  ║   └──┬──┬──┬──┬────────────────────┘      ║
                  ║      │  │  │  │                          ║
                  ║   ┌──▼──▼──▼──▼─────────────────┐         ║
                  ║   │ Tailscale sidecars + Serve   │        ║
                  ║   │ (auto Let's Encrypt HTTPS)   │        ║
                  ║   └──────────┬───────────────────┘        ║
                  ╚══════════════╪════════════════════════════╝
                                 │
                                 ▼
                          ╔══════════════╗
                          ║  Your tailnet ║   ◄── only your devices
                          ╚══════════════╝
```

---

## What you get

- **Private by default** — only your Tailscale-connected devices can reach the dashboards
- **Real Let's Encrypt HTTPS** — Tailscale issues + renews certs automatically
- **No domain to buy, no DNS to configure** — URLs are `https://<service>.<your-tailnet>.ts.net`
- One Droplet runs all dashboards + Postgres + (eventually) Bloomberg gateway
- **Push-to-deploy**: `make deploy` rebuilds dashboards from their GitHub repos

---

## One-time setup (~10 minutes)

### 0. Prereqs

- [Tailscale](https://tailscale.com/) account, free tier. Install it on your laptop + phone first so you have something to connect *from*.
- DigitalOcean account
- SSH key on your laptop (you've already got one)

### 1. Generate a Tailscale auth key

[login.tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys) → **Generate auth key**:

- **Reusable: YES** ← important; the host + 4 sidecars all use this key
- **Ephemeral: NO** ← so containers keep their identity across restarts
- **Pre-approved: YES** ← skips manual approval per device
- **Expiration: 90 days** is fine

Copy the `tskey-...` string. You'll use it twice (once for bootstrap, once in `.env`).

### 2. Provision the Droplet

DO web UI:
- **Region:** London (LON1)
- **OS:** Ubuntu 24.04 (LTS) x64
- **Plan:** Premium AMD, **4 GB RAM / 2 vCPU / $24 mo**
- **Authentication:** SSH key (the one you added)
- **Hostname:** `kx-macro`

### 3. Bootstrap the Droplet

```bash
ssh root@<droplet-public-ip>
curl -fsSL https://raw.githubusercontent.com/xkeecsai/droplet_infra/main/bootstrap.sh \
  | TS_AUTHKEY=tskey-YOUR-KEY-HERE bash
```

Bootstrap installs Tailscale on the host, joins your tailnet, locks down the firewall (SSH only on public), installs Docker. ~3 minutes.

### 4. Clone & configure

Still SSHed into the droplet:

```bash
cd /opt/kx
git clone https://github.com/xkeecsai/droplet_infra.git
cd droplet_infra

cp .env.example .env
nano .env       # set POSTGRES_PASSWORD + paste TS_AUTHKEY (same one as bootstrap)
```

### 5. Up

```bash
docker compose up -d --build
```

First build: ~5 minutes (clones + builds 4 dashboards, pulls Tailscale image, joins each sidecar to your tailnet). After this completes, in your Tailscale admin you'll see 5 devices: `kx-macro`, `liquidity`, `growth`, `inflation`, `seasonality`.

Tailscale Serve provisions HTTPS certs for each in the background. Wait ~30 seconds and:

```
https://liquidity.<your-tailnet>.ts.net   ✅
https://growth.<your-tailnet>.ts.net      ✅
https://inflation.<your-tailnet>.ts.net   ✅
https://seasonality.<your-tailnet>.ts.net ✅
```

Find your tailnet name in the Tailscale admin sidebar (looks like `tail-xxxx.ts.net` or your custom alias).

### 6. Test from devices not on your tailnet

The connections time out. The dashboards are invisible to anyone not on your tailnet.

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
make deploy-g10-cb-intel # pull app + pricer, foreground refresh, deploy, install cron
```

### Schedule daily backups

```bash
# crontab -e
0 3 * * *  cd /opt/kx/droplet_infra && ./backup.sh > /var/log/kx-backup.log 2>&1
```

### G10 Central Bank Intelligence

The private service is `https://g10-cb-intel.<tailnet>.ts.net` and defaults to port `8067`. Its operational image installs curl, serves `app:server` with Gunicorn, and shares durable snapshot/pricer-cache volumes with the refresh job.

```bash
make deploy-g10-cb-intel
curl --fail https://g10-cb-intel.<tailnet>.ts.net/healthz
```

`cron/g10-cb-intel` runs the synchronous foreground refresh at `04:30 UTC` (`08:30 Dubai`) and logs to `/var/log/g10-cb-intel-refresh.log`. The deploy target installs it in `/etc/cron.d/g10-cb-intel`. Every run archives a provenance manifest under the dashboard data volume, preserves prior accumulated history on a failed fetch, and restarts the app so Runtime Status reports the outcome.

### Add a new dashboard

1. Create the dashboard repo with a `Dockerfile` (port `808N`)
2. Add to `docker-compose.yml` — copy the `ts-liquidity` + `liquidity` block, change names + ports + repo URL
3. Add `tailscale/<name>-serve.json`:
   ```json
   {
     "TCP": {"443": {"HTTPS": true}},
     "Web": {"${TS_CERT_DOMAIN}:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8053"}}}}
   }
   ```
4. Add `ts-<name>-state` to the `volumes:` block
5. `make deploy` — Tailscale registers the new sidecar and provisions a cert

### Add a new device to your tailnet

Install Tailscale on the device → log in → done. The new device immediately can reach all dashboards.

### Rotate the Tailscale auth key

When the key expires (90 days), generate a new one in the Tailscale admin, update `.env`, and `docker compose up -d`. Existing devices stay registered (auth keys are only used for first registration).

### Wire up Bloomberg

When Capula gives you a B-PIPE allocation:

1. Build a `bbg_gateway` repo — Python service exposing a small REST API in front of `blpapi`
2. Get the Droplet's public IPv4 whitelisted by Capula's network team
3. Uncomment the `ts-bbg` + `bbg-gateway` blocks in `docker-compose.yml`, point at your repo
4. `make deploy`
5. Dashboards read from Postgres; the Bloomberg complexity is contained in one container

---

## Cost summary

| Component | Cost/mo |
|---|---|
| DO Droplet (4GB Premium AMD) | $24 |
| DO weekly backups (optional) | +$5 |
| Tailscale Personal | $0 (free up to 3 users / 100 devices) |
| **Subtotal** | **$24–29** |
| + paid data feeds (when you subscribe) | varies |

Each sidecar counts as one of your 100 free Tailscale devices. With 4 dashboards + the host you're at 5 devices. Plenty of room.

---

## Migration & disaster recovery

### Resize the Droplet

DO **resize** flow keeps the same machine, just gives it more RAM/CPU. Tailscale identities and Postgres data persist.

### Move to a fresh Droplet

```bash
# On old droplet
docker compose down
tar czf /tmp/pg_data.tar.gz -C /var/lib/docker/volumes pg_data
# scp to new droplet, extract into the same volume location
# Re-run bootstrap.sh + docker compose up
# Tailscale state lives in named volumes, also tar+restore those if you want
# device identities preserved (otherwise they re-register fresh)
```

### Restore Postgres from backup

```bash
make psql
# DROP DATABASE macro; CREATE DATABASE macro; \q
docker compose exec -T postgres pg_restore --username kx --dbname macro \
    < pg_backup/macro_YYYYMMDD_HHMMSS.dump
```

---

## Security notes

- Tailscale provides end-to-end WireGuard encryption. Traffic between your laptop and the Droplet is encrypted regardless of the network you're on.
- Postgres is **never** exposed to anyone — internal Docker network only.
- `.env` is gitignored. Never commit secrets.
- SSH on port 22 stays open publicly so you can recover if Tailscale ever has issues. To close it (force all SSH via Tailscale): `ufw delete allow OpenSSH` after confirming Tailscale SSH (`tailscale ssh root@kx-macro`) works.
- Tailscale auth keys expire (default 90 days). Set a calendar reminder to rotate.

---

*Sister repos:*
- [liquidity_indicators](https://github.com/xkeecsai/liquidity_indicators)
- [growth_indicators_dash](https://github.com/xkeecsai/growth_indicators_dash)
- [inflation_indicators](https://github.com/xkeecsai/inflation_indicators)
- [seasonality](https://github.com/xkeecsai/seasonality)
