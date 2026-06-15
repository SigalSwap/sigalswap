#!/usr/bin/env bash
# Bring up an Aztec local-network sandbox in a Docker container for E2E tests.
#
# The SDK e2e suite (`npm run test:e2e`) connects to a node at
# http://localhost:8080. Running the sandbox in Docker (instead of natively)
# avoids the same resource-leakage issues that motivated the TXE Docker setup
# (see `tools/txe/README.md`). Container teardown via `down.sh` releases
# everything atomically; no orphaned
# child processes, no sockets stuck in TIME_WAIT, no port-leak on the host.
#
# Env vars:
#   PORT           Host port to bind the node API to (default 8080).
#   IMAGE          Aztec image (default aztecprotocol/aztec:4.3.0).
#   READY_TIMEOUT  Seconds to wait for the node to respond on $PORT (default 180;
#                  first-boot of the local network can be slow because it deploys
#                  L1 contracts to the embedded Anvil instance).
#   NAME           Container name (default sigalswap-sandbox).

set -euo pipefail

PORT=${PORT:-8080}
IMAGE=${IMAGE:-aztecprotocol/aztec:4.3.0}
READY_TIMEOUT=${READY_TIMEOUT:-180}
NAME=${NAME:-sigalswap-sandbox}

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not found in PATH" >&2
  exit 1
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "Pulling $IMAGE..."
  docker pull "$IMAGE"
fi

# Tear down any stale container with the same name so up.sh is idempotent.
if docker inspect "$NAME" >/dev/null 2>&1; then
  echo "Removing stale container $NAME..."
  docker rm -f "$NAME" >/dev/null
fi

echo "Starting $NAME on port $PORT..."
# v4.3's `aztec start --local-network` requires an external L1 RPC URL.
# Anvil ships inside the aztec image
# at /opt/foundry/bin/anvil, so we run both processes in a single container:
# anvil binds 127.0.0.1:8545 inside the container; aztec connects to it via
# the same loopback. Only the aztec port is exposed to the host.
docker run -d --rm \
  --name "$NAME" \
  -p "${PORT}:8080" \
  --entrypoint /bin/sh \
  "$IMAGE" \
  -c '/opt/foundry/bin/anvil --host 127.0.0.1 --port 8545 --silent &
      until /opt/foundry/bin/cast block-number --rpc-url http://127.0.0.1:8545 >/dev/null 2>&1; do sleep 1; done
      exec node --no-warnings /usr/src/yarn-project/aztec/dest/bin/index.js start --local-network --l1-rpc-urls http://127.0.0.1:8545' >/dev/null

# Block until the node accepts HTTP on $PORT and gives a non-error response to
# a probe JSON-RPC body. We accept any HTTP 2xx/4xx (server is up even if the
# method name is wrong) but reject connection-refused / not-yet-listening.
deadline=$(( $(date +%s) + READY_TIMEOUT ))
while true; do
  status=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://localhost:${PORT}" \
    -H 'content-type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"aztec_getNodeInfo","params":[]}' 2>/dev/null || echo 000)
  case "$status" in
    2*|4*) break ;;  # server up (200 with answer, 400/404 with method-not-found, etc.)
  esac
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "ERROR: $NAME did not respond on port $PORT within ${READY_TIMEOUT}s (last HTTP code: $status)" >&2
    docker logs --tail 30 "$NAME" >&2 || true
    exit 1
  fi
  sleep 2
done

echo "$NAME is up on http://localhost:${PORT}"
