/**
 * Mutation apply/restore primitives.
 *
 * The model is: hold the original source in memory, write the mutated source
 * to the same path on disk, run tests against it, then write the original
 * back. Crash-safety: restore() is callable in `finally` blocks and is
 * idempotent. The test runner subprocess must exit before restore so we
 * don't race with concurrent reads.
 *
 * These primitives operate in-place on the project tree (which is bind-mounted
 * into the TXE container), so only one mutation can be applied at a time.
 */

import { readFileSync, writeFileSync } from 'node:fs';
import type { MutationCandidate } from './types.js';

/**
 * Compute the offset of a (line, column) pair in a source string.
 * Both line and column are 1-based to match Noir compiler diagnostics.
 */
export function offsetOfLineCol(source: string, line: number, column: number): number {
  let offset = 0;
  let currentLine = 1;
  while (currentLine < line) {
    const nextNewline = source.indexOf('\n', offset);
    if (nextNewline === -1) {
      throw new Error(
        `offsetOfLineCol: line ${line} not found (file has ${currentLine} lines)`,
      );
    }
    offset = nextNewline + 1;
    currentLine++;
  }
  return offset + (column - 1);
}

/**
 * Snapshot the on-disk source for a file. The returned closure restores the
 * file to its captured contents when invoked.
 */
export function snapshot(filePath: string): () => void {
  const original = readFileSync(filePath, 'utf-8');
  let restored = false;
  return () => {
    if (restored) return;
    writeFileSync(filePath, original, 'utf-8');
    restored = true;
  };
}

/**
 * Apply a mutation to its target file in place. Asserts that the original
 * substring at the target location matches what the candidate claims, so a
 * stale candidate (file edited between scan and apply) fails fast instead
 * of silently corrupting the source.
 */
export function applyMutation(candidate: MutationCandidate): void {
  const source = readFileSync(candidate.filePath, 'utf-8');
  const offset = offsetOfLineCol(source, candidate.line, candidate.column);
  const found = source.slice(offset, offset + candidate.original.length);
  if (found !== candidate.original) {
    throw new Error(
      `applyMutation: stale candidate at ${candidate.filePath}:${candidate.line}:${candidate.column}. ` +
        `Expected ${JSON.stringify(candidate.original)}, found ${JSON.stringify(found)}. ` +
        `Did the file change between scan and apply?`,
    );
  }
  const mutated = source.slice(0, offset) + candidate.replacement + source.slice(offset + candidate.original.length);
  writeFileSync(candidate.filePath, mutated, 'utf-8');
}
