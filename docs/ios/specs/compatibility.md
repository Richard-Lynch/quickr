# Spec: server and client compatibility

**Status:** 2026-10-22 (issue #13, phase 1: the PR-time gate). **Enforced by:**
`.github/workflows/compat.yml` and the files in `compat/`.

iOS builds stay installed long after the server moves on, so the server can't
assume every client runs the latest code. This spec sets the rule and the checks
that enforce it on every PR.

**Normative language.** **MUST**, **MUST NOT**, **SHOULD** and **MAY** follow
RFC 2119.

## 1. The rule

1. `compat/supported-clients.json` lists the iOS builds the server must keep
   serving: each one's build number and the commit it was archived from.
2. The server **MUST** stay compatible with every listed client: the API
   requests they send, the responses they read and the push payloads they
   receive.
3. Clients **MUST** ignore unknown fields. For an unknown enum case they
   **MUST** fall back (for example, an unknown `quick_log` type is a plain
   reminder), never fail. A new enum case is therefore additive, but only for
   builds that have the fallback. An older build's behaviour is declared per
   case (§3).
4. When a change needs both sides, the server ships first. The client that
   relies on it ships after that, and the server keeps serving the older listed
   builds.

## 2. OpenAPI breaking changes (`openapi breaking`, ubuntu)

`compat/openapi-breaking.sh` compares `openapi.json` with the one at the newest
`v*` tag and with each listed client's own `openapi.json` (at its sha), so a
break is caught whichever build relies on what changed. It uses oasdiff, pinned by version and checksum in the workflow. It
fails on any breaking change at the ERR level, such as a removed operation or
response field, a new required request field, or a narrower type. Warnings are
printed but don't fail the check; a response enum value added is one (§1 rule
3).

**Override.** A break passes only if every one of its lines is approved in
`compat/openapi-break-approvals.txt`. That file is oasdiff's `--err-ignore`
file: one `METHOD /path message` line per break, as oasdiff prints it. Each line
has a comment above it that names the PR and explains why no listed client is
affected. The approval is part of the PR's diff, so review sees it. Remove the
lines once no compared spec (the tag or a listed client) has what they break.

## 3. Old clients against this server (`old clients`, macos-26; `old requests`, ubuntu)

Schema checks can't see rules that live in code. `old requests` (ubuntu,
`compat/old-requests.sh`) replays each listed client's request goldens
(`shared/fixtures/requests` at its sha) through this PR's backend: the contract
and replay tests of `backend/tests/test_request_goldens.py`, pointed at them by
`QUICKR_REQUEST_GOLDENS_DIR`. Each must still validate and get its expected
status (`EXPECTED` in that test).

For each listed client, `compat/old-client.sh <sha>` does three things:

1. It extracts the client's `ios/QuickrKit` at its commit.
2. It runs the client's own wire suites against this PR's `shared/fixtures`,
   through `QUICKR_FIXTURES_DIR`.
3. It runs `compat/CompatFallbackTests.swift` (copied into the client's
   QuickrDataTests) for the cases that client predates.

The wire suites are listed in `suites`. They decode what the server sends: API
responses (`api/*.json`) and APNs payloads. They also check the notification
categories that must match the server's category ids.

Three things are left out:

- **Client-logic vectors** (quick-log eligibility, the builder, listing and
  stats). They pin the current client to the server's reference logic. An old
  build keeps its own logic by design.
- **`skip` tests.** These are tests that compare the client with the current
  schema rather than reading it, for example `endpointTableMatchesOpenAPI`.
- **API fixtures for operations the client never calls.** These are operations
  that aren't in the client's own `openapi.json`.

**Fallbacks.** A case that a client predates, such as the `single` quick_log
before 20261022, would fail that client's suites. The client's `fallbacks` entry
in the policy names the case (`file` → `name`) and the result it must give
instead. `CompatFallbackTests` checks each one through the client's production
code:

| Expected      | Meaning                                                                                                                                                                                                                                                                                                     |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `unread`      | `userInfo.quickr` doesn't decode. iOS shows the server's alert as it is, with no actions and no quickR handling. This is what builds before f4ed020 do. Checked at `QuickrNotificationInfo(userInfo:)` only: the notification service extension of those builds delivers a payload it can't read untouched. |
| `plain`       | It decodes with no quick_log, so it's a plain reminder. This is the f4ed020 fallback.                                                                                                                                                                                                                       |
| `no-category` | The client builds no category, so iOS shows the alert without actions.                                                                                                                                                                                                                                      |

The cases aren't skipped. Each one moves from the exact-match suites to its
declared fallback. A declared case missing from the fixtures is an error, so the
list can't go stale. A new fallback kind needs a branch in
`CompatFallbackTests`, and that branch must compile against every listed client.

**Why macOS.** On Linux (swift:6.2), QuickrCore builds but QuickrData doesn't:
its GRDB dependency needs `sqlite3.h`, and it imports Apple-only modules
unconditionally: `Security` (Keychain), `AppIntents`, `Network`, `notify`,
`os`/`OSLog`, `CryptoKit` and `Darwin`. The wire suites live in QuickrData, and
a listed client's code can't be changed after it ships. The job runs only on
non-draft PRs that touch `backend/`, `shared/fixtures/`, `openapi.json` or
`compat/` (as does `old requests`, on any PR).

## 4. Required checks

Each workflow ends in one job that is the check to require: `compat`, and `ios`
in ios.yml. It fails unless its path check succeeded and every other job
passed or was skipped by it. A skipped job reports as passing, so requiring the
jobs themselves would let a broken or cancelled path check through.
