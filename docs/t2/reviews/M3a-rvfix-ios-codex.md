# M3a rvfix-ios: Codex review

Command: `codex exec -s read-only -C <worktree> -o <out> "<prompt>" < /dev/null`, three rounds.

## Round 1 (on 80a8ccf4)

I found two medium-severity issues in the conflict flow.

- **Medium — A newer copy arriving during the fetch can leave the conflict based on an older revision.** In [TopicSettingsModel.swift:251](/Users/richie/code/quickr-worktrees/t2-m3a-rvfix-ios/ios/QuickrKit/Sources/QuickrUI/Topics/TopicSettingsModel.swift:251), `adopt(fresh)` ignores a fetched revision if `topicChanged` has already delivered a newer one, but the conflict branch still uses `fresh`. For example, if the fetch returns revision 4 after the store delivered revision 5, and both changed the edited field, [line 271](/Users/richie/code/quickr-worktrees/t2-m3a-rvfix-ios/ios/QuickrKit/Sources/QuickrUI/Topics/TopicSettingsModel.swift:271) moves the base to revision 4. The subsequent rebase refuses revision 5 because it changed that field. Untouched controls can therefore show revision 4 values, and “save again” encounters another conflict rather than saving on revision 5. The existing mid-save tests cover successful and offline saves, but not a stale fetch racing a newer conflicting copy.

- **Medium — Conflict detection includes fields that the PATCH does not send.** [TopicSettingsModel.swift:243](/Users/richie/code/quickr-worktrees/t2-m3a-rvfix-ios/ios/QuickrKit/Sources/QuickrUI/Topics/TopicSettingsModel.swift:243) captures `editedFields` from the raw form, while `change` is built from validated values. A name with only extra surrounding whitespace, for example, can differ in the form but normalize back to the base name and be omitted from the PATCH. If the user also edits colour and another client changes the name, the save reports a name conflict instead of retrying the colour edit. Derive the compared fields from the actual `change` payload, and cover normalized-but-unsent fields in a test.

The diff includes the requested ID lookup, bounded retries, pending-tag error mapping, and markers. I did not run tests; this is a static review.
Resolution: both fixed in 8f31ac54 (the check uses the screen's topic after adopting the fetched copy; only the fields the PATCH sends can conflict). Tests: `aConflictMovesTheBaseToTheNewestCopy` (mutation-checked: fails with `latest = fresh`), `aFieldNotSentIsNoConflict`.

## Round 2 (on 8f31ac54)

I found two correctness issues in the stale-revision flow.

- **Medium — An unsent field can be overwritten after a conflict.** [TopicSettingsModel.swift:203](/Users/richie/code/quickr-worktrees/t2-m3a-rvfix-ios/ios/QuickrKit/Sources/QuickrUI/Topics/TopicSettingsModel.swift:203) decides which controls to preserve using raw `editedFields`, even though conflict detection now uses the validated PATCH. For example, start with name `Mood`, enter `Mood ` and edit colour. If another client changes both the name and colour, the first save correctly reports only a colour conflict. Moving the base preserves `Mood `, though, so the next Save sends normalized name `Mood` along with the colour, overwriting the remote name without warning. Add a conflict-and-resave test with a normalized-but-unsent field that also changed remotely.

- **Medium — A sent field changed to the same value bypasses the required conflict.** [TopicSettingsModel.swift:275](/Users/richie/code/quickr-worktrees/t2-m3a-rvfix-ios/ios/QuickrKit/Sources/QuickrUI/Topics/TopicSettingsModel.swift:275) filters out fields whose fresh value equals the submitted value. The specified flow requires a conflict whenever a sent field changed from the base; this instead retries and reports success. The existing `theSameChangeFromElsewhereIsNoConflict` test encodes the contrary behavior.

The two round 1 scenarios are addressed in the initial conflict comparison: it uses the newest adopted copy and derives compared fields from the PATCH. The first finding above is a remaining data-loss case in the subsequent base move.

This was a static review; I did not run tests.
Resolution:

1. Fixed in the next commit: on a conflict the base move keeps only the sent fields. Test: `aConflictDoesNotKeepAFieldThatWasNotSent`.
2. Stands, by design: a sent field changed elsewhere to the value being sent overwrites nothing, so it is resent. Showing the conflict there would say "save again to keep it" over a field that is no longer dirty (Save is disabled), which breaks the rule that the message matches the screen. Test: `theSameChangeFromElsewhereIsNoConflict`. Flagged to the lead for PWA parity.

## Round 3 (on the round-2 fix)

No new correctness findings.

The last commit fixes round-2 finding (1): on conflict, it keeps only fields included in the attempted save and adopts the latest values for unsent fields. The added test covers the trailing-space name case and verifies that the second save does not overwrite the remote name.

This was a static review; I did not run the tests.