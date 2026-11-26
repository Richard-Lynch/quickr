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

## Phase 2 (diff origin/t2/m3a-i3store...69b5af63, stacked on I3-STORE)

- **Medium — A synced appearance change discards unsaved details and appearance edits.** [TopicSettingsModel.swift:88](/Users/richie/code/quickr-worktrees/t2-m3a-i3edit/ios/QuickrKit/Sources/QuickrUI/Topics/TopicSettingsModel.swift:88) calls `resetDetails()` whenever an incoming topic has a different appearance. If another device changes the colour while the user has a name, emoji, or tag edit in progress, the sync silently replaces the whole draft and clears its errors. The revision check cannot protect those edits because they are lost before Save. Preserve the draft when it is dirty and surface the conflict.

- **Medium — A synced tag spelling change can leave the editor showing stale data.** [TopicSettingsModel.swift:92](/Users/richie/code/quickr-worktrees/t2-m3a-i3edit/ios/QuickrKit/Sources/QuickrUI/Topics/TopicSettingsModel.swift:92) compares appearances using Swift’s canonical-equivalent string equality. If a remote change replaces `café` with `cafe\u{301}`, `topic` advances to the new spelling but the editor is not refreshed. The old spelling then appears dirty and a subsequent save can restore it, changing the exact tag-filter value. Compare tag scalar spelling when deciding whether the incoming appearance changed, and test the sync path.

The shared-vector tests exercise icon and tag outcomes and stored forms, including the amended emoji cases. The model tests cover combined details and appearance changes, revision propagation through the writer seam, and explicit clears. The `SessionTopicWriter` routing matches the requested one-PATCH flow by inspection, but the new tests use a fake writer and do not verify that concrete wiring.

I did not run the tests in this read-only review.
### Resolution

1. Medium, a synced appearance change resets unsaved edits: stands, justified. This is the Details section's existing rule, documented on `topicChanged`: like the PWA's forms, which are keyed by the saved values, a section whose saved values changed starts over from them. Name, slug and description already behave this way, and appearance is part of the same section and the same PATCH. When a sync arrives between the read and the Save, `expected_revision` turns the Save into `staleRevision`. Surfacing a merge conflict would be a new UX for every section, so it is out of scope here.
2. Medium, a synced tag respelling not detected: fixed (f9a22925). `topicChanged` compares code points through `AppearanceDraft.differs(from:)`. Test `aRespelledTagFromASyncResetsTheEditor`.
3. Note, the `SessionTopicWriter` routing is untested by host tests: it is two lines over I3-STORE's `TopicWrites.updateAppearance` / `TopicRequests.create(_:schedule:appearance:)`, which `TopicWritesTests` and `RequestGoldenTests` cover. The concrete path also runs in the UI classes on the simulator (fake server PATCH).

## Final (full diff origin/t2/m3a...af7442e9, after I3-STORE #211 merged)

- **Medium — An older save response can overwrite a newer topic already observed by the screen.** [TopicSettingsModel.swift:160](/Users/richie/code/quickr-worktrees/t2-m3a-i3edit/ios/QuickrKit/Sources/QuickrUI/Topics/TopicSettingsModel.swift:160) assigns the returned topic without comparing its revision to the current one. For example, a details PATCH can produce revision 4, a sync can deliver revision 5 while the response is in flight, and then the revision 4 response can replace it. The next appearance save sends revision 4 and receives `stale_revision`; the editor can also show obsolete values. The guard in `topicChanged` does not protect this response path. The independently enabled schedule and details saves provide another way for responses to arrive out of order. Add coverage for a newer observation arriving before a save response.

The create path carries appearance, and the concrete details writer routes an appearance change through one `updateAppearance` PATCH with the expected revision. The shared-vector tests check icon and tag outcomes and stored forms; the model tests cover the principal save and rebase cases. I did not run the tests in this read-only review.
### Resolution

1. Medium, an older save response could overwrite a newer copy already on screen: fixed. Both save paths (details and schedule) now take the answer only if its revision is at least the screen's (`adopt`). Test `aNewerCopyDuringASaveWinsOverItsAnswer`; with the guard removed it fails 3 expectations.

## Field-level conflicts (db49bd94, matching #220)

- **High — Details-only saves bypass revision checks.** [SessionTopicWriter.swift](/Users/richie/code/quickr-worktrees/t2-m3a-i3edit/ios/App/Topics/SessionTopicWriter.swift:30) sends `expectedRevision` only when the change includes appearance. A name, slug, or description edit therefore uses the unconditional update path. If another device changes the same field, the save can overwrite it instead of producing the conflict required by `MetaForm`. The new tests exercise the retry through appearance changes, so they do not catch this production-writer behavior.

- **High — A concurrent schedule save can invalidate the conflict check for an in-flight Details save.** [TopicSettingsModel.swift](/Users/richie/code/quickr-worktrees/t2-m3a-i3edit/ios/QuickrKit/Sources/QuickrUI/Topics/TopicSettingsModel.swift:91) rebases Details in `adopt()` even while `isSavingDetails` is true. If the schedule response arrives after the Details request starts, it can advance `detailsBase` and replace an untouched field. The stale-revision handler then computes `editedFields` against that *new* base but compares those fields against the captured *old* base at [line 216](/Users/richie/code/quickr-worktrees/t2-m3a-i3edit/ios/QuickrKit/Sources/QuickrUI/Topics/TopicSettingsModel.swift:216). A field in the already-built `change` can disappear from that set, allowing a retry that overwrites a concurrent change. The PWA suppresses rebasing throughout submission.

- **Medium — A topic update received during a failed Details save is never rebased afterward.** [TopicSettingsModel.swift](/Users/richie/code/quickr-worktrees/t2-m3a-i3edit/ios/QuickrKit/Sources/QuickrUI/Topics/TopicSettingsModel.swift:112) skips rebasing while saving, but clearing `isSavingDetails` at [line 212](/Users/richie/code/quickr-worktrees/t2-m3a-i3edit/ios/QuickrKit/Sources/QuickrUI/Topics/TopicSettingsModel.swift:212) does not reconsider the already-adopted `topic`. After a rejected or failed save, untouched fields can remain stale and the base retains its old revision until another observation arrives. The PWA re-evaluates the pending topic when submission ends.

The existing tests cover ordinary rebasing, retry, conflict, and a newer observation during a successful save, but do not cover these concurrent schedule and failed-save paths or verify revision enforcement through `SessionTopicWriter`. I did not run the tests.
### Resolution

1. High, a details-only save sent no revision: fixed. `SessionTopicWriter.saveDetails` always sends `expected_revision` through `TopicWrites.updateAppearance`, as `MetaForm` does. The fake writer checks it on every details save. Test `aNameChangedElsewhereConflicts`.
2. High, a schedule answer during a details save moved the base: fixed. `adopt` doesn't rebase while a details save is in flight, and the stale check uses the edited fields captured before sending. Test `aCopyDuringAFailedSaveIsTakenAfterIt`.
3. Medium, a copy that arrived during a failed save was never rebased: fixed. A failed save rebases on the newest copy when it ends. The same test covers it; with the rebase removed it fails.
