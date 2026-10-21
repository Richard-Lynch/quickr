#!/usr/bin/env bash
# make ios-prune: frees disk from finished work. Removes
# - shut-down quickR simulator clones (sim-clone.sh's "<source> <dir>-<hash6>") whose worktree
#   is gone, or finished: its HEAD merged into IOS_PRUNE_BASE (default origin/ios/m3) or into
#   the head of a merged pull request (milestone PRs are squash-merged), no process working in
#   it, no uncommitted change, and nothing in it (HEAD, reflog, build output) changed for
#   IOS_PRUNE_IDLE_HOURS (default 3);
# - finished worktrees' ios/build and ios/QuickrKit/.build;
# - unavailable simulators (no runtime) that aren't quickR's.
# Never touches a booted simulator, one a run holds (common.sh sim_hold), a base device, this
# worktree, or a worktree with a clone running or held. A clone's owner is the worktree
# sim-clone.sh recorded for it (and one looked up within the idle time is in use); a clone with
# no record (made before records) is judged by its name's hash against this repo's worktrees, and
# kept when that finds none. Anything it can't establish (a failed git, process or file query)
# means keep, or stop.
#
# Simulators are re-read, checked and deleted holding sim-clone.sh's lock and the cap lock (in
# that order, as sim-clone.sh takes them), so nothing creates, looks up or boots one meanwhile;
# simctl also refuses to delete a booted device. A finished worktree is checked again (in use,
# idle) just before its build output goes; a build starting in that instant can still lose it,
# and then fails (nothing but build output is ever removed).
# Usage: prune.sh [--dry-run]   (or IOS_PRUNE_DRY_RUN=1: only says what it would remove)
source "$(dirname "$0")/common.sh"
require_xcodebuild
set +e

dry="${IOS_PRUNE_DRY_RUN:-0}"
[[ "${1:-}" == --dry-run ]] && dry=1
repo="${IOS_PRUNE_REPO:-$ROOT_DIR}"
base="${IOS_PRUNE_BASE:-origin/ios/m3}"
data="${IOS_SIM_DATA_DIR:-$HOME/Library/Developer/CoreSimulator}/Devices"
current="$(cd "$repo" && pwd -P)" || die "prune: no repo at $repo"
git -C "$repo" rev-parse --verify -q "$base^{commit}" >/dev/null || die "prune: no $base here (git fetch first)"
idle_min=$(( ${IOS_PRUNE_IDLE_HOURS:-3} * 60 ))
verb="removed"; (( dry )) && verb="would remove"
freed_kb=0

kb() { du -sk "$1" 2>/dev/null | awk '{ print $1 }'; }
human() { awk -v k="$1" 'BEGIN { if (k >= 1048576) printf "%.1f GB", k / 1048576; else printf "%.0f MB", k / 1024 }'; }
note() { echo "prune: $verb $1 ($(human "${2:-0}"))"; freed_kb=$((freed_kb + ${2:-0})); }

# Finished work: reachable from the base, or from a merged pull request's head (from `gh`;
# IOS_PRUNE_MERGED_PRS=0, or no gh or network: the base alone).
finished_refs=("$base")
if [[ "${IOS_PRUNE_MERGED_PRS:-1}" == 1 ]] && command -v gh >/dev/null; then
  while read -r oid; do
    git -C "$repo" cat-file -e "$oid^{commit}" 2>/dev/null && finished_refs+=("$oid")
  done < <(cd "$repo" && perl -e 'alarm shift; exec @ARGV' 30 gh pr list --state merged --limit 200 \
    --json headRefOid -q '.[].headRefOid' 2>/dev/null)
fi
merged() {
  local ref
  for ref in "${finished_refs[@]}"; do
    git -C "$repo" merge-base --is-ancestor "$1" "$ref" 2>/dev/null && return 0
  done
  return 1
}

# What is running where: every process's working directory, and every process's full command
# line (an xcodebuild or swift started from elsewhere names its worktree). A query that fails
# stops the prune: without it nothing can be called unused.
in_use=""
read_processes() {
  local cwds args
  cwds="$(lsof -nP -a -d cwd -Fn 2>/dev/null)" || die "prune: lsof failed; not pruning"
  [[ -n "$cwds" ]] || die "prune: lsof listed no working directories; not pruning"
  args="$(ps -wwaxo command= 2>/dev/null)" || die "prune: ps failed; not pruning"
  in_use="$(sed -n 's/^n//p' <<<"$cwds")"$'\n'"$args"
}
busy() {  # busy <path>: <path> appears as a path (followed by /, a space, a quote or nothing)
  awk -v p="$1" '{
    i = index($0, p)
    while (i > 0) {
      after = substr($0, i + length(p), 1)
      if (after == "" || after == "/" || after == " " || after == "\"" || after == "\047") { found = 1; exit }
      rest = substr($0, i + 1); j = index(rest, p); i = (j > 0) ? i + j : 0
    }
  } END { exit !found }' <<<"$in_use"
}
# idle <path>: clean, and nothing changed in it for idle_min (any file of either build tree).
idle() {
  local gitdir status tree recent
  status="$(GIT_OPTIONAL_LOCKS=0 git -C "$1" status --porcelain 2>/dev/null)" || return 1
  [[ -z "$status" ]] || return 1
  gitdir="$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  # (A find that fails, say on a permission error, proves nothing: not idle.)
  recent="$(find "$gitdir/HEAD" "$gitdir/logs/HEAD" -mmin "-$idle_min" 2>/dev/null)" || return 1
  [[ -z "$recent" ]] || return 1
  for tree in "$1/ios/build" "$1/ios/QuickrKit/.build"; do
    [[ -d "$tree" ]] || continue
    recent="$(find "$tree" -mmin "-$idle_min" -print -quit 2>/dev/null)" || return 1
    [[ -z "$recent" ]] || return 1
  done
}

# The simulators now: "<udid> <state> <available> <name>" (spaces in a state as underscores).
read_devices() {
  xcrun simctl list -j devices | python3 -c '
import json, sys
for devices in json.load(sys.stdin)["devices"].values():
    for d in devices:
        print(d["udid"], d["state"].replace(" ", "_"), int(d.get("isAvailable", True)), d["name"])'
}
# A clone's "<hash6> <dir name>", from sim-clone.sh's "<source> <dir>-<hash6>"; nothing otherwise.
clone_hash() { [[ "$1" =~ ^quickR\ .+\ ([^\ ]+)-([0-9a-f]{6})$ ]] && echo "${BASH_REMATCH[2]} ${BASH_REMATCH[1]}"; }
held() { [[ -n "$(_sim_live_holds "$SIM_HOLDS/$1" 2>/dev/null)" ]]; }

# The worktrees, as "<hash6> <state> <path>", state finished, active or current. A worktree with
# a clone booted or held is active.
worktrees=""
read_worktrees() {
  local list key value path="" head="" real hash dir state devices active="" udid avail name
  devices="$(read_devices)" || die "prune: simctl list failed; not pruning"
  while read -r udid state avail name; do
    [[ -n "$udid" ]] || continue
    read -r hash dir <<<"$(clone_hash "$name")"
    [[ -n "$hash" ]] || continue
    if [[ "$state" != Shutdown ]] || held "$udid"; then active+=" $hash"; fi
  done <<<"$devices"
  list="$(git -C "$repo" worktree list --porcelain)" || die "prune: git worktree list failed; not pruning"
  worktrees=""
  while read -r key value; do
    case "$key" in
      worktree) path="$value"; head="" ;;
      HEAD) head="$value" ;;
      "")
        if [[ -n "$path" && -d "$path" ]]; then
          real="$(cd "$path" && pwd -P)"
          hash="$(printf '%s' "$real" | shasum | cut -c1-6)"
          if [[ "$real" == "$current" ]]; then state=current
          elif [[ -n "$head" && " $active " != *" $hash "* ]] && merged "$head" && ! busy "$real" && idle "$real"; then
            state=finished
          else state=active; fi
          worktrees+="$hash $state $real"$'\n'
        fi
        path=""
        ;;
    esac
  done <<<"$list"$'\n'
}
# A clone's owner state: finished, active, current, gone, or unknown (keep).
owner_state() {  # owner_state <udid> <hash6> <dir name>
  local recorded state
  recorded="$(cat "$SIM_OWNERS/$1" 2>/dev/null)"
  if [[ -n "$recorded" ]]; then
    # Looked up recently (sim-clone.sh rewrites the record each time): a run may be about to boot
    # or hold it.
    [[ -z "$(find "$SIM_OWNERS/$1" -mmin "-$idle_min" 2>/dev/null)" ]] || { echo active; return; }
    [[ -d "$recorded" ]] || { echo gone; return; }
    state="$(awk -v p="$recorded" '$3 == p { print $2; exit }' <<<"$worktrees")"
    echo "${state:-unknown}"  # a directory that is no worktree of this repo: not ours to judge
    return
  fi
  # No record (a clone made before records): its hash names this repo's worktree, or it's unknown.
  state="$(awk -v h="$2" '$1 == h { print $2; exit }' <<<"$worktrees")"
  echo "${state:-unknown}"
}

# --- simulators: under sim-clone.sh's lock, then the cap lock, with a fresh read ------------------
clone_lock="${QUICKR_SIM_CLONE_LOCK:-${TMPDIR:-/tmp}/quickr-sim-clone.lockf}"
exec 9>>"$clone_lock"
/usr/bin/lockf -t "${QUICKR_SIM_CLONE_LOCK_WAIT:-600}" 9 >/dev/null 2>&1 || die "prune: could not take $clone_lock"
_sim_hold_lock || die "prune: could not take the simulator lock $SIM_CAP_LOCK"
read_processes
read_worktrees
now="$(read_devices)" || die "prune: simctl list failed; not pruning"
while read -r udid state avail name; do
  [[ -n "$udid" ]] || continue
  if (( !avail )) && [[ "$name" != "quickR "* ]]; then
    # No runtime for it, so unbootable, and not quickR's: Xcode's leftovers. quickR's are judged below.
    if [[ "$state" != Shutdown ]] || held "$udid"; then echo "prune: keeping $name: $state or held"; continue; fi
    size="$(kb "$data/$udid")"
    if (( !dry )) && ! xcrun simctl delete "$udid" >/dev/null 2>&1; then warn "could not delete $name ($udid)"; continue; fi
    note "unavailable simulator $name" "${size:-0}"
    continue
  fi
  read -r hash dir <<<"$(clone_hash "$name")"
  [[ -n "$hash" ]] || continue  # a base device (or not quickR's): never
  owner="$(owner_state "$udid" "$hash" "$dir")"
  [[ "$owner" != unknown ]] || { echo "prune: keeping $name: its owner is unknown (no record; delete it by hand if it's stale)"; continue; }
  [[ "$owner" == finished || "$owner" == gone ]] || continue
  if [[ "$state" != Shutdown ]]; then echo "prune: keeping $name: $state"; continue; fi
  if held "$udid"; then echo "prune: keeping $name: held by a run"; continue; fi
  size="$(kb "$data/$udid")"
  if (( !dry )); then
    xcrun simctl delete "$udid" >/dev/null 2>&1 || { warn "could not delete $name ($udid)"; continue; }
    rm -rf "${SIM_HOLDS:?}/$udid" "${SIM_OWNERS:?}/$udid"
  fi
  note "simulator $name (its worktree is $owner)" "${size:-0}"
done <<<"$now"
exec 7>&- 9>&-

# --- build output of finished worktrees, each checked again just before it goes ---------------------
while read -r hash state path; do
  [[ "$state" == finished ]] || continue
  read_processes
  if busy "$path" || ! idle "$path"; then echo "prune: keeping $path: in use now"; continue; fi
  for dir in "$path/ios/build" "$path/ios/QuickrKit/.build"; do
    [[ -d "$dir" ]] || continue
    size="$(kb "$dir")"
    if (( !dry )); then
      rm -rf "$dir"
      [[ ! -e "$dir" ]] || { warn "could not remove all of $dir"; continue; }
    fi
    note "$dir" "${size:-0}"
  done
done <<<"$worktrees"

echo "prune: $verb $(human "$freed_kb") in all$( (( dry )) && echo " (dry run: nothing removed)")"
