import { describe, it, expect } from 'vitest';
import { minimumAmountOut, maximumAmountIn, liquidityAmountMins } from './slippage.js';

describe('minimumAmountOut', () => {
  it('returns quoted exactly at zero tolerance', () => {
    expect(minimumAmountOut(1000n, 0)).toBe(1000n);
  });

  it('applies 0.5% tolerance (50bps): 1000 -> 995', () => {
    expect(minimumAmountOut(1000n, 50)).toBe(995n);
  });

  it('applies 1% tolerance (100bps): 1000 -> 990', () => {
    expect(minimumAmountOut(1000n, 100)).toBe(990n);
  });

  it('applies 3% tolerance (300bps): 1000 -> 970', () => {
    expect(minimumAmountOut(1000n, 300)).toBe(970n);
  });

  it('rounds down when the formula produces a fractional amount', () => {
    // 12345 * 9950 / 10000 = 122_832_750 / 10000 = 12283 (truncated from 12283.275)
    expect(minimumAmountOut(12345n, 50)).toBe(12283n);
  });

  it('returns 0 at 100% tolerance (10000 bps)', () => {
    expect(minimumAmountOut(1000n, 10_000)).toBe(0n);
  });

  it('returns 0 at >100% tolerance (would otherwise go negative)', () => {
    expect(minimumAmountOut(1000n, 20_000)).toBe(0n);
  });

  it('handles 0 quoted', () => {
    expect(minimumAmountOut(0n, 50)).toBe(0n);
  });

  it('preserves precision at very large amounts', () => {
    const quoted = 10n ** 36n;
    expect(minimumAmountOut(quoted, 50)).toBe((quoted * 9_950n) / 10_000n);
  });

  it('throws on negative quoted', () => {
    expect(() => minimumAmountOut(-1n, 50)).toThrow(RangeError);
  });

  it('throws on negative slippage', () => {
    expect(() => minimumAmountOut(1000n, -1)).toThrow(RangeError);
  });
});

describe('maximumAmountIn', () => {
  it('returns quoted exactly at zero tolerance', () => {
    expect(maximumAmountIn(1000n, 0)).toBe(1000n);
  });

  it('applies 0.5% tolerance (50bps): 1000 -> 1005', () => {
    expect(maximumAmountIn(1000n, 50)).toBe(1005n);
  });

  it('applies 1% tolerance (100bps): 1000 -> 1010', () => {
    expect(maximumAmountIn(1000n, 100)).toBe(1010n);
  });

  it('rounds up when the formula produces a fractional amount', () => {
    // 1234 * 10050 = 12_401_700; /10000 = 1240.17 -> ceiling 1241
    expect(maximumAmountIn(1234n, 50)).toBe(1241n);
  });

  it('handles 0 quoted', () => {
    expect(maximumAmountIn(0n, 50)).toBe(0n);
  });

  it('preserves precision at very large amounts', () => {
    const quoted = 10n ** 36n;
    const numerator = quoted * 10_050n;
    expect(maximumAmountIn(quoted, 50)).toBe((numerator + 9_999n) / 10_000n);
  });

  it('throws on negative quoted', () => {
    expect(() => maximumAmountIn(-1n, 50)).toThrow(RangeError);
  });

  it('throws on negative slippage', () => {
    expect(() => maximumAmountIn(1000n, -1)).toThrow(RangeError);
  });
});

describe('liquidityAmountMins', () => {
  it('applies symmetric tolerance to both amounts', () => {
    expect(liquidityAmountMins(1000n, 2000n, 50)).toEqual({
      amount0Min: 995n,
      amount1Min: 1990n,
    });
  });

  it('returns both amounts unchanged at zero tolerance', () => {
    expect(liquidityAmountMins(1000n, 2000n, 0)).toEqual({
      amount0Min: 1000n,
      amount1Min: 2000n,
    });
  });

  it('handles 0 amounts', () => {
    expect(liquidityAmountMins(0n, 0n, 50)).toEqual({
      amount0Min: 0n,
      amount1Min: 0n,
    });
  });

  it('rounds each leg independently (no cross-leg leak)', () => {
    // 12345 * 9950 / 10000 = 122_832_750 / 10000 = 12283 (truncated from 12283.275)
    // 67890 * 9950 / 10000 = 675_505_500 / 10000 = 67550 (truncated from 67550.55)
    expect(liquidityAmountMins(12345n, 67890n, 50)).toEqual({
      amount0Min: 12283n,
      amount1Min: 67550n,
    });
  });

  it('throws on negative slippage', () => {
    expect(() => liquidityAmountMins(1000n, 1000n, -1)).toThrow(RangeError);
  });
});
