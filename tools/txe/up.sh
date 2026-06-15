#!/usr/bin/env bash
# Bring up N parallel TXE workers in Docker containers.
#
# Each worker exposes TXE on localhost:$BASE_PORT + worker_index.
# Container names are txe-worker-0, txe-worker-1, ... so down.sh can
# reliably tear them all down.
#
# The project root is bind-mounted into each container at the SAME path
# the host uses. This is required because nargo sends absolute host paths
# to TXE (for compiled artifact lookups); without the mount, TXE in the
# container ENOENTs and crashes.
#
# Env vars:
#   WORKERS        Number of containers to spawn (default 4).
#   BASE_PORT      Host port for worker 0 (default 8181). Worker N uses BASE_PORT+N.
#   TXE_IMAGE      Aztec image (default aztecprotocol/aztec:4.3.0).
#   READY_TIMEOUT  Seconds to wait per worker (default 60).
#   PROJECT_ROOT   Host directory to bind-mount into containers (default: git
#                  toplevel of CWD, or CWD itself if not a git repo).

set -euo pipefail

WORKERS=${WORKERS:-4}
BASE_PORT=${BASE_PORT:-8181}
TXE_IMAGE=${TXE_IMAGE:-aztecprotocol/aztec:4.3.0}
READY_TIMEOUT=${READY_TIMEOUT:-60}
PROJECT_ROOT=${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not found in PATH" >&2
  exit 1
fi

if ! docker image inspect "$TXE_IMAGE" >/dev/null 2>&1; then
  echo "Pulling $TXE_IMAGE..."
  docker pull "$TXE_IMAGE"
fi

for i in $(seq 0 $((WORKERS - 1))); do
  PORT=$((BASE_PORT + i))
  CONTAINER_NAME="txe-worker-$i"

  # Defensive: kill any preexisting container with the same name so re-runs
  # don't fail. -f handles both running and stopped state.
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

  docker run --rm -d \
    --name "$CONTAINER_NAME" \
    -p "${PORT}:${PORT}" \
    -v "${PROJECT_ROOT}:${PROJECT_ROOT}" \
    "$TXE_IMAGE" start --txe --port "$PORT" >/dev/null

  echo "Started $CONTAINER_NAME on port $PORT"
done

echo "Waiting for all TXE workers to be ready (timeout ${READY_TIMEOUT}s each)..."
for i in $(seq 0 $((WORKERS - 1))); do
  PORT=$((BASE_PORT + i))
  ready=false
  for attempt in $(seq 1 "$READY_TIMEOUT"); do
    if nc -z localhost "$PORT" 2>/dev/null; then
      ready=true
      break
    fi
    sleep 1
  done

  if [ "$ready" = false ]; then
    echo "ERROR: Worker $i on port $PORT failed to come up within ${READY_TIMEOUT}s" >&2
    echo "Container logs:" >&2
    docker logs "txe-worker-$i" 2>&1 | tail -20 >&2 || true
    exit 1
  fi
done

echo "All $WORKERS TXE workers ready on ports ${BASE_PORT}..$((BASE_PORT + WORKERS - 1))"
