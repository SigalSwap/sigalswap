// Drift canary: every TS wrapper in src/artifacts/ that tsc compiles (i.e.,
// not listed in tsconfig.json's exclude) must have all of its imported JSON
// dependencies resolvable on disk.
//
// The codegen pipeline (npm run codegen) generates TS wrappers from contract
// JSON artifacts; the postcodegen step copies a curated subset of JSONs into
// src/artifacts/ and rewrites the wrappers' import paths to './<json>' for
// the locally-copied ones. If a new wrapper sneaks in whose JSON isn't on the
// copy list, OR a wrapper's import path doesn't get rewritten, OR a JSON gets
// deleted out from under a wrapper, this test fails -- catching the drift
// before tsc does, and pinning the failure to "the codegen pipeline is out
// of sync" rather than a vague "missing module" error days later.
//
// Test-fixture wrappers (AbusivePair, FlashBorrower, MockFactory, MockPairV2)
// are intentionally excluded from tsc and therefore from this canary as well
// -- they are deliberately not bundled and need no JSON guarantee.

import { describe, it, expect } from 'vitest';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const SDK_ROOT = resolve(__dirname, '..');
const ARTIFACTS_DIR = resolve(__dirname, 'artifacts');

function findJsonImports(tsSource: string): string[] {
  // Match `from '<path>.json'` or `from "<path>.json"` (single or double quotes).
  const matches = tsSource.matchAll(/from\s+['"]([^'"]+\.json)['"]/g);
  return Array.from(matches, (m) => m[1]);
}

function readExcludedArtifacts(): Set<string> {
  // Parse tsconfig.json's `exclude` list and pull out the artifact-wrapper
  // entries. The tsconfig may include a trailing comma or comments; strip
  // both before JSON.parse.
  const raw = readFileSync(resolve(SDK_ROOT, 'tsconfig.json'), 'utf-8');
  const stripped = raw
    .replace(/\/\/.*$/gm, '')
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/,(\s*[\]}])/g, '$1');
  const cfg = JSON.parse(stripped) as { exclude?: string[] };
  const excluded = new Set<string>();
  for (const entry of cfg.exclude ?? []) {
    if (entry.startsWith('src/artifacts/') && entry.endsWith('.ts')) {
      excluded.add(entry.slice('src/artifacts/'.length));
    }
  }
  return excluded;
}

describe('artifact wrappers reference resolvable JSONs', () => {
  const excluded = readExcludedArtifacts();
  const wrappers = readdirSync(ARTIFACTS_DIR).filter(
    (f) => f.endsWith('.ts') && !f.endsWith('.test.ts') && !excluded.has(f),
  );

  // If codegen hasn't run yet, this catches that as a failure of the suite
  // rather than a silent zero-test pass.
  it('artifacts/ has at least one production wrapper', () => {
    expect(wrappers.length).toBeGreaterThan(0);
  });

  for (const wrapper of wrappers) {
    it(`${wrapper} imports resolve to existing JSONs`, () => {
      const wrapperPath = resolve(ARTIFACTS_DIR, wrapper);
      const src = readFileSync(wrapperPath, 'utf-8');
      const imports = findJsonImports(src);
      expect(imports.length).toBeGreaterThan(0);
      for (const importPath of imports) {
        const resolved = resolve(dirname(wrapperPath), importPath);
        expect(existsSync(resolved), `${wrapper} imports ${importPath} but ${resolved} does not exist`).toBe(true);
      }
    });
  }
});
