#!/usr/bin/env bash
# make ios-prune: frees disk from finished work. Removes
# - shut-down quickR simulator clones (sim-clone.sh's "<source> <dir>-<hash6>") whose worktree is
#   gone, or whose worktree is finished: its branch (or detached HEAD) merged into
#   IOS_PRUNE_BASE (default origin/ios/m3) or into a merged pull request, no live process working in it, and idle (nothing
#   changed in it for IOS_PRUNE_IDLE_HOURS, default 3);
# - simulators Xcode marks unavailable (`simctl delete unavailable`);
# - ios/build and ios/QuickrKit/.build of finished worktrees.
# Never touches a booted simulator, one a run holds (common.sh sim_hold), a base device, this
# worktree, or a worktree something is running in. Simulators are checked and deleted under the
# simulator cap's lock, so nothing boots one while it goes. Prints what it frees.
# Usage: prune.sh [--dry-run]   (or IOS_PRUNE_DRY_RUN=1: only says what it would remove)
source "$(dirname "$0")/common.sh"
require_xcodebuild
set +e

dry="${IOS_PRUNE_DRY_RUN:-0}"
[[ "${1:-}" == --dry-run ]] && dry=1
repo="${IOS_PRUNE_REPO:-$ROOT_DIR}"
base="${IOS_PRUNE_BASE:-origin/ios/m3}"
data="${IOS_SIM_DATA_DIR:-$HOME/Library/Developer/CoreSimulator}/Devices"
current="$(cd "$repo" && pwd -P)"
git -C "$repo" rev-parse --verify -q "$base^{commit}" >/dev/null || die "prune: no $base here (git fetch first)"
# Finished work: anything reachable from the base, or from the head of a merged pull request
# (milestone PRs are squash-merged, so their branches are no ancestors of the base). The PR heads
# come from `gh` (IOS_PRUNE_MERGED_PRS=0, or no gh or network: the base alone).
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
verb="removed"; (( dry )) && verb="would remove"
freed_kb=0

kb() { du -sk "$1" 2>/dev/null | awk '{ print $1 }'; }
human() { awk -v k="$1" 'BEGIN { if (k >= 1048576) printf "%.1f GB", k / 1048576; else printf "%.0f MB", k / 1024 }'; }
note() { echo "prune: $verb $1 ($(human "${2:-0}"))"; freed_kb=$((freed_kb + ${2:-0})); }

# Directories something is running in: every process's working directory, and every path in a
# process's arguments (an xcodebuild or swift started from elsewhere names its worktree).
in_use="$( { lsof -nP -a -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'; ps -axo command= 2>/dev/null; } )"
busy() {
  awk -v p="$1" '{
    i = index($0, p)
    while (i > 0) {
      after = substr($0, i + length(p), 1)
      if (after == "" || after == "/" || after == " " || after == "\"" || after == "\047") { found = 1; exit }
      rest = substr($0, i + 1); j = index(rest, p); i = (j > 0) ? i + j : 0
    }
  } END { exit !found }' <<<"$in_use"
}

# A worktree is idle when nothing changed in it for IOS_PRUNE_IDLE_HOURS (default 3): no
# uncommitted change, and neither its HEAD and reflog (commits, checkouts, merges, resets) nor
# its build output (builds, test runs) touched in that time. A branch just created from the base
# counts as merged too; this keeps one someone is starting on.
idle_min=$(( ${IOS_PRUNE_IDLE_HOURS:-3} * 60 ))
idle() {
  local gitdir
  # (No optional locks: a status that rewrites the index would make it look busy next time.)
  [[ -z "$(GIT_OPTIONAL_LOCKS=0 git -C "$1" status --porcelain 2>/dev/null | head -1)" ]] || return 1
  gitdir="$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  [[ -z "$(find "$gitdir/HEAD" "$gitdir/logs/HEAD" -mmin "-$idle_min" 2>/dev/null | head -1)" ]] || return 1
  [[ -z "$(find "$1/ios/build" -maxdepth 3 -mmin "-$idle_min" 2>/dev/null | head -1)" ]]
}

# The simulators, as "<udid> <state> <name>" (a state's spaces as underscores).
devices="$(xcrun simctl list -j devices | python3 -c '
import json, sys
for devices in json.load(sys.stdin)["devices"].values():
    for d in devices:
        print(d["udid"], d["state"].replace(" ", "_"), d["name"])')"
# Worktrees with a clone running or held by a run are in use, whatever else they look like.
clone_hash() { [[ "$1" =~ ^quickR\ .+\ [^\ ]+-([0-9a-f]{6})$ ]] && echo "${BASH_REMATCH[1]}"; }
in_use_hashes=""
while read -r udid state name; do
  [[ -n "$udid" ]] || continue
  h="$(clone_hash "$name")" || continue
  if [[ "$state" != Shutdown || -n "$(_sim_live_holds "$SIM_HOLDS/$udid" 2>/dev/null)" ]]; then in_use_hashes+=" $h"; fi
done <<<"$devices"

# The worktrees: "<hash6> <state> <path>", state "finished", "active" or "current".
worktrees=""
while read -r key value; do
  case "$key" in
    worktree) path="$value"; head=""; ;;
    HEAD) head="$value" ;;
    "")
      [[ -n "${path:-}" && -d "$path" ]] || { path=""; continue; }
      real="$(cd "$path" && pwd -P)"
      hash="$(printf '%s' "$real" | shasum | cut -c1-6)"
      if [[ "$real" == "$current" ]]; then state=current
      elif [[ -n "$head" && " $in_use_hashes " != *" $hash "* ]] && merged "$head" && ! busy "$real" \
        && idle "$real"; then state=finished
      else state=active; fi
      worktrees+="$hash $state $real"$'\n'
      path=""
      ;;
  esac
done < <(git -C "$repo" worktree list --porcelain; echo)

# Simulators, under the cap lock: a clone of a finished or vanished worktree, shut down, unheld.
_sim_hold_lock || die "prune: could not take the simulator lock $SIM_CAP_LOCK"
while read -r udid state name; do
  hash="$(clone_hash "$name")" || continue  # a base device: never
  owner="$(awk -v h="$hash" '$1 == h { print $2; exit }' <<<"$worktrees")"
  [[ -z "$owner" || "$owner" == finished ]] || continue
  if [[ "$state" != Shutdown ]]; then echo "prune: keeping $name: $state"; continue; fi
  if [[ -n "$(_sim_live_holds "$SIM_HOLDS/$udid" 2>/dev/null)" ]]; then echo "prune: keeping $name: held by a run"; continue; fi
  size="$(kb "$data/$udid")"
  if (( !dry )); then
    xcrun simctl delete "$udid" >/dev/null 2>&1 || { warn "could not delete $name ($udid)"; continue; }
    rm -rf "${SIM_HOLDS:?}/$udid"
  fi
  note "simulator $name (${owner:-its worktree is gone})" "${size:-0}"
done <<<"$devices"
unavailable="$(xcrun simctl list devices unavailable 2>/dev/null | grep -cE '\(unavailable')"
if (( unavailable > 0 )); then
  (( dry )) || xcrun simctl delete unavailable >/dev/null 2>&1 || warn "simctl delete unavailable failed"
  echo "prune: $verb $unavailable unavailable simulator(s)"
fi
exec 7>&-

# Build output of finished worktrees.
while read -r hash state path; do
  [[ "$state" == finished ]] || continue
  for dir in "$path/ios/build" "$path/ios/QuickrKit/.build"; do
    [[ -d "$dir" ]] || continue
    size="$(kb "$dir")"
    (( dry )) || rm -rf "$dir"
    note "$dir" "${size:-0}"
  done
done <<<"$worktrees"

echo "prune: $verb $(human "$freed_kb") in all$( (( dry )) && echo " (dry run: nothing removed)")"
