# Dockerized TXE for parallel test orchestration

Containerized Aztec TXE workers for workflows that repeatedly spin up and tear down test execution environments — mutation testing, fuzzing, parallel batch test runs.

## Why Docker

Native `aztec start --txe` leaks resources that aren't reliably released by `kill` — sockets stay in `TIME_WAIT`, child processes orphan, file descriptors accumulate. The leakage isn't fatal during one-shot test runs (which is why `aztec test` works fine for daily development), but high-cycle workflows that spawn and reap dozens of TXE instances accumulate enough leaked state to require a host reboot for recovery.

Docker container teardown via `docker rm -f` releases all of a container's resources atomically. Per-container TXE isolation also gives us free parallelism — N containers on N ports = N independent TXEs that can be driven concurrently without the cross-thread oracle-state confusion that makes `--test-threads N` flaky against a single TXE.

## Quick start

```bash
# Bring up 4 workers on ports 8181..8184 (defaults)
./tools/txe/up.sh

# Or specify count and base port
WORKERS=6 BASE_PORT=8181 ./tools/txe/up.sh

# Tear down all workers
./tools/txe/down.sh
```

After `up.sh` returns, all workers respond on their assigned ports.

## Usage from a test orchestrator

Each worker exposes its TXE on `localhost:$PORT` where `$PORT = BASE_PORT + worker_index`. A test runner connects per-worker via:

```bash
nargo test --oracle-resolver "http://127.0.0.1:$PORT" --test-threads 1
```

`--test-threads 1` is required because TXE's oracle state is unsafe under parallel-thread access against a single instance. Per-worker isolation comes from running multiple containers, not from parallel threads inside one TXE.

A typical mutation orchestrator pattern:
1. Call `tools/txe/up.sh` with `WORKERS=N` workers.
2. Maintain a worker pool of N tasks; each task is assigned a port.
3. For each mutant: pick the next available worker, apply the mutation to a sandboxed copy of the source, run `nargo test` against that worker's port, record the result.
4. Call `tools/txe/down.sh` when the run completes (or on Ctrl-C — the trap handler should call it on exit too).

## Resource sizing

Each TXE worker uses approximately 1–2 GB RAM and ~2 cores under load. On an Apple M2 Max (96 GB RAM, 12 cores):

- Memory: not the binding constraint at any reasonable parallelism.
- CPU: ~6 workers without context-switch thrash.

`WORKERS=4` is the sane default leaving headroom for the host. Bump to 6 for maximum throughput on a dedicated machine.

## Image

Uses `aztecprotocol/aztec:4.3.0` directly — no custom Dockerfile needed. The image's entrypoint is the aztec CLI binary; passing `start --txe --port=N` invokes TXE mode. The image is multi-arch (amd64 + arm64), so it runs natively on Apple Silicon — no Rosetta emulation overhead.

To pin a different Aztec version:

```bash
TXE_IMAGE=aztecprotocol/aztec:4.4.0-nightly.20260517 ./tools/txe/up.sh
```

The version should match the project's pinned `@aztec/aztec.js` in `packages/sdk/package.json` so contracts compiled against that version run against a matching TXE.

## Project root bind-mount

`up.sh` bind-mounts the project root into each container at the **same path** the host uses (e.g. `/path/to/SigalSwap → /path/to/SigalSwap`). This is required for TXE-in-Docker to work at all.

**Why:** when `nargo test` runs, it sends absolute host paths to TXE for compiled-contract-artifact lookups (e.g. `/path/to/SigalSwap/protocol/lp-token/target/sigalswap_lp_token-SigalSwapLPToken.json`). TXE then reads those files from its own filesystem. Without a bind-mount, the container can't see those files and crashes with `ENOENT`. Mounting at the same path means TXE resolves the host's absolute paths transparently.

The default `PROJECT_ROOT` is the git toplevel directory of the CWD. Override if you're running from outside the repo or have a non-standard layout:

```bash
PROJECT_ROOT=/path/to/SigalSwap ./tools/txe/up.sh
```

## Smoke test

Verify the setup works without launching a full mutation run:

```bash
./tools/txe/up.sh           # spawn 4 workers
docker ps --filter name=^txe-worker- --format 'table {{.Names}}\t{{.Ports}}\t{{.Status}}'
nc -z localhost 8181 && echo "Worker 0 OK"
nc -z localhost 8184 && echo "Worker 3 OK"
./tools/txe/down.sh         # clean up
```

## Troubleshooting

**Worker fails to come up within timeout.** Check `docker logs txe-worker-N` for the failing container. Common causes: port already in use on the host (another process or stale container), insufficient memory, or Docker Desktop resource limits set too low. The default 60s timeout accommodates first-time cold-start; subsequent runs typically come up in under 10s.

**Containers persist after orchestrator crash.** Run `./tools/txe/down.sh` manually. The script matches by name pattern `^txe-worker-` so it cleans up regardless of which orchestrator started them.

**LD_PRELOAD warning in logs.** `ERROR: ld.so: object '/usr/lib/x86_64-linux-gnu/libtcmalloc_minimal.so.4' from LD_PRELOAD cannot be preloaded` — benign on arm64 builds. The image preloads tcmalloc on amd64 for performance; arm64 doesn't bundle it. The warning is logged once at startup and ignored.
