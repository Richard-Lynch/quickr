# Codex review: M1 WP B7 (round 2, approved)

**APPROVE**

All round-1 findings are **RESOLVED** against commit `93572d0`, the updated spec, and the orchestrator decisions:

1. **`open` protocol extension — RESOLVED.** §§4.1–4.3 now define `open`, `m`, the empty value, hashing, and the foreground exception.

2. **Number formatting — RESOLVED.** `Decimal(repr(float(x)))` followed by fixed-point formatting expands exponents exactly without decimal-context rounding. Fractional trailing zeros and the dot are removed; integer positional zeros remain. Both signed zeros render as `"0"`. Subnormals and extreme finite magnitudes retain their shortest round-trip digits. Int formatting preserves base-10 precision beyond binary64’s exact-integer range. Double formatting vectors carry big-endian IEEE-754 bits, including negative zero, midpoint neighbours, and subnormals.

3. **`last_value` validation — RESOLVED.** It delegates to `validate_answers`; `decimals` neither rejects nor rounds accepted values.

4. **Preparation starvation / N+1 reads — RESOLVED.** Preparation uses at most two answer queries. Counts are requested only for eligible 5–6-option enums. Both queries filter `(topic_id, question_key)` pairs selected from current-version questions. Numeric selection uses `DISTINCT ON (topic_id)` with matching leading ordering, then descending `captured_at` and entry `id`. Grouping by topic is sufficient because each topic contributes one eligible key.

   The shared delivery deadline starts after descriptor, target, and progress reads. B6’s slot-progress behavior remains intact: interrupted slots save completed targets, resume remaining targets next tick, and are marked only when delivery completes.

5. **Escaped-character payload size — RESOLVED.** The size test now covers six-byte JSON-escaped control characters alongside four-byte Unicode, retaining the ≤4096-byte assertion.

**No NEW Blocker/Major found.**

Validation: **39 pure notification/vector tests passed**. Database-backed batching, deadline, and progress tests were inspected but not executed in this restricted environment. Independent Swift verification remains the planned cross-language check.