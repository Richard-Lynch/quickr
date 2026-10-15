# Common developer tasks. `make help` lists them.
SHELL := /bin/bash
BACKEND := cd backend && unset VIRTUAL_ENV && PYTHONPATH=.
FRONTEND := cd frontend &&

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: install
install: ## Install backend + frontend dependencies
	$(BACKEND) uv sync
	$(FRONTEND) pnpm install

.PHONY: db
db: ## Start Postgres only (localhost:5433)
	docker compose up -d --wait db

.PHONY: migrate
migrate: ## Apply database migrations
	$(BACKEND) uv run alembic upgrade head

.PHONY: migration
migration: ## Autogenerate a migration: make migration m="message"
	$(BACKEND) uv run alembic revision --autogenerate -m "$(m)"

.PHONY: api
api: ## Run the API with reload on :8100
	$(BACKEND) uv run uvicorn app.main:app --reload --port 8100

.PHONY: web
web: ## Run the Vite dev server on :5180
	$(FRONTEND) pnpm dev

.PHONY: seed
seed: ## Load demo topics and sessions
	$(BACKEND) uv run python scripts/seed.py

.PHONY: openapi
openapi: ## Regenerate openapi.json from the FastAPI app
	$(BACKEND) uv run python scripts/export_openapi.py ../openapi.json

.PHONY: client
client: openapi ## Regenerate spec + typed TS client/zod schemas
	$(FRONTEND) pnpm gen:api

.PHONY: check
check: check-backend check-frontend ## Run every check CI runs (except docker)

.PHONY: check-backend
check-backend:
	$(BACKEND) uv run ruff check . && uv run ruff format --check . && uv run mypy app scripts tests && uv run pytest -q

.PHONY: check-frontend
check-frontend:
	$(FRONTEND) pnpm format:check && pnpm lint && pnpm typecheck && pnpm test && pnpm build

.PHONY: fmt
fmt: ## Auto-format everything
	$(BACKEND) uv run ruff check --fix . && uv run ruff format .
	$(FRONTEND) pnpm format

.PHONY: up
up: ## Build and run the full stack in docker (web on :8080)
	docker compose up -d --build --wait

.PHONY: down
down: ## Stop the docker stack
	docker compose down

.PHONY: seed-docker
seed-docker: ## Load demo data into the docker stack
	docker compose exec backend python scripts/seed.py
