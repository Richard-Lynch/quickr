- **Medium — No-colour topics change the default UI.** [TopicHeader.swift](/Users/richie/code/quickr-worktrees/t2-m3a-i3render/ios/QuickrKit/Sources/QuickrUI/Topics/TopicHeader.swift:23) creates a header for an icon-only or tags-only appearance. That adds a name row, spacing, and potentially chips above the tabs even though §4.3 says a topic without a colour must look exactly as it does on `main`. The host test at [TopicHeaderTests.swift](/Users/richie/code/quickr-worktrees/t2-m3a-i3render/ios/QuickrKit/Tests/QuickrDesignTests/TopicHeaderTests.swift:52) explicitly enshrines this behavior.

- **Medium — Observation is not keyed by the topic reference.** [TopicTabsView.swift](/Users/richie/code/quickr-worktrees/t2-m3a-i3render/ios/App/Entries/TopicTabsView.swift:53) restarts its task only when the session binding changes. If SwiftUI retains this view’s identity while its `ref` changes, the existing observation continues using its captured reference and the retained `topic` ID. The header can then show the previous topic while the tabs and toolbar address the new one. Include `ref` in the task identity and reset the resolved ID when it changes.

- **Low — Tag accessibility identifiers differ from the specified contract.** [TopicHeader.swift](/Users/richie/code/quickr-worktrees/t2-m3a-i3render/ios/QuickrKit/Sources/QuickrUI/Topics/TopicHeader.swift:48) uses `topic.header.tags` and `topic.header.tags.<i>`, whereas the plan calls for the §7 identifiers `topic.tags` and `topic.tags.<i>`. Tests keyed to that contract cannot find the header chips. The new host test checks the substituted strings, so it will not catch the mismatch.

I did not find a definite `FlowRow` measurement or placement defect from the code review. The host tests exercise the content model, not the iOS-only layout, Dynamic Type rendering, VoiceOver tree, or live observation; those still need the planned UI coverage. I did not run tests. The deliberately deferred Live Activity patch is excluded from these findings.
## Resolution (m3a-irender, phase 1)

1. **Medium, no-colour topics show a header: stands (justified).** §5 puts the tag chips in the topic header and §6.3 puts the glyph there. Requirement #9 wants the emoji "rendered on every client". If §4.3 hid the header for every topic without a colour, icon-only and tags-only topics would never show their emoji or chips. So §4.3 is read as "the default theme draws no extra accent chrome". A topic with no appearance at all (nil, or `.empty`) gets no header and looks exactly like `main` (`noAppearanceShowsNoHeader`, `topicWithoutAppearanceShowsNoHeader`). A topic without a colour gets no tint rule and no initial on an accent circle (`noColourDrawsNoAccentChrome`). The spec clarification is proposed to the lead.
2. **Medium, observation not keyed by `ref`: fixed.** The `.task` id is now `HeaderKey(binding:ref:)`, so a new ref restarts the observation, and `observeTopic` resets `topic` to nil first.
3. **Low, header chip ids are not §7's: stands (justified).** §7's `topic.tags` / `topic.tags.<i>` belong to the editor (`AppearanceEditorView`). The brief asked for header ids "in the same style". `topic.header.tags.<i>` follows that style and doesn't collide with the editor's ids if both are on screen in one UI test. M3-UITEST keys on `TopicHeaderContent.tagIdentifier(_:)`.

## Round 2 (Codex, on the fixed diff)

**One finding remains:**

- **Medium — No-colour topics still change the default UI.** [TopicHeader.swift](/Users/richie/code/quickr-worktrees/t2-m3a-i3render/ios/QuickrKit/Sources/QuickrUI/Topics/TopicHeader.swift:23) creates a header for icon-only and tags-only appearances. The proposed interpretation of §4.3 limits its guarantee to accent chrome, but the spec says a topic without a colour “looks exactly as it does on `main`.” Sections 5 and 6.3 create a real conflict with that wording; they do not establish the proposed exception. The resolution remains dependent on the requested spec clarification.

The observation fix keys the task on both session binding and topic reference and resets the resolved topic when it restarts. The identifier justification also holds: §7 specifies `topic.tags` identifiers for the appearance editor, not the header.

I did not run tests or verify the iOS layout and accessibility tree on a simulator.
**Resolution:** finding 2 is confirmed fixed and the finding 3 justification is accepted. Finding 1 is a real conflict between §4.3 and §5/§6.3. It goes to the lead as a spec clarification; the code keeps the reading above until the lead rules.

## Round 3 (Codex, phase 2: on I3-STORE, diff origin/t2/m3a-i3store...HEAD)

**Findings: none.**

The header reads the stored `Topic.appearance`, and the amended §4.3 supports the icon-only and tags-only behavior. The observation is keyed by both the session binding and topic reference. I found no definite defect in `FlowRow` or the accessibility identifiers.

The host tests cover the header content model; they do not verify the iOS layout, VoiceOver tree, or live observation. I did not run tests. The deferred Live Activity patch was outside this review.
**Resolution:** no findings. The round 1/2 finding 1 is closed by the lead amending §4.3 (028d1546).

## Round 4 (Codex, full diff origin/t2/m3a...HEAD after #211 merged)

Findings: none.

The earlier no-colour finding is resolved by the amended §4.3, and the header observation is now keyed by both the session binding and topic reference. The Live Activity attributes patch was excluded as the deliberate follow-on held on M1-LA-STATE.

I did not run tests or verify the iOS layout and accessibility tree on a simulator.
**Resolution:** no findings.
