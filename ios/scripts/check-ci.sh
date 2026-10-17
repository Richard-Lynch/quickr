#!/usr/bin/env bash
# What ios.yml runs on a ready PR: gen, then build and run the Unit plan with signing off,
# on an iPhone simulator that must be on an iOS 26.x runtime.
# Usage: check-ci.sh [preferred iPhone model]
source "$(dirname "$0")/common.sh"
require_xcode
here="$(dirname "$0")"
"$here/check-xcode-version.sh"
udid="$("$here/sim-ios26.sh" "${1:-}")"
"$here/gen.sh"
"$here/test.sh" Unit "$udid" CODE_SIGNING_ALLOWED=NO
"$here/resolved-check.sh"
echo "ios: ios-check-ci passed"
