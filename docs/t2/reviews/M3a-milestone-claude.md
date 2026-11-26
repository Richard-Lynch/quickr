# M3a milestone review: Claude reviewer (Opus, pr-review-toolkit:code-reviewer)

Scope: `git diff b00f33a7..53179734` (feat/t2 + t2/m1-la-state → t2/m3a),
hand-written code and tests, against the M3a plan Acceptance/DoD, appearance.md
Part I §1–§10, §15–§16, area-B and the orchestrator rulings 1–4. Static review;
no builds or suites run (a few server `check_icon` probes in the backend venv).

## Findings

1. **Medium: after a same-field conflict the user can never save that field.**
   iOS `TopicSettingsModel.swift:160, :218–229`; PWA `SettingsPage.tsx:178,
   :219`. The base stays on the old revision once a conflict shows, so every
   later Save sends the same stale `expected_revision`, gets 409 and shows the
   conflict again. The iOS `staleRevision` text ("It shows the latest now; try
   again") doesn't match the screen. Fix: move the base to the fresh copy when
   the conflict shows; test a second Save after the conflict.
2. **Low: the PWA rebase wipes typed-but-not-added tag text** and clears 422
   field errors (`SettingsPage.tsx:73, :184`). Fix: keep `appearance.tagInput`
   when not blank; keep field errors across the rebase.
3. **Low: `// T2-M3` edits outside delimited blocks** in files M3 doesn't own:
   `backend/app/schemas/api.py:212` (`_not_nullable` moved),
   `QuickrCore/Topics/TopicEditing.swift:8–18`, `ios/App/Debug/UITestLaunch.swift:429, :678`.
4. **Low: an iOS pending-tag 422 lands on `.tags`, not `.newTag`**
   (`AppearanceEditing.swift`, `AppearanceDraft.field(serverPath:)`).

## By category

- Correctness: clean apart from 1, 2 and 4.
- Validator drift (server, PWA, iOS over `appearance-vectors.json`): clean.
- Revision and feed invariants: clean.
- iOS store migration: clean (M1 ordering/stage tables pending at the feat/t2 merge).
- Live Activity attributes and byte budget: clean.
- Silent failures: clean.
- Tests that can't fail: clean.
- Delimited blocks: mostly clean; see 3.
- Scope creep: clean.
- Rulings 1, 3, 4 hold; ruling 2 holds except finding 1.

## Resolution

All four findings plus the Codex ones (`M3a-milestone-codex.md`: X1 refetch by
id, X2 bounded re-send) are fixed in #268 (iOS) and #270 (PWA + backend); see
`docs/t2/evidence/M3a.md`.
