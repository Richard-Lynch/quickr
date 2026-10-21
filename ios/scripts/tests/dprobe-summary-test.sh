#!/usr/bin/env bash
# Tests for dprobe-summary.py's verdicts (checkpoint D's D8 and D9): a complete run is go, a
# failed round is no-go, and anything short of complete is incomplete. No Xcode needed.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/quickr-dprobe.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
summary="$here/../dprobe-summary.py"
failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

# d8 <rounds wanted> <rounds recorded> [failed round] [extra JSON line]: a D8 run's file.
d8() {
  local wanted=$1 recorded=$2 failed=${3:-0} extra=${4:-}
  {
    echo "{\"run\":\"r\",\"process\":\"app\",\"probe\":\"d8\",\"event\":\"start\",\"rounds\":$wanted,\"at\":1}"
    echo '{"run":"r","process":"nse","probe":"d8","event":"ready","at":1}'
    for i in $(seq 1 "$recorded"); do
      ok=true; missing='[]'
      [[ $i == "$failed" ]] && ok=false && missing='["quickr.t.x.1"]'
      [[ $i == 2 && $failed == 0 ]] && missing='["quickr.t.x.2"]'  # repaired by the reconcile
      echo "{\"run\":\"r\",\"process\":\"app\",\"probe\":\"d8\",\"event\":\"round\",\"round\":$i,\"ok\":$ok,\"missing\":$missing,\"overlap\":true,\"at\":1}"
    done
    [[ -n "$extra" ]] && echo "$extra"
    echo '{"run":"r","process":"nse","probe":"d8","event":"done","ok":true,"at":2}'
    echo '{"run":"r","process":"app","probe":"d8","event":"done","ok":true,"at":2}'
  } >"$tmp/r.jsonl"
}

check() {  # check <name> <expected status> <expected text>
  local out status
  out="$(python3 "$summary" "$tmp/r.jsonl")"; status=$?
  if [[ $status == "$2" ]] && grep -q -- "$3" <<<"$out"; then echo "ok: $1"; else fail "$1 (status $status): $out"; fi
}

d8 100 100;            check "100 of 100 rounds: go" 0 "D8 go"
grep -q . "$tmp/r.jsonl" && python3 "$summary" "$tmp/r.jsonl" | grep -q "1 after one reconcile" && echo "ok: a repaired round counts" || fail "repaired round"
d8 100 100 37;         check "a failed round: no-go" 1 "D8 NO-GO"
d8 100 1;              check "1 of 100 rounds: incomplete, not go" 3 "1 of 100 rounds recorded"
d8 100 100 0 '{"run":"r","process":"nse","probe":"d8","event":"timeout","round":60,"note":"out of time","at":2}'
check "an NSE timeout: incomplete" 3 "nse timeout"
d8 100 100 0 '{"run":"r","process":"app","probe":"d8","event":"error","note":"boom","at":2}'
check "an error: incomplete" 3 "app error"
d8 3 3; sed -i '' '/"process":"nse".*"done"/d' "$tmp/r.jsonl"
check "the NSE never finished: incomplete" 3 "nse never finished"
d8 3 3; sed -i '' 's/"process":"app","probe":"d8","event":"done","ok":true/"process":"app","probe":"d8","event":"done","ok":false/' "$tmp/r.jsonl"
check "the real categories not restored: incomplete" 3 "didn't restore"
d8 100 100; sed -i '' 's/"overlap":true/"overlap":false/' "$tmp/r.jsonl"
check "attempts that never overlapped: incomplete, not go" 3 "overlapped in only 0 of 100"

d9() {  # d9 [drop the NSE's size] : a D9 run's file
  for p in app nse; do
    echo "{\"run\":\"q\",\"process\":\"$p\",\"probe\":\"d9\",\"event\":\"start\",\"sizes\":[100,1000,5000],\"at\":1}"
    for s in 100 1000 5000; do
      [[ $p == nse && $s == "${1:-}" ]] && continue
      echo "{\"run\":\"q\",\"process\":\"$p\",\"probe\":\"d9\",\"event\":\"size\",\"size\":$s,\"set_ms\":1.5,\"register_ms\":9.0,\"readback_ms\":2.0,\"seen\":$s,\"ok\":true,\"at\":1}"
    done
    echo "{\"run\":\"q\",\"process\":\"$p\",\"probe\":\"d9\",\"event\":\"done\",\"ok\":true,\"at\":2}"
  done >"$tmp/r.jsonl"
}
d9; check "D9 complete: the table" 0 "nse       5000"
d9; echo '{"run":"q","process":"nse","probe":"d9","event":"timeout","size":5000,"note":"not enough time left for this size","at":2}' >>"$tmp/r.jsonl"
check "D9 with a size the NSE couldn't reach: incomplete" 3 "D9 INCOMPLETE"
d9 5000; check "D9 missing a size, with no timeout: incomplete" 3 "nse 5000: not measured"
d9; sed -i '' '/"process":"nse".*"size":5000/s/"ok":true/"ok":false,"overrun":true/' "$tmp/r.jsonl"
check "D9's last size past the deadline: incomplete" 3 "past the NSE's deadline"
d9; grep -v '"event":"start"' "$tmp/r.jsonl" >"$tmp/x" && mv "$tmp/x" "$tmp/r.jsonl"
check "D9 without start records (no sizes known): incomplete" 3 "no start record"
d9; sed -i '' '/"process":"app".*"size":1000/s/"ok":true/"ok":false/; /"process":"app".*"size":1000/s/"seen":1000/"seen":100/' "$tmp/r.jsonl"
check "D9 with a readback that showed only some: complete, with the finding" 0 "showed 100 of 1000"

if (( failures )); then
  echo "dprobe-summary-test: $failures failed"
  exit 1
fi
echo "dprobe-summary-test: all passed"
