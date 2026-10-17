#!/usr/bin/env bash
# Generate ios/quickR.xcodeproj (plus Info.plists and entitlements) from ios/project.yml,
# then copy the tracked lockfile into the generated workspace.
source "$(dirname "$0")/common.sh"
require_xcode
xcodegen generate --quiet --spec "$IOS_DIR/project.yml"
if [[ -f "$RESOLVED" ]]; then
  mkdir -p "$(dirname "$WORKSPACE_RESOLVED")"
  cp "$RESOLVED" "$WORKSPACE_RESOLVED"
else
  rm -f "$WORKSPACE_RESOLVED"
fi
