#!/usr/bin/env bash
# Warn (don't fail) when the selected Xcode isn't the 27.x the project is developed with (PLAN §2).
source "$(dirname "$0")/common.sh"
# Read all of it, then keep the first line: `| head -1` under pipefail can die of SIGPIPE (141).
version="$(xcodebuild -version)"
version="${version%%$'\n'*}"
if [[ "$version" =~ ^Xcode\ 27\. ]]; then
  echo "ios: $version"
else
  warn "expected Xcode 27.x, found '$version' ($(xcode-select -p))"
fi
