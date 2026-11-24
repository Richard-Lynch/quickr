# quickR iOS: requirements and decisions

Captured from the planning interview on 2026-10-17. The plan in
[PLAN.md](PLAN.md) must satisfy all of these. If something here turns out to be
infeasible, the plan must say so explicitly.

## Product

| Topic                    | Decision                                                                                                                                                                                                                                                                                  |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Approach                 | **Native SwiftUI** app that talks to the existing quickR backend. Not Capacitor or another web wrapper.                                                                                                                                                                                   |
| Apple program            | **Paid Apple Developer Program**: APNs, TestFlight, 1-year provisioning. The user is **not enrolled yet** (on 2026-10-17).                                                                                                                                                                |
| Scope                    | **Full parity with the PWA.** That covers the due-first home, quick-log tiles, record screen, entries (list, filter, edit, delete with undo, CSV), topic create, question builder with version check and publish, schedule editor, archive and delete, stats and series charts, settings. |
| Native extras (in scope) | **Log from a notification** (answer actions on the reminder), **Widgets** (Home and Lock Screen, interactive quick-log), **Siri, Shortcuts and the Action button** (App Intents).                                                                                                         |
| Out of scope             | Apple Watch, Live Activities, iPad layouts.                                                                                                                                                                                                                                               |
| Look                     | **Native iOS with the brand applied.** Standard iOS navigation, lists, sheets and behaviours, styled with the "field notebook" brand: paper and ink colours, orange accent, Bricolage Grotesque, Instrument Sans and JetBrains Mono.                                                      |
| Platform                 | **iOS 26+, iPhone only.**                                                                                                                                                                                                                                                                 |
| Offline                  | **Offline-first.** A local store of topics, questions (all versions) and entries. Logging always works instantly and syncs later. History can be browsed offline.                                                                                                                         |
| Reminders                | **Server-sent APNs**, sent by the existing scheduler as Web Push is today. An **on-device local-notification fallback will probably be added later**, so the design must not rule it out (keep due computation and notification identifiers compatible with that).                        |
| Bundle IDs               | `com.bahumia.quickr`, with extensions under it (e.g. `com.bahumia.quickr.widgets`). App Group `group.com.bahumia.quickr`. Display name "quickR".                                                                                                                                          |
| Web app                  | **Keep it working, with full feature parity where possible.** Backend changes must stay compatible with the PWA. New capabilities (e.g. logging from a notification) should reach the web app too where the platform allows.                                                              |

## Change policy (added 2026-10-17)

quickR is **not a production system yet**. If building the app shows that a backend or interface
change would make the overall design cleaner, make it, including breaking changes. Every consumer
must be updated in the same work package: the PWA, MCP, the tests and the generated clients.

- Prefer the clean design over compatibility shims.
- There's no need to keep old cached PWA builds working.
- `make check` stays green.
- Migrations keep working downgrades.
- Breaking changes are listed in the milestone PR.

This replaces the "additive only" wording in PLAN §5 and §1.

## Infrastructure

- **Hosting (later):** the backend runs on a home box behind **Cloudflare
  Access**. The app sends Access service-token headers (`CF-Access-Client-Id` /
  `CF-Access-Client-Secret`) as its app token. The quickR services themselves
  stay open (no auth in the app server). **Local first:** develop against the
  local docker stack now. The Cloudflare setup is a later milestone and is
  mostly the user's work.
- **Repo:** all code lives in **this repo** (monorepo). The iOS app goes in
  `ios/`.

## Process

- Work happens on short-lived branches in their own worktrees and merges
  straight into **`main`** by squash PR (merge commits are off). A PR needs the
  five required checks green: `backend`, `frontend`, `docker`, `ios gate` and
  `compat gate`. No doc may depend on a particular worktree path existing;
  finished worktrees are deleted.
- Historical: the app was first built on the long-lived branch `feat/ios-app`,
  with one PR per milestone into it and one final PR to `main` (#6, 2026-10-22).
  A milestone may still use a short integration branch (timers used
  `feat/timers`, CV `feat/client-versions`), merged to `main` as one PR.
- Each milestone PR includes demo **screenshots, videos and GIFs** (simulator
  recordings, device captures once available).
- **Testing:** a local gate (`make check-ios`) with unit tests (sync engine, due
  logic, validation, API client) and a few XCUITest flows, plus a **GitHub CI
  macOS job** that builds and runs the unit tests. The existing backend and
  frontend checks must stay green.
- The user wants Claude to **build and install to their phone locally**
  (xcodebuild/devicectl from the terminal), with TestFlight as an option once
  enrolled.

## Environment facts (2026-10-17)

- This Mac (M4 Pro) runs **macOS 15.6.1 Sequoia** with **only Command Line Tools: no Xcode** and no signing identities. Current Xcode (27.x) needs macOS Tahoe 26.6+, so the user must upgrade macOS, then install Xcode, before any device build.
- The Docker stack runs locally: web on :8080, API on :8100, Postgres on :5433.
- `codex` CLI 0.163.0 is available, and is used for the adversarial plan review.
