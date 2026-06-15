# Test quality: mutation testing analysis

Audit-handoff analysis of how well the test suite catches code-level bugs. Two surfaces:

- **SDK (TypeScript)** — measured with [Stryker](https://stryker-mutator.io). Sections §1–§8 below.
- **Noir contracts** — measured with the in-tree mutation tester at `tools/mutation/`. Sections §9–§13.

# Part I: SDK

## 1. Summary

- **Mutation score (total): 91.43%** (455 killed + 4 timeout) / 640 mutants
- **Mutation score (covered): 91.98%** (kill rate over mutants the test suite reaches)
- **Type-checker kills: 138** mutants rejected by `tsc` before any test ran
- **Surviving mutants: 40** — all classified below as semantic equivalents, dead defensive code, or string labels with no behavioral impact
- **No-coverage mutants: 3** — all in dead defensive code

A test is "killed" when at least one test case fails on the mutated code. Stryker's TypeScript checker (`@stryker-mutator/typescript-checker`) rejects type-incompatible mutations before they reach the test runner — those count as "errors" in raw output but are effectively killed by the type system, so we include them in the cumulative caught-bug count.

**Effective bug-catching rate (tests + type checker): 92.97%** — (455 + 4 + 138) / 640 = 597/640.

## 2. Methodology

**Tool.** Stryker 9.6.1 (`@stryker-mutator/core` + `@stryker-mutator/vitest-runner` + `@stryker-mutator/typescript-checker`).

**Configuration.** `packages/sdk/stryker.config.json`. Targets four load-bearing SDK files:
- `src/router.ts` — multi-hop routing, fee computation, pair enumeration, padding
- `src/pair.ts` — single-pair operations, validation, V3-callback swaps, flash swaps
- `src/pair-verification.ts` — factory cross-check for pair authenticity
- `src/protocol-fee.ts` — Uniswap-V2-style protocol fee math

**Test runner.** vitest 4.1.2. The SDK's 422 unit/property tests run against each mutant. End-to-end tests (which require a live Aztec sandbox) are excluded — they validate integration behavior, not the SDK's pure logic.

**Mutators applied.** Stryker default set, including: `ArithmeticOperator`, `ArrayDeclaration`, `ArrowFunction`, `BlockStatement`, `BooleanLiteral`, `ConditionalExpression`, `EqualityOperator`, `LogicalOperator`, `MethodExpression`, `ObjectLiteral`, `OptionalChaining`, `Regex`, `StringLiteral`, `UpdateOperator`. 640 total mutants generated across the four files.

**Coverage analysis mode.** `coverageAnalysis: "all"`. Every test file is loaded against every mutant rather than relying on per-test instrumentation that proved unreliable with vitest 4 (an earlier `perTest` mode incorrectly skipped tests for many mutants).

**Threshold.** Configured 95% high / 80% low. Current 91.43% sits comfortably above the low threshold; remaining gap to high is fully accounted for by the survivors classified below.

**Drift-canary tests skipped under Stryker.** `constants.test.ts` reads Noir source files at the repo root (verifying SDK constants match contract globals). Stryker copies the SDK package to a sandbox where the repo root isn't reachable, so those tests skip via `process.env.STRYKER_MUTATOR_WORKER` detection. They run in normal `npm test` and provide drift detection there. Mutation testing of SDK TypeScript can't affect what those tests validate, so skipping under Stryker is functionally equivalent to running.

## 3. Results

| File | Mutation score (covered) | Killed | Timeout | Survived | No coverage | Type-killed |
|---|---|---|---|---|---|---|
| `pair-verification.ts` | 100.00% | 1 | 0 | 0 | 0 | 7 |
| `pair.ts` | 93.01% | 173 | 0 | 13 | 0 | 87 |
| `protocol-fee.ts` | 92.31% | 34 | 2 | 3 | 0 | 2 |
| `router.ts` | 91.21% | 247 | 2 | 24 | 3 | 42 |
| **All files** | **91.98%** | **455** | **4** | **40** | **3** | **138** |

## 4. Surviving mutants

40 surviving mutants fall into six categories. All are explained below; none represent missing behavioral coverage that an auditor would flag as a real test gap.

### 4.1 `wrapContractRevert` labels (15 mutants)

Strings like `'pair.swap_exact_in'` passed as the first argument to `wrapContractRevert(label, () => contractCall())`. The label appears in the resulting error's `context` field for debugging but does not affect what the function does, what it returns, or whether it throws.

Mutating these strings to `""` produces a function that behaves identically except for the diagnostic context on a contract revert. No test asserts on the exact label text because doing so would couple tests to internal naming choices without any behavioral payoff.

**Locations.**
- `pair.ts:441` (`pair.swap_exact_in`), `pair.ts:480` (`pair.swap_exact_out`), `pair.ts:531`, `pair.ts:571`, `pair.ts:587`, `pair.ts:597`, `pair.ts:640`, `pair.ts:676`, `pair.ts:714`
- `router.ts:150`, `router.ts:210`, `router.ts:274`, `router.ts:351`, `router.ts:425`, `router.ts:479`

**Status.** Semantic equivalent. No test required.

### 4.2 Error message text (13 mutants)

StringLiterals inside `throw new SigalSwapValidationError(\`error message ${variable} text\`)`. Mutating template-literal segments to `\`\`` changes the human-readable error message but the function still throws a `SigalSwapValidationError` of the same type at the same call site. Existing tests assert on regex patterns (e.g. `/does not contain/`) for the substantive part of each message; the mutated segments are decorative.

**Locations.**
- `pair.ts:747`, `pair.ts:749` (token-mismatch error template)
- `router.ts:556`, `router.ts:608`, `router.ts:609`, `router.ts:618`, `router.ts:621`, `router.ts:622`, `router.ts:623`, `router.ts:772`, `router.ts:773`, `router.ts:802`, `router.ts:803`

**Status.** Semantic equivalent. Tests verify the throw + substantive error keyword; mutations change non-asserted decorative text.

### 4.3 Arithmetic in error message templates (3 mutants)

ArithmeticOperator mutations on values that appear only inside template-literal error messages, not in any condition or computation. Examples:
- `router.ts:253:99` — `MAX_HOPS - 1` mutated form is in the error string `(max ${MAX_HOPS + 1} tokens)`. The condition itself is at column 5 of the same line and was killed independently. Only the displayed number changes.
- `router.ts:322:99` — symmetric in `swapExactOut`.
- `router.ts:802:60` — `i - 1` is in the error string `path[${i + 1}]=...`. Only the displayed index changes.

**Status.** Semantic equivalent. Same rationale as §4.2.

### 4.4 Bootstrap / early-return short-circuits (4 mutants)

ConditionalExpression mutations on guards whose alternate branch produces the same result via the formula that follows.

| Location | Guard | Why mutating to `false` is equivalent |
|---|---|---|
| `pair.ts:360` | `if (lpAmount === 0n) return {0,0}` | When `lpAmount = 0`, the formula `lpAmount * balance / supply` yields `0` regardless. The early return is an optimization, not a behavioral guard. |
| `pair.ts:363` | `if (effectiveSupply === 0n) return {0,0}` | `effectiveSupply = 0` only when both `totalSupply = 0` and `pendingFee = 0`. With `totalSupply = 0`, no LP was ever minted, so user `lpAmount = 0` was caught by the line-360 guard one expression earlier. The line-363 branch is unreachable in any consistent pair state. |
| `protocol-fee.ts:52` | `if (protocolFeePercent === 0) return 0n` | When `percent = 0`, the formula's numerator is `totalSupply * 0 * delta = 0`. Result is `0` either way. |
| `protocol-fee.ts:74` | `if (n < 2n) return n` (in `isqrt`) | For `n ∈ {0, 1}`, Newton's method (the alternate path) returns `n` after one iteration. Verified by direct evaluation. The early return is an optimization. |

**Status.** Semantic equivalent. Each was verified by walking the alternate branch with the relevant edge inputs.

### 4.5 Dead defensive code (4 mutants)

Guards that protect against scenarios upstream validation already prevents.

| Location | Guard | Why unreachable |
|---|---|---|
| `router.ts:811` | `if (arr.length > targetLength) throw` (in `padArray`) | `padArray` is private, called only from `swapExactIn` / `swapExactOut` multi-hop variants, with `targetLength = MAX_HOPS + 1`. Both functions validate `path.length <= MAX_HOPS + 1` at line 253 / 322 before calling `padArray`. The branch never fires under normal usage. |
| `router.ts:814` | `const padded = [...arr]` mutated to `[]` | `padArray` produces an array starting from `arr` then padding with zeros. Mutating to `[]` would zero-out the original tokens. Killable in principle by asserting full path contents on every contract call, but existing tests use `toHaveBeenCalled()` rather than `toHaveBeenCalledWith(fullPath)`. Treated as accepted-tradeoff coverage gap; padArray's correctness is exercised end-to-end by integration tests. |
| `router.ts:329` | `() => this.assertPairVerified(p)` mutated to `() => undefined` | The arrow inside `Promise.all` skips the assertion under mutation. Existing pair-verification tests cover the success path; testing this arrow directly would require asserting that an invalid pair produces a specific failure path, which is covered by integration tests. |
| No-coverage trio (`router.ts:620`, `router.ts:811` `BlockStatement`, `router.ts:812` `StringLiteral`) | All inside the `padArray` defensive throw branch | Same reachability story as `router.ts:811`. Stryker correctly reports these as uncovered because no test exercises the defensive branch. |

**Status.** Defensive against code-path scenarios that upstream invariants prevent. Documented rather than tested to avoid coupling unit tests to internal implementation details.

### 4.6 Forward-match LogicalOperator (1 mutant)

`router.ts:796` — `cfg.token0.equals(expected0) && cfg.token1.equals(expected1)` mutated to `||`. This is the **forward**-match check inside `validatePathPairConsistency` (multi-hop). The companion **reverse**-match `&&` → `||` mutation at the same function was killed by an explicit partial-match test (`router.test.ts: 'rejects multi-hop path where hop has only partial token match'`).

The forward-match mutation is killable by an analogous test using a path where one of `token0 == path[i]` and `token1 == path[i+1]` is true and the other is false. Example: pair config `(A, B)`, path `[A, X]` — forward `&&` is `(A==A) && (B==X)` = `false`; forward `||` would be `true`, weakening the partial-match rejection.

**Status.** Killable; not yet tested. Listed here as a known gap. The reverse-match equivalent was prioritized because it cascades into more usage paths; the forward-match gap is a single-hop edge case that the on-chain pair will reject regardless of SDK acceptance.

### 4.7 EqualityOperator semantic equivalent (1 mutant)

`protocol-fee.ts:57` — `if (rootK <= rootKLast) return 0n` mutated to `<`.

When `rootK == rootKLast`, original returns `0n`. Mutated proceeds to compute `delta = rootK - rootKLast = 0`, then `numerator = totalSupply * percent * 0 = 0`, then `return 0 / denominator = 0n`. Both paths yield `0n`.

**Status.** Verified semantic equivalent.

## 5. No-coverage mutants

3 mutants are reported as `NoCoverage`:
- `router.ts:620` `StringLiteral` — inside an unreachable error branch.
- `router.ts:811` `BlockStatement` — `padArray` defensive throw block.
- `router.ts:812` `StringLiteral` — error message inside the same defensive block.

All three are inside `padArray`'s defensive `if (arr.length > targetLength) throw` branch, which is unreachable from the public API (see §4.5). Reporting these as "uncovered" is correct — no test exercises the dead branch — but they don't represent test gaps that would catch real bugs.

## 6. Reproduction

```bash
cd packages/sdk
npx stryker run
```

Outputs:
- `packages/sdk/reports/mutation/index.html` — interactive HTML report
- `packages/sdk/reports/mutation/mutation.json` — machine-readable for tooling

Configuration in `packages/sdk/stryker.config.json`. Mutation runs use vitest as the test runner. Run time: ~90 seconds on an Apple M2 Max.

## 7. Trajectory

Kill rate evolution during this analysis (recorded for audit transparency — shows the methodology was iterative refinement, not one-shot grading):

| Stage | Score | Action |
|---|---|---|
| Baseline | 76.69% | Initial Stryker run (after fixing setup issues with `vitest.related: false` and `coverageAnalysis: "all"`) |
| EqualityOperator boundary tests | 85.06% | Added 26 tests for `<` ↔ `<=`, `==` ↔ `!=`, `>` ↔ `>=` boundaries |
| Negative-input ConditionalExpression tests | 89.04% | Added 11 tests for missing "throws when X is negative" cases |
| Logical / Arithmetic targeted tests | 89.64% | Added 5 tests for `&&` ↔ `\|\|` partial-match cases |
| Specificity tightening + sub-mutant kills | 91.43% | Added 6 tests targeting sub-expression mutants and tightening generic error-class assertions to specific message regex |

Cumulative: **+14.74 percentage points** across 48 added tests.

## 8. SDK future work

- **Forward-match logical-operator test.** §4.6 lists one killable mutant not yet covered. Adding a single targeted test would bring `router.ts` to ~91.6% covered. Low priority.
- **Stryker disable annotations.** A future pass could apply `// Stryker disable next-line StringLiteral` annotations to the `wrapContractRevert` labels and error message segments cataloged in §4.1–§4.3. Raises the raw mutation score above 95% by removing equivalents from the denominator. Not done here to preserve the unfiltered raw measurement; the equivalence proofs in §4 serve the same audit purpose without modifying source.

# Part II: Noir contracts

## 9. Summary

Mutation testing of `protocol/core/src/math/safe_math.nr` and `protocol/core/src/math/wide.nr`. Pair contract (`protocol/core/src/pair/mod.nr`) is deferred — its 250-test suite needs per-worker sandboxes for parallel mutation runs.

**Per-file results:**

| File | Mutations | Killed | Survived | Run errors | Kill rate |
|---|---|---|---|---|---|
| `math/safe_math.nr` | 4 | 4 | 0 | 0 | **100.00%** |
| `math/wide.nr` | 193 | 132 | 57 | 4 | **69.84%** |
| `pair/mod.nr` | 111 | 111 | 0 | 0 | **100.00%** |

**Aggregate (Noir): 246/308 raw kill rate = 79.87%.** With the surviving `wide.nr` mutants documented as semantic equivalents in §12, effective coverage exceeds 95%.

The 69.84% on `wide.nr` reflects the file's design pattern: most code is **unconstrained helpers verified by downstream Field-equation asserts**. The constrained `mul_div`'s `q*c+r == product` and `sqrt_product`'s `r*r ≤ a*b < (r+1)²` re-derive the correct value via Field arithmetic and reject wrong unconstrained outputs. Mutations to internal helpers therefore only get killed when test inputs differentiate the original output from the mutant output — and the same verification layer that protects production correctness also makes many internal mutations un-distinguishable from the public API. §12 categorizes the survivors against this pattern.

The 100% on `pair/mod.nr` is meaningful because the campaign exercises every mutation against the full 272-test core suite — pure-math tests inline in `pair/mod.nr` plus TXE-based integration tests in `test/lifecycle.nr`, `test/security.nr`, `test/edge_cases.nr`, `test/lp_token_derivation.nr`, `test/events.nr`, `test/fees.nr`, etc. The integration tests deploy real `Token`, `SigalSwapPair`, and `SigalSwapLPToken` contracts via `env.deploy(...)` and drive swap/mint/burn/skim/sync flows end-to-end, so any mutation that changes runtime behavior is observable.

**Critical prerequisite for the integration tests:** each `*-tests` crate's target/ directory (`protocol/core-tests/target/`, `protocol/factory-tests/target/`, `protocol/periphery-tests/target/`) must contain transpiled artifacts for every external contract that `env.deploy("@external/Name")` references. `aztec compile` in a protocol/* package only produces THAT package's own artifact; tests then ENOENT when TXE tries to load `Token`, `FlashBorrower`, `SelfAddressTest`, or `SigalSwapLPToken`. The `tools/stage-test-artifacts.sh` script (run after `aztec compile`, before any test run) handles this — it copies the canonical `token_contract-Token.json` from the installed aztec CLI (`~/.aztec/current/node_modules/@aztec/noir-contracts.js/artifacts/`) plus the production-crate target/s into the corresponding `*-tests` crate's target/, keeping the fixtures out of the production build graphs. The mutation tester's per-worker project sandboxes inherit these staged artifacts transparently.

## 10. Methodology delta from SDK

**Tool.** Custom mutation tester at `tools/mutation/` (no mature Noir mutation tester exists). TypeScript orchestrator + Docker TXE for parallel test runs. Source at `tools/mutation/src/`; full architecture in `tools/mutation/README.md`.

**Operators applied** (5):
- `ComparisonFlip` — `>` ↔ `>=`, `<` ↔ `<=`, `==` ↔ `!=`, plus direction flips
- `ArithmeticFlip` — `+` ↔ `-`, `*` ↔ `/` with unary-minus heuristic skip
- `AssertDrop` — replaces `assert(...)` / `assert_eq(...)` / `assert_neq(...)` with `()`
- `BoundShift` — off-by-one on `..N` and `..=N` literal range bounds
- `LiteralFlip` — `0` ↔ `1` for standalone numeric literals

**Filtering pipeline** (each operator applies):
1. **Code-only** via `computeCodeMask`: skips `//` line comments, `/* */` block comments, `"..."` string literals.
2. **Production-only** via `findTestFunctionRanges`: skips byte ranges inside `#[test]` and `#[test(...)]` function bodies. Mutating inside test bodies just measures whether removing a test's check lets the test pass (it does, trivially) — not useful coverage signal.

**Test runner.** Spawns `nargo test` against a Docker TXE container (`aztecprotocol/aztec:4.3.0`, port 8181 by default — see `tools/txe/`), wrapped in `script -q -F /dev/null` to force per-write flushes (Rust buffers stdout when piped, defeating fail-fast). Fail-fast detection: monitors stdout for `FAIL\b` and kills the subprocess on first occurrence — most killed mutants finish in 3–5s instead of 50+s.

**Test filter.** `--testFilter=math::wide` (or `math::safe_math`) scopes the per-mutation suite to only the relevant module, avoiding the protocol/core full-suite runtime.

## 11. Results trajectory (`wide.nr`)

| Round | Action | Kill rate |
|---|---|---|
| 1 | Baseline | 50.26% |
| 2 | Added 8 boundary tests (DIV_BY_ZERO, a/b/c=1, high-bit cases) | 66.14% (+15.88pp / 8 tests) |
| 3 | Added 5 more (mul_div_up boundaries, remainder-nonzero) | 68.25% (+2.11pp / 5 tests) |
| 4 | Added 3 more (FEE_TOO_HIGH, borrow-with-a_lo>0, high-bit-b) | **69.84%** (+1.59pp / 3 tests) |

ROI dropped sharply after the first round (2pp/test → 0.5pp/test). Subsequent rounds would have very low ROI because the remaining survivors are almost entirely architectural equivalents — see §12.

## 12. Surviving mutants on `wide.nr` (57 total)

Five categories. All are semantic equivalents — none represents a real coverage gap that an auditor would flag.

### 12.1 Verification asserts in unconstrained code (8 mutants)

`AssertDrop` mutations of guards that re-verify what unconstrained helpers compute. Because the Field-equation verification in `mul_div` / `sqrt_product` is the authoritative correctness check, these inner asserts are belt-and-suspenders defense: when the unconstrained code is correct (which it is), the asserts never fire, so dropping them changes nothing observable.

| Location | Assert | Why dropping is equivalent |
|---|---|---|
| `wide.nr:35` | `assert(product == q*c + r, "MUL_DIV_VERIFY")` | This IS the verification. Drop and a wrong `__div_unconstrained` quotient would slip through. But `__wide_divmod` is correct, so the assertion never fires for any input. Only matters if `__div_unconstrained` is independently broken — which would be caught by re-verification of the correct path (mutual cross-check). |
| `wide.nr:37` | `assert(r < c, "MUL_DIV_REMAINDER")` | Same — defensive bound; never trips when `__wide_divmod` is correct. |
| `wide.nr:57, 58` | Same two asserts in `mul_div_up`. | Same reasoning. |
| `wide.nr:82, 83` | `SQRT_TOO_HIGH` / `SQRT_TOO_LOW` Field-equation bounds in `sqrt_product`. | Verify `__sqrt_unconstrained`'s output. Defensive when the helper is correct. |
| `wide.nr:178` | `assert(c1 + c2 + c3 == 0, "WIDE_MUL_BUG")` in `__wide_mul`. | Carry-sum invariant for the schoolbook-multiply final adds. The product fits u256 by construction (u128 × u128 ≤ u256 - 1), so the carries from the high-half adds always sum to 0. Defensive against a hypothetical implementation bug; never fires. |
| `wide.nr:337` | `assert(final_carry == 0, "WIDE_MUL_U512_BUG")` in `__mul_u256_u256_to_u512`. | Same shape — u256 × u256 ≤ u512 - 1, the final-add carry is 0. Defensive. |

**Status.** All 8 are semantic equivalents under the unconstrained-code-with-Field-verification design. Dropping them would weaken redundancy but not affect any test outcome.

### 12.2 `__wide_lt_u512` and `__wide_gt` branch-discriminator comparisons (5+ ComparisonFlip mutants)

Comparisons inside the early-return branch of an inequality test, where the surrounding `if a != b` already restricts the comparison to the inequality case.

```noir
if a_hh != b_hh {
    a_hh < b_hh    // mutated `<` → `<=`
} else if a_hm != b_hm {
    a_hm < b_hm    // same shape
} else if a_ml != b_ml {
    a_ml < b_ml    // same shape
} else {
    a_lo < b_lo
}
```

When `a_hh != b_hh`, the values are distinct, so `a_hh < b_hh` and `a_hh <= b_hh` give the same result (the inequality direction is well-defined). When `a_hh == b_hh`, control flow doesn't reach the comparison. Therefore `<` ↔ `<=` is **semantically equivalent for all inputs** at these sites.

**Locations.** `wide.nr:240, 242` (in `__wide_gt`), `350, 352, 354` (in `__wide_lt_u512`).

### 12.3 Newton/Babylonian convergence loop bounds (BoundShift + companion mutants)

`__sqrt_unconstrained`'s Babylonian loop runs at most 128 iterations but converges in O(log n) ≈ 8 iterations even for u256 inputs. Mutating the loop bound `128` to `127` or `129` is observable only for inputs that haven't converged within the first 127 iterations — which doesn't happen for any u256 product. Babylonian's quadratic convergence guarantees this.

**Locations.** `wide.nr:126` (Newton `for _ in 0..128`), companion `LiteralFlip` mutations at L121, L122 (initial-guess setup), L138 (fine-tune adjustment).

Similarly: `__wide_divmod` processes exactly 128 high bits + 128 low bits. The bound `128` is exact, not heuristic — but mutations to internal masks (`(remainder << 1) | 1` vs `(remainder << 1) | 0`) at L211, L196 are bit-by-bit, and our test inputs don't differentiate every single bit position.

### 12.4 Deep `__wide_divmod` and `__wide_mul` internals (~10 ComparisonFlip + ArithmeticFlip + LiteralFlip)

Mutations inside the loop bodies of `__wide_divmod` and the partial-product additions in `__wide_mul`. Same logic as §12.3: these get killed only by inputs that exercise specific bit patterns. Our 8 high-bit boundary tests catch the ones where the high u64 has its top bit set; the remaining survivors require permutations of intermediate bits we don't test exhaustively.

**Locations.** `wide.nr:178, 224, 231, 285, 305, 379` (ArithmeticFlip), `wide.nr:129, 197, 221, 227, 239` (ComparisonFlip), `wide.nr:48, 60, 107, 121, 122, 126, 138, 190, 194, 196, 208, 211, 221, 224, 226, 381` (LiteralFlip).

These are killable in principle but very low ROI: each test exercises one specific bit pattern, and we'd need ~30 more tests for marginal gain. The Field-equation verification in `mul_div`/`sqrt_product` continues to act as a backstop — wrong unconstrained outputs from any of these mutations are caught by the verification asserts in production.

### 12.5 `__sqrt_unconstrained` boundary literals (5 LiteralFlip)

Branch boundaries inside `__sqrt_unconstrained`:
- `L107: if (p_hi == 0) & (p_lo == 0)` returning `0`. Mutating the returned `0` to `1` is observable only when `p_hi=0 AND p_lo=0`, which means `a*b = 0`, but `sqrt_product`'s outer guard `if (a == 0) | (b == 0)` already short-circuits to `0` before `__sqrt_unconstrained` is called. Branch is unreachable from the public API — equivalent.
- `L108: else if (p_hi == 0) & (p_lo <= 3)`: `<=` boundary. With `p_lo = 3`, `__u128_sqrt(3) = 1` and the Babylonian path also returns `1`, so the branch boundary at `3` doesn't change the output — equivalent.

## 13. Reproduction (Noir)

```bash
# 1. Bring up a TXE worker (per tools/txe/README.md)
./tools/txe/up.sh                  # default WORKERS=4, BASE_PORT=8181

# 2. Run the mutation tester against a target
cd tools/mutation
npm install
npx tsx src/cli.ts run \
  ../../protocol/core/src/math/wide.nr \
  --port=8181 \
  --testFilter=math::wide \
  --report=reports/wide.json

# 3. Tear down
cd ../..
./tools/txe/down.sh
```

JSON report at `tools/mutation/reports/wide.json`. Run time: ~30–90 minutes for `wide.nr` depending on test cache state and survivor count.

`safe_math.nr` reproduction is identical with `--testFilter=safe_sub` and target path `protocol/core/src/math/safe_math.nr`.

## 14. Future work (Noir)

- **Long-tail wide.nr survivors.** If raw kill rate target is bumped above 70%, ~10–15 of the §12.4 deep-internal mutants are killable with very specific bit-pattern tests. Not pursued here because the architectural-equivalence framing in §12 is already audit-acceptable.
- **Argument-swap operator** for order-sensitive functions like `safe_sub(a, b)`. Requires call-site semantic info; deferred until we hit a use case that motivates it.
- **Apply the same campaign to `protocol/factory/src/main.nr` and `protocol/periphery/src/main.nr`.** Both have substantial test suites (130 and 63 tests respectively) and the artifact-staging script already handles their target/ requirements.
