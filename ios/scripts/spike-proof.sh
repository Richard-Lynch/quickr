#!/usr/bin/env bash
# SPIKE (M1): a notification action logs an entry from a killed app, on a simulator, against
# this worktree's integration stack. Brings the stack up, creates two enum topics, renders their
# APNs payloads with the server's own code (spike-payload.py in the backend container), serves
# the host coordinator (spike-coordinator.py: the test's push barrier), runs the Spike plan
# (SpikeNotificationTests) under a wall-clock limit while recording the screen, and collects the
# results, the app group's spike log, the screenshots and the video into ios/build/spike.
# On demand, not in check-ios: SpringBoard automation can stall.
#
# Usage: spike-proof.sh [simulator name or UDID, default: this worktree's clone] [limit s, default 900]
# Leaves the stack up with SPIKE_KEEP_STACK=1; shuts the simulator down if it booted it.
source "$(dirname "$0")/integration-common.sh"
require_xcode
require_docker
here="$(dirname "$0")"
udid="$(sim_udid "${1:-$("$here/sim-clone.sh")}")"
limit="${2:-900}"
work="$BUILD_DIR/spike"
rm -rf "$work"; mkdir -p "$work"

booted_here=0
if ! xcrun simctl list devices booted | grep -q "$udid"; then
  others="$(xcrun simctl list devices booted | grep -c "quickR" || true)"
  (( others < 2 )) || die "two quickR simulators are already booted (the fleet's limit); try later"
  xcrun simctl boot "$udid"; booted_here=1
fi
sim_boot "$udid"

cleanup() {
  [[ -n "${coordinator:-}" ]] && kill "$coordinator" 2>/dev/null
  [[ -n "${recorder:-}" ]] && kill -INT "$recorder" 2>/dev/null && wait "$recorder" 2>/dev/null
  (( booted_here )) && xcrun simctl shutdown "$udid" 2>/dev/null
  [[ "${SPIKE_KEEP_STACK:-0}" == 1 ]] || "$here/integration-down.sh" >/dev/null 2>&1
}
trap cleanup EXIT

"$here/integration-up.sh"
it_load_env
api="$QUICKR_IT_DIRECT_URL/api/v1"

# create_topic <name> <first label> <second label>: prints the created topic's JSON.
create_topic() {
  curl -fsS -X POST "$api/topics" -H 'Content-Type: application/json' -d "$(python3 -c '
import json, sys
name, a, b = sys.argv[1:4]
print(json.dumps({"name": name, "questions": [{"type": "enum", "key": "mood", "label": "Mood", "required": True,
  "options": [{"value": a.lower(), "label": a}, {"value": b.lower(), "label": b}]}]}))' "$1" "$2" "$3")"
}

# payload <topic JSON>: the APNs payload the scheduler would send, from the backend's own code.
payload() {
  it_compose exec -T -e SPIKE_TOPIC="$1" -e SPIKE_SERVER_ID="$QUICKR_IT_SERVER_ID" \
    -e SPIKE_DUE_SINCE="2026-10-18T08:00:00+00:00" backend-a python - < "$here/spike-payload.py"
}

topic_a="$(create_topic "Spike app" Calm Busy)"
topic_b="$(create_topic "Spike NSE" Rested Tired)"
payload "$topic_a" > "$work/payload-app-registered.json"
payload "$topic_b" > "$work/payload-nse-only.json"
python3 - "$work" "$QUICKR_IT_BASE_URL" "$topic_a" "$topic_b" <<'EOF'
import base64, json, sys
from pathlib import Path
work, server, a, b = Path(sys.argv[1]), sys.argv[2], json.loads(sys.argv[3]), json.loads(sys.argv[4])
registered = [json.loads((work / "payload-app-registered.json").read_text())]
case = lambda name, topic, label, registered: {
    "name": name, "topicId": topic["id"], "topicName": topic["name"], "optionLabel": label,
    "optionValue": label.lower(), "appRegistered": registered}
(work / "setup.json").write_text(json.dumps({
    "server": server,
    "register": base64.b64encode(json.dumps(registered).encode()).decode(),
    "cases": [case("app-registered", a, "Busy", True), case("nse-only", b, "Tired", False)],
}))
EOF

python3 "$here/spike-coordinator.py" "$udid" "$work" "$work/port" 2>"$work/coordinator.log" &
coordinator=$!
for _ in $(seq 50); do [[ -s "$work/port" ]] && break; sleep 0.1; done
[[ -s "$work/port" ]] || die "spike coordinator didn't start (see $work/coordinator.log)"

xcrun simctl io "$udid" recordVideo --force "$work/spike.mov" 2>/dev/null &
recorder=$!

export TEST_RUNNER_SPIKE_COORDINATOR="http://127.0.0.1:$(cat "$work/port")"
"$here/test.sh" Spike "$udid" &
pid=$!
( sleep "$limit"; pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null ) &
watchdog=$!
status=0
wait "$pid" || status=$?
kill "$watchdog" 2>/dev/null || true

kill -INT "$recorder" 2>/dev/null; wait "$recorder" 2>/dev/null; recorder=""
group="$(xcrun simctl get_app_container "$udid" com.bahumia.quickr group.com.bahumia.quickr 2>/dev/null || true)"
[[ -n "$group" && -f "$group/Library/quickr/spike-log.jsonl" ]] && cp "$group/Library/quickr/spike-log.jsonl" "$work/"
result="$BUILD_DIR/results/Spike-$udid.xcresult"
[[ -d "$result" ]] && xcrun xcresulttool export attachments --path "$result" --output-path "$work/attachments" >/dev/null 2>&1
for case in app-registered nse-only; do
  echo "--- $case: $(cat "$work/result-$case.json" 2>/dev/null || echo 'no result')"
  echo "    entries on the server: $(curl -fsS "$api/topics/$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["quickr"]["topic_id"])' "$work/payload-$case.json")/entries" | python3 -c 'import json,sys;print(len(json.load(sys.stdin)["items"]))')"
done
(( status == 0 )) || die "Spike plan failed or exceeded ${limit}s (exit $status); see $work and $result"
echo "ios: spike proof passed on $udid; artefacts in $work"
