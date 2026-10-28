# Spec: server and client compatibility

**Status:** 2026-10-22 (issue #13, phase 1: the PR-time gate), revised
2026-10-28 for API levels and forced updates
([client-versions.md](../../specs/client-versions.md) §7). **Enforced by:**
`.github/workflows/compat.yml` and the files in `compat/`.

iOS builds stay installed long after the server moves on, so the server can't
assume every client runs the latest code. This spec sets the rule and the checks
that enforce it on every PR. Since milestone CV, a build below the server's
minimum API level is refused (426 `client_outdated`) and asked to update, so the
rule covers only the builds at or above it.

**Normative language.** **MUST**, **MUST NOT**, **SHOULD** and **MAY** follow
RFC 2119.

## 1. The rule

1. `compat/supported-clients.json` lists the iOS builds the server must keep
   serving: each one's build number, the commit it was archived from and its
   `api_level` (the one in `shared/api-level.json` at that commit). A build
   without an `api_level`, from before milestone CV, is level 0.
2. The server **MUST** stay compatible with every listed client **whose API
   level is at least `min_client_level.ios`** in `shared/api-level.json`: the
   API requests they send, the responses they read and the push payloads they
   receive. These are the **supported** clients. The server refuses the ones
   below the minimum, so they aren't checked; the gate prints each one it
   skips.
3. Clients **MUST** ignore unknown fields. For an unknown enum case they
   **MUST** fall back (for example, an unknown `quick_log` type is a plain
   reminder), never fail. A new enum case is therefore additive, but only for
   builds that have the fallback. An older build's behaviour is declared per
   case (§3).
4. When a change needs both sides, the server ships first. The client that
   relies on it ships after that, and the server keeps serving the older
   supported builds.
5. A change that a client at the current `api_level` can't handle (a breaking
   change) is allowed if the same PR **bumps** `shared/api-level.json`: it
   raises `api_level` by one and sets `min_client_level.ios` and `.web` to it.
   Every build from before the bump is then below the minimum, so the server
   refuses it and the app asks the user to update
   ([client-versions.md](../../specs/client-versions.md) §2, §4). A listed
   build below the new minimum **MAY** be removed in the same PR.

**Note, 2026-10-28: the timers build.** The timers milestone supported no
earlier build, so the list restarted with the timers build `20261026.143027`,
from before CV and so level 0. CV ships with both minimums at 0, so it is still
supported and checked. The first breaking change raises the minimums above it,
which stops checking it.

## 2. OpenAPI breaking changes (`openapi breaking`, ubuntu)

`compat/openapi-breaking.sh` compares `openapi.json` with the one at the newest
`v*` tag and with each supported client's own `openapi.json` (at its sha), so a
break is caught whichever build relies on what changed. It uses oasdiff, pinned
by version and checksum in the workflow. A breaking change is one at the ERR
level, such as a removed operation or response field, a new required request
field, or a narrower type. Warnings are printed but don't fail the check; a
response enum value added is one (§1 rule 3).

- **Against a supported client**, a break fails. The only way to break such a
  client is to raise the minimum above its level, which takes it off the
  comparison.
- **Against the tag**, which stands for the deployed PWA and any unlisted
  build, a break passes **only if** this PR bumps `shared/api-level.json`
  compared with the tag's (§1 rule 5; `compat/api_level.py bumped`). Otherwise
  it fails with "a breaking change must bump shared/api-level.json". A tag from
  before CV has no file, which counts as level 0 with both minimums at 0.

**Approvals.** A break also passes if every one of its lines is approved in
`compat/openapi-break-approvals.txt`. This is for a break that is deliberately
not breaking for any client, such as a field no client reads; bumping is the
normal path. That file is oasdiff's `--err-ignore` file: one
`METHOD /path message` line per break, as oasdiff prints it. Each line has a
comment above it that names the PR and explains why no client is affected. The
approval is part of the PR's diff, so review sees it. Remove the lines once no
compared spec (the tag or a supported client) has what they break.

**The API level (`api level`, ubuntu, every PR).** `compat/api_level.py check`
checks that `min_client_level` is at most `api_level` on both platforms, that
none of the three went down compared with the base branch, and that `api_level`
went up by at most one. `compat/client_fixtures.py check` checks that each
listed client is well formed and that its `api_level` is the one in
`shared/api-level.json` at its sha (missing only where that file didn't exist).
The job then runs `make api-level` and fails if any generated copy of
`shared/api-level.json` changed
([client-versions.md](../../specs/client-versions.md) §2, V12).

## 3. Old clients against this server (`old clients`, macos-26; `old requests`, ubuntu)

Schema checks can't see rules that live in code. `old requests` (ubuntu,
`compat/old-requests.sh`) replays each supported client's request goldens
(`shared/fixtures/requests` at its sha) through this PR's backend: the contract
and replay tests of `backend/tests/test_request_goldens.py`, pointed at them by
`QUICKR_REQUEST_GOLDENS_DIR`. Each must still validate and get its expected
status (`EXPECTED` in that test). Each client replays at its own `api_level`
(`QUICKR_REPLAY_CLIENT_LEVEL`), so a server that refuses it fails the check
rather than passing its goldens at this commit's level.

For each supported client, `compat/old-client.sh <sha>` does three things:

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
`CompatFallbackTests`, and that branch must compile against every supported
client.

**Why macOS.** On Linux (swift:6.2), QuickrCore builds but QuickrData doesn't:
its GRDB dependency needs `sqlite3.h`, and it imports Apple-only modules
unconditionally: `Security` (Keychain), `AppIntents`, `Network`, `notify`,
`os`/`OSLog`, `CryptoKit` and `Darwin`. The wire suites live in QuickrData, and
a listed client's code can't be changed after it ships. The job runs only on
non-draft PRs that touch `backend/`, `shared/fixtures/`, `openapi.json` or
`compat/` (as does `old requests`, on any PR).

## 4. Required checks

Each gated workflow ends in one always-run job that is the check to require:
`compat gate` (compat.yml) and `ios gate` (ios.yml). It fails unless its path
check succeeded and every other job passed or was skipped by it. A skipped job
reports as passing, so requiring the jobs themselves would let a broken or
cancelled path check through. The full list for `main` and `feat/ios-app`:
`backend`, `frontend`, `docker` (ci.yml, not gated), `ios gate`, `compat gate`.

Both workflows also run on every push to `main` (ios.yml on `feat/ios-app` too),
so a pushed commit gets both gates. A `v*` tag deploys only from a commit whose
gates passed. On a push every gated job runs, `build + Unit plan` included: the
path check skips only on PRs, so a push's gate never inherits a skip (or a red
gate) from the commit before it. A push of several commits gates only its head,
so tag the head commit, not an intermediate one (which has no gate and doesn't
deploy).

## 5. Adding and pruning builds

**Adding.** A TestFlight upload from CI (`.github/workflows/testflight.yml`)
opens a PR that lists the new build first, with no fallbacks and the
`api_level` at its commit. A newer build needs none for cases it already knows.
Merge it like any other PR. A local upload (`make ios-testflight`) is added by
hand: `python3 compat/client_fixtures.py add <build> <sha> "<source>"`, and its
commit tagged `clients/ios/<build>` and pushed. A supported client's sha must
stay reachable from a tag (`old requests` checks): a squash merge deletes its
branch, and an unreachable sha can't be fetched or tested. CI uploads build from a `v*`
tag, which already covers them.

**Drafts.** A gate whose run started while the PR was a draft fails: its slow
jobs skipped, so it certifies nothing. Such a run can land after
`ready_for_review` and cancel the ready run; re-run it once the PR is ready.

**Pruning.** A build may come off the list once no tester can still run it.
TestFlight expires a build 90 days after upload, and an expired build can't be
opened; expiring it early in App Store Connect (TestFlight ▸ the build ▸ Expire
Build) counts too. Remove its entry, fallbacks included, in a PR of its own.
Lines in `compat/openapi-break-approvals.txt` that only it needed can go in the
same PR (§2). A build below `min_client_level.ios` is no longer checked, so it
may also be removed in the PR that raises the minimum above it (§1).
