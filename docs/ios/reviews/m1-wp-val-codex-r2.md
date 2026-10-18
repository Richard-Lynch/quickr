# Codex review: M1 WP VAL (round 2, approved with minors)

**APPROVE WITH MINORS.** No new Blocker/Major found in `git diff 7be6000...HEAD`.

- **RepeatLast coercion — RESOLVED.** `exactInput` gates stored shapes before form validation; list→single and string→number now return nil. Unknown keys and duplicates also return nil; valid empty maps can repeat. Tests cover these cases and preserve coercion for prefill only.
- **Server-normalised strings — RESOLVED.** Swift `ServerText.strip` and PWA `serverStrip` match Python whitespace, including U+0085/U+001C–001F and excluding U+FEFF. Shared vectors exercise requiredness, post-strip lengths, stored values, choices, and NUL.
- **Frontend/Swift length disagreement — RESOLVED for answer validation.** `answerSchema` now counts code points and shares emoji acceptance/error-message cases with Swift. Builder/topic/entry schemas also use code-point counts.
- **JSNumber differential testing — RESOLVED as a coverage gap.** Swift and Python compare actual formatting against 5,204 V8-generated bit-pattern cases, including boundaries and seeded random doubles. Python’s differential test passed; Swift execution remains unverified here.

Remaining minor observations:

- **Native cap UX:** `inputMaxLength(max) = 2 * max` permits every valid supplementary-character string, but also permits twice the ASCII limit before validation reports an error. This is a reasonable correctness tradeoff, with a changed typing experience.
- **UTF-16 backlog remains:** generated Zod validators retain UTF-16 limits. This has concrete consequences: `api/entries.ts` still calls `zEntryCreate.parse(body)`, so source/notes accepted by the revised form can fail later. Visible counters should follow the same code-point convention wherever introduced; inspected answer `.length` counters count selections, not text.
- **Choice matching is safe:** enum option values are `QuestionKey`-constrained ASCII identifiers. Python stripping therefore cannot alter a legitimate existing option identifier; it aligns surrounding-whitespace handling with server normalization.
- **Determinism:** regenerating the Node fixture in memory reproduced all 5,204 cases exactly. The `meta.node` version makes byte-for-byte output environment-dependent. Answer-text fixtures have a real pytest regeneration/drift check; JSNumber fixtures have consumer comparisons but no automated generator-output drift check.
- **No vacuous test found.** Shared cases assert acceptance, concrete normalized values, and rejection messages; minimum case-count assertions prevent empty-fixture success. The timezone test also verifies its local-year precondition. `getUTCFullYear()` correctly fixes the displayed boundary year.

Validation: **219 frontend tests and 18 backend tests passed**, including fixture drift and Python/V8 comparisons. Swift testing was blocked by read-only sandbox cache restrictions.