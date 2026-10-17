#!/usr/bin/env bash
# swift test for ios/QuickrKit on the Mac (Core and Data; UI is iOS-only).
# Needs Xcode's toolchain but not xcodegen, so CI's host job can run it as is.
source "$(dirname "$0")/common.sh"
require_xcodebuild
swift_test "$@"
