# BUILDER-UI: deviations from the PWA

The builder screens follow the PWA's `TopicBuilder`, `QuestionsEditor`,
`QuestionCard`, `OptionsEditor`, `FormPreview`, `EditQuestionsPage`,
`CompatReport` and `VersionsPage`. These are the deliberate differences.

## Data and sync

1. **Versions come from the store.** The Versions tab reads the local
   `topic_version` rows, so it works offline (sync-protocol.md §3.2: versions
   come from the server layer only). The PWA fetches `GET …/versions`. A version
   just published here shows as "v(n) · Syncing…" until the pull brings its
   row.
2. **Publish applies the topic row at once.** The publish response's topic (the
   new current version and its questions) is applied fenced, like the other
   online-only writes; the version's own row comes with the `afterOnlineOnly`
   pull.
3. **The check is a dry run.** `POST …/versions/check` applies nothing and pulls
   nothing. It carries no Expect headers, because the backend has no
   `ExpectIdentity` on it, but the response's identity is still verified. A
   check that got no answer is a plain failure, not "unconfirmed".
4. **Late answers are checked against the draft (Codex r1).** The editor is
   frozen while a check, publish or reload is out. A check answered after the
   questions changed doesn't open the review ("The questions changed while they
   were being checked"). A publish that succeeds after they changed keeps the
   later edits and stays on the editor. "Keep editing" waits for a publish.
   "Keep my draft" drops a reload in flight. The PWA allows these races.

## Editor

5. **Move and remove are in a menu.** A question's card has a ⋯ menu (Move up,
   Move down, Remove question) instead of three icon buttons; an option's
   reorder is a menu too.
6. **An unpublished question's type can change.** BUILDER's `setType` keeps the
   type picker for new questions; the PWA fixes the type when the question is
   added. Published questions are fixed in both.
7. **The change note is checked before publishing.** Over the limit, the review
   shows the error and nothing is sent. The PWA caps the field at twice the
   limit and lets the server reject it.
8. **Expand all / Collapse all counts the current questions.** The PWA's set
   kept removed questions, so it could say "Collapse all" with a card closed.
9. **"Add an option…" text is part of the draft (Codex r1).** It survives the
   Preview pane and a closed card, and typed-but-not-added text counts as an
   unsaved change. In the PWA it is the card's local state.
10. **Edit and Preview are always a switch.** There is no side-by-side layout on
    wide screens.
11. **Picking a choice in the preview counts as leaving it,** so its error shows
    at once.

## Navigation

12. **After publishing, the Versions tab replaces the editor** (and the topic
    screen it was opened from), so Back doesn't return to the editor. The PWA
    pushes `/versions`.
13. **"Edit questions" is a pencil in the topic toolbar,** next to settings
    (the PWA's `TopicLayout` header button).
14. **The conflict sheet stacks its buttons,** "Load latest version" first. A
    failed reload keeps the sheet open, with a "Could not reload" toast.
