1. **P2 — The bar cuts off the primary action’s meaning at narrow widths and enlarged text.** [RunningBar.tsx:102](/Users/richie/code/quickr-worktrees/t2-m2-fbar/frontend/src/components/runs/RunningBar.tsx:102) caps the button at 45% of the row, and line 109 truncates its title. A named action such as “Next: Breakfast” or “Lap → Rest” can become “Next: …” or “Lap → …”, hiding the destination that the spec requires the primary to communicate. The accessible name retains it, but sighted users at mobile widths or larger text sizes cannot reliably identify the action. Allow the row or button to grow or wrap, and cover long labels at narrow and enlarged-text widths.

2. **P2 — The primary is still selected by kind after the layout model selects it by role.** [RunTile.tsx:176](/Users/richie/code/quickr-worktrees/t2-m2-fbar/frontend/src/components/runs/RunTile.tsx:176) drops every primary other than `next` or `lap`. The spec requires placement by role so later model actions do not require surface-specific layout changes. If the model supplies another primary for an open run, the bar silently omits it and the tile falls through to a **Start** button for an already-open run. Dispatch the selected action through a handler that supports the model’s kinds rather than treating an unfamiliar primary as an idle run.

3. **P2 — The no-duplicate decision is not yet integrated with the Active now cards.** [onScreen.ts:34](/Users/richie/code/quickr-worktrees/t2-m2-fbar/frontend/src/components/runs/onScreen.ts:34) provides the registry, but its only caller is the temporary running tile. When PR #165 replaces that tile with `ActiveTopicCard`, those cards must register their displayed runs or the bar will show their primaries again. This needs an integration change and a test against the actual card when the branches are combined; the current tile and search tests do not cover it.

The state comparison tests verify title, icon, and enabled state, but do not exercise dispatch for each modeled primary or the long-label layout. I did not run the test suite for this review.
---

## Resolution (f2-bar, round 1)

1. **Fixed.** The bar's primary no longer truncates: the row wraps (`flex-wrap`, the link
   `flex-[1_1_12rem]`), so a title that doesn't fit beside the topic moves the button to a line
   of its own, where it wraps (`break-words`, `min-h-11`). Checked at 390 px with a long step
   name at 200 % text: `docs/t2/evidence/M2/after/pwa-running-bar-long-light.png`. jsdom has no
   layout, so this is screenshot evidence, not a unit test.
2. **Fixed.** `useOpenRunPrimary` no longer filters by kind: any primary the model places shows.
   Next and Lap tap in place; a primary of another kind opens the run panel, which handles every
   kind. `RunTileAction` never falls through to Start for an open run: with no primary (a queued
   reopen, §1.2 row 11) it renders nothing. The table test now also taps the bar in each state
   and checks the event (`next` or `lap`).
3. **Stands until #165 merges, then fixed on this branch.** The registry's only caller today is
   the running tile, which is what shows an open run's primary on `t2/m2` now. When `origin/t2/m2`
   gains #165, this branch merges it, moves the registration to the active card, and the topics
   page tests run against the real card.

---

## Round 2 (Codex, after the round-1 fixes)

1. **P2 — Typed Lap buttons fail label-in-name accessibility.** [RunTile.tsx:121](/Users/richie/code/quickr-worktrees/t2-m2-fbar/frontend/src/components/runs/RunTile.tsx:121) and [RunningBar.tsx:99](/Users/richie/code/quickr-worktrees/t2-m2-fbar/frontend/src/components/runs/RunningBar.tsx:99) use `actionLabel` for the accessible name. For a typed lap, the visible title is “Lap → Rest” but the accessible name is “Lap, then Rest · Morning”. Speech-control users cannot reliably activate the button by saying its visible label. Keep the visible wording in the accessible name, while retaining any pronunciation help needed for the arrow.

2. **P2 — The temporary running tile can make long primary labels disproportionately tall.** [RunTile.tsx:75](/Users/richie/code/quickr-worktrees/t2-m2-fbar/frontend/src/components/runs/RunTile.tsx:75) fixes the action to 5.25rem, and [line 130](/Users/richie/code/quickr-worktrees/t2-m2-fbar/frontend/src/components/runs/RunTile.tsx:130) now wraps the full step or lap-type name within that narrow column. A long name, especially at enlarged text sizes, can expand the whole topic card to many lines. The bar’s round-one fix addresses its own layout, but the same labels now appear in the tile without a layout that can accommodate them. Cover the tile at narrow width and enlarged text as well.

3. **P2 — The acceptance tests do not cover the typed-lap primary.** [RunTile.test.tsx:242](/Users/richie/code/quickr-worktrees/t2-m2-fbar/frontend/src/components/runs/RunTile.test.tsx:242) compares panel and bar for several states, but every Lap fixture is untyped. F2-BAR specifically calls for the next lap-type label, and this leaves its visible title, accessible name, icon and dispatch unverified on both surfaces. Add a typed-lap case when the model supplies that state; the current model explicitly stubs the label as null.

The round-one registry integration finding remains conditional on PR #165: the current tile registers correctly, but the active cards must take over registration when merged. I did not run the tests; this review was performed in a read-only workspace.
## Resolution (f2-bar, round 2)

1. **Stands (spec).** active-surfaces.md §1.3 sets the accessible name of `lap("Rest")` to
   "Lap, then Rest", the same on iOS VoiceOver and the PWA, and the run panel's `RunControls`
   already uses it through `actionLabel`. The bar and tile reuse that helper so all surfaces say
   the same thing; the name begins with the visible "Lap", so "click Lap" still matches. Changing
   it is a spec change for the lead, not this WP.
2. **Stands (temporary surface).** The running tile's primary exists only until #165 lands: from
   then an open run's tile is the active card, and this branch drops the tile's open-run branch
   when it merges #165. Before then the 5.25rem column wraps the title, as its "Add details"
   already does.
3. **Deferred to M1, issue filed.** `actions()` stubs `lap.nextTypeLabel` as null until
   `RunState.next_lap_type` exists (T2-M1 F1-CORE), so no typed-lap state can be built yet. The
   comparison test reads both surfaces from the model, so it covers the label as soon as M1
   supplies it; adding the row is #173.
