# Codex review: M0 WP specs (round 2)

**Verdict: NOT READY — substantially improved, but still not implementable without guesswork.**

Reviewed all three revision commits against `205f2b3`. **Source discrepancy:** this checkout’s `docs/ios/PLAN.md` §6a ends at rule 12; rules 13–16 and “Amendments from the M0 specs review” are absent. Their resolution decisions therefore could not be verified.

Round-1 findings:

1. **RESOLVED:** Outbox K5 and §9.2 preserve preceding operations while deletion is held; Undo removes only the held delete. Tests 29–31 cover both overlays.
2. **RESOLVED:** Outbox S2 and §7.4 fence verification, rebase and resend decisions; tests 32/34 explicitly prevent the superseded sender’s overwrite.
3. **RESOLVED:** Sync F10/§1.4 require expected identity on every mutation, including APNs; the health-check validity window is removed.
4. **PARTIAL:** Response epochs and request generations are specified, but error/refetch handling still permits an unfenced cross-epoch interpretation; see below.
5. **PARTIAL:** Page/token fences, one lock order and fresh reset filenames address the original races; takeover and reset crash recovery remain incomplete.
6. **RESOLVED:** Outbox §8 limits coalescing to adjacent, never-attempted operations within topic scope; tests 24/25 preserve topic barriers.
7. **RESOLVED:** Boot-paired continuous-clock leases replace wall-clock expiry; rollback, forward-jump and reboot tests are explicit.
8. **PARTIAL:** Reconciliation, append-only registration and no-await transactions address the implementation issues; PLAN still mandates pruning, and the platform guarantee remains checkpoint-dependent.
9. **RESOLVED:** Notifications §§6–8 restrict badge updates to the active store’s actual derived state, including satisfied reminders.
10. **RESOLVED:** Sync G1–G5 and the expanded matrices specify coverage, minimum-iOS execution, races and malformed-entitlement failures.

Remaining/new **Major** findings:

- **Rebuild takeover contradicts the executable loop.** Sync §7.2 says resume `stage_state.cursor`, but §5.4 always starts a live-layer pull from `cursor`, without branching on `rebuilding`. An E2 response against live E1 invokes §7.1, clearing staging again. Specify takeover before any live pull, separate staging checks/context, and context refresh after swap. S4’s expected result currently requires invented control flow.

- **Reset has an unrecoverable crash window.** Sync §12 steps 3–5 retire the current file, release both leases, then advance the registry. A crash before step 5 leaves the registry pointing permanently at a retired file; reopening selects that same file. Persist a reset intent and define idempotent launch recovery. Also specify whether writes committed after the initial warning but before retirement require renewed confirmation.

- **Cross-epoch error responses can create false tombstones.** Outbox §7.4 handles refetch 404 as “entity gone” before its epoch-mismatch branch; §5.2’s header overrides cover only 2xx. A refetch issued under E1 can return E2’s 404 while local E1 fences still pass, incorrectly failing/removing queued intent. Check identity/epoch before interpreting **every application error**, including refetch 404.

- **Undo can stall behind the create it must cancel.** Outbox §9.1 retries an uncertain create before DELETE. If that POST now returns `topic_archived` or 422, the failed create blocks DELETE under §7.2. Discarding the failed create cascades away the cancellation. “Undone” therefore need not establish the server tombstone. Define cancellation that reserves the id despite create failure; test failure between uncertain POST and DELETE.

Other requested checks:

- **Lock order:** no explicit reverse acquisition remains. Mismatch handlers must request rebuilding asynchronously after releasing `flush`; make that sequencing explicit.
- **Precondition 409 restore:** preserving prior uncertainty and sticky `maybe_delivered` is correct; explicitly clear claim fields during restoration.
- **Clock:** the system-wide continuous clock is appropriate across processes and [includes sleep](https://developer.apple.com/documentation/kernel/1646199-mach_continuous_time).
- **Categories:** append-only growth is an accepted simplification, but “a few hundred/year” is unsupported for continuously varying numbers. Add growth/registration-budget measurement to checkpoint D.