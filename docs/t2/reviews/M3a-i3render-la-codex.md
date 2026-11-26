- **[P1] Locally started activities omit appearance** — [RunActivity.swift](/Users/richie/code/quickr-worktrees/t2-m3a-i3render-la/ios/QuickrKit/Sources/QuickrCore/Runs/RunActivity.swift:202). The new parameter defaults to `nil`, but the local start path in [RunActivityCenter.swift](/Users/richie/code/quickr-worktrees/t2-m3a-i3render-la/ios/QuickrKit/Sources/QuickrData/LiveActivity/RunActivityCenter.swift:191) does not pass the topic’s appearance. Consequently, a run started on the phone creates an activity with the default theme even when the topic has an appearance. The push-to-start test does not cover this path.

- **[P2] The new budget vector is not the encoded worst case** — [test_live_activity_vectors.py](/Users/richie/code/quickr-worktrees/t2-m3a-i3render-la/backend/tests/test_live_activity_vectors.py:321). It uses four-byte Unicode characters for labels, but valid control characters encode as six-byte JSON escapes. Substituting those into the same long-label start with the largest appearance produces a payload over 4096 bytes before fitting, so the asserted untruncated fit does not establish the claimed worst-case bound. The appearance also is not added to the existing truncation and terminal vectors, leaving its interaction with those steps untested.

The optional Swift property uses synthesized `Codable` decoding, which accepts older payloads without an `appearance` key; the added round-trip test covers that case. I did not run the test suites.
## Resolution (m3a-irender)

1. **P1, locally started activities omit the appearance: stands (out of scope), filed as #226.** `RunActivityCenter` and `RunActivitySnapshot` belong to M1/M2. The snapshot fields are M2's, and rendering `attributes.appearance` is T2-WIRE-I item 3. The patch provides the field and the builder parameter (`RunActivityContent.attributes(..., appearance:)`), so wiring the local start is a single call-site change, plus a snapshot map, in T2-WIRE-I. Until then the key is optional and nothing reads it.
2. **P2, the new vector is not the encoded worst case: fixed.** The vector stays the case §15 names: four-byte labels plus the largest appearance, 3352 bytes, untruncated. Two new tests in `test_live_activity_vectors.py` pin the true worst case:
   - `test_budget_largest_body_with_the_largest_appearance_fits_after_the_first_step`: every label at 64 six-byte escapes plus the largest appearance is 4109 bytes raw. `fit` takes only `alert_label` and sends 3914 bytes, with the appearance whole.
   - `test_budget_bound_holds_with_the_largest_appearance`: after the terminal step a start is at most `fixed_bound` (1261) plus the appearance (1130), 2391 bytes. So `fit` never raises for a topic §1.3 accepts.
   - The existing truncation and terminal vectors are left as M1 generated them: the step order doesn't touch `attributes.appearance`, which these two tests prove.
   - Spec note for the lead: §15's sentence calling the four-byte case "the worst case" undercounts; the six-byte-escape labels are larger. Proposed §15 wording: "…the four-byte case is what the vector pins; with six-byte-escape labels the body exceeds 4096 bytes and the budget's first step (`alert_label`) fits it, the appearance untouched (asserted in `test_live_activity_vectors.py`)."

## Round 2 (Codex, on the fix)

- **[P2] The terminal-step test doesn't check that the appearance survives; timers2.md §8.2 asks for both budget vectors to be re-run with the appearance set: fixed.**
  - `test_budget_bound_holds_with_the_largest_appearance` now asserts the appearance is unchanged after every step.
  - New `test_budget_vectors_rerun_with_the_largest_appearance[payload_budget_truncation|payload_budget_terminal]` rebuilds each budget vector's start with the largest appearance, at the vector's limit plus the appearance's bytes. It asserts the same steps, the fit, the appearance carried whole, and the rest of the attributes and content state identical to the vector.
- The P1 justification held (#226).

## Round 3 (Codex)

**No new findings.** The round 2 fix re-runs both budget vectors with the largest appearance, checks the expected truncation steps and fitted size, and verifies that the appearance survives unchanged. The separate terminal-step test also checks it after every step.

I did not run the test suites.