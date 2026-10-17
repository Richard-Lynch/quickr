# Codex review: M1 WP DUE (round 1, approved with minors)

**APPROVE WITH MINORS**

No blocking correctness defects found. The Swift implementation matches `schedule.py` for slot inclusion, sorting/deduplication, weekday filtering before gap normalization, capped half-gap satisfaction, schedule reference points, daily/interval status, archived behavior, and `nextDueAt`. Message formatting matches C-locale English and the strict `<30 minutes` fresh window.

- **Minor — strengthen timezone regression coverage:** [DueTests.swift:50](/Users/richie/code/quickr-worktrees/ios-m1-due/ios/QuickrKit/Tests/QuickrCoreTests/Due/DueTests.swift:50). Existing vectors exercise Lord Howe’s 30-minute changes, negative offsets, and gaps/folds; the dedicated Nuuk test covers a transition crossing midnight. Add explicit political-change/date-line cases, such as Kathmandu’s 1986 gap and Apia’s skipped 2011-12-30, plus fractional-second boundary tests. These would protect behavior beyond the predominantly 2026 fixture grid.

- **Minor — bound widget helper work explicitly:** [Due.swift:57](/Users/richie/code/quickr-worktrees/ios-m1-due/ios/QuickrKit/Sources/QuickrCore/Due/Due.swift:57). `upcomingSlots` materializes and sorts the entire estimated range before taking `count`; the 3,660-day escape is checked **after** allocation/computation. Normal widget counts are inexpensive and valid schedules terminate, but this is not an effective resource bound for arbitrary public inputs. Fix by documenting/enforcing a maximum count or collecting slots incrementally. `timeline` additionally recomputes the 26-day status window for every point; reasonable for small counts, but the performance test covers status alone.

The hand-written resolver at [ZoneClock.swift:36](/Users/richie/code/quickr-worktrees/ios-m1-due/ios/QuickrKit/Sources/QuickrCore/Due/ZoneClock.swift:36) survived an independent Python emulation checked against `ZoneInfo(..., fold=0)` at 30-minute samples within ±25 hours of all **40,556 installed TZif transitions**. No mismatches appeared. Offset magnitude, DST labels, and midnight boundaries do not invalidate its candidate checks. No transitions less than 48 hours apart appeared in this dataset; the minimum spacing was 597,600 seconds in Cambridge Bay. This supports the assumption for installed data, rather than proving it for every tzdata release.

The vector harness genuinely executes all **1,831 due, 63 slot, and 360 message cases**. Throwing `map` decoding prevents dropped cases; count assertions prevent empty suites; exact `Date`/`DueStatus` equality matches the fixture’s whole-second precision. Missing optional-date keys do become `nil`, a small schema-strictness weakness, but no existing cases are skipped.

Unknown-zone UTC fallback is an acceptable documented availability choice, though it deliberately differs from Python’s exception and can produce incorrect local reminders. Consider exposing that fallback diagnostically.

Sendable/purity look sound: immutable static values, local computation, explicit clocks, no shared mutable formatter.

**Validation limitation:** Swift tests could not be rerun because the read-only sandbox blocks Swift cache writes; the timezone probe ran successfully.