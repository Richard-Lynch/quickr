#!/usr/bin/env bash
# Tests for prune.sh (make ios-prune) against a throwaway git repo with worktrees, a fake
# `xcrun simctl` (devices from a JSON file, deletions recorded), a fake `lsof` and a fake `gh`.
# What goes: shut-down clones of finished (merged, idle, unused) or vanished worktrees, their
# build output, unavailable simulators. What stays: booted and held clones, base devices, active
# worktrees (unmerged, recently changed, uncommitted, in use) and the current one; and nothing at
# all in a dry run.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
fake="$(mktemp -d "${TMPDIR:-/tmp}/quickr-prune.XXXXXX")"
fake="$(cd "$fake" && pwd -P)"
trap 'rm -rf "$fake"' EXIT
fails=0
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
ok() { echo "ok   $*"; }

# --- the repo: base (ios/m3), its worktrees, and a squash-merged PR branch ---------------------
repo="$fake/repo"
git init -q -b main "$repo"
g() { git -C "$repo" "$@"; }
g config user.email t@example.com; g config user.name t
commit() { echo "$2" >"$1/f-$2"; git -C "$1" add -A; git -C "$1" commit -qm "$2"; }
printf 'ios/build/\n.build/\n' >"$repo/.gitignore"  # as the real repo ignores its build output
commit "$repo" one
g branch -q ios/m3
g update-ref refs/remotes/origin/ios/m3 ios/m3
mk() {  # mk <name> <branch> [from]: a worktree, its HEAD and reflog dated a day ago
  g worktree add -q -b "$2" "$fake/$1" "${3:-ios/m3}"
  echo "$fake/$1"
}
old() {  # old <worktree>: everything in it last changed a day ago
  local gitdir; gitdir="$(git -C "$1" rev-parse --absolute-git-dir)"
  touch -t "$(date -v-1d +%Y%m%d%H%M)" "$gitdir/HEAD" "$gitdir/logs/HEAD"
  find "$1/ios" -exec touch -t "$(date -v-1d +%Y%m%d%H%M)" {} + 2>/dev/null
}
build() { mkdir -p "$1/ios/build/dd" "$1/ios/QuickrKit/.build"; head -c 300000 /dev/zero >"$1/ios/build/dd/blob"; }

finished="$(mk finished wp/finished)"; build "$finished"; old "$finished"
unmerged="$(mk unmerged wp/unmerged)"; commit "$unmerged" two; build "$unmerged"; old "$unmerged"
recent="$(mk recent wp/recent)"; build "$recent"                       # changed just now
dirty="$(mk dirty wp/dirty)"; build "$dirty"; echo x >"$dirty/f-one"; old "$dirty"
inuse="$(mk inuse wp/inuse)"; build "$inuse"; old "$inuse"
held="$(mk held wp/held)"; build "$held"; old "$held"
gone="$(mk gone wp/gone)"
# A PR head squash-merged elsewhere: its branch isn't in the base, but gh lists it as merged.
squashed="$(mk squashed wp/squashed)"; commit "$squashed" three; build "$squashed"; old "$squashed"
squash_oid="$(git -C "$squashed" rev-parse HEAD)"
current="$(mk current wp/current)"; build "$current"; old "$current"
hash() { printf '%s' "$(cd "$1" && pwd -P)" | shasum | cut -c1-6; }
gone_hash="$(hash "$gone")"
g worktree remove --force "$gone"

# --- fakes ----------------------------------------------------------------------------------------
bin="$fake/bin"; mkdir -p "$bin"
devices_json="$fake/devices.json"
data="$fake/CoreSimulator/Devices"
dev() {  # dev <udid> <state> <name>: a device and some data
  mkdir -p "$data/$1"; head -c 200000 /dev/zero >"$data/$1/data"
  echo "$1|$2|$3" >>"$fake/devices.txt"
}
dev c-fin Shutdown "quickR iOS-26-0 finished-$(hash "$finished")"
dev c-fin27 Shutdown "quickR iOS27 finished-$(hash "$finished")"
dev c-unm Shutdown "quickR iOS-26-0 unmerged-$(hash "$unmerged")"
dev c-rec Shutdown "quickR iOS-26-0 recent-$(hash "$recent")"
dev c-dirty Shutdown "quickR iOS-26-0 dirty-$(hash "$dirty")"
dev c-inuse Shutdown "quickR iOS-26-0 inuse-$(hash "$inuse")"
dev c-held Shutdown "quickR iOS-26-0 held-$(hash "$held")"
dev c-gone Shutdown "quickR iOS-26-0 gone-$gone_hash"
dev c-gone-booted Booted "quickR iOS27 gone-$gone_hash"
dev c-squash Shutdown "quickR iOS-26-0 squashed-$(hash "$squashed")"
dev c-cur Shutdown "quickR iOS-26-0 current-$(hash "$current")"
dev base Shutdown "quickR iOS-26-0"
dev phone Shutdown "iPhone 17"
python3 - "$fake/devices.txt" "$devices_json" <<'PY'
import json, sys
devs = [dict(zip(("udid", "state", "name"), l.strip().split("|"))) for l in open(sys.argv[1])]
json.dump({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-0": devs}}, open(sys.argv[2], "w"))
PY
cat >"$bin/xcrun" <<'SH'
#!/usr/bin/env bash
case "$*" in
"simctl list -j devices") exec cat "$FAKE_DEVICES" ;;
"simctl list devices unavailable") echo "-- Unavailable: com.apple.CoreSimulator.SimRuntime.iOS-18-0 --"
  echo "    iPhone 15 (OLD-1) (Shutdown) (unavailable, runtime profile not found)" ;;
"simctl delete unavailable") echo unavailable >>"$FAKE_DELETED" ;;
"simctl delete "*) echo "$3" >>"$FAKE_DELETED" ;;
*) exit 1 ;;
esac
SH
# lsof: the in-use worktree is some process's working directory.
printf '#!/bin/sh\necho p123\necho n%s/ios\n' "$inuse" >"$bin/lsof"
printf '#!/bin/sh\n[ "$1" = -version ] && echo "Xcode 27.1"\n' >"$bin/xcodebuild"
printf '#!/bin/sh\necho %s\n' "$squash_oid" >"$bin/gh"
chmod +x "$bin"/*
export PATH="$bin:$PATH" FAKE_DEVICES="$devices_json" FAKE_DELETED="$fake/deleted"
export IOS_PRUNE_REPO="$current" IOS_SIM_DATA_DIR="$fake/CoreSimulator"
export QUICKR_SIM_CAP_LOCK="$fake/cap.lockf" QUICKR_SIM_HOLDS="$fake/holds"
unset IOS_PRUNE_DRY_RUN IOS_PRUNE_BASE IOS_PRUNE_IDLE_HOURS IOS_PRUNE_MERGED_PRS
# The held clone: a live hold (this test's own shell, with its start time).
mkdir -p "$fake/holds/c-held"; ps -o lstart= -p $$ | tr -s ' ' >"$fake/holds/c-held/$$"

prune() { out="$(perl -e 'alarm shift; exec @ARGV' 120 "$here/../prune.sh" "$@" 2>&1)"; status=$?; }
deleted() { grep -qx "$1" "$fake/deleted" 2>/dev/null; }

# --- a dry run removes nothing ---------------------------------------------------------------------
prune --dry-run
(( status == 0 )) && ok "a dry run succeeds" || fail "dry run: status $status: $out"
[[ ! -e "$fake/deleted" && -d "$finished/ios/build" ]] && ok "and removes nothing" || fail "the dry run removed: $(cat "$fake/deleted" 2>/dev/null)"
[[ "$out" == *"would remove simulator quickR iOS-26-0 finished-"* && "$out" == *"in all (dry run"* ]] \
  && ok "it says what it would remove, and how much" || fail "dry-run output: $out"

# --- the real run -------------------------------------------------------------------------------
prune
(( status == 0 )) && ok "a run succeeds" || fail "run: status $status: $out"
for d in c-fin c-fin27 c-gone c-squash; do
  deleted "$d" && ok "deletes $d" || fail "kept $d: $out"
done
for d in c-unm c-rec c-dirty c-inuse c-held c-gone-booted c-cur base phone; do
  deleted "$d" && fail "deleted $d" || ok "keeps $d"
done
deleted unavailable && ok "deletes unavailable simulators" || fail "unavailable not deleted"
[[ ! -d "$finished/ios/build" && ! -d "$finished/ios/QuickrKit/.build" ]] && ok "removes a finished worktree's build output" \
  || fail "finished build output kept"
[[ ! -d "$squashed/ios/build" ]] && ok "and a squash-merged PR worktree's" || fail "squashed build output kept"
for w in "$unmerged" "$recent" "$dirty" "$inuse" "$held" "$current"; do
  [[ -d "$w/ios/build" ]] || fail "removed $(basename "$w")'s build output"
done
ok "keeps the build output of unmerged, recent, dirty, in-use, held and current worktrees"
[[ "$out" == *"removed "*" in all"* ]] && ok "it prints what it freed" || fail "no total: $out"

# Without gh (or with IOS_PRUNE_MERGED_PRS=0), a squash-merged branch isn't finished.
rm -f "$fake/deleted"
build "$squashed"; old "$squashed"
IOS_PRUNE_MERGED_PRS=0 prune --dry-run
[[ "$out" != *"squashed"* ]] && ok "IOS_PRUNE_MERGED_PRS=0 leaves a squash-merged worktree alone" || fail "$out"

(( fails == 0 )) && echo "prune-test: all passed" || { echo "prune-test: $fails failed"; exit 1; }
