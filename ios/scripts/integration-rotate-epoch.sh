#!/usr/bin/env bash
# Start a new change-feed epoch on integration server a (default) or b, like
# `make rotate-epoch-docker` does for the dev stack. Tests reach it as $QUICKR_IT_ROTATE_EPOCH.
# Usage: integration-rotate-epoch.sh [a|b]
source "$(dirname "$0")/integration-common.sh"
server="${1:-a}"
[[ "$server" == a || "$server" == b ]] || die "usage: $0 [a|b]"
it_load_env
it_compose exec -T "backend-$server" python scripts/rotate_epoch.py
