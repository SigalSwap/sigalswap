/**
 * Source-position scanner. Produces a per-byte boolean mask: `true` where
 * the byte is in code, `false` where it's in a comment or string literal.
 *
 * Operators consult this mask to avoid emitting candidates inside text
 * that doesn't affect program behavior — mutating a `<` inside `///`
 * doc-comment text or inside `"error message"` produces a survived mutant
 * that pollutes the report.
 *
 * Recognized non-code regions:
 *   `// ...` to end of line
 *   `/* ... *\/` (no nesting)
 *   `"..."` with `\"` escape and `\\` escape handling
 *
 * Char literals (`'a'`) are not recognized — Noir doesn't use C-style
 * char literals, and the `'` lifetime/label syntax in some Rust-likes
 * doesn't appear in Noir source we mutate.
 */

export function computeCodeMask(source: string): boolean[] {
  const mask: boolean[] = new Array<boolean>(source.length).fill(true);

  let i = 0;
  while (i < source.length) {
    const ch = source[i];
    const next = source[i + 1];

    if (ch === '/' && next === '/') {
      const newline = source.indexOf('\n', i);
      const end = newline === -1 ? source.length : newline;
      for (let j = i; j < end; j++) mask[j] = false;
      i = end;
      continue;
    }

    if (ch === '/' && next === '*') {
      const close = source.indexOf('*/', i + 2);
      const end = close === -1 ? source.length : close + 2;
      for (let j = i; j < end; j++) mask[j] = false;
      i = end;
      continue;
    }

    if (ch === '"') {
      let j = i + 1;
      while (j < source.length) {
        const c = source[j];
        if (c === '\\' && j + 1 < source.length) {
          j += 2;
          continue;
        }
        if (c === '"') {
          j++;
          break;
        }
        j++;
      }
      for (let k = i; k < j; k++) mask[k] = false;
      i = j;
      continue;
    }

    i++;
  }

  return mask;
}

/**
 * Find the matching closing paren for an opening paren at `openOffset`.
 * Walks paren depth, ignoring parens that fall in non-code regions per
 * the supplied mask. Returns the offset AFTER the closing paren, or -1
 * if no balanced match is found.
 */
export function findClosingParen(
  source: string,
  openOffset: number,
  mask: boolean[],
): number {
  if (source[openOffset] !== '(') {
    throw new Error(`findClosingParen: source[${openOffset}] is not '(', it is ${JSON.stringify(source[openOffset])}`);
  }
  let depth = 0;
  for (let i = openOffset; i < source.length; i++) {
    if (!mask[i]) continue;
    const ch = source[i];
    if (ch === '(') depth++;
    else if (ch === ')') {
      depth--;
      if (depth === 0) return i + 1;
    }
  }
  return -1;
}

/** Convert a byte offset into 1-based (line, column). */
export function lineColAt(source: string, offset: number): { line: number; column: number } {
  let line = 1;
  let column = 1;
  for (let i = 0; i < offset; i++) {
    if (source[i] === '\n') {
      line++;
      column = 1;
    } else {
      column++;
    }
  }
  return { line, column };
}

/** True when the character is part of a Noir identifier (letter, digit, underscore). */
export function isIdentChar(ch: string | undefined): boolean {
  if (ch === undefined) return false;
  return /[A-Za-z0-9_]/.test(ch);
}

/**
 * Find the matching `}` for an opening `{` at `openOffset`, balancing
 * across nested braces. Ignores braces inside non-code regions per the
 * supplied mask. Returns the offset AFTER the closing brace, or -1 if
 * unbalanced.
 */
export function findClosingBrace(
  source: string,
  openOffset: number,
  mask: boolean[],
): number {
  if (source[openOffset] !== '{') {
    throw new Error(
      `findClosingBrace: source[${openOffset}] is not '{', it is ${JSON.stringify(source[openOffset])}`,
    );
  }
  let depth = 0;
  for (let i = openOffset; i < source.length; i++) {
    if (!mask[i]) continue;
    const ch = source[i];
    if (ch === '{') depth++;
    else if (ch === '}') {
      depth--;
      if (depth === 0) return i + 1;
    }
  }
  return -1;
}

export interface ByteRange {
  start: number;
  end: number;
}

/**
 * Find the byte ranges of `#[test]` and `#[test(...)]` function bodies.
 * Mutating inside test bodies measures whether removing a test's check
 * lets the test still pass (it does, trivially), not whether the test
 * suite catches production-code regressions. Operators should exclude
 * these ranges from candidate generation.
 *
 * The ranges cover the entire `#[test...] ... fn name(...) { body }`,
 * so that comparison/arithmetic mutations inside the test body are also
 * skipped, not just `assert(...)` drops.
 */
export function findTestFunctionRanges(source: string): ByteRange[] {
  const mask = computeCodeMask(source);
  const ranges: ByteRange[] = [];

  // `#[test]` or `#[test(should_fail_with = "...")]` etc. The attribute
  // appears on its own line above the function in idiomatic Noir.
  const testAttrRegex = /#\[test(?:\b|\(|])/g;

  let match: RegExpExecArray | null;
  while ((match = testAttrRegex.exec(source)) !== null) {
    const attrStart = match.index;
    if (!mask[attrStart]) continue;

    // Find the `]` ending the attribute.
    let i = attrStart;
    let bracketDepth = 0;
    while (i < source.length) {
      if (mask[i]) {
        if (source[i] === '[') bracketDepth++;
        else if (source[i] === ']') {
          bracketDepth--;
          if (bracketDepth === 0) {
            i++;
            break;
          }
        }
      }
      i++;
    }
    // Now find the next `{` (the function body opener).
    while (i < source.length && (source[i] !== '{' || !mask[i])) i++;
    if (i >= source.length) continue;
    const close = findClosingBrace(source, i, mask);
    if (close === -1) continue;

    ranges.push({ start: attrStart, end: close });
  }
  return ranges;
}

/** True if `offset` falls within any of the supplied ranges. */
export function isInRange(offset: number, ranges: readonly ByteRange[]): boolean {
  for (const r of ranges) {
    if (offset >= r.start && offset < r.end) return true;
  }
  return false;
}
