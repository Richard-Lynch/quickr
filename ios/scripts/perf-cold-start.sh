#!/usr/bin/env bash
# PERF: the cold-start target (under 1 s from process start to Home's first tile, on the
# simulator) over the 10k-entry perf store, measured on the configuration that ships. Builds
# IOS_PERF_CONFIG (default Release, with QUICKR_PERF, which keeps the -QuickrPerfStore launch;
# Debug has it anyway), installs it, seeds the store with a first launch, then cold-launches it
# IOS_PERF_RUNS times (default 5) with simctl, no test runner attached, and reads the app's own
# PERF lines. Fails when Release's median is IOS_PERF_TARGET_MS (default 1000) or more.
# PerfLaunchUITests (perf-launch.sh) is the debug build's view, with XCTApplicationLaunchMetric.
# Usage: perf-cold-start.sh <simulator name or UDID>
source "$(dirname "$0")/common.sh"
require_xcode
udid="$(target_sim_udid "$1")"
config="${IOS_PERF_CONFIG:-Release}"; runs="${IOS_PERF_RUNS:-5}"; target="${IOS_PERF_TARGET_MS:-1000}"
args=(-configuration "$config")
[[ "$config" == Release ]] && args+=(SWIFT_ACTIVE_COMPILATION_CONDITIONS=QUICKR_PERF)
sim_boot "$udid"
xcb -destination "id=$udid" "${args[@]}" build >/dev/null
app="$DERIVED/Build/Products/$config-iphonesimulator/QuickR.app"
xcrun simctl install "$udid" "$app"
log="$(mktemp -t quickr-perf)"; trap 'rm -f "$log"' EXIT

# One launch: waits up to $1 seconds for the first tile, prints the launch's PERF lines and
# leaves the first tile's milliseconds in $first.
launch() {
  local wait="$1" i
  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  : > "$log"
  xcrun simctl launch --console-pty "$udid" "$BUNDLE_ID" -QuickrPerfStore > "$log" 2>&1 &
  local pid=$!
  for ((i = 0; i < wait * 10; i++)); do
    grep -q "first tile on screen" "$log" && break
    sleep 0.1
  done
  sleep 0.5  # the lines after it
  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  wait "$pid" 2>/dev/null || true
  first="$(sed -nE 's/.*PERF ([0-9]+) ms: first tile on screen.*/\1/p' "$log" | head -1)"
  grep -E "PERF [0-9]+ ms" "$log" | tr -d '\r' | sed 's/^/  /'
}

echo "perf: $config build, $(uptime)"
echo "perf: seeding launch"
launch 180
[[ -n "$first" ]] || die "the seeding launch never showed Home's first tile"
times=()
for ((n = 1; n <= runs; n++)); do
  echo "perf: cold launch $n"
  launch 30
  [[ -n "$first" ]] || die "launch $n never showed Home's first tile"
  times+=("$first")
done
median="$(printf '%s\n' "${times[@]}" | sort -n | sed -n "$(((runs + 1) / 2))p")"
echo "PERF $config cold start to Home's first tile (ms): ${times[*]}, median $median; $(uptime)"
if [[ "$config" == Release && "$median" -ge "$target" ]]; then
  die "the median cold start ($median ms) misses the ${target} ms target"
fi
