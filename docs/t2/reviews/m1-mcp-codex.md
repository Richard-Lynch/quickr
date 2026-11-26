No correctness findings in the diff against the M1-MCP acceptance criteria and the cited spec sections.

The new MCP paths have database-backed tests, including reopen’s missing-terminal error and remove’s required target. The timing endpoint tests compare seeded entries with the v3 vectors and cover untyped laps. The identity test checks that no mutation operation was added. The Swift DTO and the hand-written iOS and PWA timing payloads I found include `lap_types` at both required levels.

I reviewed the tests but did not run them; this workspace is read-only.