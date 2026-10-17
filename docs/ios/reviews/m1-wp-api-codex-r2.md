# Codex review: M1 WP API (round 2, approved with minors)

**APPROVE WITH MINORS**

- **Partial identity headers — RESOLVED.** [APIClassifier.swift](/Users/richie/code/quickr-worktrees/ios-m1-api/ios/QuickrKit/Sources/QuickrData/API/APIClassifier.swift:40) compares each present header independently, server first, before missing-header fallback. Partial mismatches retain observed evidence and stop the pass with `maybe_delivered`. `aPartialDifferentHeaderIsAMismatch` covers both permutations across success and error statuses.

- **Combined mismatch loses precondition evidence — RESOLVED.** Rejection evidence is now independent of mismatch priority: either recognized 409 precondition code produces `.preconditionRejected` when both headers exist, even when the server mismatch wins. `aCombinedMismatchKeepsThePreconditionEvidence` checks both codes and verifies `setsMaybeDelivered == false`.

- **Untrusted bodies — RESOLVED.** [APIOutcome.swift](/Users/richie/code/quickr-worktrees/ios-m1-api/ios/QuickrKit/Sources/QuickrData/API/APIOutcome.swift:261) gates message detail and persisted JSON on `bodyIsTrusted`. Missing or mismatched identity suppresses both. With no expected identity during bootstrap, complete headers legitimately establish provenance; “matching” in the property documentation could clarify this exception.

- **Transport coverage — RESOLVED, with a minor robustness concern.** Tests now cover trickling responses versus total deadline, cancellation after receipt of a DELETE plus connection closure, and truncated/reset response bodies.

**Both-header requirement: correct.** Sync-protocol §1.4 forbids interpreting application errors without identity headers; outbox §5.2 likewise keeps headerless errors conservative. A partial differing header still proves mismatch, but its body cannot prove “nothing executed.” Therefore `.responseHeaders` is appropriate; the precondition-code rows do not override provenance checks.

**No new Blocker/Major found.** `ObservedIdentity` preserves partial evidence while `.complete` prevents adopting an incomplete identity.

**Remaining minor:** [transport timing assertions](/Users/richie/code/quickr-worktrees/ios-m1-api/ios/QuickrKit/Tests/QuickrDataTests/API/URLSessionTransportTests.swift:54), especially cancellation under 500 ms, may flake under scheduler load. Widen scheduling slack while keeping the deadline bound below the trickle’s completion time.

Static review only; suites were not run in this read-only environment.