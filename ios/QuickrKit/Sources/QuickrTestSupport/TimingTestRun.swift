import Foundation

/// Whether this test run is the real-time one: `make ios-timing-test` sets QUICKR_TIMING_TESTS=1
/// and runs only the `TimingTests` and `MultiProcessTests` suites, one test at a time, on the normal
/// cooperative pool. Every other run (`swift test`, `make ios-core-test`, the simulator's Unit plan)
/// skips them: on a few loaded cores their deadlines expire while other tests hold the CPU.
public enum TimingTestRun {
    public static var enabled: Bool { ProcessInfo.processInfo.environment["QUICKR_TIMING_TESTS"] == "1" }
}
