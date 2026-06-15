// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 SigalSwap LLC. All rights reserved.
// Licensed under the Business Source License 1.1. See LICENSE in this directory.

// Fixed-point math for TWAP price accumulators.
//
// Uses a 112.112 fixed-point format (UQ112x112) packed into uint224.
// This gives 112 bits of integer precision and 112 bits of fractional precision,
// sufficient for price ratios between tokens with vastly different supplies.
//
// Noir doesn't have u112 or u224 natively. We represent values as u128:
// - Reserve values fit comfortably in u128 (max ~3.4 * 10^38 vs u112 max ~5.2 * 10^33)
// - Fixed-point results use u128 for the integer and fractional parts separately,
//   stored as a UQ112x112 struct
//
// The cumulative price accumulators rely on wrapping overflow behavior. We
// use a sufficiently large representation (Field) and accept modular
// arithmetic around the BN254 scalar field order.

use crate::math::wide::mul_div;

/// Number of fractional bits in the fixed-point representation
global RESOLUTION: u8 = 112;

/// Q112 = 2^112, the scaling factor for encoding
/// Stored as a u128 since 2^112 fits (u128 max is ~3.4 * 10^38, 2^112 ~ 5.2 * 10^33)
global Q112: u128 = 5192296858534827628530496329220096; // 2^112

/// UQ112x112: A 112.112 fixed-point number.
///
/// - `integer`: the integer portion of the value. Typed as `Field` (BN254 scalar,
///   ~2^254) so that cumulative TWAP accumulators have ample headroom without
///   silent truncation. Per-step prices (from `encode` / `uqdiv`) always fit
///   u112; only the accumulator form uses the wider range.
/// - `fraction`: the fractional portion scaled by Q112, bounded by `[0, Q112)`
///   which fits comfortably in `u128`.
///
/// TWAP consumers should treat the accumulator integer as modular around the
/// BN254 scalar field order and compute TWAP via Field subtraction; see the
/// periphery README for the accessor convention.
pub struct UQ112x112 {
    pub integer: Field,
    pub fraction: u128,
}

/// Encode a u128 reserve value as a UQ112x112 fixed-point number.
///
/// The fixed-point form is `z = y * Q112`. We return
/// `UQ112x112 { integer: y, fraction: 0 }` since `y * Q112` simply places
/// `y` in the integer portion with zero fractional part.
pub fn encode(y: u128) -> UQ112x112 {
    UQ112x112 { integer: y as Field, fraction: 0 }
}

/// Divide a UQ112x112 by a u128, returning a UQ112x112.
///
/// Preserves fractional precision via iterative long division on the remainder.
/// The input's integer part must fit u128 (always true in our usage: uqdiv is
/// only called on `encode(u128_reserve)` inputs, never on accumulator values).
pub fn uqdiv(x: UQ112x112, y: u128) -> UQ112x112 {
    assert(y > 0, "uqdiv: division by zero");

    // x.integer is Field-typed for accumulator compatibility, but uqdiv is only
    // ever called on encode() outputs where the integer fits u128. Cast back
    // for the integer-division semantics we need.
    let integer_u128 = x.integer as u128;
    let integer_result = integer_u128 / y;
    let remainder = integer_u128 % y;

    // fraction = (remainder << 112) / y, computed iteratively to avoid overflow.
    let fraction = fixed_point_div(remainder, y);

    UQ112x112 { integer: integer_result as Field, fraction }
}

/// Compute the fixed-point fractional result of (remainder * Q112) / divisor
/// where remainder < divisor, returning a value in [0, Q112).
///
/// Uses iterative binary long division to avoid overflow.
fn fixed_point_div(remainder: u128, divisor: u128) -> u128 {
    let mut r: u128 = remainder;
    let mut result: u128 = 0;

    for _ in 0..112 {
        r = r * 2;
        result = result * 2;
        if r >= divisor {
            r -= divisor;
            result += 1;
        }
    }

    result
}

/// Add a time-weighted price to a cumulative accumulator.
///
/// TWAP accumulator update:
///   price0_cumulative += (reserve1 / reserve0 in UQ112x112) * time_elapsed
///
/// The accumulator's integer part is Field-typed (~2^254 bits), so the
/// accumulator wraps modularly at the BN254 scalar field order rather than at
/// 2^128. Consumers compute TWAP via Field subtraction:
///     twap_price = (cumul_T2 - cumul_T1) / (T2 - T1)
/// which is correct as long as the real accumulated delta is < Field modulus
/// (always true for any realistic pool / time window).
pub fn accumulate_price(
    accumulator: UQ112x112,
    reserve_numerator: u128,
    reserve_denominator: u128,
    time_elapsed: u128,
) -> UQ112x112 {
    assert(reserve_denominator > 0, "accumulate_price: zero reserve");

    // Compute price = encode(reserve_numerator) / reserve_denominator.
    // price.integer and price.fraction both fit u128 (bounded by u112 reserves).
    let price = uqdiv(encode(reserve_numerator), reserve_denominator);

    // fraction_carry = floor(price.fraction * time_elapsed / Q112)
    // new_fraction   = (price.fraction * time_elapsed) mod Q112   (always < Q112 -> fits u128)
    let fraction_carry = mul_div(price.fraction, time_elapsed, Q112);
    let new_fraction_field = (price.fraction as Field) * (time_elapsed as Field)
        - (fraction_carry as Field) * (Q112 as Field);
    let new_fraction = new_fraction_field as u128;

    // weighted_integer = price.integer * time_elapsed.
    // Per-step product can exceed 2^128 for extreme ratios; kept as Field.
    let weighted_integer = price.integer * (time_elapsed as Field);

    // Add to accumulator with carry from fraction overflow.
    let raw_fraction = accumulator.fraction + new_fraction;
    let extra_carry = raw_fraction / Q112;
    let final_fraction = raw_fraction % Q112;

    UQ112x112 {
        integer: accumulator.integer
            + weighted_integer
            + (fraction_carry as Field)
            + (extra_carry as Field),
        fraction: final_fraction,
    }
}

/// Decode a UQ112x112 back to its integer part (truncating fractional bits).
/// Returns Field because accumulator integer values can exceed u128.
pub fn decode(x: UQ112x112) -> Field {
    x.integer
}

/// Create a zero-valued UQ112x112.
pub fn zero() -> UQ112x112 {
    UQ112x112 { integer: 0, fraction: 0 }
}

// ============================================
// Unit Tests
// ============================================

#[test]
fn test_encode_zero() {
    let result = encode(0);
    assert(result.integer == 0);
    assert(result.fraction == 0);
}

#[test]
fn test_encode_one() {
    let result = encode(1);
    assert(result.integer == 1);
    assert(result.fraction == 0);
}

#[test]
fn test_encode_large() {
    let result = encode(1000000);
    assert(result.integer == 1000000);
    assert(result.fraction == 0);
}

#[test]
fn test_uqdiv_exact() {
    // 10 / 2 = 5.0
    let result = uqdiv(encode(10), 2);
    assert(result.integer == 5);
    assert(result.fraction == 0);
}

#[test]
fn test_uqdiv_one() {
    // 7 / 1 = 7.0
    let result = uqdiv(encode(7), 1);
    assert(result.integer == 7);
    assert(result.fraction == 0);
}

#[test]
fn test_uqdiv_fractional() {
    // 1 / 2 = 0.5
    // In UQ112x112: fraction should be Q112 / 2
    let result = uqdiv(encode(1), 2);
    assert(result.integer == 0);
    let half_q112: u128 = Q112 / 2;
    assert(result.fraction == half_q112);
}

#[test]
fn test_uqdiv_one_third() {
    // 1 / 3 = 0.333...
    // In UQ112x112: fraction should be Q112 / 3 (truncated)
    let result = uqdiv(encode(1), 3);
    assert(result.integer == 0);
    let expected: u128 = Q112 / 3;
    assert(result.fraction == expected);
}

#[test]
fn test_uqdiv_mixed() {
    // 7 / 2 = 3.5
    let result = uqdiv(encode(7), 2);
    assert(result.integer == 3);
    let half_q112: u128 = Q112 / 2;
    assert(result.fraction == half_q112);
}

#[test]
fn test_uqdiv_large_numerator() {
    // 1000000 / 3 = 333333.333...
    let result = uqdiv(encode(1000000), 3);
    assert(result.integer == 333333);
    let expected_frac: u128 = Q112 / 3;
    assert(result.fraction == expected_frac);
}

#[test]
fn test_uqdiv_equal() {
    // 5 / 5 = 1.0
    let result = uqdiv(encode(5), 5);
    assert(result.integer == 1);
    assert(result.fraction == 0);
}

#[test]
fn test_uqdiv_price_ratio() {
    // Simulate a price ratio: 2000 ETH worth / 1 BTC worth
    // price = 2000 / 1 = 2000.0
    let result = uqdiv(encode(2000), 1);
    assert(result.integer == 2000);
    assert(result.fraction == 0);
}

#[test]
fn test_uqdiv_inverse_price() {
    // Inverse: 1 / 2000 = 0.0005
    let result = uqdiv(encode(1), 2000);
    assert(result.integer == 0);
    // fraction should be Q112 / 2000
    let expected: u128 = Q112 / 2000;
    assert(result.fraction == expected);
}

#[test]
fn test_decode() {
    let val = UQ112x112 { integer: 42, fraction: 12345 };
    assert(decode(val) == 42);
}

#[test]
fn test_zero() {
    let z = zero();
    assert(z.integer == 0);
    assert(z.fraction == 0);
}

#[test]
fn test_accumulate_price_basic() {
    // Starting from zero, accumulate price 2.0 for 10 seconds
    // Result should be 20.0
    let acc = zero();
    let result = accumulate_price(acc, 2000, 1000, 10);
    assert(result.integer == 20);
    assert(result.fraction == 0);
}

#[test]
fn test_accumulate_price_large_time_gap() {
    // Field arithmetic keeps a large time gap from overflowing.
    // price.fraction can be ~Q112 (~5.2e33), and time_elapsed = 3600 (1 hour).
    // 5.2e33 * 3600 = 1.87e37 fits in u128 but is close to the limit.
    // With time_elapsed = 100000 (over a day): 5.2e33 * 100000 = 5.2e38 > u128 max,
    // which only stays exact because the accumulator integer is Field-sized.
    let acc = zero();
    let result = accumulate_price(acc, 1000, 3000, 100000);
    // price = 1/3 for 100000 seconds. integer should be ~33333
    assert(result.integer == 33333);
    assert(result.fraction > 0);
}

#[test]
fn test_accumulate_price_fraction_carry() {
    // Verify that fraction overflow carries into integer correctly.
    // Accumulate price 0.5 for 3 seconds: 0.5 * 3 = 1.5
    // integer should be 1, fraction should represent 0.5
    let acc = zero();
    let result = accumulate_price(acc, 1000, 2000, 3);
    assert(result.integer == 1);
    // fraction should be approximately Q112 / 2
    let half_q112 = Q112 / 2;
    // Allow small rounding tolerance
    assert(result.fraction > half_q112 - 10);
    assert(result.fraction < half_q112 + 10);
}

#[test]
fn test_accumulate_price_fractional() {
    // Accumulate price 1/3 for 3 seconds. Due to truncation in fixed-point
    // division, floor(Q112/3) * 3 < Q112, so the integer part is 0 and the
    // fraction is close to (but slightly less than) Q112.
    let acc = zero();
    let result = accumulate_price(acc, 1000, 3000, 3);
    assert(result.integer == 0);
    // fraction should be close to Q112 (representing ~0.999...)
    assert(result.fraction > 0);
}

#[test]
fn test_accumulate_price_sequential() {
    // Accumulate price 1.0 for 5 seconds, then price 2.0 for 5 seconds
    // TWAP = (1.0 * 5 + 2.0 * 5) / 10 = 1.5
    // Cumulative after step 1: 5.0
    // Cumulative after step 2: 15.0
    let acc = zero();
    let acc1 = accumulate_price(acc, 1000, 1000, 5);
    assert(acc1.integer == 5);

    let acc2 = accumulate_price(acc1, 2000, 1000, 5);
    assert(acc2.integer == 15);
}

#[test]
fn test_accumulate_realistic_amm() {
    // Realistic scenario: ETH/USDC pool
    // reserve0 = 100 ETH (100 * 10^18 = 100_000_000_000_000_000_000)
    // reserve1 = 200,000 USDC (200_000 * 10^6 = 200_000_000_000)
    // price0 = reserve1/reserve0 (USDC per ETH)
    // Accumulate for 12 seconds (one block)
    let acc = zero();
    let reserve0: u128 = 100000000000000000000; // 100e18
    let reserve1: u128 = 200000000000;           // 200_000e6

    let result = accumulate_price(acc, reserve1, reserve0, 12);
    // price = 200_000e6 / 100e18 = 2e-9 (tiny because of decimal mismatch)
    // This is expected - the raw ratio is small, but the fractional precision captures it
    assert(result.integer == 0); // Price ratio < 1 due to decimal difference
    assert(result.fraction > 0); // But fractional part is non-zero
}

#[test]
fn test_accumulate_extreme_ratio_no_truncation() {
    // Synthetic degenerate pool: ratio near u112_max : 1. The weighted_integer
    // product u112_max * time_elapsed can exceed 2^128 for time_elapsed as
    // small as a few hours; the Field-sized accumulator keeps it exact rather
    // than overflowing u128 and silently corrupting the TWAP accumulator.
    //
    // Concrete values: reserve_num = 2^112 - 1 (u112 max), reserve_denom = 1,
    // time_elapsed = 2^32 (~136 years). Product would be (2^112 - 1) * 2^32
    // ~= 2^144, well outside u128.
    let reserve_num: u128 = 5192296858534827628530496329220095; // u112 max
    let reserve_denom: u128 = 1;
    let time_elapsed: u128 = 4294967296; // 2^32

    let acc = zero();
    let result = accumulate_price(acc, reserve_num, reserve_denom, time_elapsed);

    // Expected integer part: reserve_num * time_elapsed as a Field value.
    let expected_integer =
        (reserve_num as Field) * (time_elapsed as Field);
    assert(result.integer == expected_integer);
    // Fraction should be zero since the price is an exact integer.
    assert_eq(result.fraction, 0);

    // Verify a second accumulation still works (accumulator wraps around
    // BN254 modulus, not u128).
    let result2 = accumulate_price(result, reserve_num, reserve_denom, time_elapsed);
    let expected_integer_2 =
        (reserve_num as Field) * (time_elapsed as Field) * 2;
    assert(result2.integer == expected_integer_2);
}

#[test(should_fail_with = "uqdiv: division by zero")]
fn test_uqdiv_div_by_zero() {
    let _ = uqdiv(encode(1), 0);
}

#[test(should_fail_with = "accumulate_price: zero reserve")]
fn test_accumulate_zero_reserve() {
    let _ = accumulate_price(zero(), 1000, 0, 10);
}
