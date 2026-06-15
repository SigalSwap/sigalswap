/**
 * CLI entrypoint for the Noir mutation tester.
 *
 * Pass one or more target files and a worker port; the orchestrator scans
 * each file with all enabled operators, runs the mutations, and writes a
 * JSON report plus a human-readable summary.
 *
 * Usage:
 *   tsx src/cli.ts run <file>... [--port=8181] [--timeout=300000] [--report=path]
 */

import { execSync } from 'node:child_process';
import { mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { dirname, isAbsolute, resolve } from 'node:path';
import { ALL_OPERATORS, operatorByName } from './operators.js';
import { runMutationCampaign } from './orchestrator.js';
import { setupWorkers, teardownWorkers } from './workers.js';
import type { MutationOperator, Report } from './types.js';

interface ParsedArgs {
  files: string[];
  workers: number;
  basePort: number;
  timeoutMs: number;
  reportPath: string;
  testFilter?: string;
  operators: readonly MutationOperator[];
  /** When true, list candidates per file and exit without running tests. */
  dryRun: boolean;
}

function parseArgs(argv: string[]): ParsedArgs {
  if (argv.length === 0 || argv[0] !== 'run') {
    printUsage();
    process.exit(2);
  }
  const rest = argv.slice(1);
  const files: string[] = [];
  let workers = 4;
  let basePort = 8281;
  let timeoutMs = 300_000;
  let reportPath = 'reports/mutation.json';
  let testFilter: string | undefined;
  let operators: readonly MutationOperator[] = ALL_OPERATORS;
  let dryRun = false;

  for (const arg of rest) {
    if (arg.startsWith('--workers=')) {
      workers = parseInt(arg.slice('--workers='.length), 10);
    } else if (arg.startsWith('--port=')) {
      basePort = parseInt(arg.slice('--port='.length), 10);
    } else if (arg.startsWith('--timeout=')) {
      timeoutMs = parseInt(arg.slice('--timeout='.length), 10);
    } else if (arg.startsWith('--report=')) {
      reportPath = arg.slice('--report='.length);
    } else if (arg.startsWith('--testFilter=')) {
      testFilter = arg.slice('--testFilter='.length);
    } else if (arg.startsWith('--operators=')) {
      const names = arg.slice('--operators='.length).split(',').filter((n) => n.length > 0);
      const resolved: MutationOperator[] = [];
      for (const name of names) {
        const op = operatorByName(name);
        if (!op) {
          console.error(`Unknown operator: ${name}`);
          console.error(`Available: ${ALL_OPERATORS.map((o) => o.name).join(', ')}`);
          process.exit(2);
        }
        resolved.push(op);
      }
      operators = resolved;
    } else if (arg === '--dry-run') {
      dryRun = true;
    } else if (arg.startsWith('--')) {
      console.error(`Unknown flag: ${arg}`);
      process.exit(2);
    } else {
      files.push(arg);
    }
  }

  if (files.length === 0) {
    console.error('Need at least one target file.');
    printUsage();
    process.exit(2);
  }

  return {
    files: files.map((f) => (isAbsolute(f) ? f : resolve(process.cwd(), f))),
    workers,
    basePort,
    timeoutMs,
    reportPath: isAbsolute(reportPath) ? reportPath : resolve(process.cwd(), reportPath),
    testFilter,
    operators,
    dryRun,
  };
}

function printUsage(): void {
  process.stdout.write(
    [
      'Noir mutation tester (Phase 2.1 scaffold)',
      '',
      'Usage:',
      '  tsx src/cli.ts run <file>... [--port=8181] [--timeout=300000] [--report=path]',
      '',
      'Flags:',
      '  --workers=N        Parallel worker count (default 4). Each worker gets its',
      '                     own sandboxed project copy and Docker TXE container.',
      '  --port=N           Base port (default 8281). Worker i uses port N+i.',
      '  --timeout=MS       Per-test timeout in ms (default 300000)',
      '  --report=PATH      JSON report output path (default reports/mutation.json)',
      '  --testFilter=SUB   Substring filter for `nargo test`. Scopes runs to tests',
      '                     whose name contains SUB. Use for scaffold smoke tests; for',
      '                     production runs leave unset so every test can kill mutants.',
      `  --operators=A,B    Comma list of operators to enable (default: all). Available:`,
      `                     ${ALL_OPERATORS.map((o) => o.name).join(', ')}`,
      '  --dry-run          List the candidates each operator emits without running',
      '                     any tests. Useful for sanity-checking an operator on a file.',
      '',
      'Prerequisites:',
      '  A TXE worker must be running on the specified port before invoking.',
      '  See tools/txe/up.sh.',
      '',
    ].join('\n'),
  );
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));

  if (args.dryRun) {
    runDryRun(args);
    return;
  }

  const projectRoot = detectProjectRoot(args.files[0]!);

  process.stdout.write(
    `Mutating ${args.files.length} file(s) with ${args.workers} parallel worker(s)\n`,
  );
  for (const f of args.files) {
    process.stdout.write(`  ${f}\n`);
  }
  process.stdout.write(`Operators: ${args.operators.map((o) => o.name).join(', ')}\n`);
  process.stdout.write(`Project root: ${projectRoot}\n`);

  const workers = await setupWorkers({
    count: args.workers,
    projectRoot,
    basePort: args.basePort,
  });

  try {
    const report = await runMutationCampaign({
      targetFiles: args.files,
      operators: args.operators,
      projectRoot,
      workers,
      timeoutMs: args.timeoutMs,
      testFilter: args.testFilter,
      onProgress: (result, completed, total) => {
        const sym =
          result.verdict === 'killed'
            ? 'K'
            : result.verdict === 'compileError'
              ? 'C'
              : result.verdict === 'survived'
                ? 'S'
                : 'E';
        const dur = `${(result.durationMs / 1000).toFixed(1)}s`;
        const loc = `${trimPath(result.candidate.filePath, projectRoot)}:${result.candidate.line}`;
        process.stdout.write(
          `  [${completed}/${total}] ${sym} ${loc} (${result.candidate.operatorName}) ${dur}\n`,
        );
      },
    });

    printSummary(report);
    writeReport(report, args.reportPath);
  } finally {
    process.stdout.write('Tearing down workers...\n');
    await teardownWorkers(workers);
  }
}

function detectProjectRoot(anyTargetFile: string): string {
  // Walk up from the target file looking for the SigalSwap-specific
  // marker `protocol/core/Nargo.toml`. Stopping on a generic `package.json`
  // would land on `tools/mutation/` (or any other inner package).
  let dir = dirname(anyTargetFile);
  while (dir !== '/' && dir.length > 1) {
    if (tryStat(`${dir}/protocol/core/Nargo.toml`)) {
      return dir;
    }
    dir = dirname(dir);
  }
  // Fallback: git toplevel, then CWD. Useful if the layout changes but the
  // user runs from inside the repo.
  try {
    return execSync('git rev-parse --show-toplevel', { encoding: 'utf-8' }).trim();
  } catch {
    return process.cwd();
  }
}

function tryStat(p: string): boolean {
  try {
    statSync(p);
    return true;
  } catch {
    return false;
  }
}

function runDryRun(args: ParsedArgs): void {
  let total = 0;
  for (const filePath of args.files) {
    const source = readFileSync(filePath, 'utf-8');
    process.stdout.write(`\n${trimPath(filePath)}:\n`);
    for (const op of args.operators) {
      const candidates = op.candidates(source, filePath);
      total += candidates.length;
      process.stdout.write(`  ${op.name}: ${candidates.length} candidate(s)\n`);
      for (const c of candidates.slice(0, 5)) {
        process.stdout.write(
          `    ${c.line}:${c.column} ${JSON.stringify(c.original)} → ${JSON.stringify(c.replacement)}\n`,
        );
      }
      if (candidates.length > 5) {
        process.stdout.write(`    ... and ${candidates.length - 5} more\n`);
      }
    }
  }
  process.stdout.write(`\nTotal: ${total} candidate(s) across ${args.files.length} file(s).\n`);
  process.stdout.write('Dry-run complete (no tests executed).\n');
}

function trimPath(absPath: string, projectRoot?: string): string {
  if (projectRoot && absPath.startsWith(projectRoot)) {
    return absPath.slice(projectRoot.length + 1);
  }
  const cwd = process.cwd();
  return absPath.startsWith(cwd) ? absPath.slice(cwd.length + 1) : absPath;
}

function printSummary(report: Report): void {
  const { summary } = report;
  process.stdout.write('\n--- Summary ---\n');
  process.stdout.write(`Total mutations:   ${summary.total}\n`);
  process.stdout.write(`Killed (tests):    ${summary.killed}\n`);
  process.stdout.write(`Killed (compile):  ${summary.compileError}\n`);
  process.stdout.write(`Survived:          ${summary.survived}\n`);
  process.stdout.write(`Run errors:        ${summary.runError}\n`);
  process.stdout.write(`Kill rate:         ${(summary.killRate * 100).toFixed(2)}%\n`);
}

function writeReport(report: Report, reportPath: string): void {
  mkdirSync(dirname(reportPath), { recursive: true });
  writeFileSync(reportPath, JSON.stringify(report, null, 2), 'utf-8');
  process.stdout.write(`\nReport written to ${reportPath}\n`);
}

main().catch((err) => {
  console.error('FATAL:', err);
  process.exit(1);
});
