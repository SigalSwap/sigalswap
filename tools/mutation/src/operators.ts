/**
 * Mutation operators for Noir source.
 *
 * Each operator scans the code regions of a file (skipping comments and
 * string literals via `computeCodeMask`) and emits one or more candidates
 * per site. The orchestrator runs each candidate independently.
 *
 * Catalog:
 *   ComparisonFlip   - `>` ↔ `>=`, `<` ↔ `<=`, `==` ↔ `!=`, plus direction
 *                      flips `>` ↔ `<` and `>=` ↔ `<=`. ~6 mutations per site.
 *   ArithmeticFlip   - `+` ↔ `-`, `*` ↔ `/`. Skips unary minus.
 *   AssertDrop       - Replaces `assert(...)` / `assert_eq(...)` /
 *                      `assert_neq(...)` calls with `()`. Removes the
 *                      runtime check; tests that exercise the asserted
 *                      condition should fail.
 *   BoundShift       - Off-by-one on `..LITERAL` and `..=LITERAL` ranges
 *                      (for-loop bounds). Mutates the literal to ±1.
 *   LiteralFlip      - Small-constant replacement: `0` ↔ `1`.
 *
 * Operators NOT implemented here (deferred):
 *   - Argument swaps for order-sensitive functions: requires call-site
 *     semantic info we don't have without a real parser.
 *   - Logical operator flips (`&` ↔ `|`, `&&` ↔ `||`): rarely appears
 *     in the math libraries; revisit when running on `pair/mod.nr`.
 */

import type { MutationCandidate, MutationOperator } from './types.js';
import {
  computeCodeMask,
  findClosingParen,
  findTestFunctionRanges,
  isIdentChar,
  isInRange,
  lineColAt,
} from './scanner.js';

// ----------------------------------------------------------------------
// ComparisonFlip
// ----------------------------------------------------------------------

const COMPARISON_FLIPS: Record<string, readonly string[]> = {
  '>': ['>=', '<'],
  '>=': ['>', '<='],
  '<': ['<=', '>'],
  '<=': ['<', '>='],
  '==': ['!='],
  '!=': ['=='],
};

export const ComparisonFlip: MutationOperator = {
  name: 'ComparisonFlip',
  candidates(source: string, filePath: string): MutationCandidate[] {
    const mask = computeCodeMask(source);
    const testRanges = findTestFunctionRanges(source);
    const out: MutationCandidate[] = [];

    let i = 0;
    while (i < source.length) {
      if (!mask[i] || isInRange(i, testRanges)) {
        i++;
        continue;
      }
      const two = source.slice(i, i + 2);

      // Two-char operators first (greedy).
      if (two === '>=' || two === '<=' || two === '==' || two === '!=') {
        for (const replacement of COMPARISON_FLIPS[two] ?? []) {
          out.push(makeCandidate(source, filePath, i, two, replacement, 'ComparisonFlip'));
        }
        i += 2;
        continue;
      }

      // Single-char `>` / `<`. Skip if part of a composite token.
      const ch = source[i];
      if (ch === '>' || ch === '<') {
        const prev = source[i - 1];
        const next = source[i + 1];
        const isComposite =
          next === '=' /* >= or <= caught above, defensive */ ||
          prev === '=' /* part of => */ ||
          prev === '-' /* part of -> */ ||
          prev === '<' /* part of <<, double-angle */ ||
          next === '<' /* part of <<, double-angle */ ||
          prev === '>' ||
          next === '>'; /* >> */
        if (!isComposite) {
          for (const replacement of COMPARISON_FLIPS[ch] ?? []) {
            out.push(makeCandidate(source, filePath, i, ch, replacement, 'ComparisonFlip'));
          }
        }
      }
      i++;
    }
    return out;
  },
};

// ----------------------------------------------------------------------
// ArithmeticFlip
// ----------------------------------------------------------------------

/**
 * Mutates binary `+`, `-`, `*`, `/` to their counterparts.
 *
 * Unary minus is skipped via a heuristic: if the non-whitespace character
 * preceding `-` is an operator, comma, opening paren, or `=`/`return`-like
 * context, we treat it as unary. The conservative bias is to mutate fewer
 * binary operators rather than corrupt unary syntax. False negatives (a
 * binary `-` we skip) just under-cover; false positives (mutating a unary
 * `-` to `+`) produce broken code that compileError's, which is fine but
 * adds noise.
 */
const ARITH_FLIPS: Record<string, string> = {
  '+': '-',
  '-': '+',
  '*': '/',
  '/': '*',
};

export const ArithmeticFlip: MutationOperator = {
  name: 'ArithmeticFlip',
  candidates(source: string, filePath: string): MutationCandidate[] {
    const mask = computeCodeMask(source);
    const testRanges = findTestFunctionRanges(source);
    const out: MutationCandidate[] = [];

    for (let i = 0; i < source.length; i++) {
      if (!mask[i] || isInRange(i, testRanges)) continue;
      const ch = source[i];
      const next = source[i + 1];
      const prev = source[i - 1];

      if (!ARITH_FLIPS[ch ?? '']) continue;

      // Skip composite assignment / arrow tokens.
      if (next === '=' /* +=, -=, *=, /= */) continue;
      if (ch === '-' && next === '>' /* -> */) continue;
      if (ch === '/' && (next === '/' || next === '*' /* comments handled by mask, defensive */)) continue;
      if (prev === '/' && ch === '/' /* second slash */) continue;

      // Skip unary minus.
      if (ch === '-' && isUnaryMinus(source, i)) continue;

      const replacement = ARITH_FLIPS[ch ?? ''];
      if (replacement === undefined) continue;
      out.push(makeCandidate(source, filePath, i, ch ?? '', replacement, 'ArithmeticFlip'));
    }
    return out;
  },
};

function isUnaryMinus(source: string, offset: number): boolean {
  // Walk backwards through whitespace. The first non-whitespace character
  // tells us whether `-` is in operand position (binary) or operator
  // position (unary).
  let j = offset - 1;
  while (j >= 0 && (source[j] === ' ' || source[j] === '\t')) j--;
  if (j < 0) return true;
  const ch = source[j];
  // Identifiers, digits, and closing brackets to the left → binary.
  if (isIdentChar(ch) || ch === ')' || ch === ']') return false;
  // Otherwise (operator, comma, opening paren, newline-after-statement-start
  // typically meaning continuation of expression), treat as unary.
  return true;
}

// ----------------------------------------------------------------------
// AssertDrop
// ----------------------------------------------------------------------

const ASSERT_FUNCTIONS = ['assert_neq', 'assert_eq', 'assert'] as const;

export const AssertDrop: MutationOperator = {
  name: 'AssertDrop',
  candidates(source: string, filePath: string): MutationCandidate[] {
    const mask = computeCodeMask(source);
    const testRanges = findTestFunctionRanges(source);
    const out: MutationCandidate[] = [];

    let i = 0;
    while (i < source.length) {
      if (!mask[i] || isInRange(i, testRanges)) {
        i++;
        continue;
      }
      // Match the LONGEST function name first (assert_neq before assert_eq
      // before assert) so a leading `assert_eq` isn't mis-classified as
      // `assert` followed by `_eq(`.
      let matched: string | null = null;
      for (const fn of ASSERT_FUNCTIONS) {
        if (source.slice(i, i + fn.length) !== fn) continue;
        if (source[i + fn.length] !== '(') continue;
        // Ensure this isn't part of a larger identifier (e.g. `assertion`).
        if (isIdentChar(source[i - 1])) continue;
        matched = fn;
        break;
      }
      if (!matched) {
        i++;
        continue;
      }
      const callStart = i;
      const openParen = i + matched.length;
      const callEnd = findClosingParen(source, openParen, mask);
      if (callEnd === -1) {
        i++;
        continue;
      }

      const original = source.slice(callStart, callEnd);
      out.push(
        makeCandidate(source, filePath, callStart, original, '()', 'AssertDrop', `Drop ${matched}(...)`),
      );
      i = callEnd;
    }
    return out;
  },
};

// ----------------------------------------------------------------------
// BoundShift (off-by-one on range bounds)
// ----------------------------------------------------------------------

/**
 * Matches `..NUM` and `..=NUM` patterns where NUM is a positive decimal
 * integer literal, and emits two candidates per site: bound + 1 and
 * bound - 1. Negative literals or expression bounds are skipped — getting
 * those right requires a real parser.
 */
export const BoundShift: MutationOperator = {
  name: 'BoundShift',
  candidates(source: string, filePath: string): MutationCandidate[] {
    const mask = computeCodeMask(source);
    const testRanges = findTestFunctionRanges(source);
    const out: MutationCandidate[] = [];
    const regex = /\.\.=?(\d+)/g;

    let match: RegExpExecArray | null;
    while ((match = regex.exec(source)) !== null) {
      // The range operator starts at match.index. The literal starts after `..` or `..=`.
      const dotsLen = source.startsWith('..=', match.index) ? 3 : 2;
      const literalStart = match.index + dotsLen;
      if (!mask[literalStart] || isInRange(literalStart, testRanges)) continue;

      const literal = match[1];
      if (literal === undefined) continue;
      const value = Number(literal);
      if (!Number.isFinite(value)) continue;

      const bumped = String(value + 1);
      const dropped = String(value - 1);

      out.push(makeCandidate(source, filePath, literalStart, literal, bumped, 'BoundShift', `bound ${literal} → ${bumped}`));
      // Avoid producing a useless `..0` from `..1` if value-1 < 0.
      if (value - 1 >= 0) {
        out.push(makeCandidate(source, filePath, literalStart, literal, dropped, 'BoundShift', `bound ${literal} → ${dropped}`));
      }
    }
    return out;
  },
};

// ----------------------------------------------------------------------
// LiteralFlip (small constants)
// ----------------------------------------------------------------------

/**
 * Flips `0` ↔ `1` in code. Only standalone numeric literals; subscripts
 * inside larger numbers (`10`, `100`) are skipped. Type-suffixed literals
 * like `0u128` are recognized: the leading digit is mutated and the
 * suffix is preserved (`0u128` → `1u128`).
 */
export const LiteralFlip: MutationOperator = {
  name: 'LiteralFlip',
  candidates(source: string, filePath: string): MutationCandidate[] {
    const mask = computeCodeMask(source);
    const testRanges = findTestFunctionRanges(source);
    const out: MutationCandidate[] = [];

    for (let i = 0; i < source.length; i++) {
      if (!mask[i] || isInRange(i, testRanges)) continue;
      const ch = source[i];
      if (ch !== '0' && ch !== '1') continue;
      // Standalone digit means surrounding chars aren't digit/letter/underscore.
      const prev = source[i - 1];
      if (isIdentChar(prev) && prev !== ' ') continue;
      const next = source[i + 1];
      // The literal stays standalone if next is end-of-token or a type suffix.
      // Reject if next is a digit (multi-digit number — only mutate the leading
      // digit if it's the only digit, which means the whole literal is 0 or 1).
      if (next !== undefined && /[0-9]/.test(next)) continue;
      // `.` followed by digit is a decimal — skip (Noir mostly uses ints in
      // protocol code, but be conservative).
      if (next === '.' && i + 2 < source.length && /[0-9]/.test(source[i + 2] ?? '')) continue;

      const replacement = ch === '0' ? '1' : '0';
      out.push(makeCandidate(source, filePath, i, ch, replacement, 'LiteralFlip'));
    }
    return out;
  },
};

// ----------------------------------------------------------------------
// Bundles
// ----------------------------------------------------------------------

/** All operators in the catalog. */
export const ALL_OPERATORS: readonly MutationOperator[] = [
  ComparisonFlip,
  ArithmeticFlip,
  AssertDrop,
  BoundShift,
  LiteralFlip,
];

/** Lookup an operator by its `name`. Returns undefined if unknown. */
export function operatorByName(name: string): MutationOperator | undefined {
  return ALL_OPERATORS.find((op) => op.name === name);
}

// ----------------------------------------------------------------------
// Helper
// ----------------------------------------------------------------------

function makeCandidate(
  source: string,
  filePath: string,
  offset: number,
  original: string,
  replacement: string,
  operatorName: string,
  description?: string,
): MutationCandidate {
  const { line, column } = lineColAt(source, offset);
  return {
    filePath,
    line,
    column,
    operatorName,
    original,
    replacement,
    description: description ?? `${original} → ${replacement}`,
  };
}
