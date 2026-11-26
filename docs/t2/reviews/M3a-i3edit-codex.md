# M3a I3-EDIT phase 1: Codex review

## Round 1 (diff origin/t2/m3a...4bbef116)

- **Medium — Uncommitted tag text is silently lost on save.** [AppearanceEditing.swift](/Users/richie/code/quickr-worktrees/t2-m3a-i3edit/ios/QuickrKit/Sources/QuickrCore/Topics/AppearanceEditing.swift:250) excludes `newTag` from validation and the submitted appearance. A user can type a tag, return to the parent form, and create the topic or save another change without pressing Add; the operation succeeds without that tag. In settings, `resetDetails()` then discards the text.

- **Medium — Tag changes that differ only by Unicode normalization are omitted.** [AppearanceEditing.swift](/Users/richie/code/quickr-worktrees/t2-m3a-i3edit/ios/QuickrKit/Sources/QuickrCore/Topics/AppearanceEditing.swift:168) compares arrays using Swift `String` equality, which treats canonically equivalent spellings as equal. The spec preserves tag spelling and filters by that exact spelling, so replacing a composed tag with its decomposed equivalent can produce no PATCH even though the requested stored text changed. The tests do not cover this distinction.

- **Low — `checkIcon` adds exclusions absent from the specified iOS predicate.** [AppearanceEditing.swift](/Users/richie/code/quickr-worktrees/t2-m3a-i3edit/ios/QuickrKit/Sources/QuickrCore/Topics/AppearanceEditing.swift:90) rejects a lone regional indicator or emoji modifier before checking `isEmojiPresentation`. Section 2’s iOS row accepts either as a single `Character` whose first scalar has that property. The new tests instead assert rejection, so they encode a different contract. The exclusions align with the server predicate described in the spec, but the platform discrepancy needs resolving explicitly.

- **Low — An out-of-range server tag error is hidden.** [TopicSettingsModel.swift](/Users/richie/code/quickr-worktrees/t2-m3a-i3edit/ios/QuickrKit/Sources/QuickrUI/Topics/TopicSettingsModel.swift:185) treats any numeric `appearance.tags.<i>` path as placed and suppresses the banner, while [AppearanceEditorView.swift](/Users/richie/code/quickr-worktrees/t2-m3a-i3edit/ios/App/Topics/Builder/AppearanceEditorView.swift:165) displays errors only for existing tag indices. Such an error leaves no visible explanation; the new-topic mapping has the same issue. Map an unavailable index to the tag-list error or retain it in the banner.

The `AppearanceUpdate` representation distinguishes omission, explicit null, and an empty tag list, and the tests exercise those values through the seam. Wire encoding remains dependent on I3-STORE. I did not run the test suite in this read-only review.
### Resolution

1. Medium, pending tag text lost: fixed (c5e97a7f). `AppearanceDraft.validated` adds the typed tag as Add would; its error lands on `.newTag`. Tests `aTagTypedButNotAddedIsSent`, `aTagTypedButInvalidBlocksTheCreateOnTheAddField`, `anEleventhTagTypedButNotAddedIsTheAddFieldsError`, `aTagTypedButNotAddedIsSaved`.
2. Medium, canonical-equivalence tag compare: fixed (c5e97a7f). `AppearanceUpdate.sameSpelling` compares code points. Test `aRespelledTagIsAChange`.
3. Low, lone regional indicator / skin-tone modifier: kept on purpose. The iOS row of the §2 table accepts them, but the server row and the PWA refuse them, and §3.2 says all three validators MUST agree. A spec change has been proposed to the lead (fix the iOS row and the step-4 regex, add the two cases to `icons[]`).
4. Low, out-of-range server tag index hidden: fixed (c5e97a7f). `AppearanceDraft.field(serverPath:)` maps it to `.tags`. Test `aServerErrorOnAMissingTagLandsOnTheList`.

## Round 2 (4bbef116..c5e97a7f and the full diff)

**One finding remains in the round 2 fixes:**

- **Medium — A code-point-only tag spelling change cannot be saved through the UI.** [TopicSettingsModel.swift](/Users/richie/code/quickr-worktrees/t2-m3a-i3edit/ios/QuickrKit/Sources/QuickrUI/Topics/TopicSettingsModel.swift:201) computes `appearanceDirty` using synthesized `AppearanceDraft` equality, which treats canonically equivalent Swift strings as equal. Replacing `café` with `cafe\u{301}` therefore leaves [Save details](/Users/richie/code/quickr-worktrees/t2-m3a-i3edit/ios/App/Topics/TopicSettingsView.swift:83) disabled and does not trigger the unsaved-changes warning. The new test calls `saveDetails()` directly, so it verifies the PATCH comparison but misses the UI gate. Dirty-state comparison also needs to preserve tag code-point spelling.

The pending-tag fix sends valid uncommitted text and blocks invalid text, and the out-of-range server tag error now appears on the list. I found no other new issues in the reviewed scope. The deliberately retained emoji predicate divergence is excluded as requested. The review was based on code inspection; I did not run tests.
### Resolution

1. Medium, `appearanceDirty` used String equality: fixed in the next commit. `AppearanceDraft.differs(from:)` compares code points and counts pending tag text. `aRespelledTagIsAChange` now asserts `detailsDirty`.
