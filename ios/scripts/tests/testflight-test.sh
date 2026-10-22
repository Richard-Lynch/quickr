#!/usr/bin/env bash
# Tests for testflight.sh against a fake `xcodebuild`, in a throwaway copy of the repo layout
# (its own git repo, ios/scripts, project.yml and an empty quickR.xcodeproj): credentials from
# the environment and the env file, their validation, the key file's place, redaction, the
# build number, the dry run and the commands a real run gives xcodebuild. No Xcode needed.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/quickr-tf.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

repo="$tmp/repo"
mkdir -p "$repo/ios/quickR.xcodeproj" "$tmp/bin" "$tmp/keys"
cp -R "$here/.." "$repo/ios/scripts"
printf 'settings:\n  base:\n    MARKETING_VERSION: "1.2.3"\n' >"$repo/ios/project.yml"
printf 'ios/testflight.env\n' >"$repo/.gitignore"
git -C "$repo" init -q
git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@t commit -qm init

# The fake xcodebuild: logs its arguments, prints them (as xcodebuild's own log could), then
# looks for an ID in the watchdog's files under TMPDIR (FAKE_LEAKS), and for `archive` builds
# an archive whose bundles carry CURRENT_PROJECT_VERSION (FAKE_STALE_APPEX=1: the widget
# keeps 1). The app is portrait only with UIRequiresFullScreen, like quickR (FAKE_FULLSCREEN=0
# drops it; FAKE_ORIENTATIONS=all supports all four). An export logs the rsync it would use
# (RSYNC <path> -> <target>), as Xcode's IPA packaging would pick it.
cat >"$tmp/bin/xcodebuild" <<'SH'
#!/usr/bin/env bash
[[ "$1" == -version ]] && { echo "Xcode 27.0"; exit 0; }
printf '%s\n' "$*" >>"$FAKE_LOG"
if [[ " $* " == *" -exportArchive "* ]]; then
  r="$(command -v rsync)"
  echo "RSYNC $r -> $(readlink "$r" || echo "$r")" >>"$FAKE_LOG"
fi
echo "fake xcodebuild $*"
sleep 0.5  # the watchdog copies the output to its log
grep -rlE "$FAKE_IDS" "$TMPDIR" >>"$FAKE_LEAKS" 2>/dev/null
archive="" version=""
for arg in "$@"; do
  case "$prev" in -archivePath) archive="$arg" ;; esac
  case "$arg" in CURRENT_PROJECT_VERSION=*) version="${arg#*=}" ;; esac
  prev="$arg"
done
if [[ " $* " == *" archive "* ]]; then
  [[ -n "${FAKE_REMOVE:-}" ]] && rm -f "$FAKE_REMOVE"  # the env file goes during the archive
  app="$archive/Products/Applications/QuickR.app"
  mkdir -p "$app/PlugIns/QuickRWidgets.appex" "$app/Frameworks/X.framework"
  plist() { plutil -create xml1 "$1" && plutil -insert CFBundleVersion -string "$2" "$1"; }
  plist "$app/Info.plist" "$version"
  plutil -insert UISupportedInterfaceOrientations -array "$app/Info.plist"
  orientations=(Portrait)
  [[ "${FAKE_ORIENTATIONS:-}" == all ]] && orientations=(Portrait PortraitUpsideDown LandscapeLeft LandscapeRight)
  for o in "${orientations[@]}"; do
    plutil -insert UISupportedInterfaceOrientations -string "UIInterfaceOrientation$o" -append "$app/Info.plist"
  done
  [[ "${FAKE_FULLSCREEN:-1}" == 1 ]] && plutil -insert UIRequiresFullScreen -bool true "$app/Info.plist"
  plist "$app/PlugIns/QuickRWidgets.appex/Info.plist" "$([[ "${FAKE_STALE_APPEX:-0}" == 1 ]] && echo 1 || echo "$version")"
  plist "$app/Frameworks/X.framework/Info.plist" 9
fi
SH
chmod +x "$tmp/bin/xcodebuild"

# Homebrew's rsync 3.x, earlier in PATH than /usr/bin: Xcode's packaging fails with it.
cat >"$tmp/bin/rsync" <<'SH'
#!/usr/bin/env bash
echo "rsync: syntax or usage error (code 1)" >&2
exit 1
SH
chmod +x "$tmp/bin/rsync"

team=TEAM123456 key=KEYID12345 issuer=69a6de7a-1111-2222-3333-444455556666
mkdir -p "$tmp/wd"
printf -- '-----BEGIN PRIVATE KEY-----\nMIGT\n-----END PRIVATE KEY-----\n' >"$tmp/keys/AuthKey.p8"

failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
ok() { echo "ok: $*"; }

# run <args...>: testflight.sh in the copy, with a clean environment (only what the test sets
# with `env`) and the watchdog on, output in $tmp/out, the fake's log in $tmp/log; sets $status.
run() {
  : >"$tmp/log"
  env -i HOME="$tmp/home" PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin" TMPDIR="$tmp/wd" FAKE_LOG="$tmp/log" \
    FAKE_LEAKS="$tmp/leaks" FAKE_IDS="$team|$key|$issuer" "$@" >"$tmp/out" 2>&1
  status=$?
}
tf="$repo/ios/scripts/testflight.sh"
creds=("DEVELOPMENT_TEAM=$team" "ASC_KEY_ID=$key" "ASC_ISSUER_ID=$issuer" "ASC_KEY_PATH=$tmp/keys/AuthKey.p8")
leaks() { grep -qE "$team|$key|$issuer" "$tmp/out"; }

# 1. A real run without credentials stops before building, naming each missing one.
run "$tf"
if (( status != 0 )) && [[ "$(grep -c "is not set" "$tmp/out")" == 4 ]] && grep -q "ios-testflight-dry-run" "$tmp/out" \
  && [[ ! -s "$tmp/log" ]]; then
  ok "no credentials: refused before any build, all four named"
else
  fail "no credentials (status $status): $(cat "$tmp/out")"
fi

# 2. The dry run needs none: an unsigned archive, nothing exported, the steps printed.
run TESTFLIGHT_BUILD_NUMBER=2 "$tf" --dry-run
if (( status == 0 )) && grep -q " archive$" "$tmp/log" && grep -q "CODE_SIGNING_ALLOWED=NO" "$tmp/log" \
  && ! grep -q -- "-exportArchive\|-authenticationKey\|-allowProvisioningUpdates" "$tmp/log" \
  && grep -q "dry run done" "$tmp/out" && grep -q "a real run would stop here" "$tmp/out"; then
  ok "dry run: unsigned archive, no export, steps printed"
else
  fail "dry run (status $status): $(cat "$tmp/out") // $(cat "$tmp/log")"
fi

# 3. A real run with credentials: archive and export get the key; the output never shows it.
run "${creds[@]}" TESTFLIGHT_BUILD_NUMBER=42 "$tf"
archive_line="$(grep " archive$" "$tmp/log")"
export_line="$(grep -- "-exportArchive" "$tmp/log")"
if (( status == 0 )) && [[ "$archive_line" == *"-authenticationKeyID $key"* && "$archive_line" == *"DEVELOPMENT_TEAM=$team"* \
  && "$archive_line" == *"CURRENT_PROJECT_VERSION=42"* && "$archive_line" != *CODE_SIGNING_ALLOWED* \
  && "$export_line" == *"-authenticationKeyIssuerID $issuer"* && "$export_line" == *"ExportOptions.plist"* ]]; then
  ok "upload: archive and export get the key, the team and the build number"
else
  fail "upload (status $status): $(cat "$tmp/out") // $(cat "$tmp/log")"
fi
if leaks; then fail "the output shows an ID: $(grep -E "$team|$key|$issuer" "$tmp/out")"; else ok "no ID in the output"; fi
grep -q "ASC_KEY_ID = \*\*\*\*\*\*\*\*45" "$tmp/out" && ok "IDs print redacted" || fail "no redacted key ID: $(cat "$tmp/out")"
options="$repo/ios/build/testflight/1.2.3-42/ExportOptions.plist"
if [[ "$(plutil -extract method raw "$options")" == app-store-connect && "$(plutil -extract destination raw "$options")" == upload \
  && "$(plutil -extract teamID raw "$options")" == "$team" && "$(plutil -extract manageAppVersionAndBuildNumber raw "$options")" == false ]]; then
  ok "export options: app-store-connect, upload, the team, our build number"
else
  fail "export options: $(cat "$options")"
fi

# The dry run with credentials prints them redacted too.
run "${creds[@]}" TESTFLIGHT_BUILD_NUMBER=43 "$tf" --dry-run
if (( status == 0 )) && ! leaks && grep -q -- "-authenticationKeyID \*\*\*\*\*\*\*\*45" "$tmp/out"; then
  ok "dry run with credentials: redacted"
else
  fail "dry run with credentials (status $status): $(cat "$tmp/out")"
fi

# Shell tracing shows no ID either.
run "${creds[@]}" TESTFLIGHT_BUILD_NUMBER=44 bash -x "$tf"
if (( status == 0 )) && ! leaks; then ok "bash -x shows no ID"; else fail "bash -x (status $status): $(grep -E "$team|$key|$issuer" "$tmp/out")"; fi

# 4. The env file: read (quotes dropped, ~/ expanded), never run; the environment wins.
mkdir -p "$tmp/home/keys" && cp "$tmp/keys/AuthKey.p8" "$tmp/home/keys/"
cat >"$repo/ios/testflight.env" <<EOF
# a comment
DEVELOPMENT_TEAM="$team"
export ASC_KEY_ID='$key'
ASC_ISSUER_ID = $issuer
ASC_KEY_PATH=~/keys/AuthKey.p8
OTHER=\$(touch $tmp/ran)
EOF
run TESTFLIGHT_BUILD_NUMBER=7 "$tf"
(( status == 0 )) && grep -q -- "-authenticationKeyPath $tmp/home/keys/AuthKey.p8" "$tmp/log" \
  && ok "env file: values read, quotes dropped, ~/ expanded" || fail "env file (status $status): $(cat "$tmp/out")"
[[ -e "$tmp/ran" ]] && fail "the env file ran code" || ok "the env file is never run"
run ASC_KEY_ID=OTHERKEY99 TESTFLIGHT_BUILD_NUMBER=71 "$tf"
grep -q -- "-authenticationKeyID OTHERKEY99" "$tmp/log" && ok "the environment wins over the file" \
  || fail "environment over file: $(cat "$tmp/log")"
# The env file going away during the archive changes nothing: the export still gets, and
# filters, the IDs read at the start.
run FAKE_REMOVE="$repo/ios/testflight.env" TESTFLIGHT_BUILD_NUMBER=72 "$tf"
if (( status == 0 )) && ! leaks && grep -- "-exportArchive" "$tmp/log" | grep -q -- "-authenticationKeyID $key"; then
  ok "the file changing mid-run changes nothing"
else
  fail "env file removed mid-run (status $status): $(grep -E "$team|$key|$issuer" "$tmp/out")"
fi

# 5. Malformed values are named.
run DEVELOPMENT_TEAM=abc ASC_KEY_ID=short ASC_ISSUER_ID=nope ASC_KEY_PATH="$tmp/missing.p8" "$tf"
if (( status != 0 )) && grep -q "DEVELOPMENT_TEAM is not a 10-character" "$tmp/out" && grep -q "ASC_KEY_ID is not" "$tmp/out" \
  && grep -q "ASC_ISSUER_ID is not" "$tmp/out" && grep -q "no readable file" "$tmp/out" && [[ ! -s "$tmp/log" ]]; then
  ok "malformed credentials: each named, no build"
else
  fail "malformed (status $status): $(cat "$tmp/out")"
fi

# 6. The key's place: tracked, or inside the repo and not ignored, is refused; ignored is fine.
cp "$tmp/keys/AuthKey.p8" "$repo/ios/AuthKey.p8"
run "${creds[@]/#ASC_KEY_PATH=*/ASC_KEY_PATH=$repo/ios/AuthKey.p8}" "$tf"
(( status != 0 )) && grep -q "inside the repo and not gitignored" "$tmp/out" && ok "an unignored key in the repo is refused" \
  || fail "unignored key (status $status): $(cat "$tmp/out")"
git -C "$repo" add -f ios/AuthKey.p8
run "${creds[@]/#ASC_KEY_PATH=*/ASC_KEY_PATH=$repo/ios/AuthKey.p8}" "$tf"
(( status != 0 )) && grep -q "tracked by git" "$tmp/out" && ok "a tracked key is refused" \
  || fail "tracked key (status $status): $(cat "$tmp/out")"
git -C "$repo" rm -q --cached ios/AuthKey.p8
printf '*.p8\n' >>"$repo/.gitignore"
run "${creds[@]/#ASC_KEY_PATH=*/ASC_KEY_PATH=$repo/ios/AuthKey.p8}" TESTFLIGHT_BUILD_NUMBER=8 "$tf"
(( status == 0 )) && ok "an ignored key in the repo is accepted" || fail "ignored key (status $status): $(cat "$tmp/out")"

# 7. The build number: the default is the UTC time, a malformed one is refused, and every
# bundle must carry it.
run "$tf" --dry-run
grep -qE "CURRENT_PROJECT_VERSION=20[0-9]{6}\.[0-9]{6}( |$)" "$tmp/log" && ok "default build number: YYYYMMDD.HHMMSS" \
  || fail "default build number: $(cat "$tmp/log")"
run TESTFLIGHT_BUILD_NUMBER=1.2.3.4 "$tf" --dry-run
(( status != 0 )) && grep -q "one to three period-separated integers" "$tmp/out" && ok "a malformed build number is refused" \
  || fail "malformed build number (status $status): $(cat "$tmp/out")"
run TESTFLIGHT_BUILD_NUMBER=1234567890.12345678 "$tf" --dry-run
(( status != 0 )) && grep -q "longer than 18 characters" "$tmp/out" && ok "a build number over 18 characters is refused" \
  || fail "long build number (status $status): $(cat "$tmp/out")"
run TESTFLIGHT_BUILD_NUMBER=42 "$tf" --dry-run
(( status != 0 )) && grep -q "already archived here" "$tmp/out" && [[ ! -s "$tmp/log" ]] \
  && ok "a build number already archived is refused" || fail "reused build number (status $status): $(cat "$tmp/out")"
run FAKE_STALE_APPEX=1 TESTFLIGHT_BUILD_NUMBER=9 "$tf" --dry-run
(( status != 0 )) && grep -q "QuickRWidgets.appex/Info.plist has CFBundleVersion '1', not 9" "$tmp/out" \
  && ok "a bundle without the build number fails the archive check" || fail "stale appex (status $status): $(cat "$tmp/out")"

# The real app declares export compliance (no non-exempt encryption), so App Store Connect
# doesn't hold every build for the question.
if awk '/^  QuickR:/{app=1} /^  [A-Za-z]+:$/ && !/QuickR:/{app=0} app' "$here/../../project.yml" \
  | grep -q "ITSAppUsesNonExemptEncryption: false"; then
  ok "the app declares ITSAppUsesNonExemptEncryption false"
else
  fail "the QuickR target's info has no ITSAppUsesNonExemptEncryption: false"
fi

# The export packages with the system rsync, even with an incompatible one earlier in PATH,
# through build/testflight/.bin (a name no build number's directory can have).
run "${creds[@]}" TESTFLIGHT_BUILD_NUMBER=60 "$tf"
if (( status == 0 )) && grep -q "^RSYNC .*/build/testflight/.bin/rsync -> /usr/bin/rsync$" "$tmp/log"; then
  ok "the export uses /usr/bin/rsync, not the incompatible one earlier in PATH"
else
  fail "rsync for the export (status $status): $(grep RSYNC "$tmp/log")"
fi
[[ -L "$repo/ios/build/testflight/.bin/rsync" && ! -e "$repo/ios/build/testflight/.bin/QuickR.xcarchive" ]] \
  && ok "the rsync link dir stays apart from the build directories" || fail "the .bin dir: $(ls -la "$repo/ios/build/testflight")"

# Portrait only needs UIRequiresFullScreen, or App Store validation refuses the upload: the
# archive check stops a dry run already.
run FAKE_FULLSCREEN=0 TESTFLIGHT_BUILD_NUMBER=61 "$tf" --dry-run
(( status != 0 )) && grep -q "UIRequiresFullScreen" "$tmp/out" && ok "portrait only without UIRequiresFullScreen is refused" \
  || fail "missing UIRequiresFullScreen (status $status): $(cat "$tmp/out")"
run FAKE_FULLSCREEN=0 FAKE_ORIENTATIONS=all TESTFLIGHT_BUILD_NUMBER=62 "$tf" --dry-run
(( status == 0 )) && ok "all four orientations need no UIRequiresFullScreen" || fail "all orientations (status $status): $(cat "$tmp/out")"
# And the real app declares it: its only orientation is portrait.
app_info="$(awk '/^  QuickR:/{app=1} /^  [A-Za-z]+:$/ && !/QuickR:/{app=0} app' "$here/../../project.yml")"
if grep -q "UIRequiresFullScreen: true" <<<"$app_info" \
  && [[ "$(grep -c "UIInterfaceOrientation" <<<"$app_info")" == 1 ]] && grep -q "UIInterfaceOrientationPortrait$" <<<"$app_info"; then
  ok "the app is portrait only and declares UIRequiresFullScreen"
else
  fail "the QuickR target's orientations and UIRequiresFullScreen: $(grep -E "Orientation|FullScreen" <<<"$app_info")"
fi

# No unfiltered ID ever reached the watchdog's files.
if [[ -s "$tmp/leaks" ]]; then fail "IDs in the watchdog's files: $(sort -u "$tmp/leaks")"; else ok "the watchdog's files never held an ID"; fi

if (( failures )); then
  echo "testflight-test: $failures failed"
  exit 1
fi
echo "testflight-test: all passed"
