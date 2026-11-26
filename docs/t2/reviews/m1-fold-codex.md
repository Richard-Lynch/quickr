1. **Medium — the property test excludes valid arrival orders.** [test_run_fold_v4.py:914](/Users/richie/code/quickr-worktrees/t2-m1-fold/backend/tests/test_run_fold_v4.py:914) puts every target into the same fixed subsequence as terminals, reopens and removes. That also fixes the targets’ order relative to one another, even where the specification permits them to commute. For example, two pauses targeted by separate removes cannot swap while each remains before its own remove. Generate permutations from the actual pairwise ordering constraints instead, and assert that unrelated targets can move past one another.

2. **Medium — the vector generator has not switched to the `Timer` schema.** [test_run_fold_vectors.py:30](/Users/richie/code/quickr-worktrees/t2-m1-fold/backend/tests/test_run_fold_vectors.py:30) still constructs plain dictionaries. M1-FOLD explicitly requires merging M1-DB and generating `timer_sets` from its normalized `Timer` schema before completion. Until then, the shared vectors do not verify the schema representation that the ports must consume. Merge the dependency, construct the sets through `Timer`, and regenerate the fixture.

I found no other issues in the requested review areas. The endpoint test limitations are consistent with the stated pre-M1-DB/M1-RUNS/M1-MCP scope. I did not run the test suite; this was a static review.
---

## Resolution (t2-m1-fold)

1. **Fixed** in the commit "property test keeps only the pairwise orders §3.4 names": `reorder` draws a random topological order of the real constraints (ordered events among themselves; each reopen/remove with every occurrence of its target), and the test asserts that orders with swapped targets occur (> 200 of 12 000).
2. **Deferred to M1-DB, by the WP plan.** The WP section says the generator switches `timer_sets` to the `Timer` schema after merging `t2/m1-db` (or `t2/m1` once M1-DB is in). M1-DB hasn't started yet; it waits on M1-EXPR. The plain `{steps, laps}` dicts are the interim form. The final regeneration of the vectors happens after that merge, before the stack merges into `t2/m1`.
