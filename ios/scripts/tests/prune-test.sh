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
trap 'chmod -R u+rwx "$fake" 2>/dev/null; rm -rf "$fake"' EXIT
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
# Finished but for a build directory find can't read: nothing proves it idle, so it stays.
perm="$(mk perm wp/perm)"; build "$perm"; mkdir -p "$perm/ios/build/noread"; old "$perm"; chmod 000 "$perm/ios/build/noread"
# Finished when classified, but a build starts in it before its output goes.
late="$(mk late wp/late)"; build "$late"; old "$late"
hash() { printf '%s' "$(cd "$1" && pwd -P)" | shasum | cut -c1-6; }
gone_hash="$(hash "$gone")"
g worktree remove --force "$gone"

# --- fakes ----------------------------------------------------------------------------------------
bin="$fake/bin"; mkdir -p "$bin"
devices_json="$fake/devices.json"
data="$fake/CoreSimulator/Devices"
dev() {  # dev <udid> <state> <name> [available, default 1]: a device and some data
  mkdir -p "$data/$1"; head -c 200000 /dev/zero >"$data/$1/data"
  echo "$1|$2|$3|${4:-1}" >>"$fake/devices.txt"
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
dev old-phone Shutdown "iPhone 15" 0                         # unavailable, not ours: goes
dev old-base Shutdown "quickR iOS-18-0" 0                    # unavailable, but quickR's: stays
# Another checkout's clone: no record, no worktree of this repo, but its directory exists here.
mkdir -p "$fake/elsewhere-dir"
dev c-other Shutdown "quickR iOS-26-0 elsewhere-dir-abcdef"
# A recorded owner that is gone, and one that is no worktree of this repo.
dev c-rec-gone Shutdown "quickR iOS27 vanished-123456"
dev c-rec-foreign Shutdown "quickR iOS27 foreign-654321"
mkdir -p "$fake/owners" "$fake/foreign"
echo "$fake/vanished" >"$fake/owners/c-rec-gone"
echo "$fake/foreign" >"$fake/owners/c-rec-foreign"
# A finished worktree's clone that sim-clone.sh looked up a moment ago (a run is about to use it).
looked="$(mk looked wp/looked)"; build "$looked"; old "$looked"
dev c-looked Shutdown "quickR iOS-26-0 looked-$(hash "$looked")"
echo "$looked" >"$fake/owners/c-looked"
# An unavailable non-quickR device a run holds, and one whose deletion fails.
dev old-held Shutdown "iPhone 14" 0
dev old-stuck Shutdown "iPhone 13" 0
mkdir -p "$fake/holds/old-held"; ps -o lstart= -p $$ | tr -s ' ' >"$fake/holds/old-held/$$"
# Records made long ago, except the fresh lookup.
for f in c-rec-gone c-rec-foreign; do touch -t "$(date -v-1d +%Y%m%d%H%M)" "$fake/owners/$f"; done
python3 - "$fake/devices.txt" "$devices_json" <<'PY'
import json, sys
devs = []
for l in open(sys.argv[1]):
    udid, state, name, avail = l.rstrip("\n").split("|")
    devs.append({"udid": udid, "state": state, "name": name, "isAvailable": avail == "1"})
json.dump({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-0": devs}}, open(sys.argv[2], "w"))
PY
cat >"$bin/xcrun" <<'SH'
#!/usr/bin/env bash
case "$*" in
"simctl list -j devices") exec cat "$FAKE_DEVICES" ;;
"simctl delete unavailable") echo BULK >>"$FAKE_DELETED" ;;
"simctl delete "*) [ "$3" = "${FAKE_DELETE_FAIL:-}" ] && exit 1; echo "$3" >>"$FAKE_DELETED" ;;
*) exit 1 ;;
esac
SH
# lsof: the in-use worktree is some process's working directory; from the second call on (after
# prune classified the worktrees), so is the late one.
cat >"$bin/lsof" <<SH
#!/bin/sh
n=\$(cat "$fake/lsof.calls" 2>/dev/null || echo 0); echo \$((n + 1)) >"$fake/lsof.calls"
echo p123; echo n$inuse/ios
[ "\$n" -ge 1 ] && { echo p456; echo n$late; }
exit 0
SH
printf '#!/bin/sh\n[ "$1" = -version ] && echo "Xcode 27.1"\n' >"$bin/xcodebuild"
printf '#!/bin/sh\necho %s\n' "$squash_oid" >"$bin/gh"
chmod +x "$bin"/*
export PATH="$bin:$PATH" FAKE_DEVICES="$devices_json" FAKE_DELETED="$fake/deleted"
export IOS_PRUNE_REPO="$current" IOS_SIM_DATA_DIR="$fake/CoreSimulator"
export QUICKR_SIM_CAP_LOCK="$fake/cap.lockf" QUICKR_SIM_HOLDS="$fake/holds" QUICKR_SIM_OWNERS="$fake/owners"
export QUICKR_SIM_CLONE_LOCK="$fake/clone.lockf"
unset IOS_PRUNE_DRY_RUN IOS_PRUNE_BASE IOS_PRUNE_IDLE_HOURS IOS_PRUNE_MERGED_PRS
# The held clone: a live hold (this test's own shell, with its start time).
mkdir -p "$fake/holds/c-held"; ps -o lstart= -p $$ | tr -s ' ' >"$fake/holds/c-held/$$"

prune() { rm -f "$fake/lsof.calls"; out="$(perl -e 'alarm shift; exec @ARGV' 120 "$here/../prune.sh" "$@" 2>&1)"; status=$?; }
deleted() { grep -qx "$1" "$fake/deleted" 2>/dev/null; }

# --- a dry run removes nothing ---------------------------------------------------------------------
prune --dry-run
(( status == 0 )) && ok "a dry run succeeds" || fail "dry run: status $status: $out"
kept_all=1
for w in "$finished" "$unmerged" "$recent" "$dirty" "$inuse" "$held" "$squashed" "$current" "$late" "$looked"; do
  [[ -d "$w/ios/build" && -d "$w/ios/QuickrKit/.build" ]] || kept_all=0
done
[[ ! -e "$fake/deleted" ]] && (( kept_all )) && ok "and removes nothing (no simulator, no build tree)" \
  || fail "the dry run removed: $(cat "$fake/deleted" 2>/dev/null)"
[[ "$out" == *"would remove simulator quickR iOS-26-0 finished-"* && "$out" == *"in all (dry run"* ]] \
  && ok "it says what it would remove, and how much" || fail "dry-run output: $out"

# --- the real run -------------------------------------------------------------------------------
# The finished worktree's build tree has a file rm can't remove: reported, not counted.
blocked="$squashed/ios/QuickrKit/.build/locked"; touch -t "$(date -v-1d +%Y%m%d%H%M)" "$blocked"; chflags uchg "$blocked"
touch -t "$(date -v-1d +%Y%m%d%H%M)" "$(dirname "$blocked")"  # adding it changed the directory
trap 'chflags nouchg "$blocked" 2>/dev/null; chmod 755 "$perm/ios/build/noread" 2>/dev/null; rm -rf "$fake"' EXIT
FAKE_DELETE_FAIL=old-stuck prune
(( status == 0 )) && ok "a run succeeds" || fail "run: status $status: $out"
for d in c-fin c-fin27 c-squash c-rec-gone old-phone; do
  deleted "$d" && ok "deletes $d" || fail "kept $d: $out"
done
for d in c-unm c-rec c-dirty c-inuse c-held c-gone c-gone-booted c-cur base phone old-base c-other c-rec-foreign \
  c-looked old-held old-stuck BULK; do
  deleted "$d" && fail "deleted $d" || ok "keeps $d"
done
[[ ! -d "$finished/ios/build" && ! -d "$finished/ios/QuickrKit/.build" ]] && ok "removes a finished worktree's build output" \
  || fail "finished build output kept"
[[ ! -d "$squashed/ios/build" ]] && ok "and a squash-merged PR worktree's" || fail "squashed build output kept"
for w in "$unmerged" "$recent" "$dirty" "$inuse" "$held" "$current" "$late" "$perm"; do
  [[ -d "$w/ios/build" ]] || fail "removed $(basename "$w")'s build output"
done
ok "keeps the build output of unmerged, recent, dirty, in-use, held and current worktrees"
[[ "$out" == *"keeping $late: in use now"* ]] && ok "and of one that came into use after it was classified" \
  || fail "late worktree: $out"
[[ "$out" == *"keeping quickR iOS-26-0 gone-$gone_hash: its owner is unknown"* ]] \
  && ok "an unrecorded clone matching no worktree is kept, and said so" || fail "unknown owner: $out"
[[ "$out" == *"could not delete iPhone 13"* && "$out" != *"removed unavailable simulator iPhone 13"* ]] \
  && ok "a failed simulator deletion is reported, not counted" || fail "failed deletion: $out"
[[ "$out" == *"could not remove all of $squashed/ios/QuickrKit/.build"* && "$out" != *"removed $squashed/ios/QuickrKit/.build"* ]] \
  && ok "a build tree rm can't remove is reported, not counted" || fail "failed rm: $out"
total="$(sed -nE 's/^prune: removed ([0-9.]+ [MG]B) in all$/\1/p' <<<"$out")"
[[ -n "$total" && "$total" != "0 MB" ]] && ok "it prints what it freed ($total)" || fail "no total: $out"

# Without gh (or with IOS_PRUNE_MERGED_PRS=0), a squash-merged branch isn't finished.
rm -f "$fake/deleted"
build "$squashed"; old "$squashed"
IOS_PRUNE_MERGED_PRS=0 prune --dry-run
[[ "$out" != *"squashed"* ]] && ok "IOS_PRUNE_MERGED_PRS=0 leaves a squash-merged worktree alone" || fail "$out"

(( fails == 0 )) && echo "prune-test: all passed" || { echo "prune-test: $fails failed"; exit 1; }
