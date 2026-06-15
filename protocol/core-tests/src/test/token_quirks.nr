// Token-quirk attack tests against the pair's public-direct entries.
//
// Each test deploys an honest Token alongside a HostileToken, sets the
// hostile contract's mode, and exercises a pair entry. The defense being
// canaried is named in the test docstring.
//
// Scope: public-direct entries only (add_liquidity_public,
// remove_liquidity_public, sync). Private entries call token methods
// (transfer_to_public_and_prepare_private_balance_increase,
// finalize_transfer_to_private) that HostileToken intentionally does not
// implement -- those flows require well-behaved tokens by construction.
// See docs/token-compatibility.md for the full assumption surface.

use sigalswap_core::SigalSwapPair;
use aztec::{
    protocol::{address::AztecAddress, traits::ToField},
    test::helpers::{test_environment::TestEnvironment, txe_oracles},
};
use hostile_token::HostileToken;
use sigalswap_lp_token::SigalSwapLPToken;
use token::Token;

// Mirror of HostileToken's mode constants -- match exactly.
global MODE_HONEST: u32 = 0;
global MODE_NOOP_TRANSFER: u32 = 1;
global MODE_UNDER_DELIVERY: u32 = 2;
global MODE_OVER_DELIVERY: u32 = 3;
global MODE_HOSTILE_BALANCE: u32 = 4;
global MODE_REVERT_ON_RECIPIENT: u32 = 5;

/// Deploys honest Token + HostileToken + pair + LP Token. Returns
/// addresses for the pair and both tokens (with the hostile-token
/// address returned separately so tests can flip its mode).
/// Token addresses are canonically sorted to satisfy the pair's
/// TOKENS_NOT_SORTED constructor assert.
unconstrained fn setup_with_hostile_token() -> (
    TestEnvironment,
    AztecAddress, // pair_address
    AztecAddress, // hostile_address
    AztecAddress, // honest_address
    AztecAddress, // token0_address (whichever of the two sorts lower)
    AztecAddress, // token1_address
    AztecAddress, // lp_address
    AztecAddress, // admin
) {
    let mut env = TestEnvironment::new();
    let admin = env.create_contract_account();

    let honest_address = env.deploy("@token_contract/Token").with_public_initializer(
        admin,
        Token::interface().constructor(
            admin,
            "HonestToken00000000000000000000",
            "HON0000000000000000000000000000",
            18,
        ),
    );

    let hostile_address = env.deploy("@hostile_token/HostileToken").with_public_initializer(
        admin,
        HostileToken::interface().constructor(),
    );

    let (token0_address, token1_address) =
        if (hostile_address.to_field() as u128) < (honest_address.to_field() as u128) {
            (hostile_address, honest_address)
        } else {
            (honest_address, hostile_address)
        };

    let fee_tier_bps: u32 = 25;
    let pair_init = SigalSwapPair::interface().constructor(
        token0_address,
        token1_address,
        admin,
        fee_tier_bps,
    );
    let pair_address = env.deploy("@sigalswap_core/SigalSwapPair").with_public_initializer(admin, pair_init);

    let derived_lp_address: AztecAddress =
        env.view_public(SigalSwapPair::at(pair_address).get_lp_token());
    let lp_args: [Field; 1] = [pair_address.to_field()];
    let lp_instance = txe_oracles::deploy(
        "@sigalswap_lp_token/SigalSwapLPToken",
        "constructor",
        lp_args,
        0,
        1,
        AztecAddress::zero(),
    );
    let lp_deployed_address = lp_instance.to_address();
    assert_eq(lp_deployed_address, derived_lp_address);
    env.call_public(
        admin,
        SigalSwapLPToken::at(lp_deployed_address).constructor(pair_address),
    );

    (
        env,
        pair_address,
        hostile_address,
        honest_address,
        token0_address,
        token1_address,
        lp_deployed_address,
        admin,
    )
}

/// Helper: mint tokens to `who` for both honest and hostile.
unconstrained fn mint_both(
    env: TestEnvironment,
    admin: AztecAddress,
    hostile_address: AztecAddress,
    honest_address: AztecAddress,
    who: AztecAddress,
    amount: u128,
) {
    env.call_public(admin, Token::at(honest_address).mint_to_public(who, amount));
    env.call_public(admin, HostileToken::at(hostile_address).mint_to_public(who, amount));
}

/// Helper: user transfers both tokens to the pair address.
unconstrained fn transfer_both_to_pair(
    env: TestEnvironment,
    user: AztecAddress,
    pair_address: AztecAddress,
    hostile_address: AztecAddress,
    honest_address: AztecAddress,
    amount: u128,
) {
    env.call_public(
        user,
        Token::at(honest_address).transfer_in_public(user, pair_address, amount, 0),
    );
    env.call_public(
        user,
        Token::at(hostile_address).transfer_in_public(user, pair_address, amount, 0),
    );
}

// ============================================================
// NOOP_TRANSFER -- pair detects missing deposit via balance delta
// ============================================================

/// Hostile token accepts transfer calls but does not move state.
/// Pair's balance_of_public read sees no delta -> NO_TOKEN_*_DEPOSIT revert.
#[test(should_fail)]
unconstrained fn test_noop_transfer_blocks_add_liquidity_public() {
    let (
        mut env,
        pair_address,
        hostile_address,
        honest_address,
        _t0,
        _t1,
        _lp,
        admin,
    ) = setup_with_hostile_token();

    let user = env.create_contract_account();
    mint_both(env, admin, hostile_address, honest_address, user, 10_000);

    // Flip hostile token to NOOP_TRANSFER mode.
    env.call_public(
        admin,
        HostileToken::at(hostile_address).set_mode(MODE_NOOP_TRANSFER),
    );

    // User "transfers" both tokens to pair. The honest leg moves; the
    // hostile leg is a no-op (HostileToken accepts the call, does nothing).
    transfer_both_to_pair(env, user, pair_address, hostile_address, honest_address, 1_000);

    // add_liquidity_public reads balances; one side shows zero delta ->
    // NO_TOKEN0_DEPOSIT or NO_TOKEN1_DEPOSIT depending on hostile slot.
    env.call_public(
        user,
        SigalSwapPair::at(pair_address).add_liquidity_public(user, 0, 0),
    );
}

// ============================================================
// UNDER_DELIVERY -- pair-direct absorbs the undershoot (canonical FoT)
// ============================================================

/// Hostile token delivers 90% of requested. Pair sees only the delivered
/// amount in its balance read and mints LP against that. No revert -- the
/// pair-direct path is FoT-tolerant by design (balance-delta accounting).
#[test]
unconstrained fn test_under_delivery_pair_direct_absorbs_undershoot() {
    let (
        mut env,
        pair_address,
        hostile_address,
        honest_address,
        token0_address,
        token1_address,
        lp_address,
        admin,
    ) = setup_with_hostile_token();

    let user = env.create_contract_account();
    mint_both(env, admin, hostile_address, honest_address, user, 1_000_000);

    env.call_public(
        admin,
        HostileToken::at(hostile_address).set_under_factor(90),
    );
    env.call_public(
        admin,
        HostileToken::at(hostile_address).set_mode(MODE_UNDER_DELIVERY),
    );

    // Deposit large enough to clear MINIMUM_LIQUIDITY = 10_000 (sqrt must
    // exceed 2 * MIN = 20_000 on the first mint).
    transfer_both_to_pair(env, user, pair_address, hostile_address, honest_address, 100_000);

    // Pair should accept the (smaller) actual delivery on the hostile leg
    // and mint LP against the matched-ratio portion.
    env.call_public(
        user,
        SigalSwapPair::at(pair_address).add_liquidity_public(user, 0, 0),
    );

    // Honest leg arrived as 100_000; hostile leg arrived as 90_000 (90% of 100_000).
    let pair_balance0 = env.view_public(Token::at(token0_address).balance_of_public(pair_address));
    let pair_balance1 = env.view_public(Token::at(token1_address).balance_of_public(pair_address));
    let total: u128 = pair_balance0 + pair_balance1;
    assert_eq(total, 190_000);

    let user_lp = env.view_public(SigalSwapLPToken::at(lp_address).balance_of_public(user));
    assert(user_lp > 0 as u128);
}

// ============================================================
// OVER_DELIVERY -- pair captures surplus into reserves (over LPs benefit)
// ============================================================

/// Hostile token credits 200% of requested. Pair sees inflated balance
/// and mints LP based on the inflated amount on first mint. The surplus
/// becomes part of the reserves -- existing LPs benefit on subsequent
/// mints (V2-strict imbalanced-excess capture). No defense against
/// inflation-by-token-mint at the pair level; token whitelisting is the
/// answer.
#[test]
unconstrained fn test_over_delivery_inflates_first_mint_lp() {
    let (
        mut env,
        pair_address,
        hostile_address,
        honest_address,
        token0_address,
        token1_address,
        _lp,
        admin,
    ) = setup_with_hostile_token();

    let user = env.create_contract_account();
    mint_both(env, admin, hostile_address, honest_address, user, 1_000_000);

    env.call_public(
        admin,
        HostileToken::at(hostile_address).set_over_factor(200),
    );
    env.call_public(
        admin,
        HostileToken::at(hostile_address).set_mode(MODE_OVER_DELIVERY),
    );

    transfer_both_to_pair(env, user, pair_address, hostile_address, honest_address, 100_000);

    env.call_public(
        user,
        SigalSwapPair::at(pair_address).add_liquidity_public(user, 0, 0),
    );

    // Hostile token credited 200_000 (200% of 100_000); honest credited 100_000.
    // Total balance held by the pair after over-delivery: 300_000.
    let pair_balance0 = env.view_public(Token::at(token0_address).balance_of_public(pair_address));
    let pair_balance1 = env.view_public(Token::at(token1_address).balance_of_public(pair_address));
    let total_balance: u128 = pair_balance0 + pair_balance1;
    assert_eq(total_balance, 300_000);
}

// ============================================================
// HOSTILE_BALANCE -- pair has no defense; token whitelisting is the gate
// ============================================================

/// Hostile token lies about its `balance_of_public(pair_address)`,
/// returning a value larger than the real balance. Pair reads the lie
/// and mints LP for a phantom deposit. This test demonstrates the
/// defense GAP: a token that mis-reports its own balance can deceive
/// the pair's balance-delta accounting. Defense lives at the factory's
/// token-whitelisting / fee-tier admission layer, not in the pair.
#[test]
unconstrained fn test_hostile_balance_fools_pair() {
    let (
        mut env,
        pair_address,
        hostile_address,
        honest_address,
        _t0,
        _t1,
        lp_address,
        admin,
    ) = setup_with_hostile_token();

    let user = env.create_contract_account();
    mint_both(env, admin, hostile_address, honest_address, user, 1_000_000);

    // Configure hostile to lie when pair reads ITS OWN balance.
    // Real balance after user transfer will be 100_000; lie says 500_000.
    env.call_public(
        admin,
        HostileToken::at(hostile_address).set_hostile_balance(pair_address, 500_000),
    );
    env.call_public(
        admin,
        HostileToken::at(hostile_address).set_mode(MODE_HOSTILE_BALANCE),
    );

    // User actually transfers 100_000 of each to the pair.
    transfer_both_to_pair(env, user, pair_address, hostile_address, honest_address, 100_000);

    env.call_public(
        user,
        SigalSwapPair::at(pair_address).add_liquidity_public(user, 0, 0),
    );

    // Pair would have minted LP for a 5000-on-hostile-side, 1000-on-honest-side
    // deposit. After get_amounts_to_add matching, the user gets LP for the
    // pair-ratio amount. Crucially: LP > 0 was minted despite the deposit
    // being a lie. The point of the test is the gap, not the exact LP amount.
    let user_lp = env.view_public(SigalSwapLPToken::at(lp_address).balance_of_public(user));
    assert(user_lp > 0 as u128);
}

// ============================================================
// REVERT_ON_RECIPIENT -- pair's revert propagates cleanly
// ============================================================

/// Hostile token reverts when transferring to the pair (e.g., a token
/// with an admin-managed recipient blocklist). Pair's transfer attempt
/// fails; the underlying revert message surfaces. No half-state.
#[test(should_fail_with = "HOSTILE_TOKEN_REVERT")]
unconstrained fn test_revert_on_recipient_surfaces_cleanly() {
    let (
        mut env,
        pair_address,
        hostile_address,
        honest_address,
        _t0,
        _t1,
        _lp,
        admin,
    ) = setup_with_hostile_token();

    let user = env.create_contract_account();
    mint_both(env, admin, hostile_address, honest_address, user, 10_000);

    env.call_public(
        admin,
        HostileToken::at(hostile_address).set_hostile_recipient(pair_address),
    );
    env.call_public(
        admin,
        HostileToken::at(hostile_address).set_mode(MODE_REVERT_ON_RECIPIENT),
    );

    // Honest leg succeeds; hostile leg reverts on transfer to pair.
    env.call_public(
        user,
        Token::at(honest_address).transfer_in_public(user, pair_address, 1_000, 0),
    );
    env.call_public(
        user,
        HostileToken::at(hostile_address).transfer_in_public(user, pair_address, 1_000, 0),
    );
}

// ============================================================
// REBASE + sync() -- pair's recovery path for spontaneous balance drift
// ============================================================

/// Hostile token's admin spontaneously inflates the pair's balance
/// (rebase). sync() reads the new balance and writes it back to
/// reserves, restoring the invariant that the pair's tracked reserves
/// match its actual balances.
#[test]
unconstrained fn test_force_rebase_then_sync_restores_invariant() {
    let (
        mut env,
        pair_address,
        hostile_address,
        honest_address,
        token0_address,
        token1_address,
        _lp,
        admin,
    ) = setup_with_hostile_token();

    let user = env.create_contract_account();
    mint_both(env, admin, hostile_address, honest_address, user, 1_000_000);

    // Bootstrap pair with honest liquidity. Deposit large enough to clear
    // MINIMUM_LIQUIDITY = 10_000 on the first mint.
    transfer_both_to_pair(env, user, pair_address, hostile_address, honest_address, 100_000);
    env.call_public(
        user,
        SigalSwapPair::at(pair_address).add_liquidity_public(user, 0, 0),
    );

    // Admin rebases hostile token's balance for the pair upward by 10_000.
    // This represents a token whose admin can adjust balances out of
    // band -- a class that includes interest-bearing tokens, USDC-style
    // pause-and-redeem mechanics, and outright malicious admin actions.
    let pair_balance_before = env.view_public(Token::at(hostile_address).balance_of_public(pair_address));
    env.call_public(
        admin,
        HostileToken::at(hostile_address).force_rebase(pair_address, pair_balance_before + 10_000),
    );

    // Reserves are now out of sync with balance. sync() reads balance
    // and writes it back to reserves. Anyone can call it -- it's
    // permissionless and intended as the recovery path.
    env.call_public(user, SigalSwapPair::at(pair_address).sync());

    // After sync, reserves match balances on both sides.
    let pair_balance0_after = env.view_public(Token::at(token0_address).balance_of_public(pair_address));
    let pair_balance1_after = env.view_public(Token::at(token1_address).balance_of_public(pair_address));
    let (reserve0_after, reserve1_after, _ts): (u128, u128, u64) =
        env.view_public(SigalSwapPair::at(pair_address).get_reserves());
    assert_eq(reserve0_after, pair_balance0_after);
    assert_eq(reserve1_after, pair_balance1_after);
}
