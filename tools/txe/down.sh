#!/usr/bin/env bash
# Tear down all TXE workers spawned by up.sh.
#
# Matches containers named txe-worker-* and force-removes them.
# Force-remove (-f) handles both running and stopped state and is the
# whole point of going through Docker — native process kills don't
# reliably release TXE resources.

set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not found in PATH" >&2
  exit 1
fi

CONTAINERS=$(docker ps -aq --filter "name=^txe-worker-" 2>/dev/null || true)

if [ -z "$CONTAINERS" ]; then
  echo "No TXE workers running"
  exit 0
fi

# Word-splitting is intentional here — CONTAINERS is a list of IDs.
# shellcheck disable=SC2086
docker rm -f $CONTAINERS >/dev/null

COUNT=$(echo "$CONTAINERS" | wc -l | tr -d ' ')
echo "Stopped $COUNT TXE worker(s)"
