#!/usr/bin/env bash
# Tear down the Docker sandbox container started by up.sh.
#
# Env vars:
#   NAME    Container name (default sigalswap-sandbox).

set -euo pipefail

NAME=${NAME:-sigalswap-sandbox}

if docker inspect "$NAME" >/dev/null 2>&1; then
  docker rm -f "$NAME" >/dev/null
  echo "Removed $NAME."
else
  echo "$NAME not running."
fi
