// SPDX-License-Identifier: MIT
// Copyright (c) 2026 SigalSwap LLC

/**
 * Slippage-tolerance helpers for computing `amount_out_min` and
 * `amount_in_max` from a quoted amount and a tolerance in basis points.
 *
 * The router and pair entry points accept these floors/ceilings as raw
 * bigints (`amountOutMin`, `amountInMax`, `amount0Min`, `amount1Min`) and
 * the contract enforces them after the swap or deposit math runs:
 *
 *   amount_out_min: floor on output the user will accept on a swap
 *   amount_in_max:  ceiling on input the user is willing to pay on an
 *                   exact-output swap
 *   amount{0,1}_min: floor on each deposit leg of add_liquidity (the
 *                   pair derives the actual deposit from its balance
 *                   delta and refunds the excess; the floors guard
 *                   against price movement between quote and inclusion)
 *
 * Passing `0` as any of these floors/ceilings is a valid input that
 * disables protection -- intentional for arb bots and contract
 * integrators that provide their own upstream slippage logic, but
 * dangerous for end-user wallets. These helpers turn a percentage
 * tolerance ("user is OK with 0.5%") into the bigint floor/ceiling the
 * contract expects, so UIs don't have to re-implement the math (or
 * forget to).
 *
 * All helpers accept tolerance in basis points (1 bp = 0.01%). Common
 * values:
 *   10  = 0.10%   tight; only safe for stable-pair quotes with low expected impact
 *   50  = 0.50%   typical wallet default
 *   100 = 1.00%   loose; thin pools or volatile pairs
 *   300 = 3.00%   very loose; small-cap tokens or worst-case sandwich envelope
 *
 * Rounding follows the standard constant-product SDK convention:
 *   - minimumAmountOut rounds DOWN (the contract delivers >= floor, so a
 *     lower floor admits more trades)
 *   - maximumAmountIn rounds UP (the contract pulls <= ceiling, so a
 *     higher ceiling admits more trades)
 *
 * See `docs/mev-considerations.md` for the broader threat model these
 * helpers fit into.
 */

const BPS_DENOMINATOR = 10_000n;

function assertNonNegative(name: string, value: bigint | number): void {
  if (typeof value === 'bigint' ? value < 0n : value < 0) {
    throw new RangeError(`${name} must be non-negative`);
  }
}

/**
 * Compute the minimum amount the user will accept on the output side of
 * a swap, given a quoted output and a slippage tolerance. Rounds DOWN.
 *
 * Tolerance at or above 10000 bps (100%) returns 0 -- disables the
 * floor entirely. Negative inputs throw.
 *
 * @param quotedOut amount the pair quoted as the expected output
 * @param slippageBps tolerance in basis points; 50 = 0.50%
 * @returns floor to pass as `amountOutMin` to the router or pair
 */
export function minimumAmountOut(quotedOut: bigint, slippageBps: number): bigint {
  assertNonNegative('quotedOut', quotedOut);
  assertNonNegative('slippageBps', slippageBps);
  if (slippageBps >= 10_000) return 0n;
  return (quotedOut * (BPS_DENOMINATOR - BigInt(slippageBps))) / BPS_DENOMINATOR;
}

/**
 * Compute the maximum amount the user is willing to pay on the input
 * side of an exact-output swap, given a quoted input and a slippage
 * tolerance. Rounds UP.
 *
 * Negative inputs throw. There is no upper cap on `slippageBps` -- a
 * caller willing to pay arbitrarily more is permitted; the meaningful
 * ceiling is the user's wallet balance, which the contract surfaces as
 * an `INSUFFICIENT_INPUT_AMOUNT` revert on the transfer step.
 *
 * @param quotedIn amount the pair quoted as the required input
 * @param slippageBps tolerance in basis points; 50 = 0.50%
 * @returns ceiling to pass as `amountInMax` to the router or pair
 */
export function maximumAmountIn(quotedIn: bigint, slippageBps: number): bigint {
  assertNonNegative('quotedIn', quotedIn);
  assertNonNegative('slippageBps', slippageBps);
  const numerator = quotedIn * (BPS_DENOMINATOR + BigInt(slippageBps));
  return (numerator + BPS_DENOMINATOR - 1n) / BPS_DENOMINATOR;
}

/**
 * Compute floor amounts for both legs of an `add_liquidity` call from
 * the optimal (quoted) amounts and a single slippage tolerance applied
 * symmetrically. Each amount is floored independently via
 * `minimumAmountOut`.
 *
 * The pair refunds any excess above the optimal-ratio deposit to the
 * recipient -- these floors guard the *deposit* side against price
 * movement between when the optimal amounts were computed and when the
 * tx lands, not the refund.
 *
 * @param amount0Optimal quoted token0 deposit
 * @param amount1Optimal quoted token1 deposit
 * @param slippageBps tolerance in basis points; 50 = 0.50%
 */
export function liquidityAmountMins(
  amount0Optimal: bigint,
  amount1Optimal: bigint,
  slippageBps: number,
): { amount0Min: bigint; amount1Min: bigint } {
  return {
    amount0Min: minimumAmountOut(amount0Optimal, slippageBps),
    amount1Min: minimumAmountOut(amount1Optimal, slippageBps),
  };
}
