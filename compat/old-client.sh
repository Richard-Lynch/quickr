#!/usr/bin/env bash
# Old client vs this server: runs a supported iOS build's own wire suites (decoding the server's
# API responses and push payloads) against this checkout's shared/fixtures, plus
# CompatFallbackTests for the cases that build predates (docs/ios/specs/compatibility.md §3).
#
#   compat/old-client.sh <sha>       a client from compat/supported-clients.json
#
# Needs Xcode's toolchain: the suites are in QuickrData, which doesn't build on Linux (§3).
# COMPAT_WORK (default ios/build/compat, ignored) holds the client's sources and fixtures, under its sha.
set -euo pipefail

sha="${1:?usage: compat/old-client.sh <sha>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
work="${COMPAT_WORK:-$root/ios/build/compat}/$sha"
build="$(python3 -c 'import json,sys; print(next(c["build"] for c in json.load(open(sys.argv[1]))["clients"] if c["sha"]==sys.argv[2]))' \
  "$root/compat/supported-clients.json" "$sha")"

fail() {
  local message="build $build (${sha:0:7}): $1"
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then echo "::error title=old client $build::$message"; fi
  echo "compat: $message" >&2
  exit 1
}

python3 "$root/compat/client_fixtures.py" fixtures "$sha" "$work"

# The client's QuickrKit as it shipped. .build is kept (CI caches it per sha).
package="$work/src/ios/QuickrKit"
mkdir -p "$work/src"
find "$work/src" -mindepth 1 -maxdepth 1 ! -name ios -exec rm -rf {} +
if [[ -d "$package" ]]; then find "$package" -mindepth 1 -maxdepth 1 ! -name .build -exec rm -rf {} +; fi
git -C "$root" archive "$sha" ios/QuickrKit | tar -x -C "$work/src"
cp "$root/compat/CompatFallbackTests.swift" "$package/Tests/QuickrDataTests/"

suites=()
while IFS= read -r suite; do suites+=("$suite"); done < <(python3 "$root/compat/client_fixtures.py" suites)
suites+=(CompatFallbackTests)
filter="$(IFS='|'; echo "${suites[*]}")"
skips=()
while IFS= read -r test; do skips+=("$test"); done < <(python3 "$root/compat/client_fixtures.py" skip)
skip="$(IFS='|'; echo "${skips[*]}")"

log="$work/swift-test.log"
echo "compat: build $build (${sha:0:7}): swift test --filter '$filter' --skip '$skip'"
status=0
QUICKR_FIXTURES_DIR="$work/fixtures" QUICKR_COMPAT_FALLBACKS="$work/fallbacks.json" \
  swift test --package-path "$package" --filter "$filter" --skip "$skip" 2>&1 | tee "$log" || status=$?

if ((status != 0)); then
  fail "its wire suites fail on this PR's shared/fixtures, so this server change breaks a build users still run.
Fix the server change, or, if a failing case is one this build predates (a new enum case, say), declare
the fallback it takes in compat/supported-clients.json (docs/ios/specs/compatibility.md). Log: $log"
fi
# A suite this build lacks would pass the filter silently.
for suite in "${suites[@]}"; do
  grep -qE "Suite \"?$suite\"? passed" "$log" || fail "suite $suite didn't run (renamed or missing at this sha?)"
done
echo "compat: build $build (${sha:0:7}) reads this server's fixtures"
