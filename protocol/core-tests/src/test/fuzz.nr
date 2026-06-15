// Fuzz harnesses for AMM math invariants.
//
// Run with: nargo fuzz --timeout 120
//
// Uses u32 parameters capped to realistic AMM ranges.
// The contract enforces u112 reserves via assert_reserve_fits.
// We use u32 (max ~4e9) to keep intermediates within u128.

use sigalswap_core::pair::{
    get_amount_out, get_amount_in, compute_liquidity, compute_mint_fee,
    MAX_RESERVE, MINIMUM_LIQUIDITY,
};
use sigalswap_core::math::wide::{mul_div, sqrt_product, verify_k_invariant};

// Property 1: K invariant -- K never decreases after a swap
#[fuzz]
fn fuzz_k_invariant(amount_in: u32, reserve_in: u32, reserve_out: u32, fee_bps: u32) {
    let ri = if reserve_in < 10000 { 10000 as u128 } else { reserve_in as u128 };
    let ro = if reserve_out < 10000 { 10000 as u128 } else { reserve_out as u128 };
    let f = if fee_bps == 0 { 1 as u128 } else if fee_bps >= 10000 { 9999 as u128 } else { fee_bps as u128 };
    let ai_raw = if amount_in == 0 { 1 as u128 } else { amount_in as u128 };
    let max_swap = ri / 2;
    let ai = if ai_raw > max_swap { max_swap } else { ai_raw };
    if ai == 0 { } else {
        let ao = get_amount_out(ai, ri, ro, f);
        let k_before = ri as Field * ro as Field;
        let k_after = (ri + ai) as Field * (ro - ao) as Field;
        let diff = k_after - k_before;
        let diff_u128 = diff as u128;
        assert(diff_u128 as Field == diff, "K_DECREASED");
    }
}

// Property 2: Output is always strictly less than output reserve
#[fuzz]
fn fuzz_output_bounded(amount_in: u32, reserve_in: u32, reserve_out: u32, fee_bps: u32) {
    let ri = if reserve_in == 0 { 1 as u128 } else { reserve_in as u128 };
    let ro = if reserve_out == 0 { 1 as u128 } else { reserve_out as u128 };
    let f = if fee_bps == 0 { 1 as u128 } else if fee_bps >= 10000 { 9999 as u128 } else { fee_bps as u128 };
    let ai = if amount_in == 0 { 1 as u128 } else { amount_in as u128 };
    let ao = get_amount_out(ai, ri, ro, f);
    assert(ao < ro, "OUTPUT_EXCEEDS_RESERVE");
}

// Property 3: Monotonicity -- larger input gives larger or equal output
#[fuzz]
fn fuzz_monotonicity(amount1: u32, delta: u32, reserve_in: u32, reserve_out: u32, fee_bps: u32) {
    let ri = if reserve_in < 1000 { 1000 as u128 } else { reserve_in as u128 };
    let ro = if reserve_out == 0 { 1 as u128 } else { reserve_out as u128 };
    let f = if fee_bps == 0 { 1 as u128 } else if fee_bps >= 10000 { 9999 as u128 } else { fee_bps as u128 };
    let max_swap = ri / 2;
    let a1 = if amount1 == 0 { 1 as u128 } else { amount1 as u128 };
    let a1c = if a1 >= max_swap { max_swap - 1 } else { a1 };
    let d = if delta == 0 { 1 as u128 } else { delta as u128 };
    let remaining = max_swap - a1c;
    let dc = if d > remaining { remaining } else { d };
    if dc == 0 { } else {
        let a2 = a1c + dc;
        let o1 = get_amount_out(a1c, ri, ro, f);
        let o2 = get_amount_out(a2, ri, ro, f);
        assert(o2 >= o1, "MONOTONICITY_VIOLATED");
    }
}

// Property 4: Round-trip loss -- swap A->B->A always returns less
#[fuzz]
fn fuzz_roundtrip_loss(amount_in: u32, reserve0: u32, reserve1: u32, fee_bps: u32) {
    let r0 = if reserve0 < 10000 { 10000 as u128 } else { reserve0 as u128 };
    let r1 = if reserve1 < 10000 { 10000 as u128 } else { reserve1 as u128 };
    let f = if fee_bps == 0 { 1 as u128 } else if fee_bps >= 10000 { 9999 as u128 } else { fee_bps as u128 };
    let ai_raw = if amount_in < 100 { 100 as u128 } else { amount_in as u128 };
    let max_swap = r0 / 4;
    let ai = if ai_raw > max_swap { max_swap } else { ai_raw };
    if ai < 100 { } else {
        let b_out = get_amount_out(ai, r0, r1, f);
        if (b_out > 0) & ((r1 - b_out) > 0) {
            let a_back = get_amount_out(b_out, r1 - b_out, r0 + ai, f);
            assert(a_back < ai, "FREE_MONEY");
        }
    }
}

// Property 5: getAmountIn is conservative
#[fuzz]
fn fuzz_amount_in_conservative(desired_out: u32, reserve_in: u32, reserve_out: u32, fee_bps: u32) {
    let ri = if reserve_in == 0 { 1 as u128 } else { reserve_in as u128 };
    let ro = if reserve_out < 1000 { 1000 as u128 } else { reserve_out as u128 };
    let f = if fee_bps == 0 { 1 as u128 } else if fee_bps >= 10000 { 9999 as u128 } else { fee_bps as u128 };
    let max_out = ro / 4;
    let do_raw = if desired_out == 0 { 1 as u128 } else { desired_out as u128 };
    let dout = if do_raw > max_out { max_out } else { do_raw };
    if dout == 0 { } else {
        let req_in = get_amount_in(dout, ri, ro, f);
        if req_in <= MAX_RESERVE {
            let actual = get_amount_out(req_in, ri, ro, f);
            assert(actual >= dout, "AMOUNT_IN_NOT_CONSERVATIVE");
        }
    }
}

// Property 6: First deposit LP = sqrt(a*b) - MINIMUM_LIQUIDITY
#[fuzz]
fn fuzz_first_deposit(amount0: u32, amount1: u32) {
    // Clamp above MINIMUM_LIQUIDITY (10_000) with margin so sqrt(a*b) strictly
    // exceeds the floor and compute_liquidity doesn't hit INSUFFICIENT_INITIAL_LIQUIDITY.
    let a0 = if amount0 < 100000 { 100000 as u128 } else { amount0 as u128 };
    let a1 = if amount1 < 100000 { 100000 as u128 } else { amount1 as u128 };
    let lp = compute_liquidity(a0, a1, 0, 0, 0);
    let expected = sqrt_product(a0, a1) - MINIMUM_LIQUIDITY;
    assert(lp == expected, "FIRST_DEPOSIT_MISMATCH");
}

// Property 6b: sqrt_product is exact across the full u112 x u112 range, where
// the product crosses 2^128 into the wide-int branch. fuzz_first_deposit uses
// u32 inputs (product < 2^64), so it only ever exercises the direct branch;
// this harness forces both operands into [2^100, 2^112) so every sample lands
// in the wide branch yet stays below the BN254 modulus. sqrt_product asserts
// r*r <= a*b < (r+1)*(r+1) on-circuit, so a clean return IS the correctness
// property; an under- or over-estimating hint reverts.
#[fuzz]
fn fuzz_sqrt_product_wide(a_raw: u128, b_raw: u128) {
    let mask: u128 = (1 << 112) - 1;
    let a = (a_raw & mask) | (1 << 100);
    let b = (b_raw & mask) | (1 << 100);
    let r = sqrt_product(a, b);
    assert(r > 0, "SQRT_PRODUCT_ZERO");
}

// Property 7: Subsequent deposit LP is proportional
#[fuzz]
fn fuzz_subsequent_deposit(amount0: u32, reserve0: u32, reserve1: u32, total_supply: u32) {
    let r0 = if reserve0 < 10000 { 10000 as u128 } else { reserve0 as u128 };
    let r1 = if reserve1 < 10000 { 10000 as u128 } else { reserve1 as u128 };
    let ts = if total_supply < 10000 { 10000 as u128 } else { total_supply as u128 };
    let max_dep = r0 / 4;
    let a0_raw = if amount0 == 0 { 1 as u128 } else { amount0 as u128 };
    let a0 = if a0_raw > max_dep { max_dep } else { a0_raw };
    if a0 == 0 { } else {
        let a1 = mul_div(a0, r1, r0);
        if a1 > 0 {
            let lp = compute_liquidity(a0, a1, r0, r1, ts);
            // LP = min(a0*ts/r0, a1*ts/r1). Due to integer rounding,
            // lp may be <= a0*ts/r0. LP can be 0 for tiny deposits
            // (the contract rejects these via INSUFFICIENT_LIQUIDITY_MINTED).
            let upper_bound = mul_div(a0, ts, r0);
            assert(lp <= upper_bound, "LP_EXCEEDS_UPPER_BOUND");
        }
    }
}

// The harnesses above clamp every operand to u32 (product < 2^64), so the
// live swap/liquidity formulas are only ever exercised in the direct-arithmetic
// regime. get_amount_out / get_amount_in / compute_liquidity accept u128
// reserves capped at MAX_RESERVE = 2^112 - 1, where the Field intermediates run
// up to ~2^238 -- the "products cross 2^128" surface where a sqrt hint error
// would slip through. The u112 harnesses below force both reserves and the
// trade size into [2^100, 2^112) so every sample lands in that high regime
// (still below the BN254 modulus). All masks use (1 << 112) - 1 then OR in
// 2^100 for a nonzero floor; trade sizes are bounded to a safe fraction of the
// reserve.

global U112_MASK: u128 = (1 << 112) - 1;

// Property 1 (u112): K never decreases after a swap, checked via Field
// comparison since K ~ 2^224 overflows u128 (the u32 fuzz_k_invariant could cast
// the K delta to u128; here we compare k_after >= k_before in Field directly).
#[fuzz]
fn fuzz_k_invariant_u112(amount_in: u128, reserve_in: u128, reserve_out: u128, fee_bps: u32) {
    let ri = (reserve_in & U112_MASK) | (1 << 100);
    let ro = (reserve_out & U112_MASK) | (1 << 100);
    let f = (fee_bps % 9999) as u128 + 1; // [1, 9999], below FEE_TOO_HIGH
    let max_swap = ri / 2;
    let ai_raw = (amount_in & U112_MASK) | 1;
    let ai = if ai_raw > max_swap { max_swap } else { ai_raw };
    let ao = get_amount_out(ai, ri, ro, f);
    let k_before = (ri as Field) * (ro as Field);
    let k_after = ((ri + ai) as Field) * ((ro - ao) as Field);
    assert(!k_after.lt(k_before), "K_DECREASED");
}

// Property 5 (u112): getAmountIn is conservative -- the input it quotes for a
// desired output, fed back through getAmountOut, yields at least that output.
#[fuzz]
fn fuzz_amount_in_conservative_u112(
    desired_out: u128,
    reserve_in: u128,
    reserve_out: u128,
    fee_bps: u32,
) {
    let ri = (reserve_in & U112_MASK) | (1 << 100);
    let ro = (reserve_out & U112_MASK) | (1 << 100);
    let f = (fee_bps % 9999) as u128 + 1;
    let max_out = ro / 4;
    let do_raw = (desired_out & U112_MASK) | 1;
    let dout = if do_raw > max_out { max_out } else { do_raw };
    let req_in = get_amount_in(dout, ri, ro, f);
    if req_in <= MAX_RESERVE {
        let actual = get_amount_out(req_in, ri, ro, f);
        assert(actual >= dout, "AMOUNT_IN_NOT_CONSERVATIVE");
    }
}

// Property 7 (u112): subsequent-deposit LP stays at or below the proportional
// upper bound a0 * totalSupply / reserve0 at u112 reserve/supply magnitudes.
// Trade size <= reserve0 / 4 keeps the matched a1 below MAX_RESERVE.
#[fuzz]
fn fuzz_subsequent_deposit_u112(
    amount0: u128,
    reserve0: u128,
    reserve1: u128,
    total_supply: u128,
) {
    let r0 = (reserve0 & U112_MASK) | (1 << 100);
    let r1 = (reserve1 & U112_MASK) | (1 << 100);
    let ts = (total_supply & U112_MASK) | (1 << 100);
    let max_dep = r0 / 4;
    let a0_raw = (amount0 & U112_MASK) | 1;
    let a0 = if a0_raw > max_dep { max_dep } else { a0_raw };
    let a1 = mul_div(a0, r1, r0);
    if (a1 > 0) & (a1 <= MAX_RESERVE) {
        let lp = compute_liquidity(a0, a1, r0, r1, ts);
        let upper_bound = mul_div(a0, ts, r0);
        assert(lp <= upper_bound, "LP_EXCEEDS_UPPER_BOUND");
    }
}

// Property: the LIVE on-chain K-guard `verify_k_invariant` (the u256/u512 limb
// arithmetic actually executed on every swap/flash path) accepts a correctly
// computed swap at u112 reserve magnitudes. The other K fuzz harness checks K
// via a Field product on get_amount_out's output -- a DIFFERENT code path than
// verify_k_invariant's manual carry/borrow limb math. Here reserves in
// [2^100, 2^112) make rs0*rs1 ~ 2^246, so __wide_mul / __mul_u256_u256_to_u512 /
// __wide_lt_u512 all engage their multi-limb branches. A clean return is the
// property: a valid swap never trips K_INVARIANT_VIOLATED through the live math.
#[fuzz]
fn fuzz_verify_k_invariant_u112(amount_in: u128, reserve_in: u128, reserve_out: u128, fee_bps: u32) {
    let ri = (reserve_in & U112_MASK) | (1 << 100);
    let ro = (reserve_out & U112_MASK) | (1 << 100);
    let f = (fee_bps % 9999) as u128 + 1; // [1, 9999], below FEE_TOO_HIGH
    let max_swap = ri / 2;
    let ai_raw = (amount_in & U112_MASK) | 1;
    let ai = if ai_raw > max_swap { max_swap } else { ai_raw };
    let ao = get_amount_out(ai, ri, ro, f);
    // token0-in swap: balance0 = ri + ai (input arrived), balance1 = ro - ao
    // (output left). amount0_in = ai (fee-charged side), amount1_in = 0.
    verify_k_invariant(ri + ai, ro - ao, ri, ro, ai, 0, f);
}

// The REJECT side of the live K-guard, through the multi-limb arithmetic: taking
// one unit MORE output than get_amount_out allows drives k_after below k_before
// and must revert. The end-to-end reject canary uses ~10000-scale reserves
// (single-limb); this pins the reject path at u112 (rs0*rs1 ~ 2^246, the
// carry-propagating regime).
#[test(should_fail_with = "K_INVARIANT_VIOLATED")]
fn test_verify_k_invariant_rejects_extraction_wide() {
    let r: u128 = 1 << 110; // ~1.3e33, well under MAX_RESERVE; rs = r*10000 ~ 2^123
    let ai: u128 = 1 << 100;
    let f: u128 = 25;
    let ao_valid = get_amount_out(ai, r, r, f);
    // One extra output unit beyond the floored valid amount -> k_after < k_before.
    verify_k_invariant(r + ai, r - (ao_valid + 1), r, r, ai, 0, f);
}

// Property 2 (u112): output strictly below the output reserve at u112 magnitudes
// (the u32 fuzz_output_bounded never exercises the wide-int internals).
#[fuzz]
fn fuzz_output_bounded_u112(amount_in: u128, reserve_in: u128, reserve_out: u128, fee_bps: u32) {
    let ri = (reserve_in & U112_MASK) | (1 << 100);
    let ro = (reserve_out & U112_MASK) | (1 << 100);
    let f = (fee_bps % 9999) as u128 + 1;
    let max_swap = ri / 2;
    let ai_raw = (amount_in & U112_MASK) | 1;
    let ai = if ai_raw > max_swap { max_swap } else { ai_raw };
    let ao = get_amount_out(ai, ri, ro, f);
    assert(ao < ro, "OUTPUT_EXCEEDS_RESERVE");
}

// Property 3 (u112): monotonic output in input at u112 magnitudes.
#[fuzz]
fn fuzz_monotonicity_u112(amount1: u128, delta: u128, reserve_in: u128, reserve_out: u128, fee_bps: u32) {
    let ri = (reserve_in & U112_MASK) | (1 << 100);
    let ro = (reserve_out & U112_MASK) | (1 << 100);
    let f = (fee_bps % 9999) as u128 + 1;
    let max_swap = ri / 2;
    let a1raw = (amount1 & U112_MASK) | 1;
    let a1c = if a1raw >= max_swap { max_swap - 1 } else { a1raw };
    let remaining = max_swap - a1c;
    let d_raw = (delta & U112_MASK) | 1;
    let dc = if d_raw > remaining { remaining } else { d_raw };
    if dc > 0 {
        let o1 = get_amount_out(a1c, ri, ro, f);
        let o2 = get_amount_out(a1c + dc, ri, ro, f);
        assert(o2 >= o1, "MONOTONICITY_VIOLATED");
    }
}

// Property 4 (u112): round-trip A->B->A returns strictly less at u112 magnitudes.
// Reserves are bounded to [2^100, 2^110) (not the full 2^112) so the SECOND
// swap's reserve_out = r0 + ai stays <= MAX_RESERVE (else get_amount_out would
// correctly revert RESERVE_OVERFLOW on the synthetic post-swap reserve, which is
// a harness artifact, not a property violation). 2^110 still exercises the
// wide-arithmetic regime.
#[fuzz]
fn fuzz_roundtrip_loss_u112(amount_in: u128, reserve0: u128, reserve1: u128, fee_bps: u32) {
    let mask110: u128 = (1 << 110) - 1;
    let r0 = (reserve0 & mask110) | (1 << 100);
    let r1 = (reserve1 & mask110) | (1 << 100);
    let f = (fee_bps % 9999) as u128 + 1;
    let max_swap = r0 / 4;
    let ai_raw = (amount_in & mask110) | (1 << 64);
    let ai = if ai_raw > max_swap { max_swap } else { ai_raw };
    let b_out = get_amount_out(ai, r0, r1, f);
    if (b_out > 0) & ((r1 - b_out) > 0) {
        // r0 + ai <= 2^110 + 2^108 < MAX_RESERVE, so the second swap is in-domain.
        let a_back = get_amount_out(b_out, r1 - b_out, r0 + ai, f);
        assert(a_back < ai, "FREE_MONEY");
    }
}

// Property (u112): the protocol mint-fee formula composes two sqrt_product calls
// plus a Field-domain mul_div, and is the only live wide-math composition with no
// u112 harness. Forcing the `_last` reserves into [2^100, 2^112) makes their
// product ~2^200+ land in sqrt_product's wide-int branch, and the grown reserves
// (>= the `_last` reserves) keep root_k >= root_k_last so the formula runs the
// full numerator/denominator path. The mint fraction is phi = percent/(100+percent)
// of the sqrt-K growth, and the growth fraction is itself < 1, so the minted fee
// is strictly below total_supply * percent / 100 <= total_supply (percent <= 100).
// A clean return plus that proportional bound is the property; an over/under-
// estimating sqrt hint inside compute_mint_fee would revert in sqrt_product.
#[fuzz]
fn fuzz_mint_fee_u112(
    reserve0_last: u128,
    reserve1_last: u128,
    growth0: u128,
    growth1: u128,
    total_supply: u128,
    protocol_fee_percent: u32,
) {
    // `_last` reserves in [2^100, 2^112): their product crosses 2^128 so the
    // sqrt_product(reserve0_last, reserve1_last) call hits the wide branch.
    let r0_last = (reserve0_last & U112_MASK) | (1 << 100);
    let r1_last = (reserve1_last & U112_MASK) | (1 << 100);
    let ts = (total_supply & U112_MASK) | (1 << 100);
    // protocol_fee_percent in [1, 100].
    let pct = ((protocol_fee_percent % 100) as u128) + 1;
    // Grow each reserve by a delta bounded so the current reserve stays in u112:
    // delta <= reserve_last / 2 keeps current <= 1.5 * 2^112 < MAX_RESERVE, and
    // current >= reserve_last guarantees root_k >= root_k_last.
    let d0 = (growth0 & U112_MASK) % (r0_last / 2);
    let d1 = (growth1 & U112_MASK) % (r1_last / 2);
    let r0 = r0_last + d0;
    let r1 = r1_last + d1;
    let fee = compute_mint_fee(r0, r1, r0_last, r1_last, ts, pct);
    // phi * growth_fraction < 1, so the minted protocol fee never exceeds supply.
    assert(fee <= ts, "MINT_FEE_EXCEEDS_SUPPLY");
}
