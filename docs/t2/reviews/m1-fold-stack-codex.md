1. **[P2] The widened timing endpoint test never stores or checks the lap types it claims to cover.** In [test_api_timing.py](/Users/richie/code/quickr-worktrees/t2-m1-fold/backend/tests/test_api_timing.py:55), `seed()` still stores only `timer["steps"]`, dropping the vector’s `laps`. The newly included cases at [line 92](/Users/richie/code/quickr-worktrees/t2-m1-fold/backend/tests/test_api_timing.py:92) also pass their expectations through `served()`, which removes every `lap_types` result. Consequently, these cases pass even if the endpoint never reads a stored lap type. Store the complete normalized timer in `seed()`, and add a test that verifies the stored lap types reach the stats calculation. Once M1-MCP exposes the fields, compare the full endpoint response against the vectors.
---

## Resolution (t2-m1-fold)

1. **Fixed.** `seed()` now stores the vector's full normalised timer, lap types included. The earlier replace had missed the line because ruff had reflowed it. The new `test_stored_lap_types_reach_the_stats`, parametrised over the five §7.4 cases, spies on `timing_stats.timing_stats` during the request. It asserts that the stats the endpoint computes equal the vector's `expected`, `lap_types` included, and that the case carries lap types.
   - Mutation check: storing only the steps again fails all 5 cases. The file was restored from a backup copy.
   - The full-response comparison waits for M1-MCP, which adds `lap_types` to the `TopicTiming` schema; `served()` documents that.
