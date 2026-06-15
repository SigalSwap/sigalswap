use sigalswap_core::{SigalSwapPair, pair::MINIMUM_LIQUIDITY};
use crate::test::utils::{setup, add_liquidity, swap_exact_in, AUTHWIT_NONCE};
use aztec::{protocol::{address::AztecAddress, traits::FromField}, test::helpers::txe_oracles};
use token::Token;
use sigalswap_lp_token::SigalSwapLPToken;

// ============================================
// Edge Cases & Recovery
// ============================================

/// Skim -- send tokens directly to pair, call skim, verify excess recovered.
///
/// Skim recovers tokens that were sent to the pair outside of normal operations
/// (e.g., accidental transfers). It sends the excess (balance - reserve) to `to`.
#[test]
unconstrained fn test_skim() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let recipient = env.create_contract_account();
    let token0 = Token::at(token0_address);
    let pair = SigalSwapPair::at(pair_address);

    // Add liquidity: reserves = balances = (20000, 20000)
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    // Send 500 token0 directly to pair's public balance (simulates accidental transfer)
    env.call_public(admin, token0.mint_to_public(pair_address, 500));
    assert_eq(env.view_public(token0.balance_of_public(pair_address)), 20500);

    // Skim excess to recipient
    env.call_private(recipient, pair.skim(recipient));

    // Verify recipient received exactly 500 token0 privately
    assert_eq(env.execute_utility(token0.balance_of_private(recipient)), 500);

    // Verify token1 was not affected (no excess)
    assert_eq(env.execute_utility(Token::at(token1_address).balance_of_private(recipient)), 0);

    // Verify pair balance restored to match reserves
    assert_eq(env.view_public(token0.balance_of_public(pair_address)), 20000);
}

/// skim(zero) reverts ZERO_RECIPIENT. A partial note targeted at the zero
/// address can never be completed, so any tokens transferred via the public
/// `_skim` continuation would be permanently locked. Mirror of the recipient
/// guards on `add_liquidity_public` and `remove_liquidity_public`.
#[test(should_fail_with = "ZERO_RECIPIENT")]
unconstrained fn test_skim_zero_recipient_reverts() {
    let (mut env, pair_address, _t0, _t1, _lp_address, _admin) = setup();
    let caller = env.create_contract_account();
    env.call_private(caller, SigalSwapPair::at(pair_address).skim(AztecAddress::zero()));
}

/// `_skim` mirrors `sync()`'s TWAP timestamp advance so a TWAP consumer
/// sampling at moments bracketing only skim calls still sees `T2 > T1` and
/// can divide cumulative deltas without special-casing 0/0. Asserts the
/// timestamp advances; combined with `test_twap_accumulation` it locks in
/// the cross-path symmetry.
#[test]
unconstrained fn test_skim_advances_twap_timestamp() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let recipient = env.create_contract_account();
    let token0 = Token::at(token0_address);
    let pair = SigalSwapPair::at(pair_address);

    // Seed reserves so the inner `compute_twap_update` has non-zero ratios
    // to accumulate. With zero reserves it short-circuits and only advances
    // the timestamp; we want both the accumulation and the timestamp paths
    // exercised.
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    let (_p0i_before, _p0f_before, _p1i_before, _p1f_before, ts_before) =
        env.execute_utility(pair.get_cumulative_prices());

    // Donate so skim has something to recover; the TWAP block runs
    // unconditionally regardless of whether there's anything to skim, but
    // a non-trivial skim makes the test resemble the production path.
    env.call_public(admin, token0.mint_to_public(pair_address, 500));

    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(100);

    env.call_private(recipient, pair.skim(recipient));

    let (_p0i_after, _p0f_after, _p1i_after, _p1f_after, ts_after) =
        env.execute_utility(pair.get_cumulative_prices());

    // Timestamp must strictly advance past the pre-skim sample.
    assert(ts_after > ts_before);
    assert(ts_after >= ts_before + 100);
}

/// Sync -- send tokens directly to pair, call sync, verify reserves updated.
///
/// Sync forces reserves to match actual token balances (donates excess to LPs).
/// Unlike skim, the excess stays in the pool and becomes part of reserves.
#[test]
unconstrained fn test_sync() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let token0 = Token::at(token0_address);
    let pair = SigalSwapPair::at(pair_address);

    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    // Send 500 token0 directly to pair (donation to LPs)
    env.call_public(admin, token0.mint_to_public(pair_address, 500));

    // Sync: reserves should update to match actual balances
    env.call_public(admin, pair.sync());

    // Verify reserves now include the donation
    let (r0, r1, _ts) = env.view_public(pair.get_reserves());
    assert_eq(r0, 20500);
    assert_eq(r1, 20000);

    // Verify the balance still matches (sync doesn't move tokens)
    assert_eq(env.view_public(token0.balance_of_public(pair_address)), 20500);
}

/// Zero refund -- add exact proportional liquidity, verify partial notes handled.
///
/// When the deposit is perfectly proportional, refund = 0 for both tokens.
/// The partial note prepared for refund must NOT be finalized with 0
/// (Aztec's PartialUintNote rejects zero-value completion).
#[test]
unconstrained fn test_zero_refund() {
    let (mut env, pair_address, token0_address, token1_address, lp_address, admin) = setup();

    let provider1 = env.create_contract_account();
    let provider2 = env.create_contract_account();
    let lp_token = SigalSwapLPToken::at(lp_address);

    // First deposit: 10000/20000 (1:2 ratio)
    // sqrt(200000000) = 14142; user gets 14142 - 10000 = 4142; total = 14142
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider1, 10000, 20000, 0, 0,
    );

    // Second deposit: exactly proportional (5000/10000 matches 1:2 ratio perfectly)
    // LP minted = min(5000 * 14142 / 10000, 10000 * 14142 / 20000) = min(7071, 7071) = 7071
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider2, 5000, 10000, 0, 0,
    );

    // Verify no refund: provider2 should have 0 private balance for both tokens
    assert_eq(env.execute_utility(Token::at(token0_address).balance_of_private(provider2)), 0);
    assert_eq(env.execute_utility(Token::at(token1_address).balance_of_private(provider2)), 0);

    // Verify exact LP tokens minted (hand-computed: 7071)
    assert_eq(env.execute_utility(lp_token.balance_of_private(provider2)), 7071);

    // Verify reserves updated correctly
    assert_eq(env.view_public(Token::at(token0_address).balance_of_public(pair_address)), 15000);
    assert_eq(env.view_public(Token::at(token1_address).balance_of_public(pair_address)), 30000);
}

/// TWAP accumulation -- verify cumulative prices after time advancement.
///
/// With 1:1 reserves (10000/10000), the price in both directions is 1.0.
/// After 100 seconds, cumulative price should be 100 (integer) + 0 (fraction).
///
/// Hand computation:
///   price0 = encode(reserve1) / reserve0 = encode(10000) / 10000
///          = UQ112x112 { integer: 1, fraction: 0 }  (exact 1.0)
///   cumulative0 += 1.0 * 100 = 100 (integer part)
///   Same for price1 (symmetric reserves)
#[test]
unconstrained fn test_twap_accumulation() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let pair = SigalSwapPair::at(pair_address);

    // Add 1:1 liquidity. This sets block_timestamp_last = T.
    // TWAP not accumulated (old reserves were 0).
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    // Verify accumulators start at 0
    let (p0_int_before, _, p1_int_before, _, _) =
        env.execute_utility(pair.get_cumulative_prices());
    assert_eq(p0_int_before, 0);
    assert_eq(p1_int_before, 0);

    // Advance time by 100 seconds
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(100);

    // Swap to trigger TWAP update.
    // TWAP uses OLD reserves (10000/10000) with time_elapsed ~ 100.
    let swapper = env.create_contract_account();
    swap_exact_in(
        env, pair_address, token0_address, token1_address,
        admin, swapper, 1000, 0,
    );

    // Read cumulative prices after swap
    let (p0_int, p0_frac, p1_int, p1_frac, _) =
        env.execute_utility(pair.get_cumulative_prices());

    // With 1:1 ratio, price = 1.0 in both directions.
    // Cumulative = 1.0 * time_elapsed. Integer should be >= 100.
    // (may be slightly > 100 if TXE block time adds extra seconds)
    // Cumulative integers are Field-typed; cast to u128 for comparison
    // (safe here since values are tiny).
    assert(p0_int as u128 >= 100);
    assert(p1_int as u128 >= 100);
    // Fraction should be 0 for 1:1 ratio (price is an exact integer)
    assert_eq(p0_frac, 0);
    assert_eq(p1_frac, 0);
}

/// Slippage protection -- swap with tight amount_out_min that fails.
///
/// With reserves (20000, 20000) and 1000 token0 input at 25 bps fee,
/// the actual output is 950. Setting amount_out_min = 951 should revert.
#[test(should_fail_with = "INSUFFICIENT_OUTPUT_AMOUNT")]
unconstrained fn test_slippage_protection() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();

    let provider = env.create_contract_account();

    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    // Actual output = 950; setting min to 951 should fail.
    let swapper = env.create_contract_account();
    swap_exact_in(
        env, pair_address, token0_address, token1_address,
        admin, swapper, 1000, 951,
    );
}

/// Smoke: pair.get_fee_to / get_reserves_last return expected values on a
/// fresh pair. Both fields default to zero before any sync_protocol_fee /
/// liquidity event.
#[test]
unconstrained fn test_pair_views_fee_to_and_reserves_last_default() {
    let (mut env, pair_address, _t0, _t1, _lp_address, _admin) = setup();
    let pair = SigalSwapPair::at(pair_address);

    let fee_to = env.execute_utility(pair.get_fee_to());
    assert_eq(fee_to, AztecAddress::zero());

    let (r0_last, r1_last) = env.execute_utility(pair.get_reserves_last());
    assert_eq(r0_last, 0 as u128);
    assert_eq(r1_last, 0 as u128);
}

/// quote_amount_out rejects token_in that's not this pair's token0 or token1.
#[test(should_fail_with = "TOKEN_IN_IS_INVALID")]
unconstrained fn test_quote_amount_out_invalid_token_reverts() {
    let (mut env, pair_address, _t0, _t1, _lp_address, _admin) = setup();
    let pair = SigalSwapPair::at(pair_address);
    let stranger = AztecAddress::from_field(0xdead);

    let _ = env.execute_utility(pair.quote_amount_out(1000 as u128, stranger));
}

/// quote_amount_in rejects token_out that's not this pair's token0 or token1.
#[test(should_fail_with = "TOKEN_OUT_IS_INVALID")]
unconstrained fn test_quote_amount_in_invalid_token_reverts() {
    let (mut env, pair_address, _t0, _t1, _lp_address, _admin) = setup();
    let pair = SigalSwapPair::at(pair_address);
    let stranger = AztecAddress::from_field(0xdead);

    let _ = env.execute_utility(pair.quote_amount_in(1000 as u128, stranger));
}

/// get_amount_in rejects amount_out == reserve_out with INSUFFICIENT_LIQUIDITY,
/// not the misleading DIV_BY_ZERO that would otherwise surface from the
/// safe_sub-then-multiply denominator going to zero. Exercised here via
/// quote_amount_in (which routes through get_amount_in) at a fully-funded
/// pool, asking to drain the entire reserve_out side.
///
/// Asking to receive exactly reserve_out worth of token1 must surface
/// INSUFFICIENT_LIQUIDITY rather than bottoming out at DIV_BY_ZERO.
#[test(should_fail_with = "INSUFFICIENT_LIQUIDITY")]
unconstrained fn test_quote_amount_in_drain_reserve_reverts_with_insufficient_liquidity() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();
    let provider = env.create_contract_account();
    let pair = SigalSwapPair::at(pair_address);

    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 100000, 100000, 0, 0,
    );

    let _ = env.execute_utility(pair.quote_amount_in(100000 as u128, token1_address));
}

/// Quote read-path execution on an ASYMMETRIC pool.
///
/// Seeds a 1:4 pool (10000 token0 / 40000 token1) and drives the healthy
/// read-paths, including `quote_amount_in_public` (the public-view sibling
/// used by the router's exact-output multi-hop path):
///
///   - `quote_amount_out(1000, token0)` -> token1 out. Hand-computed at fee 25
///     bps (no protocol fee), reserve_in=10000, reserve_out=40000:
///       amount_in_with_fee = 1000 * 9975 = 9_975_000
///       denominator        = 10000 * 10000 + 9_975_000 = 109_975_000
///       out = floor(9_975_000 * 40000 / 109_975_000) = 3628
///     The reverse direction `quote_amount_out(1000, token1)` yields only 243
///     (reserve_in=40000, reserve_out=10000). Pinning 3628 (and asserting the
///     two directions differ) catches a swapped-reserve direction bug that a
///     symmetric pool would hide.
///
///   - `quote_amount_in_public(amount_out, token1)` is the fee-aware inverse of
///     `quote_amount_out` in the token0->token1 direction. Feeding back the 3628
///     output must return the original 1000 input (the ceiling lands exactly),
///     and the input must be strictly positive. A swapped direction here would
///     return a 4456-scale value, not 1000.
#[test]
unconstrained fn test_quote_read_path_asymmetric_pool() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();
    let provider = env.create_contract_account();
    let pair = SigalSwapPair::at(pair_address);

    // 1:4 asymmetric reserves: token0 = 10000, token1 = 40000.
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 10000, 40000, 0, 0,
    );

    // quote_amount_out: known input -> output, both directions.
    let out_t0_to_t1 = env.execute_utility(pair.quote_amount_out(1000 as u128, token0_address));
    assert_eq(out_t0_to_t1, 3628 as u128);
    let out_t1_to_t0 = env.execute_utility(pair.quote_amount_out(1000 as u128, token1_address));
    assert_eq(out_t1_to_t0, 243 as u128);
    // Directions must differ on an asymmetric pool (swapped-reserve guard).
    assert(out_t0_to_t1 != out_t1_to_t0);

    // quote_amount_in_public (public view).
    // Required token0 input for `out_t0_to_t1` token1 output must be positive
    // and (since get_amount_in is the ceiling inverse of get_amount_out here)
    // round back to the original 1000 input.
    let in_for_round_trip: u128 =
        env.view_public(pair.quote_amount_in_public(out_t0_to_t1, token1_address));
    assert(in_for_round_trip > 0 as u128);
    assert_eq(in_for_round_trip, 1000 as u128);

    // A direct quote_amount_in_public for a 1000 token1 output (token0 in)
    // is the small-input side of the 1:4 pool: positive and well below the
    // opposite direction's requirement.
    let in_token0_for_1000_token1: u128 =
        env.view_public(pair.quote_amount_in_public(1000 as u128, token1_address));
    assert_eq(in_token0_for_1000_token1, 258 as u128);
    let in_token1_for_1000_token0: u128 =
        env.view_public(pair.quote_amount_in_public(1000 as u128, token0_address));
    assert_eq(in_token1_for_1000_token0, 4456 as u128);
    assert(in_token0_for_1000_token1 < in_token1_for_1000_token0);
}
