# quickR

Config-driven data capture. Create **topics**, give each an ordered set of typed
**questions**, and record **sessions** (one set of answers) from your phone, the
API, or an MCP client. Then browse, edit, aggregate and export the results.

- **Question types:** `int` (min/max, unit), `double` (min/max, decimals, unit),
  `str` (min/max length, multiline), `enum` (options configured up front,
  archivable).
- **Every session records** its `source`, `captured_at`, `channel` (ui/api/mcp),
  the topic `version`, `notes` and free-form `meta`.
- **Safe evolution:** topics are versioned. Each session is pinned to the
  version it was recorded against, so historic answers always stay
  interpretable.

## Architecture

```
frontend/  React 19 + TS (strict) + Vite + Tailwind + TanStack Query + react-hook-form/zod
           └─ src/client/   ← generated from openapi.json (types, zod schemas, SDK, query hooks)
backend/   FastAPI + Pydantic v2 + SQLAlchemy 2 (async) + Alembic + FastMCP
           ├─ app/schemas/  ← single source of truth for every type
           ├─ app/services/ ← business logic shared by REST and MCP
           ├─ /api/v1       ← REST API (OpenAPI at /docs, /openapi.json)
           └─ /mcp/         ← MCP server (streamable HTTP)
openapi.json  generated from FastAPI and committed. CI fails if it drifts.
```

Types flow one way: **Pydantic models → FastAPI → `openapi.json` → hey-api
codegen → TS types + zod schemas + SDK**. Nothing is hand-duplicated. After
changing a backend model, run `make client`.

The API and MCP have **no authentication**. Put them behind your own gateway or
auth proxy.

## Quick start

```bash
make up            # full stack in docker → http://localhost:8080 (API :8100, Postgres :5433)
```

Local development:

```bash
make install       # uv sync + pnpm install
make db migrate    # Postgres in docker on :5433, apply migrations
make api           # FastAPI on :8100 (reload)
make web           # Vite on :5180 (proxies /api and /mcp to :8100)
make seed          # optional demo data
make check         # everything CI runs
```

## Versioning rules

Questions are identified by their `key` across the topic's whole history. When
you publish a new version (`POST /topics/{ref}/versions`):

| Change                                         | Allowed?                                                           |
| ---------------------------------------------- | ------------------------------------------------------------------ |
| Labels, help text, units, required flag, order | ✅                                                                 |
| Add / remove a question                        | ✅ removed questions keep their data and still appear in stats/CSV |
| Re-add a removed key with the **same** type    | ✅ (`restored`)                                                    |
| Tighten or loosen min/max/length               | ✅ with a warning (old sessions remain valid for their version)    |
| Add an enum option, archive / unarchive one    | ✅                                                                 |
| Change a key's type (even a historic key)      | ❌ use a new key                                                   |
| Remove an enum option                          | ❌ archive it instead                                              |

`POST /topics/{ref}/versions/check` is a dry run. It returns the change list and
any errors, warnings or info. Publishing also requires `base_version` to equal
the topic's current version (optimistic concurrency, `409` otherwise).

## API overview

|                                                                                       |                                                       |
| ------------------------------------------------------------------------------------- | ----------------------------------------------------- |
| `GET /api/v1/topics?q=&status=&sort=&limit=&offset=`                                  | list/search topics                                    |
| `POST /api/v1/topics` · `GET/PATCH/DELETE /api/v1/topics/{ref}`                       | CRUD (`ref` = slug or UUID; delete requires archived) |
| `POST /api/v1/topics/{ref}/archive` · `/unarchive`                                    | archive management                                    |
| `GET /api/v1/topics/{ref}/versions` · `POST .../versions/check` · `POST .../versions` | version history, dry-run, publish                     |
| `GET/POST /api/v1/topics/{ref}/sessions` · `GET .../sessions.csv`                     | list/record/export sessions                           |
| `GET/PATCH/DELETE /api/v1/sessions/{id}`                                              | view/correct/delete a session                         |
| `GET /api/v1/topics/{ref}/stats` · `GET .../questions/{key}/series`                   | aggregation and time series                           |
| `GET /api/v1/question-types`                                                          | JSON schema for every question type                   |

Send `X-QuickR-Channel: ui|api|mcp` to tag the channel (defaults to `api`).
Domain errors use one envelope: `{code, detail, errors: [{loc, message}]}`.

## MCP

Point any MCP client at `http://<host>/mcp/` (streamable HTTP). Tools:
`list_topics`, `get_topic`, `create_topic`, `update_topic`,
`set_topic_archived`, `list_topic_versions`, `check_topic_version`,
`publish_topic_version`, `record_session`, `list_sessions`, `update_session`,
`delete_session`, `topic_stats`, `question_series`.

```bash
claude mcp add --transport http quickr http://localhost:8100/mcp/
```

## CI/CD

GitHub Actions (`.github/workflows/ci.yml`) runs on every PR:

- **backend:** ruff, strict mypy, OpenAPI drift check, Alembic migration check,
  pytest against Postgres.
- **frontend:** codegen drift check, prettier, eslint (strict type-checked),
  tsc, vitest, build.
- **docker:** builds the images, boots the compose stack, and smoke-tests the
  UI, API and MCP through nginx.

`main` is protected. Changes land through PRs with all three checks green. When
CI passes on `main`, `release.yml` publishes multi-arch images to
`ghcr.io/richard-lynch/quickr-{backend,frontend}`, tagged `latest` plus the
commit SHA, and with semver tags for `v*` tags.
