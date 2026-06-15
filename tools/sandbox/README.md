# Dockerized Aztec sandbox for SDK e2e tests

The SDK e2e suite (`packages/sdk/src/e2e/`) connects to an Aztec node at
`http://localhost:8080`. This directory provides a Docker-isolated way to bring
that node up, run the e2e tests, and tear everything down with no host-side
state to clean up afterwards.

## Why Docker

Same reason as `tools/txe/`: native `aztec start` leaks file descriptors,
sockets in `TIME_WAIT`, and orphaned child processes that aren't released by
`kill`. The e2e suite runs many transactions per session, which is enough
churn for the leakage to matter. Docker `--rm` teardown releases everything
atomically.

See `tools/txe/README.md` for the full rationale.

## Quick start

```bash
# Bring sandbox up on port 8080
./tools/sandbox/up.sh

# Run e2e tests against it (in another terminal or after up.sh returns)
cd packages/sdk
npm run test:e2e

# Tear sandbox down
./tools/sandbox/down.sh
```

`up.sh` blocks until the node responds to `node_getNodeInfo`. First boot is
slow (~30-60s) because the local network deploys L1 contracts to its embedded
Anvil instance; subsequent runs reuse the image's pre-built data and start in
~10s. Default ready timeout is 180s.

## Customization

```bash
# Different port (host-side)
PORT=8081 ./tools/sandbox/up.sh

# Different aztec version (image must be pulled or pullable)
IMAGE=aztecprotocol/aztec:4.4.0-nightly.20260517 ./tools/sandbox/up.sh

# Different container name (useful if running multiple sandboxes side-by-side)
NAME=my-sandbox PORT=8082 ./tools/sandbox/up.sh
NAME=my-sandbox ./tools/sandbox/down.sh
```

## Image

Uses `aztecprotocol/aztec:4.3.0` directly. Same image as `tools/txe/`; passing
`start --local-network` (instead of `start --txe`) selects the full sandbox
mode rather than the lightweight TXE mode.

## Differences from `tools/txe/`

| | `tools/txe/` | `tools/sandbox/` |
|---|---|---|
| Mode | TXE workers (lightweight) | Local network sandbox (full) |
| Use case | Mutation testing, fuzzing, parallel Noir test runs | SDK e2e tests, manual integration testing |
| Containers | N (default 4, for parallelism) | 1 |
| Ports | 8181..8181+N-1 | 8080 |
| Startup time | ~5-10s per worker | ~30-60s (L1 deploy) |
| Bind-mount | Yes (project root) | No |
| State | Ephemeral per `down.sh` | Ephemeral per `down.sh` |

## Troubleshooting

**`up.sh` reports timeout but the node looks fine.** Increase
`READY_TIMEOUT` — first-pull installs can take longer than 180s on slower
machines. Also check `docker logs sigalswap-sandbox` for L1 deploy errors.

**Port 8080 already in use.** Either kill the conflicting process or run
`PORT=8081 ./tools/sandbox/up.sh` and point the SDK at the new port via
`SANDBOX_URL` (if the SDK supports that; otherwise stick to 8080).

**Sandbox state persists between runs.** It doesn't — the container is started
with `--rm`, so `down.sh` removes it. If you want persistence (e.g. for
debugging an e2e failure), drop the `--rm` flag in `up.sh` and use `docker
start` / `docker stop` instead.
