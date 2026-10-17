#!/usr/bin/env bash
# Generate ios/quickR.xcodeproj (plus Info.plists and entitlements) from ios/project.yml.
source "$(dirname "$0")/common.sh"
require_xcode
xcodegen generate --quiet --spec "$IOS_DIR/project.yml"
