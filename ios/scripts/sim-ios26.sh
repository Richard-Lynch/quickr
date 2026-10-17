#!/usr/bin/env bash
# CI's simulator: prints the UDID of an available iPhone on an iOS 26.x runtime, the minimum we
# deploy to (PLAN §6a rule 12). Prefers the named model, then the oldest 26.x runtime. Fails
# when no such simulator exists, rather than falling back to another iOS version.
# Usage: sim-ios26.sh [preferred device name]
source "$(dirname "$0")/common.sh"
xcrun simctl list --json devices available | python3 -c '
import json, re, sys

preferred = sys.argv[1]
candidates = []
for runtime, devices in json.load(sys.stdin)["devices"].items():
    m = re.fullmatch(r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-26-(\d+)(?:-(\d+))?", runtime)
    if not m:
        continue
    version = (26, int(m.group(1)), int(m.group(2) or 0))
    for d in devices:
        if d.get("isAvailable") and d["name"].startswith("iPhone"):
            candidates.append((d["name"] != preferred, version, d["name"], d["udid"]))
if not candidates:
    sys.exit("ios: no available iPhone simulator on an iOS 26.x runtime (xcrun simctl list runtimes)")
_, version, name, udid = min(candidates)
print(f"ios: CI simulator {name}, iOS {version[0]}.{version[1]}.{version[2]} ({udid})", file=sys.stderr)
print(udid)
' "${1:-}"
