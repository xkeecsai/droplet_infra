# Common ops shortcuts — run from the droplet, /opt/kx/droplet_infra.
# `make help` to list.

.DEFAULT_GOAL := help

help: ## list available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS=":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# ─────────────────────────────────────────────────────────────────────────
# Per-service deploys — daily workflow
# ─────────────────────────────────────────────────────────────────────────

deploy-%: ## pull + rebuild + restart one dashboard, e.g. `make deploy-liquidity`
	@./pull-one.sh $*_indicators 2>/dev/null \
	    || ./pull-one.sh $*_indicators_dash 2>/dev/null \
	    || ./pull-one.sh $* \
	    || (echo "[deploy-$*] could not pull repo — check name"; exit 1)
	docker compose build --pull $*
	docker compose up -d --no-deps $*
	@echo "[deploy-$*] done. Check: docker compose logs $* --tail=20"

deploy-g10-cb-intel: ## pull app + pricer, refresh live data, deploy, and install daily schedule
	@./pull-one.sh g10_cb_intel
	@./pull-one.sh g10_ois_meeting_pricer
	docker compose build --pull g10-cb-intel
	@./refresh-g10-cb-intel.sh
	docker compose up -d --no-deps ts-g10-cb-intel g10-cb-intel
	@install -m 0644 cron/g10-cb-intel /etc/cron.d/g10-cb-intel
	@echo "[deploy-g10-cb-intel] https://g10-cb-intel.$${TAILNET_DOMAIN:-tail284e0d.ts.net}"

schedule-cb-speeches: ## install the daily cb-speeches refresh (02:00 UTC / 06:00 Dubai)
	@install -m 0755 refresh-cb-speeches.sh /opt/kx/droplet_infra/refresh-cb-speeches.sh
	@install -m 0644 cron/cb-speeches /etc/cron.d/cb-speeches
	@systemctl restart cron
	@echo "[schedule-cb-speeches] installed. Verify: run ./refresh-cb-speeches.sh once,"
	@echo "[schedule-cb-speeches] then check source_health.json -> latest_content_at (NOT status)."

rebuild-%: ## rebuild one container without re-pulling its repo
	docker compose build --no-cache $*
	docker compose up -d --no-deps --force-recreate $*

restart-%: ## just restart one container (no rebuild)
	docker compose restart $*

# ─────────────────────────────────────────────────────────────────────────
# Full-stack ops
# ─────────────────────────────────────────────────────────────────────────

up: ## bring stack up (builds if needed)
	docker compose up -d --build

down: ## stop everything (keeps volumes)
	docker compose down

restart: ## restart all services
	docker compose restart

pull: ## clone or git-pull all dashboard repos
	./pull-dashboards.sh

deploy: ## pull ALL repos + rebuild + redeploy everything (slow)
	./deploy.sh

# ─────────────────────────────────────────────────────────────────────────
# Diagnostics & misc
# ─────────────────────────────────────────────────────────────────────────

logs: ## tail logs for all services (Ctrl-C to exit)
	docker compose logs -f --tail=100

logs-%: ## tail logs for one service, e.g. `make logs-liquidity`
	docker compose logs -f --tail=200 $*

ps: ## show running services
	docker compose ps

backup: ## one-off Postgres dump to ./pg_backup
	./backup.sh

psql: ## open psql in the postgres container
	docker compose exec postgres psql -U $${POSTGRES_USER:-kx} -d $${POSTGRES_DB:-macro}

shell-%: ## shell into a service container, e.g. `make shell-liquidity`
	docker compose exec $* /bin/bash || docker compose exec $* /bin/sh

stats: ## live CPU/RAM per container
	docker stats

.PHONY: help up down restart pull deploy deploy-g10-cb-intel logs ps backup psql stats
