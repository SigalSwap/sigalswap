// SPDX-License-Identifier: MIT
// Copyright (c) 2026 SigalSwap LLC

/**
 * Off-chain replay of the pair's `compute_mint_fee` (see
 * `protocol/core/src/pair/mod.nr`). Returns the LP-token amount that
 * `feeTo` would receive on the *next* mint or burn against the pair, given
 * the current reserves, the cached reserves at the last liquidity event,
 * the LP Token's current total supply, and the active protocol fee
 * percent.
 *
 * Useful for indexers / UIs that want to surface "accrued protocol fee"
 * numbers between liquidity events -- the on-chain mint only fires at the
 * next liquidity event, so the only way to display the accrual ahead of
 * time is the same formula running off-chain.
 *
 * Formula:
 *
 *     liquidity = totalSupply * (sqrt(K) - sqrt(K_last)) * percent
 *               / (sqrt(K) * 100 + sqrt(K_last) * percent)
 *
 * Returns 0 in the following short-circuit cases (matching the contract):
 *   - `protocolFeePercent == 0` (fee disabled by global percent or
 *     per-pair sync).
 *   - `reserve0Last == 0 && reserve1Last == 0` (fee was off at the last
 *     liquidity event; baseline is unset and re-establishes on the next
 *     liquidity event without a retroactive charge).
 *   - K hasn't grown since the baseline (`sqrt(K) <= sqrt(K_last)`).
 *
 * Rounds DOWN (matching the canonical constant-product fee mint). The protocol under-mints by at most
 * one LP-token-worth-of-value per fee calc; the remainder stays in the
 * pool as K-growth and accrues to LPs proportionally.
 *
 * @param reserve0 current reserve of token0
 * @param reserve1 current reserve of token1
 * @param reserve0Last reserve0 at the last liquidity event
 * @param reserve1Last reserve1 at the last liquidity event
 * @param totalSupply LP Token total supply (pre-fee)
 * @param protocolFeePercent fee percent in [0, 100], typically the value
 *   read from `factory.getProtocolFeeConfig().percent` mirrored to the
 *   pair via `sync_protocol_fee`. Pass 0 (or `enabled = false`) to model
 *   the fee-off case.
 */
export function computeProtocolFeeMint(
  reserve0: bigint,
  reserve1: bigint,
  reserve0Last: bigint,
  reserve1Last: bigint,
  totalSupply: bigint,
  protocolFeePercent: number,
): bigint {
  if (protocolFeePercent === 0) return 0n;
  if (reserve0Last === 0n && reserve1Last === 0n) return 0n;

  const rootK = isqrt(reserve0 * reserve1);
  const rootKLast = isqrt(reserve0Last * reserve1Last);
  if (rootK <= rootKLast) return 0n;

  const percent = BigInt(protocolFeePercent);
  const delta = rootK - rootKLast;
  const numerator = totalSupply * percent * delta;
  const denominator = rootK * 100n + rootKLast * percent;
  return numerator / denominator;
}

/**
 * Floor integer square root of a non-negative bigint. Matches the contract's
 * `sqrt_product(a, b)` semantics: `floor(sqrt(a * b))`. Newton's method
 * converges in O(log n) iterations -- fast for the u256-range inputs the
 * pair fee preview produces.
 */
function isqrt(n: bigint): bigint {
  if (n < 0n) throw new Error('isqrt: negative input');
  if (n < 2n) return n;
  let x = n;
  let y = (x + 1n) >> 1n;
  while (y < x) {
    x = y;
    y = (x + n / x) >> 1n;
  }
  return x;
}
