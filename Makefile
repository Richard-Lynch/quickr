# Common developer tasks. `make help` lists them.
SHELL := /bin/bash
BACKEND := cd backend && unset VIRTUAL_ENV && export PYTHONPATH=. &&
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

.PHONY: rotate-epoch
rotate-epoch: ## New change-feed epoch (run after a DB restore/reset; clients resync)
	$(BACKEND) uv run python scripts/rotate_epoch.py

.PHONY: rotate-epoch-docker
rotate-epoch-docker: ## rotate-epoch against the docker stack
	docker compose exec backend python scripts/rotate_epoch.py

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
vectors: ## Regenerate shared/fixtures (due, quick-log, answer-text, notification, action-entry-id, home and entries vectors, API response fixtures)
	$(BACKEND) QUICKR_UPDATE_VECTORS=1 uv run pytest -q tests/test_due_vectors.py tests/test_quicklog_vectors.py \
		tests/test_answer_text_vectors.py tests/test_notification_vectors.py tests/test_action_entry_id_vectors.py \
		tests/test_home_vectors.py tests/test_entries_vectors.py tests/test_api_fixtures.py
	$(FRONTEND) QUICKR_UPDATE_VECTORS=1 pnpm exec vitest run src/lib/home.vectors.test.ts
	$(FRONTEND) QUICKR_UPDATE_VECTORS=1 pnpm exec vitest run src/lib/entries.vectors.test.ts

# The database pytest and the migration check use: $QUICKR_TEST_DATABASE_URL if set, else
# quickr_test, or quickr_test_<worktree>_<path hash> in a git worktree (backend/tools/test_database.py).
ifdef QUICKR_TEST_DATABASE_URL
export QUICKR_TEST_DATABASE_URL
endif
TEST_DB := $(BACKEND) uv run python -m tools.test_database

.PHONY: check
check: check-backend check-frontend ## Run every check CI runs (except the docker smoke test)

.PHONY: check-backend
check-backend: ## Backend: lint, types, openapi.json freshness, pytest, migrations match models
	$(BACKEND) uv run ruff check . && uv run ruff format --check . && uv run mypy app scripts tools tests
	@$(MAKE) --no-print-directory check-openapi
	$(BACKEND) uv run pytest -q
	@$(MAKE) --no-print-directory check-migrations

.PHONY: check-openapi
check-openapi: ## openapi.json matches the FastAPI app
	$(BACKEND) out=$$(mktemp) && uv run python scripts/export_openapi.py "$$out" > /dev/null && \
		{ diff -u ../openapi.json "$$out" || { echo "openapi.json is stale - run 'make openapi'"; exit 1; }; }

.PHONY: check-migrations
check-migrations: ## Migrate the test database to head and check the models need no new migration
	$(BACKEND) export QUICKR_DATABASE_URL="$$(uv run python -m tools.test_database ensure)" && uv run alembic upgrade head && uv run alembic check

.PHONY: test-db-reset
test-db-reset: ## Drop this checkout's test database (e.g. migrated before an in-place migration edit); tests recreate it
	$(TEST_DB) reset

.PHONY: test-db-prune
test-db-prune: ## Drop peer test databases crashed runs left (this checkout's, unused, over 1 h old; all=1: every checkout's)
	$(TEST_DB) prune-peers $(if $(all),--all)

.PHONY: check-frontend
check-frontend: ## Frontend: generated client freshness, format, lint, types, tests, build
	@$(MAKE) --no-print-directory check-client
	$(FRONTEND) pnpm format:check && pnpm lint && pnpm typecheck && pnpm test && pnpm build

.PHONY: check-client
check-client: ## src/client matches openapi.json (regenerates it in place, like CI)
	$(FRONTEND) before=$$(mktemp -d) && cp -R src/client "$$before" && pnpm -s gen:api > /dev/null && \
		{ diff -r "$$before/client" src/client || { echo "src/client is stale - run 'make client'"; exit 1; }; }

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
# Preferred model for ios-check-ci, which requires an iOS 26.x runtime whatever the model.
IOS_SIM_CI ?= iPhone 17
IOS_SCRIPTS := ios/scripts

.PHONY: ios-gen
ios-gen: ## iOS: generate ios/quickR.xcodeproj from project.yml
	@$(IOS_SCRIPTS)/gen.sh

.PHONY: ios-build
ios-build: ios-gen ## iOS: simulator Debug build (IOS_SIM=name or UDID)
	@$(IOS_SCRIPTS)/build.sh "$(IOS_SIM)"

.PHONY: ios-core-test
ios-core-test: ## iOS: swift test for ios/QuickrKit on the Mac, strict pool; skips the real-time tests (ios-timing-test)
	@$(IOS_SCRIPTS)/require-xcode.sh
	@$(IOS_SCRIPTS)/swift-test.sh

.PHONY: ios-timing-test
ios-timing-test: ## iOS: the real-time tests (TimingTests, MultiProcessTests) alone and one at a time, normal pool
	@$(IOS_SCRIPTS)/require-xcode.sh
	@$(IOS_SCRIPTS)/timing-test.sh

.PHONY: ios-lifecycle-test
ios-lifecycle-test: ## iOS: the GRDB-suspension lifecycle tests, alone in their own swift test process (swift test skips them)
	@$(IOS_SCRIPTS)/require-xcode.sh
	@QUICKR_LIFECYCLE_TESTS=1 $(IOS_SCRIPTS)/swift-test.sh --filter QuickrLifecycleTests --no-parallel

.PHONY: ios-mp-test
ios-mp-test: ## iOS: the multi-process tests alone, serially, IOS_MP_RUNS times (default 1); ios-timing-test runs them too
	@$(IOS_SCRIPTS)/require-xcode.sh
	@for run in $$(seq 1 $${IOS_MP_RUNS:-1}); do \
		echo "ios-mp-test: run $$run"; \
		$(IOS_SCRIPTS)/timing-test.sh MultiProcessTests || exit 1; \
	done

.PHONY: ios-resolve
ios-resolve: ## iOS: update package pins in ios/QuickrKit/Package.resolved and check Xcode matches
	@$(IOS_SCRIPTS)/resolve.sh

.PHONY: ios-test
ios-test: ios-gen ## iOS: Unit test plan on the iOS 26.0 simulator
	@$(IOS_SCRIPTS)/test.sh Unit "$(IOS_SIM_MIN)"

.PHONY: ios-uitest
ios-uitest: ios-gen ## iOS: UI test plan (IOS_SIM=name or UDID)
	@$(IOS_SCRIPTS)/test.sh UI "$(IOS_SIM)"

.PHONY: ios-lint
ios-lint: ## iOS: swift-format lint (skips with a warning if swift-format is missing)
	@$(IOS_SCRIPTS)/lint.sh --optional

.PHONY: ios-fmt
ios-fmt: ## iOS: swift-format in place
	@$(IOS_SCRIPTS)/require-xcode.sh
	cd ios && xcrun swift-format format --in-place --recursive --parallel App AppTests UITests Widgets NotificationService QuickrKit

.PHONY: ios-script-test
ios-script-test: ## iOS: tests for the shell tooling (xcodebuild watchdog, simulator cap); no Xcode needed
	@$(IOS_SCRIPTS)/tests/watchdog-test.sh
	@$(IOS_SCRIPTS)/tests/sim-cap-test.sh

.PHONY: check-ios
check-ios: ## iOS gate: gen, swift test, Unit + UI plans on iOS 26.0 and 27.0, lint, Xcode version
	@$(IOS_SCRIPTS)/check-ios.sh "$(IOS_SIM_MIN)" "$(IOS_SIM_CUR)"

.PHONY: ios-check-ci
ios-check-ci: ## iOS: what CI runs on a ready PR (gen, build + Unit plan on iOS 26.x, no signing)
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

# Integration harness: this worktree's own docker stacks + fault proxy. See ios/README.md.
.PHONY: ios-integration
ios-integration: ## iOS: integration suite vs this worktree's stacks (up, smoke, tests, down)
	@$(IOS_SCRIPTS)/integration.sh

.PHONY: ios-integration-up
ios-integration-up: ## iOS: start this worktree's integration stacks (writes ios/build/integration.env)
	@$(IOS_SCRIPTS)/integration-up.sh

.PHONY: ios-integration-down
ios-integration-down: ## iOS: stop this worktree's integration stacks
	@$(IOS_SCRIPTS)/integration-down.sh

.PHONY: ios-sim-clone
ios-sim-clone: ## iOS: boot this worktree's own simulator under the cap (created from IOS_SIM_MIN on first use); print its UDID
	@$(IOS_SCRIPTS)/sim-clone.sh "$(IOS_SIM_MIN)"

.PHONY: ios-clean
ios-clean: ## iOS: remove the generated project and build output
	rm -rf ios/quickR.xcodeproj ios/build ios/QuickrKit/.build ios/QuickrKit/.swiftpm
