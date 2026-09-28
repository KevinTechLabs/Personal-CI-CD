# Developer shortcuts. Requires uv (https://docs.astral.sh/uv/) and Docker.
.PHONY: lock sync lint test test-agent dev dev-down smoke

COMPOSE_DEV = APP_IMAGE=personal-ci-cd:local APP_VERSION=local POSTGRES_PASSWORD=devpassword \
	docker compose -p cicd-dev -f deploy/compose/compose.yaml -f deploy/compose/compose.dev.yaml \
	--env-file deploy/compose/staging.env

lock:            ## regenerate uv.lock after editing dependencies in pyproject.toml
	uv lock

sync:
	uv sync --locked

lint: sync
	uv run ruff check . && uv run ruff format --check . && uv run bandit -c pyproject.toml -r app -q

test: sync       ## runs against the `make dev` Postgres on localhost:5432 (resets its schema)
	DATABASE_URL=postgresql+psycopg://app:devpassword@localhost:5432/app uv run pytest --cov

test-agent:
	tests/agent/run.sh

dev:             ## full stack from source on http://localhost:8081
	docker network inspect observability >/dev/null 2>&1 || docker network create observability
	$(COMPOSE_DEV) build
	$(COMPOSE_DEV) run --rm migrate
	$(COMPOSE_DEV) up -d --wait db api worker

smoke:
	scripts/smoke-test.sh http://localhost:8081

dev-down:
	$(COMPOSE_DEV) down -v
