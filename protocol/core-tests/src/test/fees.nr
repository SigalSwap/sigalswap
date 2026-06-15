use sigalswap_core::{SigalSwapPair, pair::compute_mint_fee};
use crate::test::utils::{setup, add_liquidity, swap_exact_in};
use token::Token;
use sigalswap_lp_token::SigalSwapLPToken;

// ============================================
// Protocol Fees
// ============================================

/// Enable protocol fee, verify fee_to receives LP tokens after swap + liquidity event.
#[test]
unconstrained fn test_enable_protocol_fee() {
    let (mut env, pair_address, token0_address, token1_address, lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let fee_recipient = env.create_contract_account();
    let lp_token = SigalSwapLPToken::at(lp_address);
    let pair = SigalSwapPair::at(pair_address);

    // Enable protocol fee: 20% on top of 0.25% LP fee
    env.call_public(admin, pair.set_protocol_fee(fee_recipient, 20, true));

    // Add initial liquidity (1M/1M) -- sets reserves_last
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 1000000, 1000000, 0, 0,
    );

    // Swap 100K token0 to generate K growth
    let swapper = env.create_contract_account();
    swap_exact_in(
        env, pair_address, token0_address, token1_address,
        admin, swapper, 100000, 0,
    );

    // Add more liquidity -- triggers protocol fee mint
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 100000, 100000, 0, 0,
    );

    // Verify fee_recipient received LP tokens (public balance from mint_to_public)
    let fee_lp = env.view_public(lp_token.balance_of_public(fee_recipient));
    assert(fee_lp > 0);
}

/// Fee accrual -- multiple swaps increase fee_to's LP balance at each liquidity event.
#[test]
unconstrained fn test_fee_accrual() {
    let (mut env, pair_address, token0_address, token1_address, lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let fee_recipient = env.create_contract_account();
    let lp_token = SigalSwapLPToken::at(lp_address);
    let pair = SigalSwapPair::at(pair_address);

    env.call_public(admin, pair.set_protocol_fee(fee_recipient, 20, true));

    // First deposit (sets reserves_last)
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 1000000, 1000000, 0, 0,
    );

    // First swap
    let swapper1 = env.create_contract_account();
    swap_exact_in(
        env, pair_address, token0_address, token1_address,
        admin, swapper1, 100000, 0,
    );

    // Second deposit -- triggers first fee mint
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 100000, 100000, 0, 0,
    );

    let fee_after_first = env.view_public(lp_token.balance_of_public(fee_recipient));
    assert(fee_after_first > 0);

    // Second swap (opposite direction to generate more K growth)
    let swapper2 = env.create_contract_account();
    swap_exact_in(
        env, pair_address, token1_address, token0_address,
        admin, swapper2, 100000, 0,
    );

    // Third deposit -- triggers second fee mint
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 50000, 50000, 0, 0,
    );

    let fee_after_second = env.view_public(lp_token.balance_of_public(fee_recipient));
    assert(fee_after_second > fee_after_first);
}

/// Fee math -- verify minted amount matches hand-computed expected value.
///
/// SigalSwap protocol-fee formula (protocol_fee_percent = p):
///   liquidity = totalSupply * p * (rootK - rootKLast) / (rootK * 100 + rootKLast * p)
///
/// Hand computation for this test:
///   Initial reserves: (1000000, 1000000), totalSupply = 1000000
///   After 100K swap with 30 bps total fee:
///     amount_in_with_fee = 100000 * 9970 = 997000000
///     output = floor(997000000 * 1000000 / (1000000*10000 + 997000000)) = 90661
///     New reserves: (1100000, 909339)
///   rootK = floor(sqrt(1100000 * 909339)) = floor(sqrt(1000272900000)) = 1000136
///   rootKLast = floor(sqrt(1000000 * 1000000)) = 1000000
///   delta = 136
///   denominator = 1000136*100 + 1000000*20 = 120013600
///   fee = floor(1000000 * 20 * 136 / 120013600) = floor(2720000000 / 120013600) = 22
#[test]
unconstrained fn test_fee_math() {
    let (mut env, pair_address, token0_address, token1_address, lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let fee_recipient = env.create_contract_account();
    let lp_token = SigalSwapLPToken::at(lp_address);
    let pair = SigalSwapPair::at(pair_address);
    let token0 = Token::at(token0_address);
    let token1 = Token::at(token1_address);

    env.call_public(admin, pair.set_protocol_fee(fee_recipient, 20, true));

    // Add initial liquidity (1M/1M) -- sets reserves_last = (1M, 1M)
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 1000000, 1000000, 0, 0,
    );

    // Verify initial state matches assumptions
    assert_eq(env.view_public(token0.balance_of_public(pair_address)), 1000000);
    assert_eq(env.view_public(token1.balance_of_public(pair_address)), 1000000);
    assert_eq(env.view_public(lp_token.total_supply()), 1000000);

    // Swap 100K token0 to generate K growth
    let swapper = env.create_contract_account();
    swap_exact_in(
        env, pair_address, token0_address, token1_address,
        admin, swapper, 100000, 0,
    );

    // Verify post-swap reserves match hand computation
    // With 30 bps total fee (25 LP + 5 protocol): output = 90661
    let r0 = env.view_public(token0.balance_of_public(pair_address));
    let r1 = env.view_public(token1.balance_of_public(pair_address));
    assert_eq(r0, 1100000);
    assert_eq(r1, 909339);

    // Trigger fee mint via add_liquidity
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 50000, 50000, 0, 0,
    );

    // Verify fee_recipient received exactly 22 LP tokens (hand-computed above)
    let actual_fee = env.view_public(lp_token.balance_of_public(fee_recipient));
    assert_eq(actual_fee, 22);
}

/// Disable fee -- verify reserves_last zeroed and no fees minted after disable.
#[test]
unconstrained fn test_disable_fee() {
    let (mut env, pair_address, token0_address, token1_address, lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let fee_recipient = env.create_contract_account();
    let lp_token = SigalSwapLPToken::at(lp_address);
    let pair = SigalSwapPair::at(pair_address);

    // Enable fee, add liquidity, swap to generate growth
    env.call_public(admin, pair.set_protocol_fee(fee_recipient, 20, true));
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 1000000, 1000000, 0, 0,
    );
    let swapper = env.create_contract_account();
    swap_exact_in(
        env, pair_address, token0_address, token1_address,
        admin, swapper, 100000, 0,
    );

    // Disable fee (zeros reserves_last)
    env.call_public(admin, pair.set_protocol_fee(fee_recipient, 0, false));

    // Do more swaps while fee is off
    let swapper2 = env.create_contract_account();
    swap_exact_in(
        env, pair_address, token1_address, token0_address,
        admin, swapper2, 50000, 0,
    );

    // Add liquidity -- should NOT mint any fee tokens
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 50000, 50000, 0, 0,
    );

    // Fee recipient should have 0 LP tokens
    let fee_lp = env.view_public(lp_token.balance_of_public(fee_recipient));
    assert_eq(fee_lp, 0);
}

/// Re-enable after gap -- no windfall for growth during off period.
#[test]
unconstrained fn test_reenable_no_windfall() {
    let (mut env, pair_address, token0_address, token1_address, lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let fee_recipient = env.create_contract_account();
    let lp_token = SigalSwapLPToken::at(lp_address);
    let pair = SigalSwapPair::at(pair_address);

    // Phase 1: Enable fee and establish baseline
    env.call_public(admin, pair.set_protocol_fee(fee_recipient, 20, true));
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 1000000, 1000000, 0, 0,
    );

    // Phase 2: Disable fee
    env.call_public(admin, pair.set_protocol_fee(fee_recipient, 0, false));

    // Phase 3: Big swaps while fee is off (K grows a lot)
    let swapper1 = env.create_contract_account();
    swap_exact_in(
        env, pair_address, token0_address, token1_address,
        admin, swapper1, 200000, 0,
    );
    let swapper2 = env.create_contract_account();
    swap_exact_in(
        env, pair_address, token1_address, token0_address,
        admin, swapper2, 200000, 0,
    );

    // Phase 4: Re-enable fee
    env.call_public(admin, pair.set_protocol_fee(fee_recipient, 20, true));

    // Add liquidity to set reserves_last to current (post-swap) reserves.
    // reserves_last was zeroed on disable, so compute_mint_fee returns 0 here.
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 50000, 50000, 0, 0,
    );

    // Verify no windfall: fee_recipient should have 0 LP from the off-period growth
    let fee_after_reenable = env.view_public(lp_token.balance_of_public(fee_recipient));
    assert_eq(fee_after_reenable, 0);

    // Phase 5: Small swap to generate tiny K growth
    let swapper3 = env.create_contract_account();
    swap_exact_in(
        env, pair_address, token0_address, token1_address,
        admin, swapper3, 10000, 0,
    );

    // Add liquidity to trigger fee mint for only the small swap
    // (different amounts from Phase 4 to avoid duplicate authwit nullifiers)
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 60000, 60000, 0, 0,
    );

    // Fee should be small (only for Phase 5 growth, not Phase 3 growth)
    let fee_final = env.view_public(lp_token.balance_of_public(fee_recipient));
    // Fee should be positive but tiny relative to total supply
    // With 10K swap on ~1M reserves, fee should be < 10 LP tokens
    assert(fee_final > 0);
    assert(fee_final < 10);
}

/// `set_protocol_fee(active=true, percent=0)` is rejected.
///
/// This configuration is semantically ambiguous: fees are "active" but at
/// zero rate, which leaves reserves_last unchanged while K can grow via
/// swaps. A subsequent `set_protocol_fee(active=true, percent>0)` would
/// mint a fee on the cumulative K-growth including the zero-percent period,
/// creating a windfall for fee_to that LPs are diluted to cover. The pair
/// enforces that fees are either genuinely active (percent > 0) or
/// explicitly disabled (active == false) -- no ambiguous middle state.
#[test(should_fail_with = "ACTIVE_WITH_ZERO_PERCENT")]
unconstrained fn test_set_protocol_fee_active_with_zero_percent_reverts() {
    let (mut env, pair_address, _t0, _t1, _lp, admin) = setup();
    let fee_recipient = env.create_contract_account();
    let pair = SigalSwapPair::at(pair_address);
    env.call_public(admin, pair.set_protocol_fee(fee_recipient, 0, true));
}

/// `set_protocol_fee(active=true, fee_to=zero)` is rejected. Activating
/// fees with a zero fee_to would mint protocol-fee LP to the zero
/// address on every subsequent mint/burn, silently burning protocol
/// revenue. Symmetric invariant with ACTIVE_WITH_ZERO_PERCENT.
#[test(should_fail_with = "ACTIVE_WITH_ZERO_FEE_TO")]
unconstrained fn test_set_protocol_fee_active_with_zero_fee_to_reverts() {
    let (mut env, pair_address, _t0, _t1, _lp, admin) = setup();
    let pair = SigalSwapPair::at(pair_address);
    env.call_public(admin, pair.set_protocol_fee(aztec::protocol::address::AztecAddress::zero(), 20, true));
}

/// Changing `percent` while fees remain active zeros reserves_last so
/// K-growth accrued under the old rate doesn't get minted at the new rate.
///
/// Scenario:
///   - Fees active at 20%. Liquidity added -> reserves_last = (R0, R1).
///   - Big swaps run. K grows (reserves_last unchanged, swaps don't update it).
///   - Admin changes percent to 50% (active stays true).
///   - Next mint/burn: charging the full accumulated K-growth at 50%,
///     including the portion earned at 20%, would be a retroactive
///     re-pricing windfall for fee_to. Zeroing reserves_last at the percent
///     change makes compute_mint_fee return 0 for this first post-change
///     event instead.
#[test]
unconstrained fn test_percent_change_does_not_retroactively_repriced() {
    let (mut env, pair_address, token0_address, token1_address, lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let fee_recipient = env.create_contract_account();
    let lp_token = SigalSwapLPToken::at(lp_address);
    let pair = SigalSwapPair::at(pair_address);

    // Phase 1: Enable at 20% and establish baseline via first liquidity event
    env.call_public(admin, pair.set_protocol_fee(fee_recipient, 20, true));
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 1000000, 1000000, 0, 0,
    );

    // Phase 2: Large swaps grow K. reserves_last stays at phase-1 values
    // (swaps don't touch it).
    let swapper1 = env.create_contract_account();
    swap_exact_in(
        env, pair_address, token0_address, token1_address,
        admin, swapper1, 200000, 0,
    );
    let swapper2 = env.create_contract_account();
    swap_exact_in(
        env, pair_address, token1_address, token0_address,
        admin, swapper2, 200000, 0,
    );

    // Phase 3: Admin raises percent to 50% while active stays true.
    // Zeroing reserves_last makes the new rate apply only going forward.
    env.call_public(admin, pair.set_protocol_fee(fee_recipient, 50, true));

    // Phase 4: Next liquidity event establishes a fresh baseline at the new
    // rate. compute_mint_fee short-circuits to 0 (reserves_last == 0), so
    // fee_recipient receives no LP for the old-rate-period growth.
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 50000, 50000, 0, 0,
    );

    // No windfall from the percent change. If reserves_last had not been
    // zeroed, fee_recipient would hold LP minted against the phase-2
    // K-growth at 50%; instead the balance is 0.
    assert_eq(env.view_public(lp_token.balance_of_public(fee_recipient)), 0);
}

/// Changing `fee_to` while fees remain active zeros reserves_last so
/// K-growth accrued under the prior recipient is not redirected to the
/// new recipient on the next mint/burn.
///
/// Scenario:
///   - Fees active at 20%, fee_to = X. Liquidity added -> reserves_last
///     = (R0, R1).
///   - Big swaps run. K grows (reserves_last unchanged).
///   - Admin rotates fee_to to Y (percent and active unchanged).
///   - Next mint/burn: minting LP for the full Phase-2 K-growth to Y
///     would redirect pre-rotation accrual to the new recipient. Zeroing
///     reserves_last at the rotation makes Y receive 0 for this first
///     post-rotation event; subsequent K-growth flows to Y normally.
#[test]
unconstrained fn test_set_protocol_fee_fee_to_change_resets_baseline() {
    let (mut env, pair_address, token0_address, token1_address, lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let fee_recipient_x = env.create_contract_account();
    let fee_recipient_y = env.create_contract_account();
    let lp_token = SigalSwapLPToken::at(lp_address);
    let pair = SigalSwapPair::at(pair_address);

    // Phase 1: Enable at 20% with fee_to=X; first liquidity event sets
    // reserves_last to the initial reserves.
    env.call_public(admin, pair.set_protocol_fee(fee_recipient_x, 20, true));
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 1000000, 1000000, 0, 0,
    );

    // Phase 2: Large swaps grow K. reserves_last stays at phase-1 values.
    let swapper1 = env.create_contract_account();
    swap_exact_in(
        env, pair_address, token0_address, token1_address,
        admin, swapper1, 200000, 0,
    );
    let swapper2 = env.create_contract_account();
    swap_exact_in(
        env, pair_address, token1_address, token0_address,
        admin, swapper2, 200000, 0,
    );

    // Phase 3: Admin rotates fee_to from X to Y. percent and active
    // unchanged. The reset zeros reserves_last so the next mint sees no
    // growth attributable to the pre-rotation epoch.
    env.call_public(admin, pair.set_protocol_fee(fee_recipient_y, 20, true));

    // Phase 4: First post-rotation liquidity event. compute_mint_fee
    // short-circuits to 0 (reserves_last == 0). Y receives no LP for the
    // phase-2 growth that would otherwise have been redirected.
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 50000, 50000, 0, 0,
    );

    assert_eq(env.view_public(lp_token.balance_of_public(fee_recipient_x)), 0);
    assert_eq(env.view_public(lp_token.balance_of_public(fee_recipient_y)), 0);

    // Phase 5: Small swap grows K under the fresh (post-rotation) baseline.
    let swapper3 = env.create_contract_account();
    swap_exact_in(
        env, pair_address, token0_address, token1_address,
        admin, swapper3, 10000, 0,
    );

    // Different amounts from Phase 4 to avoid duplicate authwit nullifiers.
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 60000, 60000, 0, 0,
    );

    // Y collects fee LP for the Phase-5 growth only -- the fresh epoch
    // works correctly post-rotation.
    let y_after = env.view_public(lp_token.balance_of_public(fee_recipient_y));
    assert(y_after > 0);
    // X never received anything: it was the recipient only across
    // Phases 1-2 where no mint fired.
    assert_eq(env.view_public(lp_token.balance_of_public(fee_recipient_x)), 0);
}

/// sync() must NOT erase the protocol-fee baseline. If a permissionless
/// caller were able to zero `reserves_last` by running sync() between
/// swaps and the next liquidity event, the next compute_mint_fee would
/// see no K growth and mint zero fee LP -- a 100%-efficient bypass of
/// the protocol fee. This test confirms the baseline is preserved.
///
/// Scenario: enable fees, seed pool, swap to grow k, attacker calls sync,
/// provider mints more liquidity -> fee_recipient must receive nonzero LP.
#[test]
unconstrained fn test_sync_preserves_fee_baseline() {
    let (mut env, pair_address, token0_address, token1_address, lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let attacker = env.create_contract_account();
    let fee_recipient = env.create_contract_account();
    let lp_token = SigalSwapLPToken::at(lp_address);
    let pair = SigalSwapPair::at(pair_address);

    env.call_public(admin, pair.set_protocol_fee(fee_recipient, 20, true));

    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 1000000, 1000000, 0, 0,
    );

    let swapper = env.create_contract_account();
    swap_exact_in(
        env, pair_address, token0_address, token1_address,
        admin, swapper, 100000, 0,
    );

    // Permissionless sync from the attacker's account. If sync() overwrote
    // the fee baseline with the post-swap balance, the subsequent
    // add_liquidity's compute_mint_fee would see zero growth and mint zero
    // fee LP; sync() must leave reserves_last alone.
    env.call_public(attacker, pair.sync());

    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 100000, 100000, 0, 0,
    );

    // fee_recipient receives LP proportional to the k growth between the
    // first mint and this second mint. Attacker's sync() did not erase it.
    assert(env.view_public(lp_token.balance_of_public(fee_recipient)) > 0);
}
