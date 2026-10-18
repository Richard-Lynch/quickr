#!/usr/bin/env bash
# Update the package pins in ios/QuickrKit/Package.resolved (commit it), then check that Xcode
# resolves to exactly those pins.
source "$(dirname "$0")/common.sh"
require_xcode
# Resolution fetches without printing much, so it gets a longer silence budget.
export IOS_WATCHDOG_SILENCE_MIN="${IOS_WATCHDOG_SILENCE_MIN:-40}"
watchdog swift package update --package-path "$IOS_DIR/QuickrKit"
"$(dirname "$0")/gen.sh"
args=(-resolvePackageDependencies -project "$PROJECT" -scheme "$SCHEME" -clonedSourcePackagesDirPath "$SPM_DIR")
[[ -f "$RESOLVED" ]] && args+=(-onlyUsePackageVersionsFromResolvedFile)
watchdog xcodebuild "${args[@]}" >/dev/null
"$(dirname "$0")/resolved-check.sh"
