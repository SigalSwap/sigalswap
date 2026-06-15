/**
 * Worker pool with per-worker project sandboxes.
 *
 * For parallel mutation testing, each worker needs its own copy of the
 * project tree so mutations don't conflict. The setup:
 *
 *   1. Copy the project root to /tmp/sigalswap-mutation-sandbox-{N}/ for
 *      each worker N (parallel, independent of each other).
 *   2. Spawn a Docker TXE container per worker, mounting that worker's
 *      sandbox at the SAME absolute path inside the container. nargo
 *      running from inside the sandbox sends absolute host paths to TXE;
 *      the matching-path bind-mount makes TXE resolve them transparently.
 *   3. Orchestrator's worker pool dispatches mutations: each mutation is
 *      translated from its real-project path to the worker's sandbox
 *      path before being applied, then `nargo test` runs from that
 *      worker's sandbox cwd against that worker's container port.
 *
 * Container names use the `txe-mutation-worker-N` prefix to stay clear
 * of any `txe-worker-N` containers managed by `tools/txe/up.sh` for
 * non-mutation workflows.
 */

import { spawnSync } from 'node:child_process';
import { existsSync, rmSync } from 'node:fs';
import { join, relative, sep } from 'node:path';

export interface Worker {
  index: number;
  port: number;
  sandboxRoot: string;
  containerName: string;
  busy: boolean;
}

export interface WorkersOptions {
  count: number;
  basePort: number;
  projectRoot: string;
  sandboxBase: string;
  image: string;
  readyTimeoutSec: number;
}

const DEFAULT_OPTIONS: Omit<WorkersOptions, 'count' | 'projectRoot'> = {
  basePort: 8281,
  sandboxBase: '/tmp/sigalswap-mutation-sandbox',
  image: 'aztecprotocol/aztec:4.3.0',
  readyTimeoutSec: 60,
};

export async function setupWorkers(opts: {
  count: number;
  projectRoot: string;
} & Partial<Omit<WorkersOptions, 'count' | 'projectRoot'>>): Promise<Worker[]> {
  const full: WorkersOptions = { ...DEFAULT_OPTIONS, ...opts };
  const workers: Worker[] = [];

  ensureImagePresent(full.image);

  // Setup sandboxes + containers in parallel — `cp -R` and `docker run -d`
  // both return quickly; we await the port readiness check after all are
  // dispatched so the user sees concurrent progress.
  for (let i = 0; i < full.count; i++) {
    const sandboxRoot = `${full.sandboxBase}-${i}`;
    const port = full.basePort + i;
    const containerName = `txe-mutation-worker-${i}`;

    process.stdout.write(`[worker ${i}] preparing sandbox at ${sandboxRoot}\n`);
    if (existsSync(sandboxRoot)) {
      rmSync(sandboxRoot, { recursive: true, force: true });
    }
    // `cp -R src dst` where dst doesn't exist creates dst as a peer copy
    // of src — what we want for a self-contained sandbox.
    const cp = spawnSync('cp', ['-R', full.projectRoot, sandboxRoot], { stdio: 'inherit' });
    if (cp.status !== 0) {
      throw new Error(`Worker ${i}: cp from ${full.projectRoot} to ${sandboxRoot} failed`);
    }

    // Defensive: kill any stale container with the same name from a prior
    // run that didn't tear down cleanly.
    spawnSync('docker', ['rm', '-f', containerName], { stdio: 'ignore' });

    const run = spawnSync(
      'docker',
      [
        'run',
        '--rm',
        '-d',
        '--name',
        containerName,
        '-p',
        `${port}:${port}`,
        '-v',
        `${sandboxRoot}:${sandboxRoot}`,
        full.image,
        'start',
        '--txe',
        '--port',
        String(port),
      ],
      { stdio: 'pipe' },
    );
    if (run.status !== 0) {
      throw new Error(`Worker ${i}: docker run failed: ${run.stderr.toString()}`);
    }

    workers.push({ index: i, port, sandboxRoot, containerName, busy: false });
    process.stdout.write(`[worker ${i}] container ${containerName} starting on port ${port}\n`);
  }

  process.stdout.write(`Waiting for ${full.count} worker(s) to accept connections (timeout ${full.readyTimeoutSec}s)...\n`);
  for (const w of workers) {
    await waitForPort(w.port, full.readyTimeoutSec, w.containerName);
  }
  process.stdout.write(`All ${full.count} workers ready.\n`);

  return workers;
}

export async function teardownWorkers(workers: Worker[]): Promise<void> {
  for (const w of workers) {
    spawnSync('docker', ['rm', '-f', w.containerName], { stdio: 'ignore' });
    if (existsSync(w.sandboxRoot)) {
      rmSync(w.sandboxRoot, { recursive: true, force: true });
    }
  }
}

/** Translate a path under `projectRoot` to the equivalent path under `sandboxRoot`. */
export function translatePath(originalAbs: string, projectRoot: string, sandboxRoot: string): string {
  const rel = relative(projectRoot, originalAbs);
  if (rel.startsWith('..') || rel.includes(`..${sep}`)) {
    throw new Error(
      `translatePath: ${originalAbs} is outside project root ${projectRoot} (rel = ${rel})`,
    );
  }
  return join(sandboxRoot, rel);
}

/**
 * Semaphore-style worker pool. `acquire` waits for a free worker; `release`
 * hands the worker to the next waiter, or marks it idle if none.
 */
export class WorkerPool {
  private waiters: Array<(w: Worker) => void> = [];

  constructor(private readonly workers: Worker[]) {}

  acquire(): Promise<Worker> {
    const free = this.workers.find((w) => !w.busy);
    if (free) {
      free.busy = true;
      return Promise.resolve(free);
    }
    return new Promise((resolve) => this.waiters.push(resolve));
  }

  release(worker: Worker): void {
    const next = this.waiters.shift();
    if (next) {
      // Hand off directly without flipping busy.
      next(worker);
    } else {
      worker.busy = false;
    }
  }
}

function ensureImagePresent(image: string): void {
  const inspect = spawnSync('docker', ['image', 'inspect', image], { stdio: 'ignore' });
  if (inspect.status !== 0) {
    process.stdout.write(`Pulling ${image}...\n`);
    const pull = spawnSync('docker', ['pull', image], { stdio: 'inherit' });
    if (pull.status !== 0) {
      throw new Error(`Failed to pull image ${image}`);
    }
  }
}

async function waitForPort(port: number, timeoutSec: number, containerName: string): Promise<void> {
  const deadline = Date.now() + timeoutSec * 1000;
  while (Date.now() < deadline) {
    const probe = spawnSync('nc', ['-z', 'localhost', String(port)], { stdio: 'ignore' });
    if (probe.status === 0) return;
    await sleep(1000);
  }
  // Capture container logs to aid debugging when a worker fails to come up.
  const logs = spawnSync('docker', ['logs', '--tail', '20', containerName], { stdio: 'pipe' });
  throw new Error(
    `Worker container ${containerName} did not start listening on port ${port} within ${timeoutSec}s. ` +
      `Last 20 log lines:\n${logs.stdout?.toString() ?? ''}${logs.stderr?.toString() ?? ''}`,
  );
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
