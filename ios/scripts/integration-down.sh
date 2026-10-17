#!/usr/bin/env bash
# Stop and remove this worktree's integration stacks (containers, network, data) and
# ios/build/integration.env. Safe to run when nothing is up.
source "$(dirname "$0")/integration-common.sh"
require_docker
it_placeholder_ports
it_compose --progress quiet down -v --remove-orphans --timeout 5
rm -f "$IT_ENV_FILE"
echo "integration: $IT_PROJECT down" >&2
