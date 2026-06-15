/**
 * Core types for the Noir mutation tester.
 *
 * The flow:
 *   1. An Operator scans a Noir source file and emits MutationCandidates.
 *   2. The Orchestrator dispatches each candidate to a Worker.
 *   3. The Worker applies the mutation, runs `nargo test` against its
 *      dedicated TXE container port, observes pass/fail, then restores.
 *   4. The Orchestrator aggregates Verdicts into a Report.
 */

/** A single point-mutation in a Noir source file. */
export interface MutationCandidate {
  /** Absolute path to the source file. */
  filePath: string;
  /** 1-based line number. */
  line: number;
  /** 1-based column where the original substring starts. */
  column: number;
  /** Identifies the operator that produced this mutation, e.g. "ComparisonFlip". */
  operatorName: string;
  /** Original substring being replaced. Stored verbatim for restore + reporting. */
  original: string;
  /** Replacement substring written to the file when the mutation is applied. */
  replacement: string;
  /** Optional human-readable note (e.g. "flipping > to >="). */
  description?: string;
}

/**
 * Outcome of running the test suite against one mutated source.
 *
 *   killed       — at least one test failed when the source was mutated
 *                  (the mutation was caught — good, our tests are working)
 *   survived     — every test passed despite the mutation
 *                  (the mutation slipped through — coverage gap)
 *   compileError — `nargo test` failed to even compile the mutated source
 *                  (the type system caught it, effectively killed)
 *   runError     — the runner crashed for some reason unrelated to the
 *                  mutation itself (e.g. TXE worker died, IO error). The
 *                  mutation should be retried or skipped, not counted.
 */
export type Verdict = 'killed' | 'survived' | 'compileError' | 'runError';

/** Per-mutation result captured by the orchestrator. */
export interface MutationResult {
  candidate: MutationCandidate;
  verdict: Verdict;
  /** Wall-clock duration of the `nargo test` run, in milliseconds. */
  durationMs: number;
  /**
   * For `survived` results, an opportunity for a future operator to attach
   * an equivalence claim ("this mutation is semantically equivalent because
   * X"). For `killed` results, optionally a snippet of the failing-test
   * output for debugging. Kept short — the full nargo log is not retained.
   */
  note?: string;
}

/** Aggregate report assembled at the end of a mutation run. */
export interface Report {
  /** ISO-8601 timestamp when the run completed. */
  generatedAt: string;
  /** Absolute paths of files mutated in this run. */
  targetFiles: string[];
  /** Per-mutation results in candidate-emission order. */
  results: MutationResult[];
  /** Aggregate counts. */
  summary: {
    total: number;
    killed: number;
    survived: number;
    compileError: number;
    runError: number;
    /** killed + compileError as a fraction of (total - runError). */
    killRate: number;
  };
}

/**
 * Operator interface. An operator is a plugin that, given a source file,
 * emits candidates the engine should test. Each operator implements a
 * specific mutation class (comparison flips, assert drops, etc.).
 */
export interface MutationOperator {
  /** Stable identifier used in reports and CLI flags. */
  readonly name: string;
  /** Emit candidates for this file. May return an empty array. */
  candidates(source: string, filePath: string): MutationCandidate[];
}
