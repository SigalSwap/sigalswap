use sigalswap_core::{SigalSwapPair, pair::MINIMUM_LIQUIDITY};
use crate::test::utils::{setup, add_liquidity, remove_liquidity, swap_exact_in, swap_exact_out, AUTHWIT_NONCE};
use aztec::protocol::{abis::function_selector::FunctionSelector, traits::{FromField, ToField}};
use flash_borrower::FlashBorrower;
use token::Token;
use sigalswap_lp_token::SigalSwapLPToken;

// ============================================
// Security Features
// ============================================

/// Pause blocks swaps.
/// Admin pauses the pair, then a swap attempt should revert with "PAUSED".
#[test(should_fail_with = "PAUSED")]
unconstrained fn test_pause_blocks_swaps() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let swapper = env.create_contract_account();

    // Add liquidity first
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 10000, 20000, 0, 0,
    );

    // Admin pauses the pair (admin = factory in our test setup)
    env.call_public(admin, SigalSwapPair::at(pair_address).set_pause(true));

    // Swap should fail with PAUSED
    swap_exact_in(
        env, pair_address, token0_address, token1_address,
        admin, swapper, 100, 0,
    );
}

/// Pause blocks mints (add_liquidity).
#[test(should_fail_with = "PAUSED")]
unconstrained fn test_pause_blocks_mints() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();

    let provider1 = env.create_contract_account();
    let provider2 = env.create_contract_account();

    // First deposit (before pause)
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider1, 10000, 20000, 0, 0,
    );

    // Pause
    env.call_public(admin, SigalSwapPair::at(pair_address).set_pause(true));

    // Second deposit should fail with PAUSED
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider2, 500, 1000, 0, 0,
    );
}

/// Pause blocks flash_swap. flash_swap is the only pause-gated entry that
/// transfers reserves OUT of the pair (optimistic transfer before the
/// post-callback K-check), so its pause gate is load-bearing for emergency
/// containment -- pin it directly so a future refactor can't silently drop it.
#[test(should_fail_with = "PAUSED")]
unconstrained fn test_pause_blocks_flash_swap() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let pair = SigalSwapPair::at(pair_address);

    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    // Deploy a flash borrower; its callback never runs because the pause gate
    // at the top of flash_swap reverts before any borrow or callback.
    let borrower_init = FlashBorrower::interface().constructor();
    let borrower_address =
        env.deploy("@flash_borrower/FlashBorrower").with_public_initializer(admin, borrower_init);

    env.call_public(admin, pair.set_pause(true));

    let callback_sel =
        FunctionSelector::from_signature("flash_callback(Field,Field,Field,Field,Field,Field)");
    env.call_public(
        admin,
        pair.flash_swap(1000, 0, borrower_address, callback_sel, 0),
    );
}

/// Pause blocks add_liquidity_public. Both tokens are pre-deposited so the
/// deposit-delta checks would pass; the pause gate is then the only remaining
/// revert cause. If a refactor dropped the gate, the call would mint LP and
/// this canary would fail to observe PAUSED.
#[test(should_fail_with = "PAUSED")]
unconstrained fn test_pause_blocks_add_liquidity_public() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let recipient = env.create_contract_account();
    let pair = SigalSwapPair::at(pair_address);

    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 100000, 100000, 0, 0,
    );

    env.call_public(admin, pair.set_pause(true));

    // Pre-deposit both tokens into the pair's public balance.
    env.call_public(admin, Token::at(token0_address).mint_to_public(pair_address, 500));
    env.call_public(admin, Token::at(token1_address).mint_to_public(pair_address, 500));

    env.call_public(admin, pair.add_liquidity_public(recipient, 0, 0));
}

/// Pause allows withdrawals (remove_liquidity always works).
#[test]
unconstrained fn test_pause_allows_withdrawals() {
    let (mut env, pair_address, token0_address, token1_address, lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let lp_token = SigalSwapLPToken::at(lp_address);

    // Add liquidity
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 10000, 20000, 0, 0,
    );

    let provider_lp = env.execute_utility(lp_token.balance_of_private(provider));

    // Pause
    env.call_public(admin, SigalSwapPair::at(pair_address).set_pause(true));

    // Remove liquidity should SUCCEED even while paused
    remove_liquidity(
        env, pair_address, lp_address, provider,
        provider_lp, 0, 0,
    );

    // Verify provider got tokens back
    assert(env.execute_utility(Token::at(token0_address).balance_of_private(provider)) > 0);
    assert(env.execute_utility(Token::at(token1_address).balance_of_private(provider)) > 0);
}

/// Unpause restores normal operation.
#[test]
unconstrained fn test_unpause_restores() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let swapper = env.create_contract_account();

    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 10000, 20000, 0, 0,
    );

    // Pause then unpause
    env.call_public(admin, SigalSwapPair::at(pair_address).set_pause(true));
    env.call_public(admin, SigalSwapPair::at(pair_address).set_pause(false));

    // Swap should work again
    swap_exact_in(
        env, pair_address, token0_address, token1_address,
        admin, swapper, 100, 0,
    );

    // Verify swapper received tokens
    assert(env.execute_utility(Token::at(token1_address).balance_of_private(swapper)) > 0);
}

/// Access control -- set_pause rejects non-factory caller.
#[test(should_fail_with = "ONLY_FACTORY")]
unconstrained fn test_set_pause_only_factory() {
    let (mut env, pair_address, _token0_address, _token1_address, _lp_address, _admin) = setup();

    let attacker = env.create_contract_account();

    // Attacker tries to pause -- should fail because attacker != factory (admin)
    env.call_public(attacker, SigalSwapPair::at(pair_address).set_pause(true));
}

/// Access control -- set_protocol_fee rejects non-factory caller.
#[test(should_fail_with = "ONLY_FACTORY")]
unconstrained fn test_set_protocol_fee_only_factory() {
    let (mut env, pair_address, _token0_address, _token1_address, _lp_address, _admin) = setup();

    let attacker = env.create_contract_account();

    env.call_public(
        attacker,
        SigalSwapPair::at(pair_address).set_protocol_fee(attacker, 20, true),
    );
}

/// Verify that add_liquidity input validation works.
#[test(should_fail_with = "INCORRECT_TOKEN0_LIMITS")]
unconstrained fn test_add_liquidity_bad_limits() {
    let (mut env, pair_address, _token0_address, _token1_address, _lp_address, _admin) = setup();

    let provider = env.create_contract_account();
    let pair = SigalSwapPair::at(pair_address);

    // amount0_min > amount0_max should fail
    env.call_private(
        provider,
        pair.add_liquidity(500, 1000, 600, 500, AUTHWIT_NONCE),
    );
}

/// Verify swap rejects invalid token address.
#[test(should_fail_with = "TOKEN_IN_IS_INVALID")]
unconstrained fn test_swap_invalid_token() {
    let (mut env, pair_address, _token0_address, token1_address, _lp_address, _admin) = setup();

    let swapper = env.create_contract_account();
    let pair = SigalSwapPair::at(pair_address);
    let fake_token = aztec::protocol::address::AztecAddress::from_field(999);

    env.call_private(
        swapper,
        pair.swap_exact_in(
            fake_token,
            token1_address,
            100,
            0,
            AUTHWIT_NONCE,
        ),
    );
}

/// Verify swap rejects same token in/out.
#[test(should_fail_with = "SAME_TOKEN_SWAP")]
unconstrained fn test_swap_same_token() {
    let (mut env, pair_address, token0_address, _token1_address, _lp_address, _admin) = setup();

    let swapper = env.create_contract_account();
    let pair = SigalSwapPair::at(pair_address);

    env.call_private(
        swapper,
        pair.swap_exact_in(
            token0_address,
            token0_address,
            100,
            0,
            AUTHWIT_NONCE,
        ),
    );
}

/// Flash swap success -- borrow tokens, repay with fee in callback, verify K holds.
#[test]
unconstrained fn test_flash_swap_repay() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let token0 = Token::at(token0_address);
    let pair = SigalSwapPair::at(pair_address);

    // Add liquidity: 10000 / 10000
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    let reserve0_before = env.view_public(token0.balance_of_public(pair_address));

    // Deploy flash borrower
    let borrower_init = FlashBorrower::interface().constructor();
    let borrower_address =
        env.deploy("@flash_borrower/FlashBorrower").with_public_initializer(admin, borrower_init);

    // Pre-fund borrower with 5 token0 to cover the 0.25% fee on 1000 borrowed (fee ~3)
    env.call_public(admin, token0.mint_to_public(borrower_address, 5));

    // Flash swap: borrow 1000 token0, callback repays everything
    let callback_sel =
        FunctionSelector::from_signature("flash_callback(Field,Field,Field,Field,Field,Field)");
    env.call_public(
        admin,
        pair.flash_swap(1000, 0, borrower_address, callback_sel, 0),
    );

    // Verify pair gained the fee (reserves increased by the pre-funded amount)
    let reserve0_after = env.view_public(token0.balance_of_public(pair_address));
    assert(reserve0_after > reserve0_before);
    // The pair should have gained 5 token0 (the borrower's pre-funded excess)
    assert_eq(reserve0_after, reserve0_before + 5);
}

/// Flash swap failure -- callback does not repay, tx reverts.
#[test(should_fail_with = "INSUFFICIENT_REPAYMENT")]
unconstrained fn test_flash_swap_no_repay() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let pair = SigalSwapPair::at(pair_address);

    // Add liquidity: 10000 / 10000
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    // Deploy flash borrower
    let borrower_init = FlashBorrower::interface().constructor();
    let borrower_address =
        env.deploy("@flash_borrower/FlashBorrower").with_public_initializer(admin, borrower_init);

    // Flash swap with bad_callback that does nothing -- should revert
    let bad_sel =
        FunctionSelector::from_signature("bad_callback(Field,Field,Field,Field,Field,Field)");
    env.call_public(
        admin,
        pair.flash_swap(1000, 0, borrower_address, bad_sel, 0),
    );
}

/// Flash swap partial repay -- callback repays a tiny non-zero amount,
/// enough to pass `INSUFFICIENT_REPAYMENT` (which only requires `amount_in > 0`
/// on at least one side) but far below the K-preserving amount. Asserts the
/// K invariant check sits behind INSUFFICIENT_REPAYMENT and still fires.
/// Invariant test confirming `verify_k_invariant` is wired into `flash_swap`
/// and that the wide-int math catches the shortfall without Field wraparound.
#[test(should_fail_with = "K_INVARIANT_VIOLATED")]
unconstrained fn test_flash_swap_partial_repay_reverts_k_invariant() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let token0 = Token::at(token0_address);
    let pair = SigalSwapPair::at(pair_address);

    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    let borrower_init = FlashBorrower::interface().constructor();
    let borrower_address =
        env.deploy("@flash_borrower/FlashBorrower").with_public_initializer(admin, borrower_init);

    // Pre-fund the borrower with 1 token0 -- just enough for the 1-unit
    // "partial repay" so INSUFFICIENT_REPAYMENT (amount_in > 0) passes.
    env.call_public(admin, token0.mint_to_public(borrower_address, 1));

    let partial_sel = FunctionSelector::from_signature(
        "partial_repay_callback(Field,Field,Field,Field,Field,Field)",
    );
    // Borrow 1000 token0, callback returns just 1. K must revert.
    env.call_public(
        admin,
        pair.flash_swap(1000, 0, borrower_address, partial_sel, 0),
    );
}

// ============================================
// swap_exact_out_public revert paths
// ============================================
//
// These cover the V3-style exact-output public swap. Every guard at the top of
// the function and each blocklist entry for callback_contract must fire.

/// Pause blocks exact-output public swap.
#[test(should_fail_with = "PAUSED")]
unconstrained fn test_exact_out_public_paused_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp, admin) = setup();
    let provider = env.create_contract_account();

    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    env.call_public(admin, SigalSwapPair::at(pair_address).set_pause(true));

    let borrower_init = FlashBorrower::interface().constructor();
    let borrower =
        env.deploy("@flash_borrower/FlashBorrower").with_public_initializer(admin, borrower_init);

    let callback_sel =
        FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).swap_exact_out_public(
            token0_address, token1_address, 500, 600,
            borrower, borrower, callback_sel,
        ),
    );
}

/// amount_in_max below required input reverts.
/// 500 out from 20000/20000 at 25 bps requires 515 in; 514 is insufficient.
#[test(should_fail_with = "EXCESSIVE_INPUT_AMOUNT")]
unconstrained fn test_exact_out_public_excessive_input_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp, admin) = setup();
    let provider = env.create_contract_account();
    let recipient = env.create_contract_account();

    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    let borrower_init = FlashBorrower::interface().constructor();
    let borrower =
        env.deploy("@flash_borrower/FlashBorrower").with_public_initializer(admin, borrower_init);
    env.call_public(admin, Token::at(token0_address).mint_to_public(borrower, 600));

    let callback_sel =
        FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).swap_exact_out_public(
            token0_address, token1_address, 500, 514,
            recipient, borrower, callback_sel,
        ),
    );
}

/// Callback that does not pay reverts with INSUFFICIENT_PAYMENT.
#[test(should_fail_with = "INSUFFICIENT_PAYMENT")]
unconstrained fn test_exact_out_public_insufficient_payment_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp, admin) = setup();
    let provider = env.create_contract_account();
    let recipient = env.create_contract_account();

    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    let borrower_init = FlashBorrower::interface().constructor();
    let borrower =
        env.deploy("@flash_borrower/FlashBorrower").with_public_initializer(admin, borrower_init);
    env.call_public(admin, Token::at(token0_address).mint_to_public(borrower, 600));

    // Use bad_swap_payment_callback (empty body -- does not pay)
    let bad_sel =
        FunctionSelector::from_signature("bad_swap_payment_callback(Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).swap_exact_out_public(
            token0_address, token1_address, 500, 600,
            recipient, borrower, bad_sel,
        ),
    );
}

/// Invalid token_in reverts before any callback.
#[test(should_fail_with = "TOKEN_IN_IS_INVALID")]
unconstrained fn test_exact_out_public_invalid_token_in_reverts() {
    let (mut env, pair_address, _token0, token1_address, _lp, admin) = setup();
    let fake_token = aztec::protocol::address::AztecAddress::from_field(999);

    let borrower_init = FlashBorrower::interface().constructor();
    let borrower =
        env.deploy("@flash_borrower/FlashBorrower").with_public_initializer(admin, borrower_init);

    let callback_sel =
        FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).swap_exact_out_public(
            fake_token, token1_address, 500, 600,
            borrower, borrower, callback_sel,
        ),
    );
}

/// Invalid token_out reverts before any callback.
#[test(should_fail_with = "TOKEN_OUT_IS_INVALID")]
unconstrained fn test_exact_out_public_invalid_token_out_reverts() {
    let (mut env, pair_address, token0_address, _token1, _lp, admin) = setup();
    let fake_token = aztec::protocol::address::AztecAddress::from_field(999);

    let borrower_init = FlashBorrower::interface().constructor();
    let borrower =
        env.deploy("@flash_borrower/FlashBorrower").with_public_initializer(admin, borrower_init);

    let callback_sel =
        FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).swap_exact_out_public(
            token0_address, fake_token, 500, 600,
            borrower, borrower, callback_sel,
        ),
    );
}

/// Same token in/out reverts.
#[test(should_fail_with = "SAME_TOKEN_SWAP")]
unconstrained fn test_exact_out_public_same_token_reverts() {
    let (mut env, pair_address, token0_address, _token1, _lp, admin) = setup();

    let borrower_init = FlashBorrower::interface().constructor();
    let borrower =
        env.deploy("@flash_borrower/FlashBorrower").with_public_initializer(admin, borrower_init);

    let callback_sel =
        FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).swap_exact_out_public(
            token0_address, token0_address, 500, 600,
            borrower, borrower, callback_sel,
        ),
    );
}

/// callback_contract = zero reverts with INVALID_CALLBACK_TARGET.
#[test(should_fail_with = "INVALID_CALLBACK_TARGET")]
unconstrained fn test_exact_out_public_callback_zero_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp, admin) = setup();
    let zero_addr = aztec::protocol::address::AztecAddress::zero();

    let callback_sel =
        FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).swap_exact_out_public(
            token0_address, token1_address, 500, 600,
            zero_addr, zero_addr, callback_sel,
        ),
    );
}

/// callback_contract = pair itself reverts.
#[test(should_fail_with = "INVALID_CALLBACK_TARGET")]
unconstrained fn test_exact_out_public_callback_self_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp, admin) = setup();

    let callback_sel =
        FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).swap_exact_out_public(
            token0_address, token1_address, 500, 600,
            pair_address, pair_address, callback_sel,
        ),
    );
}

/// callback_contract = token0 reverts.
/// Prevents tricking a token contract into executing an attacker-controlled selector.
#[test(should_fail_with = "INVALID_CALLBACK_TARGET")]
unconstrained fn test_exact_out_public_callback_token0_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp, admin) = setup();

    let callback_sel =
        FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).swap_exact_out_public(
            token0_address, token1_address, 500, 600,
            token0_address, token0_address, callback_sel,
        ),
    );
}

/// callback_contract = token1 reverts.
#[test(should_fail_with = "INVALID_CALLBACK_TARGET")]
unconstrained fn test_exact_out_public_callback_token1_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp, admin) = setup();

    let callback_sel =
        FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).swap_exact_out_public(
            token0_address, token1_address, 500, 600,
            token1_address, token1_address, callback_sel,
        ),
    );
}

/// callback_contract = LP token reverts.
#[test(should_fail_with = "INVALID_CALLBACK_TARGET")]
unconstrained fn test_exact_out_public_callback_lp_reverts() {
    let (mut env, pair_address, token0_address, token1_address, lp_address, admin) = setup();

    let callback_sel =
        FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).swap_exact_out_public(
            token0_address, token1_address, 500, 600,
            lp_address, lp_address, callback_sel,
        ),
    );
}

/// callback_contract = factory reverts.
/// In the test setup admin plays the factory role, so setting callback to admin
/// triggers the config.factory branch of the blocklist.
#[test(should_fail_with = "INVALID_CALLBACK_TARGET")]
unconstrained fn test_exact_out_public_callback_factory_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp, admin) = setup();

    let callback_sel =
        FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).swap_exact_out_public(
            token0_address, token1_address, 500, 600,
            admin, admin, callback_sel,
        ),
    );
}

// ============================================
// swap_exact_in_public -- revert surface
// (parallel to swap_exact_out_public revert tests above)
// ============================================

/// Pause blocks swap_exact_in_public.
#[test(should_fail_with = "PAUSED")]
unconstrained fn test_exact_in_public_paused_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp, admin) = setup();
    let provider = env.create_contract_account();
    let recipient = env.create_contract_account();

    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    env.call_public(admin, SigalSwapPair::at(pair_address).set_pause(true));

    let borrower_init = FlashBorrower::interface().constructor();
    let borrower =
        env.deploy("@flash_borrower/FlashBorrower").with_public_initializer(admin, borrower_init);

    let callback_sel =
        FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).swap_exact_in_public(
            token0_address, token1_address, 500, 0,
            recipient, borrower, callback_sel,
        ),
    );
}

/// Invalid token_in reverts.
#[test(should_fail_with = "TOKEN_IN_IS_INVALID")]
unconstrained fn test_exact_in_public_invalid_token_in_reverts() {
    let (mut env, pair_address, _token0, token1_address, _lp, admin) = setup();
    let fake_token = aztec::protocol::address::AztecAddress::from_field(999);

    let borrower_init = FlashBorrower::interface().constructor();
    let borrower =
        env.deploy("@flash_borrower/FlashBorrower").with_public_initializer(admin, borrower_init);

    let callback_sel =
        FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).swap_exact_in_public(
            fake_token, token1_address, 500, 0,
            borrower, borrower, callback_sel,
        ),
    );
}

/// Invalid token_out reverts.
#[test(should_fail_with = "TOKEN_OUT_IS_INVALID")]
unconstrained fn test_exact_in_public_invalid_token_out_reverts() {
    let (mut env, pair_address, token0_address, _token1, _lp, admin) = setup();
    let fake_token = aztec::protocol::address::AztecAddress::from_field(999);

    let borrower_init = FlashBorrower::interface().constructor();
    let borrower =
        env.deploy("@flash_borrower/FlashBorrower").with_public_initializer(admin, borrower_init);

    let callback_sel =
        FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).swap_exact_in_public(
            token0_address, fake_token, 500, 0,
            borrower, borrower, callback_sel,
        ),
    );
}

/// token_in == token_out reverts with SAME_TOKEN_SWAP.
#[test(should_fail_with = "SAME_TOKEN_SWAP")]
unconstrained fn test_exact_in_public_same_token_reverts() {
    let (mut env, pair_address, token0_address, _token1, _lp, admin) = setup();

    let borrower_init = FlashBorrower::interface().constructor();
    let borrower =
        env.deploy("@flash_borrower/FlashBorrower").with_public_initializer(admin, borrower_init);

    let callback_sel =
        FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).swap_exact_in_public(
            token0_address, token0_address, 500, 0,
            borrower, borrower, callback_sel,
        ),
    );
}

/// callback_contract = zero reverts.
#[test(should_fail_with = "INVALID_CALLBACK_TARGET")]
unconstrained fn test_exact_in_public_callback_zero_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp, admin) = setup();
    let zero_addr = aztec::protocol::address::AztecAddress::zero();

    let callback_sel =
        FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).swap_exact_in_public(
            token0_address, token1_address, 500, 0,
            zero_addr, zero_addr, callback_sel,
        ),
    );
}

/// callback_contract = pair itself reverts.
#[test(should_fail_with = "INVALID_CALLBACK_TARGET")]
unconstrained fn test_exact_in_public_callback_self_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp, admin) = setup();

    let callback_sel =
        FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).swap_exact_in_public(
            token0_address, token1_address, 500, 0,
            pair_address, pair_address, callback_sel,
        ),
    );
}

/// callback_contract = token0 reverts.
#[test(should_fail_with = "INVALID_CALLBACK_TARGET")]
unconstrained fn test_exact_in_public_callback_token0_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp, admin) = setup();

    let callback_sel =
        FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).swap_exact_in_public(
            token0_address, token1_address, 500, 0,
            token0_address, token0_address, callback_sel,
        ),
    );
}

/// callback_contract = token1 reverts.
#[test(should_fail_with = "INVALID_CALLBACK_TARGET")]
unconstrained fn test_exact_in_public_callback_token1_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp, admin) = setup();

    let callback_sel =
        FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).swap_exact_in_public(
            token0_address, token1_address, 500, 0,
            token1_address, token1_address, callback_sel,
        ),
    );
}

/// callback_contract = LP token reverts.
#[test(should_fail_with = "INVALID_CALLBACK_TARGET")]
unconstrained fn test_exact_in_public_callback_lp_reverts() {
    let (mut env, pair_address, token0_address, token1_address, lp_address, admin) = setup();

    let callback_sel =
        FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).swap_exact_in_public(
            token0_address, token1_address, 500, 0,
            lp_address, lp_address, callback_sel,
        ),
    );
}

/// callback_contract = factory reverts (admin plays factory role in the setup).
#[test(should_fail_with = "INVALID_CALLBACK_TARGET")]
unconstrained fn test_exact_in_public_callback_factory_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp, admin) = setup();

    let callback_sel =
        FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).swap_exact_in_public(
            token0_address, token1_address, 500, 0,
            admin, admin, callback_sel,
        ),
    );
}

// ============================================
// flash_swap -- borrower blocklist canaries
// ============================================
//
// `flash_swap` rejects six borrower addresses with INVALID_BORROWER:
// {zero, self, token0, token1, lp_token, factory}. Optimistically
// transferring borrowed reserves to any of these would either burn the
// loan (token0 / token1 contracts have no rescue surface and would
// silently absorb), corrupt protocol accounting (self / lp_token /
// factory), or land at the zero address.
//
// Implementation note: token0 and token1 share a single combined assert
// `(borrower != token0) & (borrower != token1)`; the other four are
// individual asserts. Both arms of the combined assert still revert with
// "INVALID_BORROWER", so the canaries below cover all six conditions
// uniformly via `should_fail_with`.
//
// Liquidity must be seeded before the borrower blocklist is reached: the
// strict-less-than `INSUFFICIENT_LIQUIDITY_*` checks at the top of
// `flash_swap` fire on a zero-reserve pair regardless of the borrower
// argument.

/// borrower = zero reverts with INVALID_BORROWER.
#[test(should_fail_with = "INVALID_BORROWER")]
unconstrained fn test_flash_swap_borrower_zero_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp, admin) = setup();
    let provider = env.create_contract_account();
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    let zero_addr = aztec::protocol::address::AztecAddress::zero();
    let callback_sel =
        FunctionSelector::from_signature("flash_callback(Field,Field,Field,Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).flash_swap(1000, 0, zero_addr, callback_sel, 0),
    );
}

/// borrower = pair itself reverts with INVALID_BORROWER.
#[test(should_fail_with = "INVALID_BORROWER")]
unconstrained fn test_flash_swap_borrower_self_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp, admin) = setup();
    let provider = env.create_contract_account();
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    let callback_sel =
        FunctionSelector::from_signature("flash_callback(Field,Field,Field,Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).flash_swap(1000, 0, pair_address, callback_sel, 0),
    );
}

/// borrower = token0 reverts (combined-assert arm).
#[test(should_fail_with = "INVALID_BORROWER")]
unconstrained fn test_flash_swap_borrower_token0_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp, admin) = setup();
    let provider = env.create_contract_account();
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    let callback_sel =
        FunctionSelector::from_signature("flash_callback(Field,Field,Field,Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).flash_swap(1000, 0, token0_address, callback_sel, 0),
    );
}

/// borrower = token1 reverts (combined-assert arm).
#[test(should_fail_with = "INVALID_BORROWER")]
unconstrained fn test_flash_swap_borrower_token1_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp, admin) = setup();
    let provider = env.create_contract_account();
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    let callback_sel =
        FunctionSelector::from_signature("flash_callback(Field,Field,Field,Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).flash_swap(1000, 0, token1_address, callback_sel, 0),
    );
}

/// borrower = LP token reverts.
#[test(should_fail_with = "INVALID_BORROWER")]
unconstrained fn test_flash_swap_borrower_lp_reverts() {
    let (mut env, pair_address, token0_address, token1_address, lp_address, admin) = setup();
    let provider = env.create_contract_account();
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    let callback_sel =
        FunctionSelector::from_signature("flash_callback(Field,Field,Field,Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).flash_swap(1000, 0, lp_address, callback_sel, 0),
    );
}

/// borrower = factory reverts (admin plays factory role in the setup).
#[test(should_fail_with = "INVALID_BORROWER")]
unconstrained fn test_flash_swap_borrower_factory_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp, admin) = setup();
    let provider = env.create_contract_account();
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    let callback_sel =
        FunctionSelector::from_signature("flash_callback(Field,Field,Field,Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).flash_swap(1000, 0, admin, callback_sel, 0),
    );
}

/// amount_out_min above computed output reverts with INSUFFICIENT_OUTPUT_AMOUNT.
#[test(should_fail_with = "INSUFFICIENT_OUTPUT_AMOUNT")]
unconstrained fn test_exact_in_public_insufficient_output_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp, admin) = setup();
    let provider = env.create_contract_account();
    let recipient = env.create_contract_account();

    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    let borrower_init = FlashBorrower::interface().constructor();
    let borrower =
        env.deploy("@flash_borrower/FlashBorrower").with_public_initializer(admin, borrower_init);
    env.call_public(admin, Token::at(token0_address).mint_to_public(borrower, 500));

    // 500 in at 25 bps gives ~486 out; demanding 900 min triggers the revert.
    let callback_sel =
        FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).swap_exact_in_public(
            token0_address, token1_address, 500, 900,
            recipient, borrower, callback_sel,
        ),
    );
}

/// Pair constructor rejects fee_tier_bps >= 5000.
///
/// Defense in depth: the factory's whitelist enforces the policy cap, but a
/// direct deployment (bypassing the factory) could otherwise pass a tier that
/// combined with the 100% protocol markup would exceed get_amount_out's
/// FEE_TOO_HIGH bound (10000). Reject at construction instead.
#[test(should_fail_with = "FEE_TIER_TOO_HIGH")]
unconstrained fn test_pair_constructor_rejects_excessive_fee_tier() {
    let mut env = aztec::test::helpers::test_environment::TestEnvironment::new();
    let admin = env.create_contract_account();

    let token0 = env
        .deploy("@token_contract/Token")
        .with_public_initializer(
            admin,
            Token::interface().constructor(
                admin,
                "TokenA0000000000000000000000000",
                "TKA0000000000000000000000000000",
                18,
            ),
        );
    let token1 = env
        .deploy("@token_contract/Token")
        .with_public_initializer(
            admin,
            Token::interface().constructor(
                admin,
                "TokenB1111111111111111111111111",
                "TKB1111111111111111111111111111",
                18,
            ),
        );

    // Attempt to deploy a pair at the cap boundary (5000 is the first rejected
    // value -- assertion is strict `<`). LP token is no longer a constructor
    // arg; the pair derives its LP address from its own address internally.
    let pair_init = SigalSwapPair::interface().constructor(
        token0, token1, admin, 5000,
    );
    let _: aztec::protocol::address::AztecAddress =
        env.deploy("@sigalswap_core/SigalSwapPair").with_public_initializer(admin, pair_init);
}

/// Pair constructor rejects unsorted tokens.
///
/// Defense in depth: the factory's `register_pair` enforces the canonical
/// `token0 < token1` ordering, but a direct deployment could otherwise
/// leave a relabeled-but-functional pair alongside the canonical pair,
/// splitting liquidity. The pair-side assertion mirrors the factory's
/// exact comparison so both gates trip with the same revert message.
#[test(should_fail_with = "TOKENS_NOT_SORTED")]
unconstrained fn test_pair_constructor_rejects_unsorted_tokens() {
    let mut env = aztec::test::helpers::test_environment::TestEnvironment::new();
    let admin = env.create_contract_account();

    let token_a = env
        .deploy("@token_contract/Token")
        .with_public_initializer(
            admin,
            Token::interface().constructor(
                admin,
                "TokenA0000000000000000000000000",
                "TKA0000000000000000000000000000",
                18,
            ),
        );
    let token_b = env
        .deploy("@token_contract/Token")
        .with_public_initializer(
            admin,
            Token::interface().constructor(
                admin,
                "TokenB1111111111111111111111111",
                "TKB1111111111111111111111111111",
                18,
            ),
        );

    // Pick the swapped-order pair regardless of the natural deploy ordering:
    // pass the larger address as token0 and the smaller as token1 so the
    // strict-less assertion always trips.
    let (bad_token0, bad_token1) =
        if (token_a.to_field() as u128) < (token_b.to_field() as u128) {
            (token_b, token_a)
        } else {
            (token_a, token_b)
        };
    let pair_init = SigalSwapPair::interface().constructor(
        bad_token0, bad_token1, admin, 25,
    );
    let _: aztec::protocol::address::AztecAddress =
        env.deploy("@sigalswap_core/SigalSwapPair").with_public_initializer(admin, pair_init);
}

// ============================================
// Reentrancy lock coverage
// ============================================

/// The pair's reentrancy lock must stay held across the flash_swap callback.
///
/// `flash_swap` acquires the reentrancy lock and then issues a callback to
/// an attacker-controlled contract. If the attacker's callback tries to
/// reenter any pair function that also acquires the lock, the assertion at
/// the top of that function (`assert(!locked, "LOCKED")`) must fire, causing
/// the entire flash_swap tx to revert.
///
/// This test uses the `flash_borrower`'s `reentrant_sync_callback` which,
/// instead of repaying the flash loan, calls `pair.sync()`. Expected:
/// `sync` reverts with "LOCKED" because flash_swap is still holding the
/// lock higher up the call stack. (`sync` is chosen because it's public,
/// zero-arg, and acquires the lock unconditionally.)
///
/// The failure mode this test detects: a refactor that accidentally
/// releases the lock before the callback (or never acquires it) would allow
/// `sync` to proceed inside the callback, indicating the reentrancy guard
/// is no longer covering the full flash_swap window.
#[test(should_fail_with = "LOCKED")]
unconstrained fn test_flash_swap_reentrant_sync_reverts_locked() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let token0 = Token::at(token0_address);
    let pair = SigalSwapPair::at(pair_address);

    // Seed the pool so flash_swap has reserves to lend.
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    // Deploy the flash borrower fixture (which has a reentrant callback
    // mode) and pre-fund it so it could in principle repay. We don't want
    // the failure to be INSUFFICIENT_REPAYMENT -- we want LOCKED from the
    // reentrant skim attempt.
    let borrower_init = FlashBorrower::interface().constructor();
    let borrower_address =
        env.deploy("@flash_borrower/FlashBorrower").with_public_initializer(admin, borrower_init);
    env.call_public(admin, token0.mint_to_public(borrower_address, 10));

    // Run flash_swap pointing at `reentrant_sync_callback`. Inside the
    // callback, the borrower tries to call pair.sync, which acquires the
    // same lock -> LOCKED revert.
    let reentrant_sel = FunctionSelector::from_signature(
        "reentrant_sync_callback(Field,Field,Field,Field,Field,Field)",
    );
    env.call_public(
        admin,
        pair.flash_swap(1000, 0, borrower_address, reentrant_sel, 0),
    );
}

// ============================================
// Direct-call attack surface on add_liquidity_public
// ============================================

/// A direct caller with no deposit cannot mint LP. Because `add_liquidity_public`
/// derives deposit amounts from `balance - reserve`, an attacker who calls
/// the entry without pre-depositing tokens sees a zero delta on token0 and
/// reverts at the first assertion. This is the anti-drain invariant: no
/// deposit, no LP.
#[test(should_fail_with = "NO_TOKEN0_DEPOSIT")]
unconstrained fn test_add_liquidity_public_without_deposit_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let attacker = env.create_contract_account();

    // Seed the pool so reserves and balances are both non-zero. If we skipped
    // this, the attacker's call would still fail (0 delta) but the test
    // wouldn't exercise the attack it's trying to prevent: siphoning value
    // from a populated pool.
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 100000, 100000, 0, 0,
    );

    // Attacker calls the public entry directly, with no pre-deposit.
    env.call_public(
        attacker,
        SigalSwapPair::at(pair_address).add_liquidity_public(attacker, 0, 0),
    );
}

/// A direct caller who deposits only one of the two tokens cannot mint LP.
/// The pair asserts both deltas are positive; a single-sided deposit trips
/// NO_TOKEN1_DEPOSIT.
#[test(should_fail_with = "NO_TOKEN1_DEPOSIT")]
unconstrained fn test_add_liquidity_public_partial_deposit_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let attacker = env.create_contract_account();

    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 100000, 100000, 0, 0,
    );

    // Attacker deposits only token0 by minting directly into pair's public
    // balance. token1 balance is unchanged, so delta1 == 0.
    env.call_public(admin, Token::at(token0_address).mint_to_public(pair_address, 500));

    env.call_public(
        attacker,
        SigalSwapPair::at(pair_address).add_liquidity_public(attacker, 0, 0),
    );
}

/// `recipient == AztecAddress::zero()` is rejected at the entry so LP tokens
/// and refunds cannot be sent to an unrecoverable address on a caller mistake.
#[test(should_fail_with = "ZERO_RECIPIENT")]
unconstrained fn test_add_liquidity_public_zero_recipient_reverts() {
    let (mut env, pair_address, _token0_address, _token1_address, _lp_address, _admin) = setup();

    let caller = env.create_contract_account();

    env.call_public(
        caller,
        SigalSwapPair::at(pair_address).add_liquidity_public(
            aztec::protocol::address::AztecAddress::zero(),
            0, 0,
        ),
    );
}

// ============================================
// Recipient blocklist canaries
// ============================================
//
// The four public entries that take a `recipient` (add_liquidity_public,
// remove_liquidity_public, swap_exact_in_public, swap_exact_out_public)
// each assert `recipient != X` for X in {zero, self, token0, token1,
// lp_token, factory}. LP minted to or tokens delivered to any of these
// protocol-internal addresses would be permanently stranded -- none of
// them have a rescue surface for arbitrary deposits. Mirrors the
// INVALID_CALLBACK_TARGET blocklist on the V3 swap entries; distinct
// revert message so integrators can tell the two guards apart.
//
// add_liquidity_public and remove_liquidity_public keep their separate
// `ZERO_RECIPIENT` assert at function entry (canaried elsewhere); the
// 5-element `INVALID_RECIPIENT` set below covers the remaining cases.
// swap_exact_*_public collapse the zero check into the same blocklist.

#[test(should_fail_with = "INVALID_RECIPIENT")]
unconstrained fn test_add_liquidity_public_recipient_self_reverts() {
    let (mut env, pair_address, _t0, _t1, _lp, _admin) = setup();
    let caller = env.create_contract_account();
    env.call_public(caller, SigalSwapPair::at(pair_address).add_liquidity_public(pair_address, 0, 0));
}

#[test(should_fail_with = "INVALID_RECIPIENT")]
unconstrained fn test_add_liquidity_public_recipient_token0_reverts() {
    let (mut env, pair_address, token0_address, _t1, _lp, _admin) = setup();
    let caller = env.create_contract_account();
    env.call_public(caller, SigalSwapPair::at(pair_address).add_liquidity_public(token0_address, 0, 0));
}

#[test(should_fail_with = "INVALID_RECIPIENT")]
unconstrained fn test_add_liquidity_public_recipient_token1_reverts() {
    let (mut env, pair_address, _t0, token1_address, _lp, _admin) = setup();
    let caller = env.create_contract_account();
    env.call_public(caller, SigalSwapPair::at(pair_address).add_liquidity_public(token1_address, 0, 0));
}

#[test(should_fail_with = "INVALID_RECIPIENT")]
unconstrained fn test_add_liquidity_public_recipient_lp_reverts() {
    let (mut env, pair_address, _t0, _t1, lp_address, _admin) = setup();
    let caller = env.create_contract_account();
    env.call_public(caller, SigalSwapPair::at(pair_address).add_liquidity_public(lp_address, 0, 0));
}

#[test(should_fail_with = "INVALID_RECIPIENT")]
unconstrained fn test_add_liquidity_public_recipient_factory_reverts() {
    let (mut env, pair_address, _t0, _t1, _lp, admin) = setup();
    // admin == factory in test setup.
    let caller = env.create_contract_account();
    env.call_public(caller, SigalSwapPair::at(pair_address).add_liquidity_public(admin, 0, 0));
}

#[test(should_fail_with = "INVALID_RECIPIENT")]
unconstrained fn test_remove_liquidity_public_recipient_self_reverts() {
    let (mut env, pair_address, _t0, _t1, _lp, _admin) = setup();
    let caller = env.create_contract_account();
    env.call_public(
        caller,
        SigalSwapPair::at(pair_address).remove_liquidity_public(pair_address, 1, 0, 0),
    );
}

#[test(should_fail_with = "INVALID_RECIPIENT")]
unconstrained fn test_remove_liquidity_public_recipient_token0_reverts() {
    let (mut env, pair_address, token0_address, _t1, _lp, _admin) = setup();
    let caller = env.create_contract_account();
    env.call_public(
        caller,
        SigalSwapPair::at(pair_address).remove_liquidity_public(token0_address, 1, 0, 0),
    );
}

#[test(should_fail_with = "INVALID_RECIPIENT")]
unconstrained fn test_remove_liquidity_public_recipient_token1_reverts() {
    let (mut env, pair_address, _t0, token1_address, _lp, _admin) = setup();
    let caller = env.create_contract_account();
    env.call_public(
        caller,
        SigalSwapPair::at(pair_address).remove_liquidity_public(token1_address, 1, 0, 0),
    );
}

#[test(should_fail_with = "INVALID_RECIPIENT")]
unconstrained fn test_remove_liquidity_public_recipient_lp_reverts() {
    let (mut env, pair_address, _t0, _t1, lp_address, _admin) = setup();
    let caller = env.create_contract_account();
    env.call_public(
        caller,
        SigalSwapPair::at(pair_address).remove_liquidity_public(lp_address, 1, 0, 0),
    );
}

#[test(should_fail_with = "INVALID_RECIPIENT")]
unconstrained fn test_remove_liquidity_public_recipient_factory_reverts() {
    let (mut env, pair_address, _t0, _t1, _lp, admin) = setup();
    let caller = env.create_contract_account();
    env.call_public(
        caller,
        SigalSwapPair::at(pair_address).remove_liquidity_public(admin, 1, 0, 0),
    );
}

#[test(should_fail_with = "INVALID_RECIPIENT")]
unconstrained fn test_exact_in_public_recipient_zero_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp, _admin) = setup();
    let callback_sel = FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    let callback_target = env.create_contract_account();
    env.call_public(
        callback_target,
        SigalSwapPair::at(pair_address).swap_exact_in_public(
            token0_address, token1_address, 500, 0,
            aztec::protocol::address::AztecAddress::zero(), callback_target, callback_sel,
        ),
    );
}

#[test(should_fail_with = "INVALID_RECIPIENT")]
unconstrained fn test_exact_in_public_recipient_self_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp, _admin) = setup();
    let callback_sel = FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    let callback_target = env.create_contract_account();
    env.call_public(
        callback_target,
        SigalSwapPair::at(pair_address).swap_exact_in_public(
            token0_address, token1_address, 500, 0,
            pair_address, callback_target, callback_sel,
        ),
    );
}

#[test(should_fail_with = "INVALID_RECIPIENT")]
unconstrained fn test_exact_in_public_recipient_token0_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp, _admin) = setup();
    let callback_sel = FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    let callback_target = env.create_contract_account();
    env.call_public(
        callback_target,
        SigalSwapPair::at(pair_address).swap_exact_in_public(
            token0_address, token1_address, 500, 0,
            token0_address, callback_target, callback_sel,
        ),
    );
}

#[test(should_fail_with = "INVALID_RECIPIENT")]
unconstrained fn test_exact_in_public_recipient_token1_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp, _admin) = setup();
    let callback_sel = FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    let callback_target = env.create_contract_account();
    env.call_public(
        callback_target,
        SigalSwapPair::at(pair_address).swap_exact_in_public(
            token0_address, token1_address, 500, 0,
            token1_address, callback_target, callback_sel,
        ),
    );
}

#[test(should_fail_with = "INVALID_RECIPIENT")]
unconstrained fn test_exact_in_public_recipient_lp_reverts() {
    let (mut env, pair_address, token0_address, token1_address, lp_address, _admin) = setup();
    let callback_sel = FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    let callback_target = env.create_contract_account();
    env.call_public(
        callback_target,
        SigalSwapPair::at(pair_address).swap_exact_in_public(
            token0_address, token1_address, 500, 0,
            lp_address, callback_target, callback_sel,
        ),
    );
}

#[test(should_fail_with = "INVALID_RECIPIENT")]
unconstrained fn test_exact_in_public_recipient_factory_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp, admin) = setup();
    let callback_sel = FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    let callback_target = env.create_contract_account();
    env.call_public(
        callback_target,
        SigalSwapPair::at(pair_address).swap_exact_in_public(
            token0_address, token1_address, 500, 0,
            admin, callback_target, callback_sel,
        ),
    );
}

#[test(should_fail_with = "INVALID_RECIPIENT")]
unconstrained fn test_exact_out_public_recipient_zero_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp, _admin) = setup();
    let callback_sel = FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    let callback_target = env.create_contract_account();
    env.call_public(
        callback_target,
        SigalSwapPair::at(pair_address).swap_exact_out_public(
            token0_address, token1_address, 500, 1000,
            aztec::protocol::address::AztecAddress::zero(), callback_target, callback_sel,
        ),
    );
}

#[test(should_fail_with = "INVALID_RECIPIENT")]
unconstrained fn test_exact_out_public_recipient_self_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp, _admin) = setup();
    let callback_sel = FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    let callback_target = env.create_contract_account();
    env.call_public(
        callback_target,
        SigalSwapPair::at(pair_address).swap_exact_out_public(
            token0_address, token1_address, 500, 1000,
            pair_address, callback_target, callback_sel,
        ),
    );
}

#[test(should_fail_with = "INVALID_RECIPIENT")]
unconstrained fn test_exact_out_public_recipient_token0_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp, _admin) = setup();
    let callback_sel = FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    let callback_target = env.create_contract_account();
    env.call_public(
        callback_target,
        SigalSwapPair::at(pair_address).swap_exact_out_public(
            token0_address, token1_address, 500, 1000,
            token0_address, callback_target, callback_sel,
        ),
    );
}

#[test(should_fail_with = "INVALID_RECIPIENT")]
unconstrained fn test_exact_out_public_recipient_token1_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp, _admin) = setup();
    let callback_sel = FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    let callback_target = env.create_contract_account();
    env.call_public(
        callback_target,
        SigalSwapPair::at(pair_address).swap_exact_out_public(
            token0_address, token1_address, 500, 1000,
            token1_address, callback_target, callback_sel,
        ),
    );
}

#[test(should_fail_with = "INVALID_RECIPIENT")]
unconstrained fn test_exact_out_public_recipient_lp_reverts() {
    let (mut env, pair_address, token0_address, token1_address, lp_address, _admin) = setup();
    let callback_sel = FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    let callback_target = env.create_contract_account();
    env.call_public(
        callback_target,
        SigalSwapPair::at(pair_address).swap_exact_out_public(
            token0_address, token1_address, 500, 1000,
            lp_address, callback_target, callback_sel,
        ),
    );
}

#[test(should_fail_with = "INVALID_RECIPIENT")]
unconstrained fn test_exact_out_public_recipient_factory_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp, admin) = setup();
    let callback_sel = FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    let callback_target = env.create_contract_account();
    env.call_public(
        callback_target,
        SigalSwapPair::at(pair_address).swap_exact_out_public(
            token0_address, token1_address, 500, 1000,
            admin, callback_target, callback_sel,
        ),
    );
}

// ============================================
// Pair-side pause event canaries
// ============================================
//
// `set_pause` emits `PairPausedEvent` on inactive-to-paused transitions
// and `PairUnpausedEvent` on paused-to-inactive transitions. Idempotent calls
// (set_pause(p) when already at p) emit nothing and skip the storage
// write entirely. Mirrors `set_protocol_fee`'s no-op semantics on
// repeated identical pushes. TXE doesn't introspect emitted event
// payloads, so these tests verify the operation completes (proves emit
// did not revert) and the state observed via `is_paused_view`.

#[test]
unconstrained fn test_set_pause_emits_event_on_change() {
    let (mut env, pair_address, _t0, _t1, _lp, admin) = setup();
    let pair = SigalSwapPair::at(pair_address);

    // Inactive -> paused: PairPausedEvent should emit, state flip observable.
    env.call_public(admin, pair.set_pause(true));
    let paused = env.execute_utility(pair.is_paused_view());
    assert_eq(paused, true);

    // Paused -> inactive: PairUnpausedEvent should emit, state flip observable.
    env.call_public(admin, pair.set_pause(false));
    let paused2 = env.execute_utility(pair.is_paused_view());
    assert_eq(paused2, false);
}

#[test]
unconstrained fn test_set_pause_idempotent_no_event_on_no_change() {
    let (mut env, pair_address, _t0, _t1, _lp, admin) = setup();
    let pair = SigalSwapPair::at(pair_address);

    // Pair starts inactive. set_pause(false) is idempotent -- should
    // succeed without emitting an event or writing to storage.
    env.call_public(admin, pair.set_pause(false));
    let paused1 = env.execute_utility(pair.is_paused_view());
    assert_eq(paused1, false);

    // Pause once, then call set_pause(true) again. Second call is a no-op.
    env.call_public(admin, pair.set_pause(true));
    env.call_public(admin, pair.set_pause(true));
    let paused2 = env.execute_utility(pair.is_paused_view());
    assert_eq(paused2, true);
}

// ============================================
// Donation absorption canaries (V2-strict invariant)
// ============================================
//
// Donations to the pair (tokens transferred outside any protocol interaction)
// must flow into reserves on the next state-changing call -- not out to the
// caller via refund or inflated swap output. `skim` is the explicit recovery
// path; every other entry treats donations as gifts to LPs.

/// Direct caller invokes `add_liquidity_public` after a one-sided donation
/// arrived at the pair. The donation must be absorbed into reserves; the
/// caller's `recipient` must not receive any token0/token1 refund. LP minted
/// only for the matched (pair-ratio) portion of what was deposited.
#[test]
unconstrained fn test_add_liquidity_public_absorbs_donation_to_reserves() {
    let (mut env, pair_address, token0_address, token1_address, lp_address, admin) = setup();
    let provider = env.create_contract_account();
    let caller = env.create_contract_account();
    let token0 = Token::at(token0_address);
    let token1 = Token::at(token1_address);
    let pair = SigalSwapPair::at(pair_address);
    let lp_token = SigalSwapLPToken::at(lp_address);

    // Seed the pool: reserves (100_000, 100_000)
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 100_000, 100_000, 0, 0,
    );

    // Donation: 500 token0 sent to pair from outside any protocol interaction.
    env.call_public(admin, token0.mint_to_public(pair_address, 500));

    // Caller "pre-deposits" a balanced (1000, 1000) at pool ratio 1:1 by
    // minting directly into the pair's public balance. The pair's V2-strict
    // entry sees only `balance - reserve`; it doesn't care who put the
    // tokens there.
    env.call_public(admin, token0.mint_to_public(pair_address, 1000));
    env.call_public(admin, token1.mint_to_public(pair_address, 1000));

    // Snapshot caller's public balances before the call.
    let caller_t0_before = env.view_public(token0.balance_of_public(caller));
    let caller_t1_before = env.view_public(token1.balance_of_public(caller));
    let caller_lp_before = env.view_public(lp_token.balance_of_public(caller));

    env.call_public(caller, pair.add_liquidity_public(caller, 0, 0));

    // Reserves include the 500 token0 donation plus the balanced deposit.
    let (r0, r1, _ts) = env.view_public(pair.get_reserves());
    assert_eq(r0, 101_500);
    assert_eq(r1, 101_000);

    // No refund of token0/token1 -- caller's public balances unchanged.
    assert_eq(env.view_public(token0.balance_of_public(caller)), caller_t0_before);
    assert_eq(env.view_public(token1.balance_of_public(caller)), caller_t1_before);

    // Caller did receive LP tokens for the matched portion (1000, 1000).
    let caller_lp_after = env.view_public(lp_token.balance_of_public(caller));
    assert(caller_lp_after > caller_lp_before, "LP minted to caller");
}

/// Private `add_liquidity` (the partial-note refund path) after a one-sided
/// donation arrived at the pair. The pair's `_add_liquidity` continuation
/// caps each side's deposit at `amount_i_max` BEFORE matching, so the
/// donation portion (`deposited - capped`) stays in reserves where it
/// benefits all LPs, rather than flowing back to the caller as partial-note
/// change. Mirrors `test_add_liquidity_public_absorbs_donation_to_reserves`
/// for the V3-style public path.
#[test]
unconstrained fn test_add_liquidity_private_absorbs_donation_to_reserves() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();
    let provider = env.create_contract_account();
    let depositor = env.create_contract_account();
    let token0 = Token::at(token0_address);
    let token1 = Token::at(token1_address);
    let pair = SigalSwapPair::at(pair_address);

    // Seed the pool: reserves (100_000, 100_000).
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 100_000, 100_000, 0, 0,
    );

    // Donation: 500 token0 sent to pair from outside any protocol interaction.
    env.call_public(admin, token0.mint_to_public(pair_address, 500));

    // Depositor adds balanced (1_000, 1_000) at the 1:1 pool ratio via the
    // private path. A refund formula of `deposited - matched` would return
    // 500 token0 as caller refund (the donation flowing back).
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, depositor, 1_000, 1_000, 0, 0,
    );

    // Reserves must include the 500 token0 donation plus the 1_000-each deposit.
    let (r0, r1, _ts) = env.view_public(pair.get_reserves());
    assert_eq(r0, 101_500);
    assert_eq(r1, 101_000);

    // Depositor's private balances must be zero on both sides -- they paid
    // (1_000, 1_000) via authwit, all of it was matched, no refund. A
    // donation-extraction would instead leave depositor's token0 at 500.
    let depositor_t0 = env.execute_utility(token0.balance_of_private(depositor));
    let depositor_t1 = env.execute_utility(token1.balance_of_private(depositor));
    assert_eq(depositor_t0, 0 as u128);
    assert_eq(depositor_t1, 0 as u128);
}

/// Donation extraction attack: with a pre-existing donation on the pair,
/// an attacker calls private `add_liquidity` with tiny `amount_i_max` (1, 1)
/// hoping to receive the donation as partial-note change. The cap at
/// `amount_i_max` blocks it -- the donation portion is excluded from the
/// refund pool entirely, attacker gets 0 refund, donation stays in reserves.
#[test]
unconstrained fn test_add_liquidity_private_extraction_attack_blocked() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();
    let provider = env.create_contract_account();
    let attacker = env.create_contract_account();
    let token0 = Token::at(token0_address);
    let token1 = Token::at(token1_address);
    let pair = SigalSwapPair::at(pair_address);

    // Seed the pool: reserves (20_000, 20_000).
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20_000, 20_000, 0, 0,
    );

    // Donation: 5_000 token0 to the pair.
    env.call_public(admin, token0.mint_to_public(pair_address, 5_000));

    // Attacker calls private `add_liquidity(1, 1, 0, 0, ...)`. Without the cap
    // at amount_i_max they would walk away with 4_999 token0 net (5_000 refund
    // - 1 paid). The cap forces matched=(1, 1), refund=(0, 0): attacker pays a
    // fair (1, 1) for 1 LP, donation stays in reserves.
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, attacker, 1, 1, 0, 0,
    );

    // Attacker's private token0 balance must be 0. A donation flowing back
    // as partial-note change would instead leave this at 5_000.
    let attacker_t0 = env.execute_utility(token0.balance_of_private(attacker));
    let attacker_t1 = env.execute_utility(token1.balance_of_private(attacker));
    assert_eq(attacker_t0, 0 as u128);
    assert_eq(attacker_t1, 0 as u128);

    // Reserves: token0 grew to 20_000 + 5_000 (donation) + 1 (attacker's
    // matched portion) = 25_001. token1 grew to 20_001.
    let (r0, r1, _ts) = env.view_public(pair.get_reserves());
    assert_eq(r0, 25_001);
    assert_eq(r1, 20_001);
}

/// Loose authwit refund: caller authorizes more on one side than the
/// pool ratio matches. The unmatched portion of the abundant side must be
/// refunded back to the caller's private balance. This is the legitimate
/// V2-router refund flow that the cap-at-amount_i_max preserves -- the
/// cap is a no-op when there's no donation/imbalance, so `capped == max`
/// and `refund = max - matched` exactly mirrors V2-router semantic.
#[test]
unconstrained fn test_add_liquidity_private_caller_refund_works_for_imbalanced_authwit() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();
    let provider = env.create_contract_account();
    let depositor = env.create_contract_account();
    let token0 = Token::at(token0_address);
    let token1 = Token::at(token1_address);
    let pair = SigalSwapPair::at(pair_address);

    // Seed pool at 1:1 ratio: reserves (100_000, 100_000).
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 100_000, 100_000, 0, 0,
    );

    // No donation. Depositor authorizes (1_500, 1_000) -- 50% over-authorization
    // on token0. Optimal at 1:1 ratio is (1_000, 1_000); 500 token0 should
    // be refunded.
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, depositor, 1_500, 1_000, 0, 0,
    );

    // Reserves grew by the matched portion only: (101_000, 101_000).
    let (r0, r1, _ts) = env.view_public(pair.get_reserves());
    assert_eq(r0, 101_000);
    assert_eq(r1, 101_000);

    // Depositor's private token0 balance: 500 (the unmatched portion of
    // their authorization, refunded via partial note). Token1 fully consumed.
    let depositor_t0 = env.execute_utility(token0.balance_of_private(depositor));
    let depositor_t1 = env.execute_utility(token1.balance_of_private(depositor));
    assert_eq(depositor_t0, 500 as u128);
    assert_eq(depositor_t1, 0 as u128);
}

// Note on FoT undershoot: the cap at `amount_i_max` is a no-op when the
// pair receives less than authorized (FoT delivery). In that case
// `capped = min(deposited, max) = deposited`, refund = deposited - matched
// is bounded by what the pair actually holds, no overdraft. Cannot be
// canaried directly without a fee-on-transfer Token fixture, but the cap
// expression handles this case correctly by construction.

/// Private `swap_exact_in` after a donation on the input side: the swap
/// math must use the caller's declared `amount_in`, not the inflated
/// balance-delta. Reserves grow to include the donation; the user's
/// output equals the canonical formula on declared input.
#[test]
unconstrained fn test_swap_exact_in_absorbs_donation_to_reserves() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();
    let provider = env.create_contract_account();
    let swapper = env.create_contract_account();
    let token0 = Token::at(token0_address);
    let pair = SigalSwapPair::at(pair_address);

    // Seed pool to (100_000, 100_000) with 25 bps fee (default fee tier).
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 100_000, 100_000, 0, 0,
    );

    // Donation: 50_000 token0 sent to pair before the swap. If the pair
    // used balance-delta as the swap input, the user would receive ~33_500
    // token1 (output for 51_000 input at the 1:1 reserve ratio). Under
    // the V2-strict cap-at-declared rule, the user receives ~987 token1
    // (output for 1_000 declared input).
    env.call_public(admin, token0.mint_to_public(pair_address, 50_000));

    // User swaps 1000 token0 -> token1.
    swap_exact_in(
        env, pair_address, token0_address, token1_address,
        admin, swapper, 1_000, 0,
    );

    // Reserves: token0 grew to 100_000 + 50_000 (donation) + 1_000 (declared
    // amount_in) = 151_000. token1 dropped by the canonical amount_out
    // for 1_000 input at 25 bps fee:
    //   amount_out = (1000 * 9975 * 100000) / (100000 * 10000 + 1000 * 9975) = 987
    // So reserves[1] = 100_000 - 987 = 99_013.
    let (r0, r1, _ts) = env.view_public(pair.get_reserves());
    assert_eq(r0, 151_000);
    assert_eq(r1, 99_013);
}

/// Private `swap_exact_out` after a donation on the input side: the
/// `change` refund must be capped at `amount_in_max - amount_in`, not at
/// `actual_received - amount_in`. The donation stays in reserves.
#[test]
unconstrained fn test_swap_exact_out_absorbs_donation_to_reserves() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();
    let provider = env.create_contract_account();
    let swapper = env.create_contract_account();
    let token0 = Token::at(token0_address);
    let pair = SigalSwapPair::at(pair_address);

    // Seed pool to (100_000, 100_000), 25 bps fee.
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 100_000, 100_000, 0, 0,
    );

    // Donation: 500 token0 to pair before the swap.
    env.call_public(admin, token0.mint_to_public(pair_address, 500));

    // User wants exactly 1000 token1 out, willing to pay up to 2000 token0.
    // Required input at 25 bps fee:
    //   amount_in = ceil((1000 * 100000 * 10000) / (99000 * 9975)) = 1013
    // Refund: amount_in_max - amount_in = 2000 - 1013 = 987.
    swap_exact_out(
        env, pair_address, token0_address, token1_address,
        admin, swapper, 1_000, 2_000,
    );

    // Reserves: r0 = 100_000 + 1_013 (amount_in) + 500 (donation) = 101_513.
    // r1 = 100_000 - 1_000 = 99_000. If the pair refunded a
    // balance-delta-derived change, r0 would land at 101_013 because the
    // donation would have gone out as part of the user's change. The
    // 500-token0 difference is what this canary protects.
    let (r0, r1, _ts) = env.view_public(pair.get_reserves());
    assert_eq(r0, 101_513);
    assert_eq(r1, 99_000);
}


// ============================================
// Private swap entry zero-amount fail-fast canaries
// ============================================
// The private swap entries (`swap_exact_in`, `swap_exact_out`) reject zero
// amounts at the boundary so a user with a stale UI or an automation bug
// doesn't burn their authwit nonce on a token-side `transfer_to_public(0)`
// and the public continuation gas before the deep
// `INSUFFICIENT_INPUT_AMOUNT` / `INSUFFICIENT_OUTPUT_AMOUNT` revert in
// `get_amount_*`. Symmetric with the `add_liquidity` entry's
// `INSUFFICIENT_INPUT_AMOUNTS` guard. The canaries below pin the assertion
// shape so a future entry refactor that drops a guard surfaces here.

#[test(should_fail_with = "INSUFFICIENT_INPUT_AMOUNT")]
unconstrained fn test_swap_exact_in_private_zero_amount_in_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();
    let provider = env.create_contract_account();
    let swapper = env.create_contract_account();

    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    // No mint / authwit needed: the entry-side `amount_in > 0` assert fires
    // before any token-side call, and the test framework expects a revert
    // before authwit consumption.
    let pair = SigalSwapPair::at(pair_address);
    env.call_private(swapper, pair.swap_exact_in(
        token0_address, token1_address,
        0 as u128, 0 as u128, AUTHWIT_NONCE,
    ));
}

#[test(should_fail_with = "INSUFFICIENT_OUTPUT_AMOUNT")]
unconstrained fn test_swap_exact_out_private_zero_amount_out_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();
    let provider = env.create_contract_account();
    let swapper = env.create_contract_account();

    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    let pair = SigalSwapPair::at(pair_address);
    env.call_private(swapper, pair.swap_exact_out(
        token0_address, token1_address,
        0 as u128, 1000 as u128, AUTHWIT_NONCE,
    ));
}

/// `swap_exact_out` also rejects `amount_in_max == 0` (with a positive
/// `amount_out`). Without this guard, the private leg would proceed
/// through `transfer_to_public_and_prepare_private_balance_increase(0)`
/// and the public continuation would later revert when the K-derived
/// `amount_in > amount_in_max` check fires -- gas-waste-on-revert.
#[test(should_fail_with = "INSUFFICIENT_INPUT_MAX")]
unconstrained fn test_swap_exact_out_private_zero_amount_in_max_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();
    let provider = env.create_contract_account();
    let swapper = env.create_contract_account();

    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    let pair = SigalSwapPair::at(pair_address);
    env.call_private(swapper, pair.swap_exact_out(
        token0_address, token1_address,
        100 as u128, 0 as u128, AUTHWIT_NONCE,
    ));
}

// ================================================================
// Liquidity slippage canaries
//
// The add/remove-liquidity min-bound guards are correct in source today;
// these are canaries that pin the revert so a future edit cannot silently
// neuter the slippage protection. Every other liquidity test passes mins of
// `0, 0`; here we pass a min the matched amount cannot satisfy. The add-side
// guards live on the subsequent-deposit ratio path in
// `get_amounts_to_add` (pair/mod.nr); the remove-side guards live on the
// `_remove_liquidity` proportional-withdrawal path (main.nr).
// ================================================================

/// AMOUNT_1_BELOW_MINIMUM -- subsequent-deposit ratio path, first branch.
///
/// Pool seeded 1:1 at 100000/100000 (above the first-mint MINIMUM_LIQUIDITY floor). A second deposit of amount0_max=4000,
/// amount1_max=5000 takes the "use max amount0" branch: the equivalent
/// token1 at the 1:1 ratio is 4000 (= mul_div(4000, 100000, 100000)), which is
/// <= amount1_max so the branch asserts `amount1_equivalent >= amount1_min`.
/// amount1_min=4500 is <= amount1_max (passes the entry INCORRECT_TOKEN1_LIMITS
/// check) but above the 4000 the ratio yields, so the guard fires.
#[test(should_fail_with = "AMOUNT_1_BELOW_MINIMUM")]
unconstrained fn test_add_liquidity_ratio_amount1_below_minimum_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();
    let provider1 = env.create_contract_account();
    let provider2 = env.create_contract_account();

    // Seed the pool so reserves are non-zero (drives the subsequent-deposit
    // ratio branch rather than the first-deposit branch).
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider1, 100000, 100000, 0, 0,
    );

    // Matched amount1 = 4000; demanding amount1_min = 4500 (<= amount1_max)
    // violates the ratio-path floor.
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider2, 4000, 5000, 0, 4500,
    );
}

/// AMOUNT_0_BELOW_MINIMUM -- subsequent-deposit ratio path, else branch.
///
/// Pool seeded 1:1 at 100000/100000 (above the first-mint MINIMUM_LIQUIDITY floor). A second deposit of amount0_max=5000,
/// amount1_max=4000 makes amount1_equivalent (5000) exceed amount1_max, so the
/// else branch fixes token1 at its max and back-computes amount0_equivalent =
/// mul_div(4000, 100000, 100000) = 4000. That branch asserts
/// `amount0_equivalent >= amount0_min`. amount0_min=4500 is <= amount0_max
/// (passes INCORRECT_TOKEN0_LIMITS) but above the 4000 the ratio yields.
#[test(should_fail_with = "AMOUNT_0_BELOW_MINIMUM")]
unconstrained fn test_add_liquidity_ratio_amount0_below_minimum_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();
    let provider1 = env.create_contract_account();
    let provider2 = env.create_contract_account();

    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider1, 100000, 100000, 0, 0,
    );

    // Matched amount0 = 4000; demanding amount0_min = 4500 (<= amount0_max)
    // violates the ratio-path floor on the token0 side.
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider2, 5000, 4000, 4500, 0,
    );
}

/// BELOW_MINIMUM_0 -- remove-liquidity proportional-withdrawal floor (token0).
///
/// Pool seeded 10000/20000; provider holds 4142 LP, total supply 14142.
/// Burning 2071 LP yields amount0 = floor(2071 * 10000 / 14142) = 1464.
/// Passing amount0_min = 1465 (one above the matched amount) trips the floor.
#[test(should_fail_with = "BELOW_MINIMUM_0")]
unconstrained fn test_remove_liquidity_below_minimum_0_reverts() {
    let (mut env, pair_address, token0_address, token1_address, lp_address, admin) = setup();
    let provider = env.create_contract_account();

    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 10000, 20000, 0, 0,
    );

    remove_liquidity(
        env, pair_address, lp_address, provider,
        2071, 1465, 0,
    );
}

/// BELOW_MINIMUM_1 -- remove-liquidity proportional-withdrawal floor (token1).
///
/// Same seed as above. Burning 2071 LP yields amount1 =
/// floor(2071 * 20000 / 14142) = 2928. Passing amount1_min = 2929 trips the
/// floor.
#[test(should_fail_with = "BELOW_MINIMUM_1")]
unconstrained fn test_remove_liquidity_below_minimum_1_reverts() {
    let (mut env, pair_address, token0_address, token1_address, lp_address, admin) = setup();
    let provider = env.create_contract_account();

    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 10000, 20000, 0, 0,
    );

    remove_liquidity(
        env, pair_address, lp_address, provider,
        2071, 0, 2929,
    );
}

/// INSUFFICIENT_0_AMOUNT -- remove-liquidity zero-yield guard (token0 side).
///
/// This guard fires only when the burn rounds the token0 withdrawal to zero,
/// which the always-`0, 0` mins in every other test never reach. To reach it,
/// seed an extreme asymmetry where token0 reserve (10001) is far below total
/// supply: total = floor(sqrt(10001 * 1e9)) = 3162435. Burning 1 LP yields
/// amount0 = floor(1 * 10001 / 3162435) = 0 (token0 reserve < total supply),
/// while amount1 = floor(1 * 1e9 / 3162435) = 316 > 0. The token0-side
/// `amount0 > 0` assert fires before the token1-side check. Mins are 0, 0 so
/// the BELOW_MINIMUM floors do not preempt.
#[test(should_fail_with = "INSUFFICIENT_0_AMOUNT")]
unconstrained fn test_remove_liquidity_zero_token0_yield_reverts() {
    let (mut env, pair_address, token0_address, token1_address, lp_address, admin) = setup();
    let provider = env.create_contract_account();

    // token0 = 10001 (small), token1 = 1e9 (large).
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 10001, 1_000_000_000, 0, 0,
    );

    remove_liquidity(
        env, pair_address, lp_address, provider,
        1, 0, 0,
    );
}

/// INSUFFICIENT_1_AMOUNT -- remove-liquidity zero-yield guard (token1 side).
///
/// Mirror of the above with the asymmetry flipped: token1 reserve (10001) is
/// far below total supply 3162435, so burning 1 LP yields amount1 =
/// floor(1 * 10001 / 3162435) = 0 while amount0 = floor(1 * 1e9 / 3162435) =
/// 316 > 0. amount0 clears its `> 0` check, so execution reaches the
/// token1-side `amount1 > 0` assert.
#[test(should_fail_with = "INSUFFICIENT_1_AMOUNT")]
unconstrained fn test_remove_liquidity_zero_token1_yield_reverts() {
    let (mut env, pair_address, token0_address, token1_address, lp_address, admin) = setup();
    let provider = env.create_contract_account();

    // token0 = 1e9 (large), token1 = 10001 (small).
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 1_000_000_000, 10001, 0, 0,
    );

    remove_liquidity(
        env, pair_address, lp_address, provider,
        1, 0, 0,
    );
}
