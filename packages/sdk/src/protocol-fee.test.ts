import { describe, it, expect } from 'vitest';
import { computeProtocolFeeMint } from './protocol-fee.js';

describe('computeProtocolFeeMint', () => {
  // ================================================================
  // Drift canary against the Noir contract's compute_mint_fee tests.
  // If a fixture below stops matching, the SDK's pure replay has
  // diverged from the on-chain math (rounding, formula, sqrt) and any
  // indexer or LP UI relying on this helper will report stale numbers.
  // Source fixtures: protocol/core/src/pair/mod.nr (test_mint_fee_*).
  // ================================================================

  describe('matches Noir contract fixtures', () => {
    it('test_mint_fee_with_growth: 11000^2 vs 10000^2 baseline, 5000 supply, 20% -> 76', () => {
      // Noir: compute_mint_fee(11000, 11000, 10000, 10000, 5000, 20) == 76
      expect(
        computeProtocolFeeMint(11000n, 11000n, 10000n, 10000n, 5000n, 20),
      ).toBe(76n);
    });

    it('test_mint_fee_matches_one_sixth_model: 15000^2 vs 10000^2 baseline, 10000 supply, 20% -> 588', () => {
      // Noir: compute_mint_fee(15000, 15000, 10000, 10000, 10000, 20) == 588
      // Equivalent to the canonical 1/6 protocol-fee model with this percent.
      expect(
        computeProtocolFeeMint(15000n, 15000n, 10000n, 10000n, 10000n, 20),
      ).toBe(588n);
    });
  });

  describe('short-circuits', () => {
    it('returns 0 when percent is 0 (fee disabled by global percent)', () => {
      expect(
        computeProtocolFeeMint(10000n, 10000n, 5000n, 5000n, 5000n, 0),
      ).toBe(0n);
    });

    it('returns 0 when both reserves_last are 0 (no baseline)', () => {
      expect(
        computeProtocolFeeMint(10000n, 10000n, 0n, 0n, 5000n, 20),
      ).toBe(0n);
    });

    it('returns 0 when K has not grown since the baseline', () => {
      expect(
        computeProtocolFeeMint(10000n, 10000n, 10000n, 10000n, 5000n, 20),
      ).toBe(0n);
    });

    it('returns 0 when K has shrunk since the baseline (defensive)', () => {
      // sqrt_product floor catches K shrinkage; the contract returns 0
      // here as well (rootK <= rootKLast branch in compute_mint_fee).
      expect(
        computeProtocolFeeMint(9000n, 9000n, 10000n, 10000n, 5000n, 20),
      ).toBe(0n);
    });
  });

  describe('floors (rounds down)', () => {
    it('returns the floor when the formula produces a fractional LP amount', () => {
      // 5000 * (11000-10000) * 20 = 100_000_000
      // 11000*100 + 10000*20 = 1_300_000
      // floor(100_000_000 / 1_300_000) = 76, remainder 12_000_000
      // The remainder stays in the pool as K-growth (LPs benefit on next mint/burn).
      expect(
        computeProtocolFeeMint(11000n, 11000n, 10000n, 10000n, 5000n, 20),
      ).toBe(76n);
    });
  });

  describe('isqrt boundary cases', () => {
    // Boundary tests targeting the internal isqrt() helper through
    // computeProtocolFeeMint. These assert behavior at the n=0 and n=2
    // boundaries that distinguish the helper's branches.

    it('handles isqrt(0) when one reserve_last is zero', () => {
      // reserve0Last=0, reserve1Last=1: product=0, isqrt(0) is called.
      // isqrt(0) must return 0 (not throw); the guard is `n < 2n`, not `n <= 0n`.
      // rootK=isqrt(100)=10, rootKLast=0, delta=10
      // num = 1000*20*10 = 200000; den = 10*100 + 0*20 = 1000
      // fee = 200000 / 1000 = 200
      expect(
        computeProtocolFeeMint(10n, 10n, 0n, 1n, 1000n, 20),
      ).toBe(200n);
    });

    it('does not short-circuit when only one reserve_last is zero (asymmetric guard)', () => {
      // The bootstrap guard `if (reserve0Last === 0n && reserve1Last === 0n)
      // return 0n` requires BOTH reserves_last to be zero. With only
      // reserve1Last=0 (and reserve0Last>0), the function MUST proceed and
      // compute a non-zero fee.
      // rootK = isqrt(10*10) = 10, rootKLast = isqrt(5*0) = 0.
      // delta = 10 - 0 = 10; num = 1000*20*10 = 200000; den = 10*100 = 1000.
      // fee = 200000 / 1000 = 200.
      expect(
        computeProtocolFeeMint(10n, 10n, 5n, 0n, 1000n, 20),
      ).toBe(200n);
    });

    it('throws on negative reserve product (isqrt defensive guard)', () => {
      // isqrt rejects negative inputs (the `n < 0n` guard at line ~73).
      // If the guard is elided, Newton's method runs on the negative input
      // and returns nonsense. Reserves with one negative value produce a
      // negative product; the throw catches this and prevents silent
      // miscomputation.
      expect(() =>
        computeProtocolFeeMint(10n, -1n, 5n, 5n, 1000n, 20),
      ).toThrow(/isqrt: negative input/);
    });

    it('handles isqrt(2) at the small-input boundary', () => {
      // reserve0Last=1, reserve1Last=2: product=2, isqrt(2) is called.
      // isqrt(2) must return 1 (Newton's method floors); a `n <= 2n`
      // short-circuit would wrongly return n=2, producing a different
      // rootKLast and a different fee output.
      // rootK=isqrt(100)=10, rootKLast=1 (NOT 2), delta=9
      // num = 1000*20*9 = 180000; den = 10*100 + 1*20 = 1020
      // fee = floor(180000 / 1020) = 176
      expect(
        computeProtocolFeeMint(10n, 10n, 1n, 2n, 1000n, 20),
      ).toBe(176n);
    });
  });

  describe('handles wide-range inputs without overflow', () => {
    it('u112-range reserves (~5e33) compute without intermediate overflow', () => {
      // u112 max ~= 2^112 ~= 5.19e33. Pick reserves near that bound and
      // verify the helper returns a sensible non-negative result -- the
      // bigint path scales naturally where Number/Math.sqrt would lose
      // precision around 2^53.
      const r0 = 1n << 100n;     // ~1.27e30
      const r1 = 1n << 100n;
      const r0Last = 1n << 99n;  // ~6.34e29
      const r1Last = 1n << 99n;
      const totalSupply = 1n << 100n;
      const result = computeProtocolFeeMint(r0, r1, r0Last, r1Last, totalSupply, 20);
      expect(result).toBeGreaterThan(0n);
      // Sanity bound: the protocol mint can't exceed totalSupply * percent / 100.
      expect(result).toBeLessThan((totalSupply * 20n) / 100n);
    });
  });
});
