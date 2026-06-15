/**
 * Test runner: invoke `nargo test` against a worker's TXE port and classify
 * the outcome.
 *
 * Each invocation runs ALL tests in the package — there's no per-test
 * filter for mutation testing because we want any test to be able to kill
 * the mutant. nargo's exit code is the verdict: 0 = all passed (mutation
 * survived), nonzero = at least one failed (mutation killed). Compile
 * failures show up as nonzero exit with a specific stderr signature, which
 * we extract into the `compileError` verdict so the operator can distinguish
 * "type system caught the bug" from "an assertion caught the bug" — both
 * are good outcomes but the reporting is cleaner when separated.
 */

import { spawn } from 'node:child_process';
import { dirname } from 'node:path';
import { existsSync, statSync } from 'node:fs';
import type { Verdict } from './types.js';

export interface RunnerOptions {
  /** Absolute path to the package directory containing the Nargo.toml. */
  packageDir: string;
  /** Localhost port of the TXE worker for this run. */
  workerPort: number;
  /** Hard cap on a single test invocation, in milliseconds. */
  timeoutMs: number;
  /**
   * Optional substring filter passed to `nargo test`. When set, only tests
   * whose fully-qualified name contains this substring run. Used to scope
   * mutation runs to the module containing the mutated code; without it,
   * every mutation runs the full package test suite (~minutes per
   * mutation for protocol/core's 250 tests). For production runs this
   * should usually be unset so every test gets the chance to kill the
   * mutant — set it for scaffold smoke tests.
   */
  testFilter?: string;
}

export interface RunOutcome {
  verdict: Exclude<Verdict, 'runError'> | { kind: 'runError'; reason: string };
  durationMs: number;
  /** Last few lines of stderr/stdout for diagnosis. */
  tail: string;
}

const COMPILE_ERROR_MARKERS = [
  'aborting due to',
  'error[',
  "error: couldn't",
  'cannot find type',
  'expected type',
];

/** Walk up from a file path looking for the nearest `Nargo.toml`. */
export function findPackageDir(filePath: string): string {
  let dir = dirname(filePath);
  while (dir !== '/' && dir.length > 1) {
    const candidate = `${dir}/Nargo.toml`;
    if (existsSync(candidate) && statSync(candidate).isFile()) {
      return dir;
    }
    dir = dirname(dir);
  }
  throw new Error(`findPackageDir: no Nargo.toml found for ${filePath}`);
}

export function runNargoTest(opts: RunnerOptions): Promise<RunOutcome> {
  return new Promise((resolve) => {
    const startedAt = Date.now();
    const buf: string[] = [];
    const argv: string[] = [
      'test',
      '--silence-warnings',
      '--oracle-resolver',
      `http://127.0.0.1:${opts.workerPort}`,
      '--test-threads',
      '1',
    ];
    if (opts.testFilter) argv.push(opts.testFilter);

    // Wrap nargo in `script -q -F /dev/null` to attach a pseudo-tty
    // and force per-write flushes. nargo (Rust) buffers stdout when
    // connected to a non-TTY pipe and only flushes on exit; that
    // defeats fail-fast — the first `FAIL` token only arrives after
    // every test in the suite has already run. With the script wrapper,
    // each test's "ok"/"FAIL" line lands in our stdout chunks within
    // milliseconds of nargo printing it, so we can kill on the first
    // failure.
    //
    // Tradeoff: macOS's `script` does NOT propagate the wrapped command's
    // exit code (always exits 0). The runner compensates by detecting
    // failure from output content too — see the close handler below.
    const child = spawn(
      'script',
      ['-q', '-F', '/dev/null', 'nargo', ...argv],
      {
        cwd: opts.packageDir,
        env: {
          ...process.env,
          NARGO_FOREIGN_CALL_TIMEOUT: '300000',
        },
        // Close stdin: macOS `script` tries to read from stdin when
        // attached and exits prematurely (code 1) if anything goes
        // sideways. We pipe stdout/stderr for monitoring; stdin is
        // unused.
        stdio: ['ignore', 'pipe', 'pipe'],
      },
    );

    /**
     * Fail-fast: kill nargo as soon as the first `FAIL` token shows up in
     * stdout. nargo prints `... ok` or `... FAIL` per test as it runs;
     * mutation testing only needs to know if ANY test failed, not the
     * full count. Without this, every killed mutation pays the entire
     * suite runtime even when test 1 already caught it (~50s for
     * wide.nr's 31 tests vs ~3s if test 1 catches the mutation).
     */
    let failFastTriggered = false;
    let timedOut = false;

    const timer = setTimeout(() => {
      timedOut = true;
      child.kill('SIGKILL');
    }, opts.timeoutMs);

    child.stdout.on('data', (chunk: Buffer) => {
      const text = chunk.toString('utf-8');
      buf.push(text);
      // Match per-test `FAIL` only in the STATUS position (after the `...`
      // separator in `Testing <name> ... FAIL`), so a passing test whose NAME
      // contains "FAIL" (which appears before the `...`) is not mis-scored as a
      // killed mutant. The summary line `N test(s) failed` is the backstop.
      if (!failFastTriggered && /\.\.\..*FAIL|\d+ tests? failed/.test(text)) {
        failFastTriggered = true;
        child.kill('SIGKILL');
      }
    });
    child.stderr.on('data', (chunk: Buffer) => {
      buf.push(chunk.toString('utf-8'));
    });

    child.on('error', (err: Error) => {
      clearTimeout(timer);
      resolve({
        verdict: { kind: 'runError', reason: `spawn failed: ${err.message}` },
        durationMs: Date.now() - startedAt,
        tail: buf.join('').slice(-500),
      });
    });

    child.on('close', (code: number | null, _signal: NodeJS.Signals | null) => {
      clearTimeout(timer);
      const durationMs = Date.now() - startedAt;
      const out = buf.join('');
      const tail = out.slice(-500);

      // Order matters: timeout precedes fail-fast (a fail-fast kill is
      // intentional and means at least one test failed before the timer
      // would have fired).
      if (timedOut) {
        resolve({
          verdict: { kind: 'runError', reason: `timeout after ${opts.timeoutMs}ms` },
          durationMs,
          tail,
        });
        return;
      }

      if (failFastTriggered) {
        resolve({ verdict: 'killed', durationMs, tail });
        return;
      }

      // The script wrapper always exits 0 on macOS, so we can't trust
      // the exit code to distinguish survived from late-killed. Detect
      // both states from output content: the compile-error markers, the
      // final-summary line, or the per-test FAIL pattern.
      if (COMPILE_ERROR_MARKERS.some((marker) => out.includes(marker))) {
        resolve({ verdict: 'compileError', durationMs, tail });
        return;
      }
      // FAIL only in the status position (after `...`) so a passing test whose
      // name contains "FAIL" doesn't read as a killed mutant; summary as backstop.
      if (/\.\.\..*FAIL|\d+ tests? failed/.test(out)) {
        resolve({ verdict: 'killed', durationMs, tail });
        return;
      }
      if (code === 0) {
        resolve({ verdict: 'survived', durationMs, tail });
        return;
      }
      // Non-zero exit not accompanied by a recognized failure pattern.
      // Most likely a runner crash (worker died, IO error, etc.).
      resolve({
        verdict: { kind: 'runError', reason: `nargo exit ${code} with no recognized failure pattern` },
        durationMs,
        tail,
      });
    });
  });
}
