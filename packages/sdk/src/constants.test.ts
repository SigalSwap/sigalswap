// Drift canary: each typed SDK constant must match the contract source it
// mirrors. If a Noir global changes, the SDK constant must change in
// lock-step or this test fails. The grep approach beats hardcoded line
// numbers: refactors that move a global within its file still pass, but a
// value change always trips us.

import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import {
  MINIMUM_LIQUIDITY,
  TIMELOCK_DELAY_SECONDS,
  TIMELOCK_WINDOW_SECONDS,
  MAX_INTERFACE_FEE_BIPS,
  LP_TOKEN_SALT,
  LP_TOKEN_CLASS_ID,
} from './constants.js';
import { MAX_HOPS } from './router.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, '../../..');

function readSource(relativePath: string): string {
  return readFileSync(resolve(REPO_ROOT, relativePath), 'utf-8');
}

/**
 * Match a `pub global NAME: Type = VALUE;` declaration in Noir source.
 * Returns the captured value (trimmed).
 */
function findGlobal(src: string, name: string): string {
  // Allow optional newline + leading whitespace before the value (some
  // globals split a long Field literal onto a second line).
  const re = new RegExp(`pub\\s+global\\s+${name}\\s*:\\s*[A-Za-z0-9_]+\\s*=\\s*([\\s\\S]+?);`, 'm');
  const m = src.match(re);
  if (!m) throw new Error(`global ${name} not found in source`);
  return m[1].trim();
}

// Stryker copies the SDK package to a sandbox under packages/sdk/.stryker-tmp/
// for mutation testing; the protocol/ source tree at the repo root is not in
// that sandbox, so REPO_ROOT-relative reads ENOENT. These tests verify SDK
// constants match Noir source, which mutation testing of TypeScript files
// cannot affect — skipping under Stryker is functionally equivalent to running.
const skipUnderStryker = !!process.env.STRYKER_MUTATOR_WORKER;

describe.skipIf(skipUnderStryker)('SDK constants match contract globals', () => {
  it('MINIMUM_LIQUIDITY matches pair/mod.nr', () => {
    const src = readSource('protocol/core/src/pair/mod.nr');
    expect(findGlobal(src, 'MINIMUM_LIQUIDITY')).toBe(`${MINIMUM_LIQUIDITY}`);
  });

  it('TIMELOCK_DELAY matches factory/main.nr', () => {
    const src = readSource('protocol/factory/src/main.nr');
    expect(findGlobal(src, 'TIMELOCK_DELAY')).toBe(`${TIMELOCK_DELAY_SECONDS}`);
  });

  it('TIMELOCK_WINDOW matches factory/main.nr', () => {
    const src = readSource('protocol/factory/src/main.nr');
    expect(findGlobal(src, 'TIMELOCK_WINDOW')).toBe(`${TIMELOCK_WINDOW_SECONDS}`);
  });

  it('MAX_INTERFACE_FEE_BIPS matches periphery/libraries/mod.nr', () => {
    const src = readSource('protocol/periphery/src/libraries/mod.nr');
    expect(findGlobal(src, 'MAX_INTERFACE_FEE_BIPS')).toBe(`${MAX_INTERFACE_FEE_BIPS}`);
  });

  it('LP_TOKEN_SALT matches core/main.nr', () => {
    const src = readSource('protocol/core/src/main.nr');
    expect(findGlobal(src, 'LP_TOKEN_SALT')).toBe(`${LP_TOKEN_SALT.toBigInt()}`);
  });

  it('LP_TOKEN_CLASS_ID matches core/main.nr', () => {
    const src = readSource('protocol/core/src/main.nr');
    // The hex literal in source is multi-line; collapse whitespace before compare.
    const found = findGlobal(src, 'LP_TOKEN_CLASS_ID').replace(/\s+/g, '');
    expect(found.toLowerCase()).toBe(LP_TOKEN_CLASS_ID.toString().toLowerCase());
  });

  it('MAX_HOPS matches periphery/libraries/mod.nr', () => {
    const src = readSource('protocol/periphery/src/libraries/mod.nr');
    expect(findGlobal(src, 'MAX_HOPS')).toBe(`${MAX_HOPS}`);
  });
});
