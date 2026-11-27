1. **[P2] Required clock and status identifiers remain unavailable — [ActiveTopicCard.swift:112](/Users/richie/code/quickr-worktrees/t2-m2-home/ios/App/Home/Tiles/ActiveTopicCard.swift:112).** The summary combines its children into one accessibility element, so `tile.<slug>.segment`, `tile.<slug>.total`, and `run.status` cannot be addressed individually as required by §3.2. Round 1 records this as raised with the lead, but the spec has not been changed and the issue remains unresolved. An automated test cannot assert those individual values through the specified identifiers.
---

## Resolution (i2-home)

1. **Stands, same as round 1 finding 3.** §7's single combined VoiceOver element and §3.2's child
   ids conflict; the combined element is the user-facing rule and wins. The ids stay as the spec
   writes them; the spec correction (one id on the combined summary, UI tests reading its label)
   is with the lead for the spec-correction commit. No spec edit on a WP branch.
