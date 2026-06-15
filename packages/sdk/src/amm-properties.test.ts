/**
 * AMM property-based tests — verify mathematical invariants hold
 * for random inputs.
 *
 * These test the core AMM formulas that protect user funds:
 * 1. K never decreases after a swap (fees increase K)
 * 2. Output is always less than the output reserve (can't drain pool)
 * 3. Monotonicity: larger input → larger output
 * 4. Round-trip loss: swap A→B→A always loses to fees
 * 5. Liquidity is proportional: deposit/withdraw preserves ratio
 */

import { describe, it, expect } from 'vitest';

// ================================================================
// Pure AMM math (mirrors Noir contract formulas exactly)
// ================================================================

const FEE_BPS = 25n; // 0.25%

/** Permanently-locked minimum liquidity on first mint. Mirrors pair::MINIMUM_LIQUIDITY. */
const MINIMUM_LIQUIDITY = 10_000n;

/** Compute swap output for exact input. Mirrors pair/mod.nr::get_amount_out */
function getAmountOut(amountIn: bigint, reserveIn: bigint, reserveOut: bigint, feeBps = FEE_BPS): bigint {
  if (amountIn <= 0n || reserveIn <= 0n || reserveOut <= 0n) return 0n;
  const amountInWithFee = amountIn * (10000n - feeBps);
  const numerator = amountInWithFee * reserveOut;
  const denominator = reserveIn * 10000n + amountInWithFee;
  return numerator / denominator;
}

/** Compute required input for exact output. Mirrors pair/mod.nr::get_amount_in */
function getAmountIn(amountOut: bigint, reserveIn: bigint, reserveOut: bigint, feeBps = FEE_BPS): bigint {
  if (amountOut <= 0n || reserveIn <= 0n || reserveOut <= 0n || amountOut >= reserveOut) return 0n;
  const numerator = reserveIn * amountOut * 10000n;
  const denominator = (reserveOut - amountOut) * (10000n - feeBps);
  // True ceiling, mirroring the contract's `mul_div_up` (ceil(a*b/c)). NOT
  // `floor + 1`, which over-states the input by 1 on exact divisions.
  return (numerator + denominator - 1n) / denominator;
}

/** Compute liquidity tokens for a deposit. Mirrors pair/mod.nr::compute_liquidity */
function computeLiquidity(
  amount0: bigint, amount1: bigint,
  reserve0: bigint, reserve1: bigint,
  totalSupply: bigint,
): bigint {
  if (totalSupply === 0n) {
    return sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
  }
  const liq0 = amount0 * totalSupply / reserve0;
  const liq1 = amount1 * totalSupply / reserve1;
  return liq0 < liq1 ? liq0 : liq1;
}

/** Integer square root (Babylonian method) */
function sqrt(n: bigint): bigint {
  if (n < 0n) throw new Error('sqrt of negative');
  if (n === 0n) return 0n;
  let x = n;
  let y = (x + 1n) / 2n;
  while (y < x) {
    x = y;
    y = (x + n / x) / 2n;
  }
  return x;
}

/** Generate a random bigint in [min, max] */
function randomBigInt(min: bigint, max: bigint): bigint {
  const range = max - min;
  const bits = range.toString(2).length;
  const bytes = Math.ceil(bits / 8);
  const buf = new Uint8Array(bytes);
  crypto.getRandomValues(buf);
  let val = 0n;
  for (const b of buf) val = (val << 8n) | BigInt(b);
  return min + (val % (range + 1n));
}

// ================================================================
// Property tests
// ================================================================

const NUM_TRIALS = 100;
const MIN_RESERVE = 10_000n;
const MAX_RESERVE = 10n ** 18n; // 1e18
const MIN_SWAP = 1n;
const MAX_SWAP_FRACTION = 50n; // max 1/50th of reserve per swap

describe('AMM property: K invariant', () => {
  it('K never decreases after a swap (fees increase K)', () => {
    for (let i = 0; i < NUM_TRIALS; i++) {
      const reserve0 = randomBigInt(MIN_RESERVE, MAX_RESERVE);
      const reserve1 = randomBigInt(MIN_RESERVE, MAX_RESERVE);
      const maxSwap = reserve0 / MAX_SWAP_FRACTION;
      if (maxSwap < MIN_SWAP) continue;
      const amountIn = randomBigInt(MIN_SWAP, maxSwap);

      const amountOut = getAmountOut(amountIn, reserve0, reserve1);
      if (amountOut === 0n) continue;

      const kBefore = reserve0 * reserve1;
      const kAfter = (reserve0 + amountIn) * (reserve1 - amountOut);

      expect(kAfter).toBeGreaterThanOrEqual(kBefore);
    }
  });
});

describe('AMM property: output bounds', () => {
  it('output is always less than output reserve', () => {
    for (let i = 0; i < NUM_TRIALS; i++) {
      const reserve0 = randomBigInt(MIN_RESERVE, MAX_RESERVE);
      const reserve1 = randomBigInt(MIN_RESERVE, MAX_RESERVE);
      // Even with a huge input, output can't exceed reserve
      const amountIn = randomBigInt(1n, MAX_RESERVE);

      const amountOut = getAmountOut(amountIn, reserve0, reserve1);
      expect(amountOut).toBeLessThan(reserve1);
    }
  });

  it('output is zero when input is zero', () => {
    const out = getAmountOut(0n, 100_000n, 100_000n);
    expect(out).toBe(0n);
  });
});

describe('AMM property: monotonicity', () => {
  it('larger input always produces larger output', () => {
    for (let i = 0; i < NUM_TRIALS; i++) {
      const reserve0 = randomBigInt(MIN_RESERVE, MAX_RESERVE);
      const reserve1 = randomBigInt(MIN_RESERVE, MAX_RESERVE);
      const amount1 = randomBigInt(1n, reserve0 / 10n || 1n);
      const amount2 = amount1 + randomBigInt(1n, reserve0 / 10n || 1n);

      const out1 = getAmountOut(amount1, reserve0, reserve1);
      const out2 = getAmountOut(amount2, reserve0, reserve1);

      expect(out2).toBeGreaterThanOrEqual(out1);
    }
  });
});

describe('AMM property: round-trip loss', () => {
  it('swap A→B→A always returns less than started (fee loss)', () => {
    for (let i = 0; i < NUM_TRIALS; i++) {
      const reserve0 = randomBigInt(MIN_RESERVE, MAX_RESERVE);
      const reserve1 = randomBigInt(MIN_RESERVE, MAX_RESERVE);
      const maxSwap = reserve0 / MAX_SWAP_FRACTION;
      if (maxSwap < 10n) continue;
      const amountIn = randomBigInt(10n, maxSwap);

      // Swap A → B
      const bOut = getAmountOut(amountIn, reserve0, reserve1);
      if (bOut === 0n) continue;
      const newR0 = reserve0 + amountIn;
      const newR1 = reserve1 - bOut;

      // Swap B → A
      const aBack = getAmountOut(bOut, newR1, newR0);

      // Should always lose to fees
      expect(aBack).toBeLessThan(amountIn);
    }
  });
});

describe('AMM property: getAmountIn / getAmountOut consistency', () => {
  it('getAmountOut(getAmountIn(y)) >= y (paying computed input yields at least desired output)', () => {
    for (let i = 0; i < NUM_TRIALS; i++) {
      const reserve0 = randomBigInt(MIN_RESERVE, MAX_RESERVE);
      const reserve1 = randomBigInt(MIN_RESERVE, MAX_RESERVE);
      const maxOut = reserve1 / MAX_SWAP_FRACTION;
      if (maxOut < 1n) continue;
      const desiredOut = randomBigInt(1n, maxOut);

      const requiredIn = getAmountIn(desiredOut, reserve0, reserve1);
      if (requiredIn === 0n) continue;

      // Paying the computed input should yield at least the desired output
      // (getAmountIn rounds UP, so you overpay slightly, getting more output)
      const actualOut = getAmountOut(requiredIn, reserve0, reserve1);
      expect(actualOut).toBeGreaterThanOrEqual(desiredOut);
    }
  });
});

describe('AMM property: liquidity math', () => {
  it('first deposit: LP tokens = sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY', () => {
    for (let i = 0; i < NUM_TRIALS; i++) {
      const amount0 = randomBigInt(10_000n, 10n ** 12n);
      const amount1 = randomBigInt(10_000n, 10n ** 12n);

      const lp = computeLiquidity(amount0, amount1, 0n, 0n, 0n);
      const expected = sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
      expect(lp).toBe(expected);
      expect(lp).toBeGreaterThan(0n);
    }
  });

  it('subsequent deposit: LP is min of proportional amounts', () => {
    for (let i = 0; i < NUM_TRIALS; i++) {
      const reserve0 = randomBigInt(MIN_RESERVE, MAX_RESERVE);
      const reserve1 = randomBigInt(MIN_RESERVE, MAX_RESERVE);
      const totalSupply = randomBigInt(MIN_RESERVE, MAX_RESERVE);

      // Deposit proportional amounts
      const amount0 = randomBigInt(1n, reserve0 / 10n || 1n);
      const amount1 = amount0 * reserve1 / reserve0; // exact ratio
      if (amount1 === 0n) continue;

      const lp = computeLiquidity(amount0, amount1, reserve0, reserve1, totalSupply);

      // LP should be proportional to deposit relative to reserves
      const expected0 = amount0 * totalSupply / reserve0;
      const expected1 = amount1 * totalSupply / reserve1;
      const expected = expected0 < expected1 ? expected0 : expected1;
      expect(lp).toBe(expected);
    }
  });

  it('LP tokens are always positive for non-trivial deposits', () => {
    for (let i = 0; i < NUM_TRIALS; i++) {
      const reserve0 = randomBigInt(MIN_RESERVE, MAX_RESERVE);
      const reserve1 = randomBigInt(MIN_RESERVE, MAX_RESERVE);
      const totalSupply = randomBigInt(MIN_RESERVE, MAX_RESERVE);
      const amount0 = randomBigInt(MIN_RESERVE, reserve0);
      const amount1 = randomBigInt(MIN_RESERVE, reserve1);

      const lp = computeLiquidity(amount0, amount1, reserve0, reserve1, totalSupply);
      expect(lp).toBeGreaterThan(0n);
    }
  });
});

describe('AMM property: fee extraction', () => {
  it('total fees collected equals expected fee rate', () => {
    // For a swap of amountIn with feeBps, the effective fee should be close to feeBps/10000
    for (let i = 0; i < NUM_TRIALS; i++) {
      const reserve0 = randomBigInt(10n ** 10n, 10n ** 15n);
      const reserve1 = randomBigInt(10n ** 10n, 10n ** 15n);
      // Small swap relative to reserves for accurate fee measurement
      const amountIn = randomBigInt(1n, reserve0 / 1000n || 1n);

      // Swap with fee
      const outWithFee = getAmountOut(amountIn, reserve0, reserve1, FEE_BPS);
      // Swap without fee
      const outNoFee = getAmountOut(amountIn, reserve0, reserve1, 0n);

      if (outNoFee === 0n) continue;

      // The fee should reduce output
      expect(outWithFee).toBeLessThanOrEqual(outNoFee);

      // For small swaps, fee percentage should be approximately feeBps/10000
      if (outNoFee > 1000n) {
        const feeTaken = outNoFee - outWithFee;
        const feeRate = feeTaken * 10000n / outNoFee;
        // Allow some tolerance due to integer division (±2 bps)
        expect(feeRate).toBeGreaterThanOrEqual(FEE_BPS - 2n);
        expect(feeRate).toBeLessThanOrEqual(FEE_BPS + 2n);
      }
    }
  });
});

// ================================================================
// Extreme fee tiers
// ================================================================

describe('AMM property: extreme fee tiers', () => {
  it('K invariant holds at feeBps=1 (minimum fee)', () => {
    for (let i = 0; i < NUM_TRIALS; i++) {
      const reserve0 = randomBigInt(MIN_RESERVE, MAX_RESERVE);
      const reserve1 = randomBigInt(MIN_RESERVE, MAX_RESERVE);
      const maxSwap = reserve0 / MAX_SWAP_FRACTION;
      if (maxSwap < 1n) continue;
      const amountIn = randomBigInt(1n, maxSwap);
      const amountOut = getAmountOut(amountIn, reserve0, reserve1, 1n);
      if (amountOut === 0n) continue;
      const kBefore = reserve0 * reserve1;
      const kAfter = (reserve0 + amountIn) * (reserve1 - amountOut);
      expect(kAfter).toBeGreaterThanOrEqual(kBefore);
    }
  });

  it('K invariant holds at feeBps=9999 (maximum fee)', () => {
    for (let i = 0; i < NUM_TRIALS; i++) {
      const reserve0 = randomBigInt(MIN_RESERVE, MAX_RESERVE);
      const reserve1 = randomBigInt(MIN_RESERVE, MAX_RESERVE);
      const amountIn = randomBigInt(1n, reserve0);
      const amountOut = getAmountOut(amountIn, reserve0, reserve1, 9999n);
      // At 99.99% fee, output should be tiny
      const kBefore = reserve0 * reserve1;
      const kAfter = (reserve0 + amountIn) * (reserve1 - amountOut);
      expect(kAfter).toBeGreaterThanOrEqual(kBefore);
    }
  });

  it('zero fee produces identical output to explicit no-fee calculation', () => {
    for (let i = 0; i < NUM_TRIALS; i++) {
      const reserve0 = randomBigInt(MIN_RESERVE, MAX_RESERVE);
      const reserve1 = randomBigInt(MIN_RESERVE, MAX_RESERVE);
      const maxSwap = reserve0 / MAX_SWAP_FRACTION;
      if (maxSwap < 1n) continue;
      const amountIn = randomBigInt(1n, maxSwap);
      const out0fee = getAmountOut(amountIn, reserve0, reserve1, 0n);
      // Manual no-fee: amountIn * reserveOut / (reserveIn + amountIn)
      const expected = amountIn * reserve1 / (reserve0 + amountIn);
      expect(out0fee).toBe(expected);
    }
  });
});

// ================================================================
// Removal proportionality
// ================================================================

function getAmountsOnRemove(toBurn: bigint, totalSupply: bigint, balance0: bigint, balance1: bigint): [bigint, bigint] {
  return [toBurn * balance0 / totalSupply, toBurn * balance1 / totalSupply];
}

describe('AMM property: removal proportionality', () => {
  it('removal amounts preserve reserve ratio (within rounding)', () => {
    for (let i = 0; i < NUM_TRIALS; i++) {
      const balance0 = randomBigInt(MIN_RESERVE, MAX_RESERVE);
      const balance1 = randomBigInt(MIN_RESERVE, MAX_RESERVE);
      const totalSupply = randomBigInt(MIN_RESERVE, MAX_RESERVE);
      const toBurn = randomBigInt(1n, totalSupply / 10n || 1n);

      const [amount0, amount1] = getAmountsOnRemove(toBurn, totalSupply, balance0, balance1);
      if (amount0 === 0n || amount1 === 0n) continue;

      // amount0/amount1 should approximate balance0/balance1
      // Cross-multiply to avoid division: amount0 * balance1 ≈ amount1 * balance0
      const lhs = amount0 * balance1;
      const rhs = amount1 * balance0;
      // Allow ±balance0 tolerance (1 unit of rounding per token)
      const diff = lhs > rhs ? lhs - rhs : rhs - lhs;
      expect(diff).toBeLessThanOrEqual(balance0 + balance1);
    }
  });
});

// ================================================================
// getAmountIn boundary behavior
// ================================================================

describe('AMM property: getAmountIn boundary', () => {
  it('getAmountIn increases monotonically as amountOut approaches reserveOut', () => {
    const reserveIn = 1_000_000n;
    const reserveOut = 1_000_000n;
    const fractions = [10n, 20n, 30n, 40n, 50n, 60n, 70n, 80n, 90n, 95n, 99n];

    let prevIn = 0n;
    for (const pct of fractions) {
      const amountOut = reserveOut * pct / 100n;
      const amountIn = getAmountIn(amountOut, reserveIn, reserveOut);
      expect(amountIn).toBeGreaterThan(prevIn);
      prevIn = amountIn;
    }
  });
});

// ================================================================
// First deposit with asymmetric amounts
// ================================================================

describe('AMM property: asymmetric first deposit', () => {
  it('first deposit with highly asymmetric amounts produces correct LP', () => {
    for (let i = 0; i < NUM_TRIALS; i++) {
      const amount0 = randomBigInt(10n ** 12n, 10n ** 18n);
      const amount1 = randomBigInt(1000n, 10000n);
      const lp = computeLiquidity(amount0, amount1, 0n, 0n, 0n);
      const expected = sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
      expect(lp).toBe(expected);
      expect(lp).toBeGreaterThan(0n);
    }
  });
});
