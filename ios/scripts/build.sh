#!/usr/bin/env bash
# Debug build for a simulator. Usage: build.sh <simulator name or UDID> [extra xcodebuild args...]
source "$(dirname "$0")/common.sh"
require_xcode
udid="$(sim_udid "$1")"; shift
xcb -destination "id=$udid" "$@" build
