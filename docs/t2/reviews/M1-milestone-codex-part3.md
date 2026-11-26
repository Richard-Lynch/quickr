**P1: None found.**

**P2: None found.**

**P3: Validation can report a later timer error before an earlier one.** In [questions.py](/Users/richie/code/quickr-worktrees/t2-m1/backend/app/schemas/questions.py:365), the cross-list key checks run in an `after` model validator. Pydantic skips that validator when a nested field is invalid, so the ordering required by timers2.md §1.3 is not preserved.

For example, this timer has both a step/lap key collision and an invalid alert label:

```json
{
  "steps": [{"key": "a", "label": "A"}],
  "laps": [{
    "key": "a",
    "label": "A",
    "alerts": [{"key": "x", "label": "", "at": "1s"}]
  }]
}
```

The server reports `laps.0.alerts.0.label`; §1.3 places the `laps.0.key` collision before alert-label validation. I reproduced this with `Timer.model_validate`. Fix it by collecting and ordering timer validation errors explicitly, so cross-list checks still participate when nested fields have errors.

The review excluded the issues listed in the request.
## Resolution (added by t2-m1-evidence)

The P3 on validation order is **justified, not changed**. It is the same point
as Codex finding 2 on M1-DB ([#158](https://github.com/Richard-Lynch/quickr/pull/158),
`docs/t2/reviews/m1-db-codex.md`), which was justified there as the existing
pydantic behaviour. From #158's body:

> Pydantic reports every field-level error (pattern, label length, counts, `ms`
> bounds) at once, and the cross-field rules (key namespace, name uniqueness,
> alert keys, `at`) run once the fields are valid. Among themselves they run in
> the §1.3 table order, each at its own path. This is the existing idiom for
> questions (`_check_question_list`) and v1 steps. The API returns every field
> error, and clients map them by path. The `builder-vectors.json` cases
> (I1-BUILDER) are generated from this reference, so the ports reproduce
> exactly this behaviour.

In the example, the server reports `laps.0.alerts.0.label`. The key collision
at `laps.0.key` is reported once that label is fixed. Both clients reproduce
this from the shared vectors: iOS `BuilderVectorTests`, and the PWA
`builder.vectors.test.ts` (#262).
