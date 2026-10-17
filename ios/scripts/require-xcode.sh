#!/usr/bin/env bash
# Fail fast, with a clear message, when Xcode or xcodegen is missing.
source "$(dirname "$0")/common.sh"
require_xcode
