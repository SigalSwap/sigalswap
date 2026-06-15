/**
 * Orchestrator: drive the mutation loop across a pool of sandboxed workers.
 *
 * Loop:
 *   for each operator on each target file → emit candidates
 *   wrap candidates in a Promise.all, each dispatched through the pool:
 *     acquire a worker (semaphore)
 *     translate candidate's filePath from project root to the worker's
 *       sandbox root
 *     snapshot the worker's copy of the file
 *     try:
 *       apply mutation to the worker's copy
 *       run `nargo test` from the worker's package dir against the worker's
 *         TXE container port
 *       classify the verdict
 *     finally:
 *       restore the worker's file from snapshot
 *       release the worker
 *   collect all results, assemble the Report
 *
 * `--workers=1` reduces to serial-with-sandbox; `--workers=N` exercises
 * the parallel-with-sandbox path.
 */

import { readFileSync } from 'node:fs';
import type {
  MutationCandidate,
  MutationOperator,
  MutationResult,
  Report,
  Verdict,
} from './types.js';
import { applyMutation, snapshot } from './apply.js';
import { findPackageDir, runNargoTest } from './runner.js';
import { translatePath, WorkerPool, type Worker } from './workers.js';

export interface OrchestratorOptions {
  /** Absolute paths of files to mutate. */
  targetFiles: string[];
  /** Operators to apply against each target file. */
  operators: readonly MutationOperator[];
  /** Project root (used to translate candidate paths into worker sandboxes). */
  projectRoot: string;
  /** Initialized worker pool. */
  workers: readonly Worker[];
  /** Per-mutation test timeout (ms). */
  timeoutMs: number;
  /** Optional substring filter passed to `nargo test`. */
  testFilter?: string;
  /** Optional progress hook called after each result lands. */
  onProgress?: (result: MutationResult, completed: number, total: number) => void;
}

export async function runMutationCampaign(opts: OrchestratorOptions): Promise<Report> {
  const allCandidates: MutationCandidate[] = [];
  for (const filePath of opts.targetFiles) {
    const source = readFileSync(filePath, 'utf-8');
    for (const operator of opts.operators) {
      allCandidates.push(...operator.candidates(source, filePath));
    }
  }

  const pool = new WorkerPool([...opts.workers]);
  let completed = 0;

  const results: MutationResult[] = await Promise.all(
    allCandidates.map(async (candidate) => {
      const worker = await pool.acquire();
      let result: MutationResult;
      try {
        result = await processMutation(candidate, worker, opts);
      } finally {
        pool.release(worker);
      }
      completed++;
      opts.onProgress?.(result, completed, allCandidates.length);
      return result;
    }),
  );

  return assembleReport(opts.targetFiles, results);
}

async function processMutation(
  candidate: MutationCandidate,
  worker: Worker,
  opts: OrchestratorOptions,
): Promise<MutationResult> {
  const sandboxFilePath = translatePath(candidate.filePath, opts.projectRoot, worker.sandboxRoot);
  const packageDir = findPackageDir(sandboxFilePath);
  const restore = snapshot(sandboxFilePath);

  try {
    // applyMutation expects the candidate's filePath to point at the file
    // it will modify. Translate the candidate before passing it in.
    applyMutation({ ...candidate, filePath: sandboxFilePath });

    const outcome = await runNargoTest({
      packageDir,
      workerPort: worker.port,
      timeoutMs: opts.timeoutMs,
      testFilter: opts.testFilter,
    });

    const verdict: Verdict =
      typeof outcome.verdict === 'object' ? 'runError' : outcome.verdict;
    const note =
      typeof outcome.verdict === 'object'
        ? `runError: ${outcome.verdict.reason}`
        : verdict === 'killed' || verdict === 'compileError'
          ? outcome.tail.split('\n').slice(-3).join(' | ')
          : undefined;

    return {
      candidate,
      verdict,
      durationMs: outcome.durationMs,
      note,
    };
  } catch (err) {
    return {
      candidate,
      verdict: 'runError',
      durationMs: 0,
      note: `applyMutation: ${(err as Error).message}`,
    };
  } finally {
    restore();
  }
}

function assembleReport(targetFiles: string[], results: MutationResult[]): Report {
  const counts: Record<Verdict, number> = {
    killed: 0,
    survived: 0,
    compileError: 0,
    runError: 0,
  };
  for (const result of results) {
    counts[result.verdict]++;
  }
  const denominator = results.length - counts.runError;
  const killRate = denominator === 0 ? 0 : (counts.killed + counts.compileError) / denominator;

  return {
    generatedAt: new Date().toISOString(),
    targetFiles,
    results,
    summary: {
      total: results.length,
      killed: counts.killed,
      survived: counts.survived,
      compileError: counts.compileError,
      runError: counts.runError,
      killRate,
    },
  };
}
