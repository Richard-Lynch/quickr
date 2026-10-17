#!/usr/bin/env bash
# swift-format lint over the iOS sources. Skips with a warning if swift-format is unavailable.
source "$(dirname "$0")/common.sh"
if ! xcrun --find swift-format >/dev/null 2>&1; then
  warn "swift-format not found; skipping the lint"
  exit 0
fi
cd "$IOS_DIR"
xcrun swift-format lint --strict --recursive --parallel \
  --configuration "$IOS_DIR/.swift-format" \
  App AppTests UITests Widgets NotificationService QuickrKit/Package.swift QuickrKit/Sources QuickrKit/Tests
