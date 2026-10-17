#!/usr/bin/env bash
# What ios.yml runs on a ready PR: gen, then build and run the Unit plan with signing off.
# Usage: check-ci.sh <simulator name or UDID>
source "$(dirname "$0")/common.sh"
require_xcode
here="$(dirname "$0")"
"$here/check-xcode-version.sh"
"$here/gen.sh"
"$here/test.sh" Unit "$1" CODE_SIGNING_ALLOWED=NO
echo "ios: ios-check-ci passed"
