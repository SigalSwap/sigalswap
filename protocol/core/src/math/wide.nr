// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 SigalSwap LLC. All rights reserved.
// Licensed under the Business Source License 1.1. See LICENSE in this directory.

// Wide arithmetic helpers for AMM math.
//
// Uses two ZK-optimized patterns:
//
// 1. Field mulDiv: Products of u112-capped values fit in BN254 Field (~254 bits).
//    Division computed unconstrained, verified with a single Field equation.
//
// 2. Unconstrained sqrt: Computed off-circuit, verified with r*r <= x < (r+1)*(r+1)
//    AFTER constraining the hint to r < 2^113 so the Field squares cannot wrap
//    the modulus (see sqrt_product). The range constraint is load-bearing for
//    soundness, not just an optimization.
//
// No external dependencies. Unconstrained helpers use schoolbook 256-bit
// arithmetic (two u128 halves) for intermediate products that overflow u128.

/// Multiply two u128 values and divide by a u128, returning floor(a * b / c).
///
/// Uses Field for the product (safe when a * b < BN254 modulus ~2^254).
/// Division computed unconstrained and verified with: a * b == q * c + r, r < c.
pub fn mul_div(a: u128, b: u128, c: u128) -> u128 {
    assert(c > 0, "DIV_BY_ZERO");

    if (a == 0) | (b == 0) {
        0
    } else {
        let a_f = a as Field;
        let b_f = b as Field;
        let c_f = c as Field;
        let product = a_f * b_f;

        let (q, r) = unsafe { __div_unconstrained(a, b, c) };

        // Verify: a * b == q * c + r
        assert(product == (q as Field) * c_f + (r as Field), "MUL_DIV_VERIFY");
        // Verify: r < c
        assert(r < c, "MUL_DIV_REMAINDER");

        q
    }
}

/// Multiply two u128 values and divide by a u128, rounding UP.
pub fn mul_div_up(a: u128, b: u128, c: u128) -> u128 {
    assert(c > 0, "DIV_BY_ZERO");

    if (a == 0) | (b == 0) {
        0
    } else {
        let a_f = a as Field;
        let b_f = b as Field;
        let c_f = c as Field;
        let product = a_f * b_f;

        let (q, r) = unsafe { __div_unconstrained(a, b, c) };

        assert(product == (q as Field) * c_f + (r as Field), "MUL_DIV_VERIFY");
        assert(r < c, "MUL_DIV_REMAINDER");

        if r > 0 { q + 1 } else { q }
    }
}

/// Integer square root of (a * b), returned as u128.
///
/// The root is computed unconstrained, then pinned on-circuit by the integer
/// bound r*r <= a*b < (r+1)*(r+1). That bound is checked in BN254 Field
/// arithmetic, which only equals the integer comparison while the squares do
/// not wrap the field modulus p (~2^253.6). Callers pass u112-bounded operands
/// (product < 2^224), so the honest root is < 2^112; we additionally CONSTRAIN
/// the unconstrained hint to r < 2^113 before the Field comparisons, so r_sq and
/// r_plus_1_sq stay below 2^226 < p and cannot wrap. Without that constraint a
/// malicious prover (in a client-proven private context) could substitute a
/// forged r ~ 2^126 whose true square wraps mod p to a residue satisfying both
/// asserts; the constraint makes the verification sound in any caller context.
pub fn sqrt_product(a: u128, b: u128) -> u128 {
    if (a == 0) | (b == 0) {
        0
    } else {
        let r = unsafe { __sqrt_unconstrained(a, b) };

        // Pin the hint into the honest range BEFORE squaring it in Field, so
        // r_sq / r_plus_1_sq cannot wrap the BN254 modulus. Honest roots of
        // u112-bounded products are < 2^112; 2^113 leaves headroom without
        // admitting any wrap-forgeable value (a forged root must be ~2^126.8+
        // for its square to wrap, which this rejects).
        let max_root: u128 = 1 << 113;
        assert(r < max_root, "SQRT_ROOT_RANGE");

        // Verify: r * r <= a * b < (r + 1) * (r + 1)
        let a_f = a as Field;
        let b_f = b as Field;
        let r_f = r as Field;
        let r_plus_1_f = (r + 1) as Field;

        let product = a_f * b_f;
        let r_sq = r_f * r_f;
        let r_plus_1_sq = r_plus_1_f * r_plus_1_f;

        assert(!product.lt(r_sq), "SQRT_TOO_HIGH");
        assert(product.lt(r_plus_1_sq), "SQRT_TOO_LOW");

        r
    }
}

// ============================================
// Unconstrained helpers (zero circuit cost)
// Uses schoolbook 256-bit arithmetic: (high: u128, low: u128)
// ============================================

/// Compute floor((a * b) / c) where a * b may exceed u128.
unconstrained fn __div_unconstrained(a: u128, b: u128, c: u128) -> (u128, u128) {
    // Wide multiply: a * b as (high, low)
    let (p_hi, p_lo) = __wide_mul(a, b);
    // Wide divide: (high, low) / c
    __wide_divmod(p_hi, p_lo, c)
}

/// Compute floor(sqrt(a * b)) where a * b may exceed u128.
unconstrained fn __sqrt_unconstrained(a: u128, b: u128) -> u128 {
    let (p_hi, p_lo) = __wide_mul(a, b);

    if (p_hi == 0) & (p_lo == 0) {
        0
    } else if (p_hi == 0) & (p_lo <= 3) {
        1
    } else {
        // Babylonian method on (high, low) representation
        // Initial guess: approximate sqrt
        let mut guess = if p_hi > 0 {
            // Product is large (>= 2^128). The Newton loop below is descend-only
            // (it breaks the moment the iterate stops decreasing), so it only
            // converges when seeded from an OVER-estimate of the root. Seed with
            // (floor(sqrt(p_hi)) + 1) << 64, a guaranteed upper bound:
            //   product < (p_hi + 1) * 2^128 <= (floor(sqrt(p_hi)) + 1)^2 * 2^128
            // so seed^2 > product, i.e. seed > sqrt(product). A bare
            // floor(sqrt(p_hi)) << 64 would be an under-estimate, which the
            // descend-only loop cannot climb away from.
            (__u128_sqrt(p_hi) + 1) * (1 << 64)
        } else {
            __u128_sqrt(p_lo)
        };

        if guess == 0 {
            guess = 1;
        }

        // Newton iterations: guess = (guess + product/guess) / 2
        for _ in 0..128 {
            let (div_q, _) = __wide_divmod(p_hi, p_lo, guess);
            let new_guess = (guess + div_q) / 2;
            if new_guess >= guess {
                break;
            }
            guess = new_guess;
        }

        // Fine-tune: check if guess^2 <= product < (guess+1)^2
        let (g_hi, g_lo) = __wide_mul(guess, guess);
        if __wide_gt(g_hi, g_lo, p_hi, p_lo) {
            guess -= 1;
        }

        guess
    }
}

/// Schoolbook multiply: a * b = (high, low) where value = high * 2^128 + low.
///
/// Each of the four u64*u64 partial products fits u128, but their weighted
/// sum can overflow u128 at intermediate points (e.g. lh + hl when both
/// inputs have their high u64 set to max). We thread explicit carry bits
/// through every add so no intermediate step relies on wraparound.
unconstrained fn __wide_mul(a: u128, b: u128) -> (u128, u128) {
    let mask: u128 = 0xFFFFFFFFFFFFFFFF; // 2^64 - 1
    let a_lo = a & mask;
    let a_hi = a >> 64;
    let b_lo = b & mask;
    let b_hi = b >> 64;

    // Four partial products: u64 * u64 <= (2^64 - 1)^2 < 2^128. Fit u128.
    let ll = a_lo * b_lo; // weight 2^0
    let lh = a_lo * b_hi; // weight 2^64
    let hl = a_hi * b_lo; // weight 2^64
    let hh = a_hi * b_hi; // weight 2^128

    // mid = lh + hl, conceptually u129 (mid_carry is the 2^128 bit).
    let (mid_sum, mid_carry) = __add_u128_with_carry(lh, hl);
    let mid_sum_lo = mid_sum & mask;
    let mid_sum_hi = mid_sum >> 64;

    // low 128 bits = ll + (mid_sum_lo << 64).
    let mid_shifted = mid_sum_lo << 64;
    let (low, carry_from_low) = __add_u128_with_carry(ll, mid_shifted);

    // high 128 bits = hh + mid_sum_hi + (mid_carry << 64) + carry_from_low.
    // Product fits u256, so the final carries here must sum to 0.
    let (h1, c1) = __add_u128_with_carry(hh, mid_sum_hi);
    let (h2, c2) = __add_u128_with_carry(h1, mid_carry << 64);
    let (high, c3) = __add_u128_with_carry(h2, carry_from_low);
    assert(c1 + c2 + c3 == 0 as u128, "WIDE_MUL_BUG");

    (high, low)
}

/// Divide (high, low) by divisor, returning (quotient, remainder).
/// Assumes quotient fits in u128.
unconstrained fn __wide_divmod(high: u128, low: u128, divisor: u128) -> (u128, u128) {
    if high == 0 {
        (low / divisor, low % divisor)
    } else {
        // Binary long division
        let mut remainder: u128 = 0;
        let mut quotient: u128 = 0;

        // Process high bits first (128 bits from high)
        for i in 0..128 {
            let bit_pos = 127 - i;
            remainder = (remainder << 1) | ((high >> bit_pos) & 1);
            if remainder >= divisor {
                remainder -= divisor;
                // This bit contributes to the high part of quotient,
                // but since we assume quotient fits u128, these would
                // overflow quotient. For AMM math, quotient always fits.
            }
        }

        // Process low bits (128 bits from low)
        for i in 0..128 {
            let bit_pos = 127 - i;
            remainder = (remainder << 1) | ((low >> bit_pos) & 1);
            if remainder >= divisor {
                remainder -= divisor;
                quotient = quotient | (1 << bit_pos);
            }
        }

        (quotient, remainder)
    }
}

/// Integer sqrt of a u128 value (Babylonian method, unconstrained).
unconstrained fn __u128_sqrt(val: u128) -> u128 {
    if val <= 1 {
        val
    } else {
        let mut x = val / 2 + 1;
        let mut y = val;
        for _ in 0..128 {
            if x >= y {
                break;
            }
            y = x;
            x = (val / x + x) / 2;
        }
        y
    }
}

/// Compare two wide values: is (a_hi, a_lo) > (b_hi, b_lo)?
unconstrained fn __wide_gt(a_hi: u128, a_lo: u128, b_hi: u128, b_lo: u128) -> bool {
    if a_hi != b_hi {
        a_hi > b_hi
    } else {
        a_lo > b_lo
    }
}

// ============================================
// u256 / u512 helpers for wide-int K invariant check
// ============================================
//
// `balance * 10000` in flash_swap can reach ~2^142, past Field's ~2^254 modulus
// when squared. The K check therefore operates on u256 adjusted balances and
// their u512 product. All ops below are unconstrained (AVM-only; our public
// callers are `#[external("public")]`). They use u128 limbs with explicit
// carry propagation rather than Field arithmetic so overflow behavior is
// deterministic at every step.

/// Add two u128 values returning (sum mod 2^128, carry_bit).
unconstrained fn __add_u128_with_carry(a: u128, b: u128) -> (u128, u128) {
    let max_u128: u128 = 0xffffffffffffffffffffffffffffffff;
    if b <= max_u128 - a {
        (a + b, 0 as u128)
    } else {
        // a + b >= 2^128. Wrapped = a + b - 2^128 = b - (max - a) - 1.
        let wrapped = b - (max_u128 - a) - 1;
        (wrapped, 1 as u128)
    }
}

/// Sum three u128 values returning (sum mod 2^128, total_carry).
/// Total carry fits u128 easily (at most 2).
unconstrained fn __add3_u128_with_carry(a: u128, b: u128, c: u128) -> (u128, u128) {
    let (s1, c1) = __add_u128_with_carry(a, b);
    let (s2, c2) = __add_u128_with_carry(s1, c);
    (s2, c1 + c2)
}

/// Sum four u128 values returning (sum mod 2^128, total_carry).
/// Total carry fits u128 easily (at most 3).
unconstrained fn __add4_u128_with_carry(
    a: u128, b: u128, c: u128, d: u128,
) -> (u128, u128) {
    let (s1, c1) = __add_u128_with_carry(a, b);
    let (s2, c2) = __add_u128_with_carry(s1, c);
    let (s3, c3) = __add_u128_with_carry(s2, d);
    (s3, c1 + c2 + c3)
}

/// Subtract two u256 values (hi, lo). Asserts a >= b (no underflow).
pub fn wide_sub_u256(a: (u128, u128), b: (u128, u128)) -> (u128, u128) {
    let (a_hi, a_lo) = a;
    let (b_hi, b_lo) = b;
    assert(
        (a_hi > b_hi) | ((a_hi == b_hi) & (a_lo >= b_lo)),
        "WIDE_SUB_UNDERFLOW",
    );
    if a_lo >= b_lo {
        (a_hi - b_hi, a_lo - b_lo)
    } else {
        // Borrow from high: result_lo = 2^128 - (b_lo - a_lo)
        // In borrow branch a_hi > b_hi (because a_hi == b_hi would require
        // a_lo >= b_lo to satisfy the assert, contradiction).
        let borrow_amount = b_lo - a_lo;
        let max_u128: u128 = 0xffffffffffffffffffffffffffffffff;
        let lo = (max_u128 - borrow_amount) + 1;
        let hi = a_hi - b_hi - 1;
        (hi, lo)
    }
}

/// Multiply two u256 values (each (hi, lo)) producing u512 as four u128 limbs
/// (hh, hm, ml, lo) such that value = hh*2^384 + hm*2^256 + ml*2^128 + lo.
unconstrained fn __mul_u256_u256_to_u512(
    a: (u128, u128),
    b: (u128, u128),
) -> (u128, u128, u128, u128) {
    let (a_hi, a_lo) = a;
    let (b_hi, b_lo) = b;

    // Four u128 x u128 -> u256 partial products.
    let (ll_up, ll_lo) = __wide_mul(a_lo, b_lo);
    let (hl_up, hl_lo) = __wide_mul(a_hi, b_lo);
    let (lh_up, lh_lo) = __wide_mul(a_lo, b_hi);
    let (hh_up, hh_lo) = __wide_mul(a_hi, b_hi);

    // Columns by output position:
    //   lo  (pos 0)  : ll_lo
    //   ml  (pos 128): ll_up + hl_lo + lh_lo
    //   hm  (pos 256): hl_up + lh_up + hh_lo + carry_ml
    //   hh  (pos 384): hh_up + carry_hm
    let lo = ll_lo;
    let (ml, carry_ml) = __add3_u128_with_carry(ll_up, hl_lo, lh_lo);
    let (hm, carry_hm) = __add4_u128_with_carry(hl_up, lh_up, hh_lo, carry_ml);
    let (hh, final_carry) = __add_u128_with_carry(hh_up, carry_hm);

    // final_carry must be 0 -- u256 * u256 fits u512 by construction. This
    // guards against future bugs in limb accounting; it should never fire.
    assert(final_carry == 0 as u128, "WIDE_MUL_U512_BUG");

    (hh, hm, ml, lo)
}

/// Lex compare two u512 values (hh, hm, ml, lo).
unconstrained fn __wide_lt_u512(
    a: (u128, u128, u128, u128),
    b: (u128, u128, u128, u128),
) -> bool {
    let (a_hh, a_hm, a_ml, a_lo) = a;
    let (b_hh, b_hm, b_ml, b_lo) = b;
    if a_hh != b_hh {
        a_hh < b_hh
    } else if a_hm != b_hm {
        a_hm < b_hm
    } else if a_ml != b_ml {
        a_ml < b_ml
    } else {
        a_lo < b_lo
    }
}

/// Derive the actual amount IN on each side after a swap-style op.
///
/// Returns `(amount0_in, amount1_in)`: post-balance minus the
/// reserve-after-pair-transferred-out level. Non-negative; captures both
/// repayment-in-kind and donations on either side.
///
/// Caller invariants:
/// - `amount_i_out <= reserve_i` so `reserve_i - amount_i_out` doesn't underflow.
///
/// Pure formula: callers compute once, then reuse the result for both
/// `INSUFFICIENT_REPAYMENT` (flash_swap) and `verify_k_invariant`.
pub fn compute_amounts_in(
    reserve0: u128,
    reserve1: u128,
    amount0_out: u128,
    amount1_out: u128,
    balance0: u128,
    balance1: u128,
) -> (u128, u128) {
    let expected0 = reserve0 - amount0_out;
    let expected1 = reserve1 - amount1_out;
    let amount0_in = if balance0 > expected0 { balance0 - expected0 } else { 0 };
    let amount1_in = if balance1 > expected1 { balance1 - expected1 } else { 0 };
    (amount0_in, amount1_in)
}

/// Verify the constant-product K invariant after a swap-style operation.
///
/// Asserts:
///
///   (balance0 * 10000 - amount0_in * fee_bps) *
///   (balance1 * 10000 - amount1_in * fee_bps)
///     >= reserve0 * reserve1 * 10000 * 10000
///
/// Callers compute `(amount0_in, amount1_in)` via `compute_amounts_in` and
/// pass them in -- this lets flash_swap also use the same values for its
/// `INSUFFICIENT_REPAYMENT` check without recomputing the formula, and
/// keeps this function purely a verifier (no derivation).
///
/// Runs entirely in u128/u256/u512 limb arithmetic so balances up to the full
/// u128 range are handled without Field modular wraparound.
///
/// Caller invariants (must all hold; the fee bound is asserted internally so a
/// misconfigured fee fails fast rather than tripping `wide_sub_u256`'s
/// underflow guard later):
/// - `reserve_i <= MAX_RESERVE` (u112) so `reserve_i * 10000` fits u128.
/// - `amount_i_in <= balance_i` (true by construction when amount_in comes
///   from `compute_amounts_in`).
/// - `fee_bps < 10000` so `balance_i * 10000 - amount_i_in * fee_bps` stays
///   non-negative.
pub fn verify_k_invariant(
    balance0: u128,
    balance1: u128,
    reserve0: u128,
    reserve1: u128,
    amount0_in: u128,
    amount1_in: u128,
    fee_bps: u128,
) {
    let scale: u128 = 10000;
    assert(fee_bps < scale, "FEE_TOO_HIGH");

    // balance_i * scale and amount_i_in * fee_bps: up to 2^142 each (needs u256).
    let bs0 = unsafe { __wide_mul(balance0, scale) };
    let bs1 = unsafe { __wide_mul(balance1, scale) };
    let af0 = unsafe { __wide_mul(amount0_in, fee_bps) };
    let af1 = unsafe { __wide_mul(amount1_in, fee_bps) };

    // balance_i_adj = bs_i - af_i. Non-negative per the fee_bps invariant above.
    let adj0 = wide_sub_u256(bs0, af0);
    let adj1 = wide_sub_u256(bs1, af1);

    // k_before = (reserve0 * scale) * (reserve1 * scale). Each factor fits u128
    // given the MAX_RESERVE invariant. Product fits u256.
    let rs0 = reserve0 * scale;
    let rs1 = reserve1 * scale;
    let (kb_hi, kb_lo) = unsafe { __wide_mul(rs0, rs1) };

    // k_after = adj0 * adj1 fits u512 (in practice u284 since each adj <= 2^142).
    let k_after = unsafe { __mul_u256_u256_to_u512(adj0, adj1) };
    let k_before = (0 as u128, 0 as u128, kb_hi, kb_lo);

    let lt = unsafe { __wide_lt_u512(k_after, k_before) };
    assert(!lt, "K_INVARIANT_VIOLATED");
}

// ============================================
// Unit Tests
// ============================================

#[test]
fn test_mul_div() {
    assert(mul_div(1000, 2000, 500) == 4000);
}

#[test]
fn test_mul_div_large() {
    let a: u128 = 1000000000000000000;
    let b: u128 = 2000000000000000000;
    let c: u128 = 1000000000000000000;
    assert(mul_div(a, b, c) == 2000000000000000000);
}

#[test]
fn test_mul_div_zero() {
    assert(mul_div(0, 12345, 100) == 0);
    assert(mul_div(12345, 0, 100) == 0);
}

// Boundary: c = 0 must trigger DIV_BY_ZERO. Without this test, the
// `assert(c > 0)` guard at the top of mul_div is mutation-resilient via
// vacuous-truth (existing tests pass c >= 100).
#[test(should_fail_with = "DIV_BY_ZERO")]
fn test_mul_div_div_by_zero() {
    let _ = mul_div(10, 20, 0);
}

// Boundary: a = 1 distinguishes the (a == 0) shortcut from (a == 1)
// mutations. Existing tests pass a >= 1000, so a == 1 is unexercised.
#[test]
fn test_mul_div_a_one() {
    // 1 * 100 / 5 = 20
    assert(mul_div(1, 100, 5) == 20);
}

// Symmetric to test_mul_div_a_one: exercises the (b == 0) shortcut at b = 1.
#[test]
fn test_mul_div_b_one() {
    assert(mul_div(100, 1, 5) == 20);
}

// Boundary: c = 1 distinguishes the `c > 0` guard from `c > 1` mutations.
#[test]
fn test_mul_div_c_one() {
    // 10 * 20 / 1 = 200
    assert(mul_div(10, 20, 1) == 200);
}

// Exercise __wide_divmod across the full 128-bit range by setting
// bit 127 of `a`. Without this test, BoundShift mutations on the
// `for i in 0..128` loop (lines 194, 206) can shift to 127 or 129
// without affecting the output for tested inputs.
#[test]
fn test_mul_div_high_bit_a() {
    let a: u128 = 1 << 127; // 2^127
    let b: u128 = 2;        // a * b = 2^128 (overflows u128, exercises wide-divmod high-half)
    let c: u128 = 4;
    // 2^128 / 4 = 2^126
    assert(mul_div(a, b, c) == 1 << 126);
}

// Symmetric to test_mul_div_high_bit_a, with bit 127 on b. Without this,
// some __wide_mul-internal mutations differentiate only when b's high u64
// has its top bit set.
#[test]
fn test_mul_div_high_bit_b() {
    let a: u128 = 2;
    let b: u128 = 1 << 127;
    let c: u128 = 4;
    assert(mul_div(a, b, c) == 1 << 126);
}

#[test]
fn test_mul_div_up() {
    assert(mul_div_up(10, 3, 4) == 8);
    assert(mul_div_up(10, 4, 4) == 10);
}

// Boundary parallel to test_mul_div_div_by_zero for the rounding-up variant.
#[test(should_fail_with = "DIV_BY_ZERO")]
fn test_mul_div_up_div_by_zero() {
    let _ = mul_div_up(10, 20, 0);
}

// Non-zero remainder: 7*5=35; 35/3 = 11 r 2. The verification
// `product == q*c + r` only catches `+ -> -` mutations when r is non-zero
// (otherwise q*c+r and q*c-r both equal q*c). Existing test_mul_div uses
// inputs where r=0.
#[test]
fn test_mul_div_remainder_nonzero() {
    assert(mul_div(7, 5, 3) == 11);
}

// Same boundary for mul_div_up's verification.
#[test]
fn test_mul_div_up_remainder_nonzero() {
    // 7*5=35, 35/3 = 11 r 2; rounded up = 12.
    assert(mul_div_up(7, 5, 3) == 12);
}

// Boundary tests on mul_div_up's `(a == 0) | (b == 0) | (c > 0)` guards.
// Existing test_mul_div_up uses a=10, b in {3,4}, c=4 -- none is 1.
#[test]
fn test_mul_div_up_a_one() {
    assert(mul_div_up(1, 100, 5) == 20);
}

#[test]
fn test_mul_div_up_b_one() {
    assert(mul_div_up(100, 1, 5) == 20);
}

#[test]
fn test_mul_div_up_c_one() {
    // Exact division: 10*20/1 = 200, no rounding adjustment.
    assert(mul_div_up(10, 20, 1) == 200);
}

#[test]
fn test_sqrt_product() {
    assert(sqrt_product(100, 100) == 100);
    assert(sqrt_product(1000000, 1000000) == 1000000);
}

#[test]
fn test_sqrt_product_large() {
    let a: u128 = 1000000000000000000;
    let b: u128 = 4000000000000000000;
    assert(sqrt_product(a, b) == 2000000000000000000);
}

#[test]
fn test_sqrt_product_small() {
    assert(sqrt_product(1, 1) == 1);
    assert(sqrt_product(1, 2) == 1);
    assert(sqrt_product(1, 3) == 1);
    assert(sqrt_product(2, 2) == 2);
    assert(sqrt_product(1, 4) == 2);
}

#[test]
fn test_sqrt_product_zero() {
    assert(sqrt_product(0, 12345) == 0);
    assert(sqrt_product(12345, 0) == 0);
}

#[test]
fn test_sqrt_product_amm_realistic() {
    assert(sqrt_product(1000, 4000) == 2000);
}

// Boundary: a = 1 with non-trivial b. Distinguishes `a == 0` shortcut
// from mutations to that constant.
#[test]
fn test_sqrt_product_a_one() {
    // sqrt(1 * 100) = 10
    assert(sqrt_product(1, 100) == 10);
}

// Exercise __wide_mul's high-half path: when both a and b have their high
// u64 set, the inner `a_hi * b_hi` term contributes meaningfully. Without
// this test, the mid-range Newton-iteration loop bound mutations and many
// __wide_mul-internal mutations are unkilled.
#[test]
fn test_sqrt_product_high_bit() {
    // a*b = 2^128. sqrt = 2^64.
    let a: u128 = 1 << 64;
    let b: u128 = 1 << 64;
    assert(sqrt_product(a, b) == 1 << 64);
}

// Products >= 2^128 with roots that are NOT a multiple of 2^64. These are the
// realistic pool sizes for 18-decimal tokens, where the wide-int branch's
// Newton seed must be an over-estimate. The cases above all sit below 2^128
// (the direct __u128_sqrt branch) or land exactly on a 2^64 multiple
// (test_sqrt_product_high_bit), so they never exercise this path.
#[test]
fn test_sqrt_product_above_128_non_power() {
    // 1 : 4000 at 18 decimals. product 4e39. Non-perfect-square; floor(sqrt)
    // pinned by the on-circuit r*r <= product < (r+1)*(r+1) verification
    // (sound because the hint is range-constrained to r < 2^113, no Field wrap).
    assert(
        sqrt_product(1000000000000000000, 4000000000000000000000)
            == 63245553203367586639,
    );
    // 19 : 19 at 18 decimals (perfect square; root 19e18).
    assert(
        sqrt_product(19000000000000000000, 19000000000000000000)
            == 19000000000000000000,
    );
    // 1000 : 1000 at 18 decimals.
    assert(
        sqrt_product(1000000000000000000000, 1000000000000000000000)
            == 1000000000000000000000,
    );
    // Just past the coincidentally-exact 2^64 x 2^64 case.
    let a: u128 = (1 << 64) + 1;
    assert(sqrt_product(a, a) == (1 << 64) + 1);
}

// Maximum u112 operands: the documented precondition bound (product ~ 2^224,
// still below the BN254 modulus). Also confirms the over-estimate seed itself
// stays within u128 at the top of the supported range.
#[test]
fn test_sqrt_product_u112_max() {
    let max_u112: u128 = (1 << 112) - 1;
    assert(sqrt_product(max_u112, max_u112) == max_u112);
}

// The hint range constraint in sqrt_product fails closed outside the documented
// u112 input domain. A product whose honest root reaches 2^113 trips
// SQRT_ROOT_RANGE rather than letting the Field-squared verification operate in
// the band where a forged root could wrap the modulus. Here a*b = 2^226 is still
// below the BN254 modulus, so the revert is the range guard, not a product wrap.
#[test(should_fail_with = "SQRT_ROOT_RANGE")]
fn test_sqrt_product_root_range_guard() {
    let out_of_domain: u128 = 1 << 113; // honest root would be 2^113 == bound
    let _ = sqrt_product(out_of_domain, out_of_domain);
}

// ============================================
// wide_sub_u256 / mul_u256_u256_to_u512 / wide_lt_u512 tests
// ============================================

global MAX_U128: u128 = 0xffffffffffffffffffffffffffffffff;

#[test]
fn test_wide_sub_u256_no_borrow() {
    let a = (5 as u128, 10 as u128);
    let b = (2 as u128, 3 as u128);
    assert_eq(wide_sub_u256(a, b), (3 as u128, 7 as u128));
}

#[test]
fn test_wide_sub_u256_with_borrow() {
    // (1, 0) - (0, 1) = (0, MAX_U128)
    let a = (1 as u128, 0 as u128);
    let b = (0 as u128, 1 as u128);
    assert_eq(wide_sub_u256(a, b), (0 as u128, MAX_U128));
}

// Borrow path with non-zero a_lo. The existing borrow tests use a_lo = 0,
// so `b_lo - a_lo` and `b_lo + a_lo` produce the same result there. This
// test forces a_lo > 0 so the operator direction matters.
// (1, 5) - (0, 7): 2^128 + 5 - 7 = 2^128 - 2, i.e. (0, MAX - 1).
#[test]
fn test_wide_sub_u256_borrow_a_lo_nonzero() {
    let a = (1 as u128, 5 as u128);
    let b = (0 as u128, 7 as u128);
    assert_eq(wide_sub_u256(a, b), (0 as u128, MAX_U128 - 1));
}

#[test]
fn test_wide_sub_u256_equal() {
    let a = (42 as u128, 99 as u128);
    assert_eq(wide_sub_u256(a, a), (0 as u128, 0 as u128));
}

#[test]
fn test_wide_sub_u256_borrow_max_low() {
    // (2, 0) - (0, MAX_U128) = (1, 1)
    //   Because 2*2^128 - (MAX_U128) = 2*2^128 - (2^128 - 1) = 2^128 + 1.
    //   As (hi, lo): hi = 1, lo = 1.
    let a = (2 as u128, 0 as u128);
    let b = (0 as u128, MAX_U128);
    assert_eq(wide_sub_u256(a, b), (1 as u128, 1 as u128));
}

#[test(should_fail_with = "WIDE_SUB_UNDERFLOW")]
fn test_wide_sub_u256_underflow_high() {
    let a = (0 as u128, 5 as u128);
    let b = (1 as u128, 0 as u128);
    let _ = wide_sub_u256(a, b);
}

#[test(should_fail_with = "WIDE_SUB_UNDERFLOW")]
fn test_wide_sub_u256_underflow_equal_hi() {
    let a = (3 as u128, 1 as u128);
    let b = (3 as u128, 2 as u128);
    let _ = wide_sub_u256(a, b);
}

#[test]
unconstrained fn test_mul_u256_u256_to_u512_small() {
    // (0, 3) * (0, 4) = 12
    let (hh, hm, ml, lo) = __mul_u256_u256_to_u512(
        (0 as u128, 3 as u128),
        (0 as u128, 4 as u128),
    );
    assert_eq(hh, 0 as u128);
    assert_eq(hm, 0 as u128);
    assert_eq(ml, 0 as u128);
    assert_eq(lo, 12 as u128);
}

#[test]
unconstrained fn test_mul_u256_u256_to_u512_crosses_128() {
    // (0, MAX) * (0, 2) = 2 * (2^128 - 1) = 2^129 - 2
    //   = 1 * 2^128 + (MAX - 1)
    let (hh, hm, ml, lo) = __mul_u256_u256_to_u512(
        (0 as u128, MAX_U128),
        (0 as u128, 2 as u128),
    );
    assert_eq(hh, 0 as u128);
    assert_eq(hm, 0 as u128);
    assert_eq(ml, 1 as u128);
    assert_eq(lo, MAX_U128 - 1);
}

#[test]
unconstrained fn test_mul_u256_u256_to_u512_pow_128() {
    // 2^128 * 2^128 = 2^256. As (hh, hm, ml, lo) = (0, 1, 0, 0).
    let (hh, hm, ml, lo) = __mul_u256_u256_to_u512(
        (1 as u128, 0 as u128),
        (1 as u128, 0 as u128),
    );
    assert_eq(hh, 0 as u128);
    assert_eq(hm, 1 as u128);
    assert_eq(ml, 0 as u128);
    assert_eq(lo, 0 as u128);
}

#[test]
unconstrained fn test_mul_u256_u256_to_u512_max_squared() {
    // MAX_U256 * MAX_U256 = (2^256 - 1)^2 = 2^512 - 2^257 + 1.
    // Limbs: hh = MAX, hm = MAX - 1, ml = 0, lo = 1.
    // Derivation:
    //   MAX_U128 * MAX_U128 = 2^256 - 2^129 + 1, (hi=MAX-1, lo=1) from __wide_mul.
    //   All four cross products produce the same (MAX-1, 1).
    //   ml = (MAX-1) + 1 + 1 = MAX+1 -> (0, carry=1)
    //   hm = (MAX-1) + (MAX-1) + 1 + 1 = 2*MAX -> (MAX-1, carry=1)
    //   hh = (MAX-1) + 1 = MAX
    let (hh, hm, ml, lo) = __mul_u256_u256_to_u512(
        (MAX_U128, MAX_U128),
        (MAX_U128, MAX_U128),
    );
    assert_eq(hh, MAX_U128);
    assert_eq(hm, MAX_U128 - 1);
    assert_eq(ml, 0 as u128);
    assert_eq(lo, 1 as u128);
}

#[test]
unconstrained fn test_mul_u256_u256_to_u512_zero() {
    let (hh, hm, ml, lo) = __mul_u256_u256_to_u512(
        (MAX_U128, MAX_U128),
        (0 as u128, 0 as u128),
    );
    assert_eq(hh, 0 as u128);
    assert_eq(hm, 0 as u128);
    assert_eq(ml, 0 as u128);
    assert_eq(lo, 0 as u128);
}

#[test]
unconstrained fn test_wide_lt_u512_equal() {
    let a = (1 as u128, 2 as u128, 3 as u128, 4 as u128);
    assert(!__wide_lt_u512(a, a));
}

#[test]
unconstrained fn test_wide_lt_u512_hh_decides() {
    let a = (1 as u128, 0 as u128, 0 as u128, 0 as u128);
    let b = (2 as u128, 0 as u128, 0 as u128, 0 as u128);
    assert(__wide_lt_u512(a, b));
    assert(!__wide_lt_u512(b, a));
}

#[test]
unconstrained fn test_wide_lt_u512_hm_decides_when_hh_equal() {
    let a = (5 as u128, 1 as u128, MAX_U128, MAX_U128);
    let b = (5 as u128, 2 as u128, 0 as u128, 0 as u128);
    assert(__wide_lt_u512(a, b));
}

#[test]
unconstrained fn test_wide_lt_u512_ml_decides() {
    let a = (5 as u128, 5 as u128, 1 as u128, MAX_U128);
    let b = (5 as u128, 5 as u128, 2 as u128, 0 as u128);
    assert(__wide_lt_u512(a, b));
}

#[test]
unconstrained fn test_wide_lt_u512_lo_decides() {
    let a = (5 as u128, 5 as u128, 5 as u128, 1 as u128);
    let b = (5 as u128, 5 as u128, 5 as u128, 2 as u128);
    assert(__wide_lt_u512(a, b));
}

// ============================================
// verify_k_invariant tests
// ============================================

#[test]
fn test_verify_k_equal() {
    // balances = reserves, no amounts in/out -> K unchanged. Passes.
    verify_k_invariant(1000, 1000, 1000, 1000, 0, 0, 30);
}

// fee_bps == scale (10000) violates the precondition `fee_bps < scale` and
// must trigger FEE_TOO_HIGH. Without this, the assert and its `<` operator
// are mutation-resilient (existing tests use fee_bps = 30, far below the
// boundary).
#[test(should_fail_with = "FEE_TOO_HIGH")]
fn test_verify_k_fee_too_high() {
    verify_k_invariant(1000, 1000, 1000, 1000, 0, 0, 10000);
}

#[test]
fn test_verify_k_strict_improvement() {
    // Donation without any transfer out: balances > reserves, fees applied to
    // amount_in (= balance - reserve since amount_out = 0). K strictly increases
    // because the donations dominate. Passes.
    let (a0_in, a1_in) = compute_amounts_in(1000, 1000, 0, 0, 1500, 2000);
    assert_eq(a0_in, 500);
    assert_eq(a1_in, 1000);
    verify_k_invariant(1500, 2000, 1000, 1000, a0_in, a1_in, 30);
}

#[test]
fn test_verify_k_one_sided_swap_passes() {
    // Simulate a swap: pair sent 10 of token1 out (amount1_out=10), got 11 of token0 back.
    // Pre-reserves (100, 100). Post-balances: (111, 90).
    // amount0_in = 111 - 100 = 11; amount1_in = 0.
    // fee_bps = 0 for clean math.
    // k_before = 100*100*10000*10000 = 10^12 * 10^4 = 10^12 * 10^4 = 1e16
    //   Actually: 100 * 10000 * 100 * 10000 = 10^12. Not 1e16.
    //   = 10^4 * 10^4 * 100 * 100 = 10^8 * 10^4 = 10^12.
    // k_after = (111*10000 - 11*0) * (90*10000 - 0*0) = 1,110,000 * 900,000 = 9.99e11.
    //   = 999,000,000,000.
    // Hmm, 999e9 < 1e12. K violation at zero fee!
    //
    // That's expected: constant product says 111*90 = 9990 < 100*100 = 10000.
    // So a "fair" swap at fee=0 actually has output slightly less to preserve K.
    //
    // For a passing zero-fee test: take K = 100 * 100 = 10000. If amount_in = 11,
    // amount_out for exact K is amount_out such that (100 + 11) * (100 - amount_out) >= 10000.
    //   (100 - amount_out) >= 10000/111, i.e., amount_out <= 100 - 90.09 = 9.90.
    // So amount_out = 9 would pass: (111) * (91) = 10101 >= 10000. Test that.
    let (a0_in, a1_in) = compute_amounts_in(100, 100, 0, 9, 111, 91);
    // Sanity: amount0_in == 11 (balance delta), amount1_in == 0.
    assert_eq(a0_in, 11);
    assert_eq(a1_in, 0);
    verify_k_invariant(111, 91, 100, 100, a0_in, a1_in, 0);
}

#[test(should_fail_with = "K_INVARIANT_VIOLATED")]
fn test_verify_k_violation() {
    // Pair sent out more than the curve allows. amount0_in=0, amount1_out=20.
    // Post: balance0=100, balance1=80. reserves=100,100. fee_bps=0.
    // k_before = 100*100*1e8 = 1e12
    // k_after = (100*10000) * (80*10000) = 1e6 * 8e5 = 8e11 < 1e12. Violation.
    let (a0_in, a1_in) = compute_amounts_in(100, 100, 0, 20, 100, 80);
    verify_k_invariant(100, 80, 100, 100, a0_in, a1_in, 0);
}

#[test]
fn test_verify_k_donation_output_side_passes() {
    // Simulate public swap where callback donates token_out back to pair.
    // Pair transferred 10 of token1 out, but callback donated 5 back.
    // Net balance1 change: reserve1 - 10 + 5 = reserve1 - 5.
    // amount0_in = balance0 - reserve0 = 11. amount1_in = donation = 5.
    // fee_bps = 0.
    // k_before = 100*100*1e8 = 1e12.
    // balances = (111, 95), reserves = (100, 100), amount1_out = 10.
    // expected1 = 100 - 10 = 90. balance1=95 > 90, so amount1_in = 5.
    // k_after = (111*10000) * (95*10000) = 1.11e6 * 9.5e5 = 1.0545e12 > 1e12. Passes.
    let (a0_in, a1_in) = compute_amounts_in(100, 100, 0, 10, 111, 95);
    // Derived amounts capture donation on the output side (5) plus net input (11).
    assert_eq(a0_in, 11);
    assert_eq(a1_in, 5);
    verify_k_invariant(111, 95, 100, 100, a0_in, a1_in, 0);
}

#[test]
fn test_verify_k_large_balance_no_wrap() {
    // balance > 2^112: the wide-int check handles it correctly without wrap.
    let big: u128 = (1 as u128) << 120; // 2^120, well past MAX_RESERVE (2^112-1)
    // Reserves stay u112-bounded per the caller invariant.
    let reserve: u128 = 1000;
    // Simulate a pure donation: balance_i starts at reserve_i, someone transfers
    // `big` extra into the pair directly. No amount_out by the pair, so no swap
    // happened. amount_i_in = balance_i - reserve_i = big. fee_bps applies to it
    // but since no actual swap, K should strictly increase.
    //
    // k_before = 1000 * 1000 * 1e8 = 1e14.
    // adj0 = big * 10000 - big * 30 = big * 9970 (for fee_bps = 30).
    // adj1 = same.
    // k_after = (big * 9970)^2 >> 1e14. Passes (no wrap with wide-int).
    let (a0_in, a1_in) = compute_amounts_in(reserve, reserve, 0, 0, big, big);
    verify_k_invariant(big, big, reserve, reserve, a0_in, a1_in, 30);
}
