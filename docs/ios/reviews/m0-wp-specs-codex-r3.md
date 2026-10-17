# Codex review: M0 WP specs (round 3)

**NOT READY.** Two Major gaps remain; no Blocker found. Reviewed `0e79fb5...HEAD`, both previous reviews, the integration branch’s PLAN §6a—including amendments 13–16—and the feed backend.

**Round-2 findings**

- **RESOLVED — rebuild takeover.** Sync §§5.4/7 branch on persisted `rebuilding` before requesting a live page, resume `stage_state.cursor`, use a staging context, and refresh context after swap.
- **RESOLVED — reset crash recovery.** Sync §12 persists reset intent, defines recovery before/after retirement, and rechecks count/max-seq before destructive retirement.
- **PARTIAL — cross-epoch errors.** Outbox §5.2 step 0 and §7.4 now check headers before interpreting errors; tests 55–58 cover refetch 404 and claim restoration. However, the server can label an E2 result with E1 headers; see below.
- **RESOLVED — Undo blocked by its create.** Outbox S8/§9.1 retire cancelled creates on unsuccessful completion, expiry, swap and budget release. Tests 51–54 cover delayed POST, archive and validation failure.
- **RESOLVED — lock order and restoration details.** Sync §5.6 explicitly releases `flush` before asynchronously requesting coordination. Outbox §5.2 explicitly clears all claim fields.
- **RESOLVED — notification-plan conflict/growth claim.** PLAN amendment 16 authorizes append-only categories and reconciliation. Notifications §5.1/D1 acknowledge unbounded growth and require measurements.

**Judgment calls**

- **Cancellation of every queued create: acceptable.** Removing E and its edits without touching other entities does not move surviving operations across topic barriers. Test 15 explicitly covers cancelling E after F was queued. Silent removal is valid only when `maybe_delivered = 0` reliably proves non-delivery.
- **Held-delete release through `cancelCreate`: acceptable.** Outbox §9.2 preserves the complete overlay throughout the hold, then uses the released delete as the cancellation delete. This handles uncertain/in-flight creates without retrying them. Add explicit nonadjacent-create and uncertain-create hold-release tests.

**Remaining Majors**

1. **Response epoch provenance does not match the client’s safety assumption.** [Server identity middleware](/Users/richie/code/quickr-worktrees/ios-m0-feed/backend/app/api/identity.py:54) loads identity **before** executing the endpoint; only `/changes` explicitly supplies snapshot headers. Sequence: middleware reads E1 → epoch rotates to E2 → refetch reads E2 and returns 404 → middleware attaches E1. Outbox §7.4 then accepts that 404 and creates a false tombstone. Thus round-2 test 55 assumes stronger server behavior than exists. Bind headers to the read/mutation transaction’s identity, including errors, and test rotation between middleware entry and entity lookup.

2. **Malformed successful responses leave cancellation safety undefined.** [Outbox §5.1](/Users/richie/code/quickr-worktrees/ios-m0-specs/docs/ios/specs/outbox.md:192) retries non-JSON 2xx with `maybe_delivered` unchanged, while §5.2 says any create 2xx is an Ack requiring `EntryOut`. If POST committed but its response is malformed, an implementer must choose between contradictory rules. Retrying with `maybe_delivered = 0` lets Undo silently drop the create while the server entry survives. Require undecodable/missing required success bodies to become uncertain; define cancellation handling and test it.

**Minor contract mismatches**

- Sync F10 promises rejection before **any locks**; `feed.writer` deliberately checks preconditions **under** the advisory lock. Specify “before mutation effects.”
- F8’s unconditional `has_more=false ⇒ next=head` fails when `after>head`: `changes.py` returns `next=after`. Qualify it for valid cursors; the existing restore check handles this case.