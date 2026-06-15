use crate::{SigalSwapLPToken, test::utils::setup};

/// burn_public on the caller's own balance reduces balance and total_supply.
/// This path is the permissionless self-burn -- anyone holding LP can destroy
/// their own balance (authwit nonce = 0 on self-owned call).
#[test]
unconstrained fn self_burn_reduces_balance_and_supply() {
    let (mut env, lp_address, pair, _outsider) = setup();
    let lp = SigalSwapLPToken::at(lp_address);
    let holder = env.create_contract_account();

    // Pair mints 1000 LP to holder's public balance.
    env.call_public(pair, lp.mint_to_public(holder, 1000 as u128));

    // Holder burns 400 of their own balance (authwit_nonce = 0 for self-call).
    env.call_public(holder, lp.burn_public(holder, 400 as u128, 0));

    let bal: u128 = env.view_public( lp.balance_of_public(holder));
    assert_eq(bal, 600 as u128);

    let supply: u128 = env.view_public( lp.total_supply());
    assert_eq(supply, 600 as u128);
}

/// Attempting to burn more than balance reverts.
#[test(should_fail)]
unconstrained fn burn_more_than_balance_reverts() {
    let (mut env, lp_address, pair, _outsider) = setup();
    let lp = SigalSwapLPToken::at(lp_address);
    let holder = env.create_contract_account();

    env.call_public(pair, lp.mint_to_public(holder, 100 as u128));

    env.call_public(holder, lp.burn_public(holder, 500 as u128, 0));
}

/// Burn of zero succeeds as a no-op and doesn't corrupt state.
#[test]
unconstrained fn burn_zero_is_noop() {
    let (mut env, lp_address, pair, _outsider) = setup();
    let lp = SigalSwapLPToken::at(lp_address);
    let holder = env.create_contract_account();

    env.call_public(pair, lp.mint_to_public(holder, 1000 as u128));
    env.call_public(holder, lp.burn_public(holder, 0 as u128, 0));

    let bal: u128 = env.view_public( lp.balance_of_public(holder));
    assert_eq(bal, 1000 as u128);

    let supply: u128 = env.view_public( lp.total_supply());
    assert_eq(supply, 1000 as u128);
}
