#!/usr/bin/env bash
# swift-format lint over the iOS sources. Fails if swift-format is unavailable, unless run
# with --optional (then it warns and skips).
# Usage: lint.sh [--optional]
source "$(dirname "$0")/common.sh"
if ! xcrun --find swift-format >/dev/null 2>&1; then
  msg="swift-format not found (it ships with Xcode 16+; check xcode-select -p = $(xcode-select -p))"
  [[ "${1:-}" == "--optional" ]] && { warn "$msg; skipping the lint"; exit 0; }
  die "$msg"
fi
cd "$IOS_DIR"
xcrun swift-format lint --strict --recursive --parallel \
  --configuration "$IOS_DIR/.swift-format" \
  App AppTests UITests Widgets NotificationService QuickrKit/Package.swift QuickrKit/Sources QuickrKit/Tests
