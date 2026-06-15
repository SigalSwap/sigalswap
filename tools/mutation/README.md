# Noir mutation tester

Mutation testing for SigalSwap's Noir contracts. The SDK side is complete (`docs/test-quality.md`); the contract side is the next work.

**Phases 2.1 (scaffold) and 2.2 (operator catalog) are complete.** Phase 2.3 is the first real run on `protocol/core/src/math/safe_math.nr` to capture a baseline kill rate. Phases 3.x then iterate on `math/wide.nr` and `pair/mod.nr`.

## Architecture

```
┌─────────────┐
│ CLI (cli.ts)│
└──────┬──────┘
       │
       ▼
┌────────────────────┐    candidates       ┌────────────────┐
│ Orchestrator       │◀───────────────────▶│ Operators      │
│ (orchestrator.ts)  │                     │ (operators.ts) │
└─────┬──────────────┘                     └────────────────┘
      │
      │ apply / restore
      ▼
┌────────────────┐    nargo test     ┌──────────────────┐
│ Mutation file  │──spawn subprocess▶│ TXE worker (8181)│
│ (apply.ts)     │   to runner.ts    │  Docker container│
└────────────────┘                   └──────────────────┘
```

## Files

- `src/types.ts` — `MutationCandidate`, `MutationResult`, `Verdict`, `Report`, `MutationOperator`.
- `src/scanner.ts` — Source position helpers: `computeCodeMask` (skip comments/strings), `findClosingParen` / `findClosingBrace` (balanced delimiter scan), `findTestFunctionRanges` (skip `#[test]` bodies), `lineColAt`, `isIdentChar`.
- `src/operators.ts` — Operator implementations: `ComparisonFlip`, `ArithmeticFlip`, `AssertDrop`, `BoundShift`, `LiteralFlip`. Each operator skips comments, string literals, and test-function bodies.
- `src/apply.ts` — In-place mutation + restore primitives. Bytewise apply via `(line, column)` offsets; idempotent restore in `finally`.
- `src/runner.ts` — Spawns `nargo test` against a worker port; classifies the outcome (`killed`, `survived`, `compileError`, `runError`).
- `src/orchestrator.ts` — Iterates candidates, calls apply/run/restore, aggregates results into a `Report`.
- `src/cli.ts` — Parse args, run the campaign, print a summary, write JSON.

## Quick start

```bash
# 1. Bring up a TXE worker (Phase 2.0 infrastructure)
./tools/txe/up.sh                  # WORKERS=4 BASE_PORT=8181 by default

# 2. Run the mutation tester against a target file
cd tools/mutation
npm install
npx tsx src/cli.ts run ../../protocol/core/src/math/safe_math.nr --port=8181

# 3. Tear down the worker
cd ../..
./tools/txe/down.sh
```

The CLI prints per-mutation status as it runs and writes a JSON report to `tools/mutation/reports/mutation.json` by default.

## Verdicts

| Verdict        | Meaning |
|----------------|---------|
| `killed`       | At least one test failed against the mutated source. The test suite caught the bug — good outcome. |
| `compileError` | `nargo test` failed to compile the mutated source. The type system rejected the bug — also good. Reported separately so the audit handoff can distinguish "tests caught it" from "types caught it". |
| `survived`     | Every test passed despite the mutation. A coverage gap; either add a test that distinguishes the original from the mutant, or document the mutant as semantically equivalent. |
| `runError`     | The runner crashed for reasons unrelated to the mutation (TXE worker died, file IO error, timeout, etc.). Doesn't count toward the kill rate. |

The kill rate reported in the summary is `(killed + compileError) / (total - runError)`.

## Operator catalog (Phase 2.2)

| Operator | Mutations per site | Skips |
|---|---|---|
| `ComparisonFlip` | 1–2 (e.g. `>` → `>=` and `>` → `<`) | composite tokens (`->`, `=>`, `<<`, `>>`) |
| `ArithmeticFlip` | 1 (`+` ↔ `-`, `*` ↔ `/`) | unary minus (heuristic), composite assignment (`+=`, `-=`, ...), division-as-comment (`//`) |
| `AssertDrop` | 1 per call (replaces with `()`) | identifiers extending the keyword (`assertion`) |
| `BoundShift` | 1–2 per range (`bound ± 1`) | non-numeric or negative bounds |
| `LiteralFlip` | 1 per site (`0` ↔ `1`) | multi-digit literals, numeric subscripts of identifiers |

All operators apply the following filters before emitting candidates:
1. **Code-only:** `computeCodeMask` excludes byte ranges inside `//` line comments, `/* */` block comments, and `"..."` string literals.
2. **Production-only:** `findTestFunctionRanges` excludes byte ranges inside `#[test]` and `#[test(...)]` function bodies. Mutating inside test bodies just measures whether removing a test's check lets the test pass (it does, trivially); not useful coverage signal.

Inspect what an operator emits without running tests:

```bash
npx tsx src/cli.ts run path/to/file.nr --dry-run
# or filter to one operator
npx tsx src/cli.ts run path/to/file.nr --dry-run --operators=ComparisonFlip
```

## Phase 2.1 + 2.2 scope (complete)

- ✅ Mutation candidate emission via the `MutationOperator` interface.
- ✅ In-place mutation + restore primitives.
- ✅ Test runner subprocess management with timeout + verdict classification.
- ✅ Sequential orchestrator (one mutation at a time, against worker port 8181).
- ✅ JSON + console report.
- ✅ End-to-end working invocation.
- ✅ Full operator catalog (5 operators, ~7 mutation classes total).
- ✅ Code-region and test-body exclusion via the scanner.
- ✅ `--dry-run`, `--operators`, `--testFilter` CLI flags.

## Deferred to Phase 2.3

- First real run on `protocol/core/src/math/safe_math.nr`. Iterate to ≥95% kill rate via test additions or equivalence documentation, mirroring the SDK methodology.
- Subsequent runs on `math/wide.nr` and `pair/mod.nr`.

## Future operator work

- **Argument swaps** for order-sensitive functions (e.g. `safe_sub(a, b)` is not commutative). Requires call-site semantic info we don't have without a real Noir parser.
- **Logical operator flips** (`&` ↔ `|`, `&&` ↔ `||`). Rarely appears in math libraries; revisit when we run on `pair/mod.nr` which has more conditional logic.
- **Per-line opt-out annotations** like `// mutation-disable next-line ComparisonFlip` for cataloged equivalents — analogous to Stryker's `// Stryker disable`. Useful once Phase 3.x runs surface real survivors that should be marked equivalent rather than tested.
- **Stuck-mutation detection** — some mutations (e.g. `<` → `<=` in a `while` condition) can cause infinite loops. The per-test timeout (`--timeout`) catches this, but a smarter detector could flag suspected stuck mutations before consuming the full timeout.

## Deferred to Phase 3+

- Parallel worker dispatch. Currently the orchestrator runs serially against one TXE worker because mutations write to files in a project tree shared by all workers via the bind-mount. Parallelism requires per-worker sandbox copies of the project. This is the long-pole change before mutation runs on `pair/mod.nr` (which has the largest test suite — serial runtime would be hours).

## Why TypeScript and not Rust/Go

The SDK is TypeScript and the team's daily-driver. Sharing language reduces cognitive overhead and lets us reuse existing tooling (tsx, vitest later if we want to test the tester). Performance isn't the bottleneck — `nargo test` invocations dominate runtime (~seconds each). The orchestrator could be a shell script and barely be slower; TypeScript buys testability and structured types that catch operator bugs early.
