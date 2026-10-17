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
seed: ## Load demo topics and entries
	$(BACKEND) uv run python scripts/seed.py

.PHONY: vapid
vapid: ## Print a fresh VAPID key pair for QUICKR_VAPID_PRIVATE_KEY / QUICKR_VAPID_PUBLIC_KEY
	$(BACKEND) uv run python -c "from app.services.push import generate_vapid_keys as g; k = g(); print(f'QUICKR_VAPID_PRIVATE_KEY={k.private_key}'); print(f'QUICKR_VAPID_PUBLIC_KEY={k.public_key}')"

.PHONY: notebook
notebook: ## Open the API exploration notebook (needs the API on :8100; QUICKR_API overrides)
	$(BACKEND) uv run --group notebook jupyter lab notebooks/explore_api.ipynb

.PHONY: openapi
openapi: ## Regenerate openapi.json from the FastAPI app
	$(BACKEND) uv run python scripts/export_openapi.py ../openapi.json

.PHONY: client
client: openapi ## Regenerate spec + typed TS client/zod schemas
	$(FRONTEND) pnpm gen:api

.PHONY: vectors
vectors: ## Regenerate shared/fixtures (due + quick-log vectors, API response fixtures)
	$(BACKEND) QUICKR_UPDATE_VECTORS=1 uv run pytest -q tests/test_due_vectors.py tests/test_quicklog_vectors.py tests/test_api_fixtures.py

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

# --- iOS (ios/). Needs full Xcode 27.x and xcodegen; every target checks first and fails fast.
# Not part of `make check`, which stays Xcode-free. Logic lives in ios/scripts/. See ios/README.md.
IOS_SIM_MIN ?= quickR iOS-26-0
IOS_SIM_CUR ?= quickR iOS27
IOS_SIM ?= $(IOS_SIM_MIN)
IOS_SIM_CI ?= iPhone 17
IOS_SCRIPTS := ios/scripts

.PHONY: ios-gen
ios-gen: ## iOS: generate ios/quickR.xcodeproj from project.yml
	@$(IOS_SCRIPTS)/gen.sh

.PHONY: ios-build
ios-build: ios-gen ## iOS: simulator Debug build (IOS_SIM=name or UDID)
	@$(IOS_SCRIPTS)/build.sh "$(IOS_SIM)"

.PHONY: ios-core-test
ios-core-test: ## iOS: swift test for ios/QuickrKit on the Mac
	@$(IOS_SCRIPTS)/require-xcode.sh
	swift test --package-path ios/QuickrKit

.PHONY: ios-test
ios-test: ios-gen ## iOS: Unit test plan on the iOS 26.0 simulator
	@$(IOS_SCRIPTS)/test.sh Unit "$(IOS_SIM_MIN)"

.PHONY: ios-uitest
ios-uitest: ios-gen ## iOS: UI test plan (IOS_SIM=name or UDID)
	@$(IOS_SCRIPTS)/test.sh UI "$(IOS_SIM)"

.PHONY: ios-lint
ios-lint: ## iOS: swift-format lint
	@$(IOS_SCRIPTS)/lint.sh

.PHONY: ios-fmt
ios-fmt: ## iOS: swift-format in place
	@$(IOS_SCRIPTS)/require-xcode.sh
	cd ios && xcrun swift-format format --in-place --recursive --parallel App AppTests UITests Widgets NotificationService QuickrKit

.PHONY: check-ios
check-ios: ## iOS gate: gen, swift test, Unit + UI plans on iOS 26.0 and 27.0, lint, Xcode version
	@$(IOS_SCRIPTS)/check-ios.sh "$(IOS_SIM_MIN)" "$(IOS_SIM_CUR)"

.PHONY: ios-check-ci
ios-check-ci: ## iOS: what CI runs on a ready PR (gen, build + Unit plan, no signing; IOS_SIM_CI)
	@$(IOS_SCRIPTS)/check-ci.sh "$(IOS_SIM_CI)"

.PHONY: ios-sim-run
ios-sim-run: ios-gen ## iOS: build, install and launch on a simulator (IOS_SIM; URL=quickr://... opens it)
	@$(IOS_SCRIPTS)/sim-run.sh "$(IOS_SIM)" "$(URL)"

IOS_SHOTS ?= docs/ios/demo/m0
.PHONY: ios-shots
ios-shots: ios-gen ## iOS: light + dark screenshots with a clean status bar into IOS_SHOTS
	@$(IOS_SCRIPTS)/shots.sh "$(IOS_SIM)" "$(IOS_SHOTS)"

IOS_GIF ?= docs/ios/demo/m0/launch.gif
.PHONY: ios-demo-record
ios-demo-record: ios-gen ## iOS: record a launch on the simulator and convert to IOS_GIF
	@$(IOS_SCRIPTS)/demo-record.sh "$(IOS_SIM)" "$(IOS_GIF)"

.PHONY: ios-clean
ios-clean: ## iOS: remove the generated project and build output
	rm -rf ios/quickR.xcodeproj ios/build ios/QuickrKit/.build ios/QuickrKit/.swiftpm
