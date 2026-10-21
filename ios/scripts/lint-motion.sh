#!/usr/bin/env bash
# Reduce Motion lint: motion must go through QuickrUI's Tokens/Motion.swift (qrAnimation,
# withQRAnimation, QuickrMotion.animation, @QuickrReduceMotion), so both the system setting and
# the UI tests' -QuickrReduceMotion turn it off. Flags a bare `withAnimation` and a direct read of
# `\.accessibilityReduceMotion` anywhere else.
# Fails on a hit (every App/ call site goes through QuickrMotion); QUICKR_MOTION_LINT=warn only warns.
# Usage: lint-motion.sh
source "$(dirname "$0")/common.sh"
cd "$IOS_DIR"
hits=$(grep -rnE '\bwithAnimation\b|\\\.accessibilityReduceMotion' --include='*.swift' \
  App Widgets NotificationService QuickrKit/Sources | grep -v '^QuickrKit/Sources/QuickrUI/Tokens/Motion.swift:' || true)
[[ -z "$hits" ]] && exit 0
count=$(printf '%s\n' "$hits" | wc -l | tr -d ' ')
printf '%s\n' "$hits" >&2
msg="$count motion call(s) bypass Reduce Motion: use withQRAnimation / qrAnimation / @QuickrReduceMotion (Tokens/Motion.swift)"
[[ "${QUICKR_MOTION_LINT:-strict}" == strict ]] && die "$msg"
warn "$msg"
