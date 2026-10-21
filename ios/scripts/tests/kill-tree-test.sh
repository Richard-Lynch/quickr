#!/usr/bin/env bash
# Tests for common.sh kill_tree: a limit's stop reaches every descendant (grandchildren included,
# as xcodebuild sits under test.sh's watchdog pipeline), and nothing outside the tree.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
set +e
failures=0
check() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1"; failures=$((failures + 1)); fi; }
alive() { kill -0 "$1" 2>/dev/null; }

# A three-level tree: bash → bash → sleep, plus a sleep in a pipeline; and a bystander.
work="$(mktemp -d "${TMPDIR:-/tmp}/quickr-killtree.XXXXXX")"
tree=""
bystander=""
# Whatever a failing kill_tree left behind is stopped here, by PID, so no sleep outlives the test.
trap 'for p in $tree $bystander; do kill "$p" 2>/dev/null; done; rm -rf "$work"' EXIT
bash -c "bash -c 'sleep 300 & echo \$! > $work/grandchild; sleep 300 | cat; wait' & wait" 2>/dev/null &
root=$!
sleep 300 2>/dev/null &
bystander=$!
for _ in $(seq 50); do [[ -s "$work/grandchild" ]] && break; sleep 0.1; done
grandchild="$(cat "$work/grandchild")"
check "the tree is up" 'alive "$root" && alive "$grandchild"'
descendants() { local c; for c in $(pgrep -P "$1"); do echo "$c"; descendants "$c"; done; }
tree="$(descendants "$root")"
check "the tree has at least four processes under the root" '(( $(wc -l <<<"$tree") >= 4 ))'

kill_tree "$root"
wait "$root" 2>/dev/null
for _ in $(seq 50); do alive "$grandchild" || break; sleep 0.1; done
check "the root is stopped" '! alive "$root"'
check "a grandchild is stopped" '! alive "$grandchild"'
left() { local p; for p in $tree; do alive "$p" && echo "$p"; done; }
for _ in $(seq 50); do [[ -z "$(left)" ]] && break; sleep 0.1; done
check "nothing of the tree is left" '[[ -z "$(left)" ]]'
check "a process outside the tree is untouched" 'alive "$bystander"'
kill "$bystander" 2>/dev/null
wait "$bystander" 2>/dev/null
check "a pid that has gone is not an error" 'kill_tree "$root"'

(( failures == 0 )) && echo "kill-tree-test: all passed" || { echo "kill-tree-test: $failures failed"; exit 1; }
