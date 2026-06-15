#!/usr/bin/env node
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 SigalSwap LLC

// Postcodegen step: ensure every TS wrapper in `src/artifacts/` has its
// imported JSON next to it on disk, then collapse cross-compile import paths
// to local relative paths. Replaces an explicit cp list -- the JSONs to copy
// are derived from the wrappers' actual imports, so adding a new contract
// (or a new test-fixture cross-compile) requires no manual list maintenance.
//
// Order of operations:
//   1. Drop wrappers in WRAPPER_DROP_LIST (codegen produces them as a
//      side-effect of cross-compile dependencies; the SDK has no use for
//      them as TS).
//   2. Walk every remaining wrapper, extract `from '<path>.json'` imports,
//      and ensure each JSON exists in `src/artifacts/` -- copying from the
//      first matching cross-compile target dir, or from noir-contracts.js
//      for the standard Token artifact.
//   3. Rewrite wrapper imports of the form
//      `'../../../../protocol/.../target/<json>'` to `'./<json>'` so the
//      wrapper resolves locally regardless of how it was generated.
//
// Failure modes:
//   - A wrapper imports a JSON that no target dir provides -> hard fail
//     ("no JSON source found for X"). Surfaces missing-codegen at postcodegen
//     time, before tsc.

import {
  readFileSync,
  writeFileSync,
  readdirSync,
  copyFileSync,
  existsSync,
  unlinkSync,
  statSync,
} from 'node:fs';
import { dirname, resolve, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const __dirname = dirname(fileURLToPath(import.meta.url));
const SDK_ROOT = resolve(__dirname, '..');
const REPO_ROOT = resolve(SDK_ROOT, '../..');
const ARTIFACTS_DIR = resolve(SDK_ROOT, 'src/artifacts');

// Wrappers that codegen produces as a side-effect of cross-compile deps but
// the SDK never uses (their contracts are deployed only via Noir TXE tests).
// Listing here keeps `src/artifacts/` from accumulating orphans whose JSON
// imports would otherwise need to be tracked or excluded.
const WRAPPER_DROP_LIST = new Set([
  'SelfAddressTest.ts',
]);

// Cross-compile target dirs to search for JSONs. Order matters only when a
// JSON appears in multiple dirs (first match wins) -- in practice each JSON
// is unique to its owning package's target/.
const TARGET_DIRS = [
  resolve(REPO_ROOT, 'protocol/core/target'),
  resolve(REPO_ROOT, 'protocol/periphery/target'),
  resolve(REPO_ROOT, 'protocol/factory/target'),
  resolve(REPO_ROOT, 'protocol/lp-token/target'),
  ...readdirSync(resolve(REPO_ROOT, 'protocol/test-contracts'))
    .filter((d) => statSync(resolve(REPO_ROOT, 'protocol/test-contracts', d)).isDirectory())
    .map((d) => resolve(REPO_ROOT, 'protocol/test-contracts', d, 'target')),
].filter(existsSync);

function findJsonImports(tsSource) {
  const matches = tsSource.matchAll(/from\s+['"]([^'"]+\.json)['"]/g);
  return Array.from(matches, (m) => m[1]);
}

function locateJson(jsonName) {
  for (const dir of TARGET_DIRS) {
    const candidate = resolve(dir, jsonName);
    if (existsSync(candidate)) return candidate;
  }
  // Aztec's standard Token isn't in any protocol/*/target -- it lives in the
  // npm package. Fall back here only when the cross-compile copy isn't found
  // (which can happen on a clean clone before any contract has been built).
  if (jsonName === 'token_contract-Token.json') {
    const noirContractsRoot = dirname(require.resolve('@aztec/noir-contracts.js'));
    const tokenPath = resolve(noirContractsRoot, '..', 'artifacts', jsonName);
    if (existsSync(tokenPath)) return tokenPath;
  }
  return null;
}

// Step 1: drop unwanted wrappers.
let dropped = 0;
for (const name of WRAPPER_DROP_LIST) {
  const fp = resolve(ARTIFACTS_DIR, name);
  if (existsSync(fp)) {
    unlinkSync(fp);
    dropped += 1;
  }
}

// Step 1b: prune codegenCache entries for dropped wrappers. `aztec codegen`
// writes a per-contract hash entry to `codegenCache.json` regardless of
// whether the matching wrapper is later removed; without this step the
// cache file grows entries for SDK-orphan contracts on every codegen run.
const CACHE_PATH = resolve(SDK_ROOT, 'codegenCache.json');
const DROPPED_CONTRACT_NAMES = new Set(
  Array.from(WRAPPER_DROP_LIST, (w) => w.replace(/\.ts$/, '')),
);
let cachePruned = 0;
if (existsSync(CACHE_PATH)) {
  const cache = JSON.parse(readFileSync(CACHE_PATH, 'utf-8'));
  for (const [key, entry] of Object.entries(cache)) {
    if (DROPPED_CONTRACT_NAMES.has(entry.contractName)) {
      delete cache[key];
      cachePruned += 1;
    }
  }
  if (cachePruned > 0) {
    writeFileSync(CACHE_PATH, JSON.stringify(cache, null, 2) + '\n');
  }
}

// Step 2: derive JSON copy list from wrapper imports.
const wrapperFiles = readdirSync(ARTIFACTS_DIR).filter(
  (f) => f.endsWith('.ts') && !f.endsWith('.test.ts'),
);

const requiredJsons = new Set();
for (const wrapper of wrapperFiles) {
  const src = readFileSync(resolve(ARTIFACTS_DIR, wrapper), 'utf-8');
  for (const importPath of findJsonImports(src)) {
    requiredJsons.add(basename(importPath));
  }
}

let copied = 0;
for (const jsonName of requiredJsons) {
  const target = resolve(ARTIFACTS_DIR, jsonName);
  if (existsSync(target)) {
    // Already present from a prior postcodegen run -- refresh from source so
    // a stale local copy doesn't shadow a freshly recompiled artifact.
    const source = locateJson(jsonName);
    if (source && source !== target) {
      copyFileSync(source, target);
      copied += 1;
    }
    continue;
  }
  const source = locateJson(jsonName);
  if (!source) {
    throw new Error(
      `copy-artifacts: no JSON source found for ${jsonName} ` +
        `(referenced by a wrapper in src/artifacts/). Searched: ` +
        TARGET_DIRS.join(', '),
    );
  }
  copyFileSync(source, target);
  copied += 1;
}

// Step 3: rewrite cross-compile import paths to local relative paths.
let rewritten = 0;
for (const wrapper of wrapperFiles) {
  const fp = resolve(ARTIFACTS_DIR, wrapper);
  const src = readFileSync(fp, 'utf-8');
  const out = src.replace(
    /'\.\.\/\.\.\/\.\.\/\.\.\/protocol\/[^']+\/target\/([^']+\.json)'/g,
    "'./$1'",
  );
  if (out !== src) {
    writeFileSync(fp, out);
    rewritten += 1;
  }
}

console.log(
  `copy-artifacts: dropped ${dropped} wrapper(s), pruned ${cachePruned} ` +
    `cache entr${cachePruned === 1 ? 'y' : 'ies'}, refreshed ${copied} ` +
    `JSON(s), rewrote ${rewritten} wrapper import(s)`,
);
