#!/usr/bin/env bash
# PERF: cold starts over the 10k-entry perf store (PerfLaunchUITests: process start to Home's
# first tile, and XCTApplicationLaunchMetric). Real time, so apart from the UI plan, which skips
# them. Usage: perf-launch.sh <simulator name or UDID> [extra xcodebuild args...]
source "$(dirname "$0")/common.sh"
sim="$1"; shift
# xcodebuild hands TEST_RUNNER_<name> to the test runner as <name>.
export TEST_RUNNER_QUICKR_UIT_PERF=1
"$(dirname "$0")/test.sh" UI "$sim" -only-testing:QuickRUITests/PerfLaunchUITests "$@"
