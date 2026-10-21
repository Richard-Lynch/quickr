# PERF: a heavy user's store, measured

The store is `PerfSeed`, the same in every run:

- 20 topics of five shapes, 39 versions in all.
- 10,000 entries over a year, skewed towards a few topics. The busiest has about
  2,800.
- An outbox with an item in every state.

The simulator runs launch the app with `-QuickrPerfStore`, which opens that
store offline, so the network never gates the first render. Device numbers come
at M4-DEV.

Every number below was taken at a 1-minute load average under 6, and each line
gives its `uptime`. Runs at a higher load were discarded. The bounds in the
tests are fixed ceilings, not derived from these numbers.

## Cold start to Home's first tile (simulator, iOS 26.0)

`make ios-perf-cold-start` builds the app, seeds the store, then cold-launches
it 5 times with `simctl`, with no test runner attached. It reads the app's own
measure: process start, as the kernel records it, to the first tile's
`onAppear`. It fails when Release's median reaches 1 s.

| Build                   | Launches (ms)           | Median     | Load (1 min)      |
| ----------------------- | ----------------------- | ---------- | ----------------- |
| Release (`QUICKR_PERF`) | 617, 602, 602, 598, 610 | **602 ms** | 4.43 at the start |
| Debug                   | 603, 601, 604, 617, 608 | 604 ms     | 4.40 at the start |

The target is under 1 s on Release, and it is met with about 400 ms to spare.
Release and Debug come out the same because the launch isn't bound by the code
that optimisation speeds up. A Release launch breaks down as follows:

| Step                                               | Time since process start                           |
| -------------------------------------------------- | -------------------------------------------------- |
| `App.init`                                         | ~355 ms (dyld and runtime set-up on the simulator) |
| Environment and session open                       | +15 ms                                             |
| `didFinishLaunching`                               | +15 ms                                             |
| Scene and first views, until Home starts observing | +165 ms                                            |
| `start()` to a bound store                         | +10 ms                                             |
| Home's first query to its first tile on screen     | +75 ms                                             |

No hot spot was worth a change. Several candidates were checked:

- The topics query (counts and last capture over the 10,000 entries) uses
  `ix_entry_topic` and takes 3 ms warm.
- Registering the bundled fonts takes 4 ms.
- The app embeds no dynamic frameworks.
- The largest step, before `App.init`, is the simulator's process set-up.

`PerfLaunchUITests` (`make ios-perf-launch`, Debug, which the scheme's test
action requires) measures the same launch under XCUITest, which adds its own
launch overhead. At a load of 4.87 at the start:

- First tile: 1132, 1127, 1259, 1174 and 1138 ms, median 1138 ms. The bound is 2
  s.
- `XCTApplicationLaunchMetric` (first frame, responsive): 1.135, 1.173, 1.129,
  1.204 and 1.111 s. These are stable enough to keep.

## The data paths (host, `make ios-timing-test`, Debug)

`TimingTests.Perf`, over the same seed, at a load of 5.01 at the start:

| Path                                                     | Time  | Bound |
| -------------------------------------------------------- | ----- | ----- |
| Cold start: session bound                                | 9 ms  |       |
| Cold start: Home has its 20 topics, with derived counts  | 21 ms | 1 s   |
| The busiest topic's entries (2,791 rows, 3 pinned)       | 59 ms | 1 s   |
| Overview: stats and 3 series fetched, decoded and cached | 6 ms  | 1 s   |
| Overview: the same from the cache, offline               | 9 ms  | 1 s   |
| The NSE: open read-only, reconcile, check, badge         | 21 ms | 2 s   |
