// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 SigalSwap LLC. All rights reserved.
// Licensed under the Business Source License 1.1. See LICENSE in this directory.

// SigalSwap Pair - Helper library functions
// Pure computation used by the pair contract (in main.nr).
//
// The actual contract with storage and entry points is defined in main.nr
// following Aztec's pattern of one contract per package.

use crate::math::{safe_sub, min};
use crate::math::fixed_point::{UQ112x112, accumulate_price};
use crate::math::wide::{mul_div, mul_div_up, sqrt_product};
use crate::types::PairConfig;
use aztec::protocol::{address::AztecAddress, traits::FromField};

/// Minimum liquidity permanently locked on first mint.
///
/// Set to 10_000 for first-mint-inflation protection. For 18/8/6-decimal
/// tokens (the overwhelming majority of what a DEX sees) the locked cost is
/// dust. For low-decimal tokens (2-decimal stablecoins, 0-decimal legacy
/// tokens) the higher floor makes pair creation materially more expensive --
/// intended as a mild deterrent against pairs over tokens with weird decimal
/// designs we don't want anyway. See the pair README's "First-mint inflation"
/// section.
pub global MINIMUM_LIQUIDITY: u128 = 10000;

/// Maximum reserve value (u112 max). Reserves are capped at u112 to ensure that
/// the K invariant product (reserve * reserve * 10000^2) fits in BN254 Field without
/// modular wraparound. This is the standard constant-product reserve constraint.
pub global MAX_RESERVE: u128 = 5192296858534827628530496329220095; // 2^112 - 1

/// Assert that a reserve value fits in u112.
pub fn assert_reserve_fits(value: u128) {
    assert(value <= MAX_RESERVE, "RESERVE_OVERFLOW");
}

/// Given an input amount and pair reserves, returns the maximum output amount.
/// Applies the fee specified in basis points.
///
/// Formula: amountOut = (amountIn * (10000 - fee_bps) * reserveOut) /
///                      (reserveIn * 10000 + amountIn * (10000 - fee_bps))
///
/// This is the standard constant-product fee formula generalized for variable fee tiers.
/// For a 0.30% fee (30 bps): fee_bps = 30
pub fn get_amount_out(
    amount_in: u128,
    reserve_in: u128,
    reserve_out: u128,
    fee_bps: u128,
) -> u128 {
    assert(amount_in > 0, "INSUFFICIENT_INPUT_AMOUNT");
    assert((reserve_in > 0) & (reserve_out > 0), "INSUFFICIENT_LIQUIDITY");
    assert(fee_bps < 10000, "FEE_TOO_HIGH");
    assert_reserve_fits(amount_in);
    assert_reserve_fits(reserve_in);
    assert_reserve_fits(reserve_out);

    // amountOut = (amountIn * (10000 - feeBps) * reserveOut) /
    //             (reserveIn * 10000 + amountIn * (10000 - feeBps))
    //
    // The numerator is a three-way product of u112-capped values * 10000,
    // max ~2^238, which fits in BN254 Field (~2^254). We compute the
    // product in Field and divide via the unconstrained hint pattern.
    let amount_in_with_fee = amount_in * (10000 - fee_bps);
    let denominator = reserve_in * 10000 + amount_in_with_fee;
    mul_div(amount_in_with_fee, reserve_out, denominator)
}

/// Given a desired output amount and pair reserves, returns the required input amount.
/// Applies the fee specified in basis points. Rounds up to favor the pool.
///
/// Formula: amountIn = ceil( (reserveIn * amountOut * 10000) /
///                           ((reserveOut - amountOut) * (10000 - fee_bps)) )
/// computed via `mul_div_up` (true ceiling, rounds up to favor the pool). A
/// `floor(...) + 1` form would over-charge by 1 on exact divisions.
pub fn get_amount_in(
    amount_out: u128,
    reserve_in: u128,
    reserve_out: u128,
    fee_bps: u128,
) -> u128 {
    assert(amount_out > 0, "INSUFFICIENT_OUTPUT_AMOUNT");
    assert((reserve_in > 0) & (reserve_out > 0), "INSUFFICIENT_LIQUIDITY");
    // Strict-less guard: `amount_out == reserve_out` would drain the side
    // entirely, leaving `safe_sub(reserve_out, amount_out) = 0` and the
    // denominator below zero -- `mul_div_up` would surface that as
    // `DIV_BY_ZERO`, which masks the actual cause. Reject up front with
    // the same message used elsewhere for "asked for more output than
    // this pair has."
    assert(amount_out < reserve_out, "INSUFFICIENT_LIQUIDITY");
    assert(fee_bps < 10000, "FEE_TOO_HIGH");
    assert_reserve_fits(amount_out);
    assert_reserve_fits(reserve_in);
    assert_reserve_fits(reserve_out);

    // amountIn = ceil((reserveIn * amountOut * 10000) /
    //                 ((reserveOut - amountOut) * (10000 - feeBps)))
    let denominator = safe_sub(reserve_out, amount_out) * (10000 - fee_bps);
    mul_div_up(reserve_in, amount_out * 10000, denominator)
}

/// Resolve the effective fee_bps for a quote: the LP fee tier plus the
/// active protocol-fee markup if fees are on. Mirrors the live formula
/// used in every swap path so quotes match settlement.
pub fn quote_fee_bps(config: PairConfig, fee_active: bool, fee_percent: u32) -> u128 {
    let lp_fee_bps = config.fee_tier_bps as u128;
    if fee_active {
        let protocol_percent = fee_percent as u128;
        // The protocol markup is rounded UP (ceil), not floored. Integer bps
        // cannot represent a fractional markup, so flooring would let the
        // markup truncate to zero (a 5 bps tier at percent = 19 floors
        // 0.95 -> 0) while compute_mint_fee still skims the exact fraction of
        // K-growth, quietly drawing the protocol's cut out of the LP fee.
        // Rounding up keeps the trader-charged markup >= the exact value, so
        // the protocol fee is never zero and LPs always receive their full LP
        // fee (any sub-bps rounding remainder accrues to LPs, not the
        // protocol). ceil(a/100) == (a + 99) / 100 for the integer
        // a = lp_fee_bps * protocol_percent.
        lp_fee_bps + ((lp_fee_bps * protocol_percent + 99) / 100)
    } else {
        lp_fee_bps
    }
}

/// Compute the swap output for a given input amount and direction.
/// Shared body for `quote_amount_out` (utility) and any future on-chain
/// quoter; resolves direction from token_in and applies the same fee
/// model live swaps charge so quotes match settlement.
pub fn compute_quote_amount_out(
    amount_in: u128,
    token_in: AztecAddress,
    config: PairConfig,
    reserve0: u128,
    reserve1: u128,
    fee_active: bool,
    fee_percent: u32,
) -> u128 {
    assert(
        (token_in == config.token0) | (token_in == config.token1),
        "TOKEN_IN_IS_INVALID",
    );
    let fee_bps = quote_fee_bps(config, fee_active, fee_percent);
    if token_in == config.token0 {
        get_amount_out(amount_in, reserve0, reserve1, fee_bps)
    } else {
        get_amount_out(amount_in, reserve1, reserve0, fee_bps)
    }
}

/// Compute the required swap input for a desired output amount and
/// direction. Shared body for `quote_amount_in_public` (public view) and
/// `quote_amount_in` (utility) so the on-chain V2-router-style getAmountsIn
/// path and the off-chain SDK simulator stay in lock-step.
pub fn compute_quote_amount_in(
    amount_out: u128,
    token_out: AztecAddress,
    config: PairConfig,
    reserve0: u128,
    reserve1: u128,
    fee_active: bool,
    fee_percent: u32,
) -> u128 {
    assert(
        (token_out == config.token0) | (token_out == config.token1),
        "TOKEN_OUT_IS_INVALID",
    );
    let fee_bps = quote_fee_bps(config, fee_active, fee_percent);
    if token_out == config.token1 {
        get_amount_in(amount_out, reserve0, reserve1, fee_bps)
    } else {
        get_amount_in(amount_out, reserve1, reserve0, fee_bps)
    }
}

/// Compute optimal amounts to add as liquidity, respecting the current price ratio
/// and the caller's min/max bounds.
///
/// On first deposit (both reserves zero), returns (amount0_max, amount1_max) since
/// there is no prior ratio to follow.
pub fn get_amounts_to_add(
    amount0_max: u128,
    amount1_max: u128,
    amount0_min: u128,
    amount1_min: u128,
    reserve0: u128,
    reserve1: u128,
) -> (u128, u128) {
    if (reserve0 == 0) | (reserve1 == 0) {
        // First deposit: caller sets the initial price ratio
        assert(amount0_max >= amount0_min, "AMOUNT_0_BELOW_MINIMUM");
        assert(amount1_max >= amount1_min, "AMOUNT_1_BELOW_MINIMUM");
        (amount0_max, amount1_max)
    } else {
        // Try using max amount0, compute equivalent amount1
        let amount1_equivalent = get_equivalent_amount(amount0_max, reserve0, reserve1);
        if amount1_equivalent <= amount1_max {
            assert(amount1_equivalent >= amount1_min, "AMOUNT_1_BELOW_MINIMUM");
            (amount0_max, amount1_equivalent)
        } else {
            // Max amount0 requires too much amount1; try max amount1 instead
            let amount0_equivalent = get_equivalent_amount(amount1_max, reserve1, reserve0);
            assert(amount0_equivalent <= amount0_max);
            assert(amount0_equivalent >= amount0_min, "AMOUNT_0_BELOW_MINIMUM");
            (amount0_equivalent, amount1_max)
        }
    }
}

/// Compute token amounts returned when removing liquidity.
/// Each token amount is proportional to the LP tokens being burned.
pub fn get_amounts_on_remove(
    to_burn: u128,
    total_supply: u128,
    balance0: u128,
    balance1: u128,
) -> (u128, u128) {
    (
        mul_div(to_burn, balance0, total_supply),
        mul_div(to_burn, balance1, total_supply),
    )
}

/// Compute the liquidity tokens to mint for a deposit.
///
/// First deposit:  sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY
/// Subsequent:     min(amount0 * totalSupply / reserve0, amount1 * totalSupply / reserve1)
pub fn compute_liquidity(
    amount0: u128,
    amount1: u128,
    reserve0: u128,
    reserve1: u128,
    total_supply: u128,
) -> u128 {
    if total_supply == 0 {
        // First deposit: geometric mean minus minimum locked liquidity
        // Amounts must fit in u112 so that sqrt_product's Field intermediate
        // (amount0 * amount1, max 2^224) doesn't wrap.
        assert_reserve_fits(amount0);
        assert_reserve_fits(amount1);
        let liquidity = sqrt_product(amount0, amount1);
        assert(liquidity > MINIMUM_LIQUIDITY, "INSUFFICIENT_INITIAL_LIQUIDITY");
        safe_sub(liquidity, MINIMUM_LIQUIDITY)
    } else {
        // Subsequent deposits: proportional to existing reserves
        min(
            mul_div(amount0, total_supply, reserve0),
            mul_div(amount1, total_supply, reserve1),
        )
    }
}

/// Compute protocol fee LP tokens to mint.
/// Called at the start of mint/burn to capture accumulated trading fee growth.
///
/// The protocol share derives from protocol_fee_percent (additive fee model).
///
/// Formula:
///   liquidity = totalSupply * (rootK - rootKLast) * protocol_percent
///             / (rootK * 100 + rootKLast * protocol_percent)
///
/// At protocol_percent = 20 (20% markup) this gives the protocol 1/6 of fee growth.
///
/// Returns 0 if fees are off (k_last == 0 or protocol_percent == 0) or if k hasn't grown.
pub fn compute_mint_fee(
    reserve0: u128,
    reserve1: u128,
    reserve0_last: u128,
    reserve1_last: u128,
    total_supply: u128,
    protocol_fee_percent: u128,
) -> u128 {
    if ((reserve0_last == 0) & (reserve1_last == 0)) | (protocol_fee_percent == 0) {
        0
    } else {
        let root_k = sqrt_product(reserve0, reserve1);
        let root_k_last = sqrt_product(reserve0_last, reserve1_last);

        if root_k <= root_k_last {
            0
        } else {
            // numerator = totalSupply * (rootK - rootKLast) * protocol_percent
            // denominator = rootK * 100 + rootKLast * protocol_percent
            // numerator_a = totalSupply * delta (u112 * u112 = u224, needs Field)
            // numerator_b = protocol_percent (<= 100)
            // denominator fits in u128 (u112 * 100 + u112 * 100 < u120)
            let delta = safe_sub(root_k, root_k_last);
            let denominator = root_k * 100 + root_k_last * protocol_fee_percent;
            // Floor (`mul_div`, not `mul_div_up`): rounding favors LPs. The
            // protocol under-mints by at most one LP-token-worth-of-value per
            // fee calc; the remainder stays in the pool as K-growth. A future
            // refactor swapping to `mul_div_up` would over-charge at edges.
            mul_div(total_supply * protocol_fee_percent, delta, denominator)
        }
    }
}

/// Result of a TWAP accumulator update, containing all new values to write to storage.
///
/// Integer parts are Field to let the accumulator wrap modularly around the
/// BN254 scalar field order rather than at 2^128; fractional parts remain u128
/// (always < Q112). See `math/fixed_point.nr` for the full rationale.
pub struct TwapUpdate {
    pub price0_cumul_int: Field,
    pub price0_cumul_frac: u128,
    pub price1_cumul_int: Field,
    pub price1_cumul_frac: u128,
    pub block_timestamp: u64,
}

/// Compute updated TWAP price accumulators.
///
/// Updates the constant-product price accumulator portion of state.
/// Called BEFORE writing new reserves on every mint/burn/swap/sync.
///
/// For each block where time has elapsed:
///   price0_cumulative += (reserve1 / reserve0) * time_elapsed  (in UQ112x112)
///   price1_cumulative += (reserve0 / reserve1) * time_elapsed  (in UQ112x112)
///
/// Returns the new accumulator values and timestamp.
/// If time_elapsed == 0 or reserves are zero, returns the current values unchanged.
pub fn compute_twap_update(
    reserve0: u128,
    reserve1: u128,
    price0_cumul_int: Field,
    price0_cumul_frac: u128,
    price1_cumul_int: Field,
    price1_cumul_frac: u128,
    block_timestamp_last: u64,
    current_timestamp: u64,
) -> TwapUpdate {
    // Guard against timestamp underflow (clock weirdness, test environments)
    if current_timestamp <= block_timestamp_last {
        TwapUpdate {
            price0_cumul_int,
            price0_cumul_frac,
            price1_cumul_int,
            price1_cumul_frac,
            block_timestamp: block_timestamp_last,
        }
    } else {
        let time_elapsed = current_timestamp - block_timestamp_last;

        if (time_elapsed > 0) & (reserve0 > 0) & (reserve1 > 0) {
            let acc0 = UQ112x112 { integer: price0_cumul_int, fraction: price0_cumul_frac };
            let new_acc0 = accumulate_price(acc0, reserve1, reserve0, time_elapsed as u128);

            let acc1 = UQ112x112 { integer: price1_cumul_int, fraction: price1_cumul_frac };
            let new_acc1 = accumulate_price(acc1, reserve0, reserve1, time_elapsed as u128);

            TwapUpdate {
                price0_cumul_int: new_acc0.integer,
                price0_cumul_frac: new_acc0.fraction,
                price1_cumul_int: new_acc1.integer,
                price1_cumul_frac: new_acc1.fraction,
                block_timestamp: current_timestamp,
            }
        } else {
            TwapUpdate {
                price0_cumul_int,
                price0_cumul_frac,
                price1_cumul_int,
                price1_cumul_frac,
                block_timestamp: current_timestamp,
            }
        }
    }
}

/// Given an amount of one token and the pair reserves, returns the equivalent
/// amount of the other token that maintains the current price ratio.
fn get_equivalent_amount(amount: u128, reserve_a: u128, reserve_b: u128) -> u128 {
    assert((reserve_a > 0) & (reserve_b > 0), "INSUFFICIENT_LIQUIDITY");
    mul_div(amount, reserve_b, reserve_a)
}

// ============================================
// Unit Tests
// ============================================

#[test]
fn test_get_amount_out_basic() {
    // 1000 in, reserves 10000/10000, 0.30% fee (30 bps)
    // amountOut = (1000 * 9970 * 10000) / (10000 * 10000 + 1000 * 9970)
    //           = 99700000 / 109970000 = 906 (truncated)
    let out = get_amount_out(1000, 10000, 10000, 30);
    assert(out == 906);
}

#[test]
fn test_get_amount_out_zero_fee() {
    // With 0 fee: amountOut = (1000 * 10000 * 10000) / (10000 * 10000 + 1000 * 10000)
    //           = 100000000 / 110000000 = 909
    let out = get_amount_out(1000, 10000, 10000, 0);
    assert(out == 909);
}

#[test]
fn test_get_amount_out_high_fee() {
    // 1% fee (100 bps)
    let out = get_amount_out(1000, 10000, 10000, 100);
    assert(out > 0);
    // Higher fee should give less output
    let out_low_fee = get_amount_out(1000, 10000, 10000, 30);
    assert(out < out_low_fee);
}

#[test]
fn test_get_amount_in_basic() {
    // Want 906 out, reserves 10000/10000, 0.30% fee
    let amount_in = get_amount_in(906, 10000, 10000, 30);
    // Should be approximately 1000 (with rounding up)
    assert(amount_in >= 999);
    assert(amount_in <= 1001);
}

#[test]
fn test_get_amounts_to_add_first_deposit() {
    let (a0, a1) = get_amounts_to_add(1000, 2000, 0, 0, 0, 0);
    assert(a0 == 1000);
    assert(a1 == 2000);
}

#[test]
fn test_get_amounts_to_add_proportional() {
    // Reserves are 1:2 ratio, depositing up to 1000 token0
    let (a0, a1) = get_amounts_to_add(1000, 2000, 0, 0, 5000, 10000);
    assert(a0 == 1000);
    assert(a1 == 2000);
}

#[test]
fn test_get_amounts_on_remove() {
    // Burn 10% of supply from a 50/50 pool
    let (a0, a1) = get_amounts_on_remove(100, 1000, 5000, 10000);
    assert(a0 == 500);
    assert(a1 == 1000);
}

#[test]
fn test_compute_liquidity_first_deposit() {
    // First deposit: sqrt(10000 * 40000) - 10000 = 20000 - 10000 = 10000
    let liq = compute_liquidity(10000, 40000, 0, 0, 0);
    assert(liq == 10000);
}

#[test]
fn test_compute_liquidity_subsequent() {
    // Subsequent: min(500 * 2000 / 5000, 1000 * 2000 / 10000)
    //           = min(200, 200) = 200
    let liq = compute_liquidity(500, 1000, 5000, 10000, 2000);
    assert(liq == 200);
}

#[test(should_fail_with = "INSUFFICIENT_INPUT_AMOUNT")]
fn test_get_amount_out_zero_input() {
    let _ = get_amount_out(0, 10000, 10000, 30);
}

#[test(should_fail_with = "INSUFFICIENT_LIQUIDITY")]
fn test_get_amount_out_zero_reserves() {
    let _ = get_amount_out(1000, 0, 10000, 30);
}

// Symmetric: reserve_out = 0. Existing test only covers reserve_in = 0,
// so a mutation of the AND in `(reserve_in > 0) & (reserve_out > 0)` can
// swap left/right without being noticed.
#[test(should_fail_with = "INSUFFICIENT_LIQUIDITY")]
fn test_get_amount_out_zero_reserve_out() {
    let _ = get_amount_out(1000, 10000, 0, 30);
}

// Boundary on the fee_bps < 10000 guard. fee_bps = 10000 must trigger
// FEE_TOO_HIGH (and not silently produce a zero amount-in-with-fee).
#[test(should_fail_with = "FEE_TOO_HIGH")]
fn test_get_amount_out_fee_too_high() {
    let _ = get_amount_out(1000, 10000, 10000, 10000);
}

#[test(should_fail_with = "INSUFFICIENT_OUTPUT_AMOUNT")]
fn test_get_amount_in_zero_output() {
    let _ = get_amount_in(0, 10000, 10000, 30);
}

#[test(should_fail_with = "INSUFFICIENT_LIQUIDITY")]
fn test_get_amount_in_zero_reserve_in() {
    let _ = get_amount_in(100, 0, 10000, 30);
}

#[test(should_fail_with = "INSUFFICIENT_LIQUIDITY")]
fn test_get_amount_in_zero_reserve_out() {
    let _ = get_amount_in(100, 10000, 0, 30);
}

// Boundary on the strict-less amount_out < reserve_out guard. amount_out
// equal to reserve_out must trigger INSUFFICIENT_LIQUIDITY.
#[test(should_fail_with = "INSUFFICIENT_LIQUIDITY")]
fn test_get_amount_in_drain_reserve_out() {
    let _ = get_amount_in(10000, 10000, 10000, 30);
}

#[test(should_fail_with = "FEE_TOO_HIGH")]
fn test_get_amount_in_fee_too_high() {
    let _ = get_amount_in(100, 10000, 10000, 10000);
}

#[test(should_fail_with = "INSUFFICIENT_INITIAL_LIQUIDITY")]
fn test_compute_liquidity_too_small() {
    // sqrt(1 * 1) = 1, which is less than MINIMUM_LIQUIDITY (10000)
    let _ = compute_liquidity(1, 1, 0, 0, 0);
}

// --- compute_mint_fee tests ---

#[test]
fn test_mint_fee_no_fee() {
    // protocol_percent = 0 -> no fee
    assert(compute_mint_fee(10000, 10000, 5000, 5000, 5000, 0) == 0);
}

#[test]
fn test_mint_fee_no_k_last() {
    // reserves_last = (0, 0) -> no fee (fee was off during last event)
    assert(compute_mint_fee(10000, 10000, 0, 0, 5000, 20) == 0);
}

#[test]
fn test_mint_fee_no_growth() {
    // k hasn't grown -> no fee
    // current: 10000/10000, last: 10000/10000
    assert(compute_mint_fee(10000, 10000, 10000, 10000, 5000, 20) == 0);
}

#[test]
fn test_mint_fee_with_growth() {
    // Reserves grew from 10000/10000 to 11000/11000
    // rootK = sqrt(11000*11000) = 11000, rootKLast = sqrt(10000*10000) = 10000
    // With 20% protocol fee:
    //   numerator = 5000 * (11000 - 10000) * 20 = 100_000_000
    //   denominator = 11000 * 100 + 10000 * 20 = 1_300_000
    //   liquidity = 76
    let fee = compute_mint_fee(11000, 11000, 10000, 10000, 5000, 20);
    assert(fee == 76);
}

// --- compute_twap_update tests ---

#[test]
fn test_twap_no_time_elapsed() {
    let result = compute_twap_update(10000, 20000, 0, 0, 0, 0, 100, 100);
    assert(result.price0_cumul_int == 0);
    assert(result.price1_cumul_int == 0);
    assert(result.block_timestamp == 100);
}

#[test]
fn test_twap_zero_reserves() {
    // Should not accumulate if reserves are zero (pool not initialized)
    let result = compute_twap_update(0, 0, 0, 0, 0, 0, 100, 112);
    assert(result.price0_cumul_int == 0);
    assert(result.price1_cumul_int == 0);
}

#[test]
fn test_twap_basic_accumulation() {
    // 1:1 price ratio, 10 seconds elapsed
    // price0 = reserve1/reserve0 = 1.0, accumulated for 10s -> integer = 10
    // price1 = reserve0/reserve1 = 1.0, accumulated for 10s -> integer = 10
    let result = compute_twap_update(10000, 10000, 0, 0, 0, 0, 100, 110);
    assert(result.price0_cumul_int == 10);
    assert(result.price1_cumul_int == 10);
    assert(result.price0_cumul_frac == 0);
    assert(result.price1_cumul_frac == 0);
}

#[test]
fn test_twap_asymmetric_ratio() {
    // 1:2 price ratio, 12 seconds elapsed
    // price0 = 20000/10000 = 2.0, for 12s -> integer = 24
    // price1 = 10000/20000 = 0.5, for 12s -> integer = 6, fraction > 0
    let result = compute_twap_update(10000, 20000, 0, 0, 0, 0, 100, 112);
    assert(result.price0_cumul_int == 24);
    assert(result.price1_cumul_int == 6);
    assert(result.price0_cumul_frac == 0);
    // price1 fraction: 0.5 * 12 = 6.0 -> no fractional part
    assert(result.price1_cumul_frac == 0);
}

#[test]
fn test_twap_sequential_accumulation() {
    // First period: 1:1 ratio for 10 seconds
    let r1 = compute_twap_update(10000, 10000, 0, 0, 0, 0, 100, 110);
    assert(r1.price0_cumul_int == 10); // 1.0 * 10 = 10

    // Second period: price changed to 1:2, another 10 seconds
    // price0 = 2.0 for 10s, added to previous 10 -> 30
    let r2 = compute_twap_update(
        10000, 20000,
        r1.price0_cumul_int, r1.price0_cumul_frac,
        r1.price1_cumul_int, r1.price1_cumul_frac,
        r1.block_timestamp, 120,
    );
    assert(r2.price0_cumul_int == 30); // 10 + 2.0*10 = 30

    // TWAP for price0 over full 20 seconds: (30 - 0) / 20 = 1.5
    // This is correct: average of 1.0 for 10s and 2.0 for 10s
}

#[test]
fn test_mint_fee_matches_one_sixth_model() {
    // Verify our formula matches the 1/6 protocol-fee model with 20% protocol markup
    // 1/6 model: liquidity = totalSupply * (rootK - rootKLast) / (rootK * 5 + rootKLast)
    // SigalSwap:  liquidity = totalSupply * (rootK - rootKLast) * 20 / (rootK * 100 + rootKLast * 20)
    // These should be identical since 20/100 simplifies the same way
    let reserve0: u128 = 15000;
    let reserve1: u128 = 15000;
    let total_supply: u128 = 10000;

    // rootK = 15000, rootKLast = sqrt(10000*10000) = 10000
    // 1/6 model: 10000 * 5000 / (15000 * 5 + 10000) = 50_000_000 / 85_000 = 588
    // SigalSwap:  10000 * 5000 * 20 / (15000 * 100 + 10000 * 20) = 1_000_000_000 / 1_700_000 = 588
    let fee = compute_mint_fee(reserve0, reserve1, 10000, 10000, total_supply, 20);
    assert(fee == 588);
}

// --- quote direction-resolution tests ---

// Helper: build a PairConfig with distinct token0/token1 addresses and a
// chosen LP fee tier. Other address fields are arbitrary -- the quote
// helpers only read token0/token1/fee_tier_bps.
fn make_quote_config(fee_tier_bps: u32) -> PairConfig {
    PairConfig {
        token0: AztecAddress::from_field(0x10),
        token1: AztecAddress::from_field(0x20),
        factory: AztecAddress::from_field(0x30),
        fee_tier_bps,
        version: 1,
        lp_token: AztecAddress::from_field(0x40),
    }
}

// compute_quote_amount_out must resolve direction from token_in: token0 in
// means reserve0 is reserve_in, token1 in means reserve1 is reserve_in.
// Asymmetric reserves (1_000_000 vs 4_000_000) make a swapped-reserve bug
// produce a visibly different result, so the two directions must differ.
// Expected values come from calling get_amount_out directly, so we assert
// the wrapper picks the right reserve order rather than a hardcoded number.
#[test]
fn test_compute_quote_amount_out_direction_fee_off() {
    let config = make_quote_config(30);
    let reserve0: u128 = 1_000_000;
    let reserve1: u128 = 4_000_000;
    let amount_in: u128 = 10_000;
    // fee off -> quote_fee_bps == lp_fee_bps == 30
    let fee_bps: u128 = 30;

    let out0 = compute_quote_amount_out(
        amount_in, config.token0, config, reserve0, reserve1, false, 0,
    );
    let out1 = compute_quote_amount_out(
        amount_in, config.token1, config, reserve0, reserve1, false, 0,
    );

    // token0 in -> reserve0 is reserve_in, reserve1 is reserve_out
    assert(out0 == get_amount_out(amount_in, reserve0, reserve1, fee_bps));
    // token1 in -> reserve1 is reserve_in, reserve0 is reserve_out
    assert(out1 == get_amount_out(amount_in, reserve1, reserve0, fee_bps));
    // Asymmetric pool: the two directions must differ, proving direction matters.
    assert(out0 != out1);
}

// Same direction-resolution check with the protocol fee ON, so the effective
// fee_bps flows through quote_fee_bps as well. lp_fee_bps = 30, percent = 20:
// ceil(30*20/100) = ceil(6.0) = 6 -> total fee_bps = 36.
#[test]
fn test_compute_quote_amount_out_direction_fee_on() {
    let config = make_quote_config(30);
    let reserve0: u128 = 1_000_000;
    let reserve1: u128 = 4_000_000;
    let amount_in: u128 = 10_000;
    let fee_bps: u128 = quote_fee_bps(config, true, 20);
    assert(fee_bps == 36);

    let out0 = compute_quote_amount_out(
        amount_in, config.token0, config, reserve0, reserve1, true, 20,
    );
    let out1 = compute_quote_amount_out(
        amount_in, config.token1, config, reserve0, reserve1, true, 20,
    );

    assert(out0 == get_amount_out(amount_in, reserve0, reserve1, fee_bps));
    assert(out1 == get_amount_out(amount_in, reserve1, reserve0, fee_bps));
    assert(out0 != out1);
}

// compute_quote_amount_in must resolve direction from token_out: token1 out
// uses get_amount_in(reserve0 as reserve_in, reserve1 as reserve_out), token0
// out swaps them. Asymmetric reserves make the two directions differ.
#[test]
fn test_compute_quote_amount_in_direction_fee_off() {
    let config = make_quote_config(30);
    let reserve0: u128 = 1_000_000;
    let reserve1: u128 = 4_000_000;
    let amount_out: u128 = 10_000;
    let fee_bps: u128 = 30;

    // token1 out -> need token0 in -> (reserve_in = reserve0, reserve_out = reserve1)
    let in_for_token1_out = compute_quote_amount_in(
        amount_out, config.token1, config, reserve0, reserve1, false, 0,
    );
    // token0 out -> need token1 in -> (reserve_in = reserve1, reserve_out = reserve0)
    let in_for_token0_out = compute_quote_amount_in(
        amount_out, config.token0, config, reserve0, reserve1, false, 0,
    );

    assert(in_for_token1_out == get_amount_in(amount_out, reserve0, reserve1, fee_bps));
    assert(in_for_token0_out == get_amount_in(amount_out, reserve1, reserve0, fee_bps));
    assert(in_for_token1_out != in_for_token0_out);
}

// Same direction check for compute_quote_amount_in with the protocol fee ON.
// lp_fee_bps = 30, percent = 20 -> fee_bps = 36 (as above).
#[test]
fn test_compute_quote_amount_in_direction_fee_on() {
    let config = make_quote_config(30);
    let reserve0: u128 = 1_000_000;
    let reserve1: u128 = 4_000_000;
    let amount_out: u128 = 10_000;
    let fee_bps: u128 = quote_fee_bps(config, true, 20);
    assert(fee_bps == 36);

    let in_for_token1_out = compute_quote_amount_in(
        amount_out, config.token1, config, reserve0, reserve1, true, 20,
    );
    let in_for_token0_out = compute_quote_amount_in(
        amount_out, config.token0, config, reserve0, reserve1, true, 20,
    );

    assert(in_for_token1_out == get_amount_in(amount_out, reserve0, reserve1, fee_bps));
    assert(in_for_token0_out == get_amount_in(amount_out, reserve1, reserve0, fee_bps));
    assert(in_for_token1_out != in_for_token0_out);
}

// --- quote_fee_bps round-up tests ---

// The protocol markup is rounded UP (ceil), so a sub-bps markup is never
// floored to zero. A 5 bps tier at percent = 19 gives ceil(5*19/100) =
// ceil(0.95) = 1, so the total is 6 bps (NOT 5 -- a floor would drop the
// markup and quietly draw the protocol cut out of the LP fee).
#[test]
fn test_quote_fee_bps_round_up_nondivisible() {
    let config = make_quote_config(5);
    // ceil(0.95) = 1 -> 5 + 1 = 6
    assert(quote_fee_bps(config, true, 19) == 6);
}

// Contrast at exact divisions and the fee-off path for the same 5 bps tier.
#[test]
fn test_quote_fee_bps_divisible_and_off() {
    let config = make_quote_config(5);
    // percent = 20 -> ceil(5*20/100) = ceil(1.0) = 1 -> total 6 (exact)
    assert(quote_fee_bps(config, true, 20) == 6);
    // percent = 0 -> markup ceil(0) = 0 -> total stays at the LP tier (5)
    assert(quote_fee_bps(config, true, 0) == 5);
    // fee inactive -> just the LP tier (5), percent ignored
    assert(quote_fee_bps(config, false, 19) == 5);
}

// 25 bps tier at percent = 19: ceil(25*19/100) = ceil(4.75) = 5 -> total 30.
#[test]
fn test_quote_fee_bps_round_up_25bps_tier() {
    let config = make_quote_config(25);
    assert(quote_fee_bps(config, true, 19) == 30);
}
