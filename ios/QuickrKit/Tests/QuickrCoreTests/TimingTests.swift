import QuickrTestSupport
import Testing

/// Tests whose outcome depends on real time: request deadlines, flush budgets, transport
/// timeouts, performance bounds. In a parallel run on a few cores (CI has 3) they miss their
/// deadlines while other tests hold the CPU, so they run alone, one at a time, on the normal
/// cooperative pool: `make ios-timing-test`. Every other run skips them (`TimingTestRun`).
@Suite(
    .serialized, .timeLimit(.minutes(2)),
    .enabled(if: TimingTestRun.enabled, "real-time: runs alone with make ios-timing-test (QUICKR_TIMING_TESTS=1)"))
struct TimingTests {}
