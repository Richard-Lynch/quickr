#!/usr/bin/env bash
# The real-time tests on the Mac: the TimingTests and MultiProcessTests suites, alone in their
# own `swift test`, one test at a time, on the normal cooperative pool. Every other run skips
# them (QuickrTestSupport `TimingTestRun`): on a few loaded cores their deadlines expire while
# other tests hold the CPU. swift-test.sh runs everything else, with a strict pool.
# Usage: timing-test.sh [swift test filter], default 'TimingTests|MultiProcessTests'.
source "$(dirname "$0")/common.sh"
require_xcodebuild
export QUICKR_TIMING_TESTS=1 LIBDISPATCH_COOPERATIVE_POOL_STRICT=0
swift_test --filter "${1:-TimingTests|MultiProcessTests}" --no-parallel
