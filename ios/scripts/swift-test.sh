#!/usr/bin/env bash
# swift test for ios/QuickrKit on the Mac (Core and Data; UI is iOS-only).
# Needs Xcode's toolchain but not xcodegen, so CI's host job can run it as is.
source "$(dirname "$0")/common.sh"
require_xcodebuild
# One cooperative-pool thread per QoS, so a test that blocks a pool thread (a semaphore wait,
# a sync wait on async work) hangs here too, not only on a 3-core CI runner. The build is
# unaffected. LIBDISPATCH_COOPERATIVE_POOL_STRICT=0 runs with the normal pool.
export LIBDISPATCH_COOPERATIVE_POOL_STRICT="${LIBDISPATCH_COOPERATIVE_POOL_STRICT:-1}"
swift_test "$@"
