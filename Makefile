# Common ops shortcuts — run from the droplet, /opt/kx/kx-infra.
# `make help` to list.

.DEFAULT_GOAL := help

help: ## list available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS=":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

up: ## bring stack up (builds if needed)
	docker compose up -d --build

down: ## stop everything (keeps volumes)
	docker compose down

restart: ## restart all services
	docker compose restart

deploy: ## pull + rebuild + redeploy
	./deploy.sh

logs: ## tail logs (Ctrl-C to exit)
	docker compose logs -f --tail=100

ps: ## show running services
	docker compose ps

backup: ## one-off Postgres dump to ./pg_backup
	./backup.sh

psql: ## open psql in the postgres container
	docker compose exec postgres psql -U $${POSTGRES_USER:-kx} -d $${POSTGRES_DB:-macro}

shell-%: ## shell into a service container, e.g. `make shell-liquidity`
	docker compose exec $* /bin/bash || docker compose exec $* /bin/sh

reload-caddy: ## reload Caddy config without restarting
	docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile

.PHONY: help up down restart deploy logs ps backup psql reload-caddy
