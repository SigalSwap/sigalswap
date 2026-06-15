use crate::{SigalSwapLPToken, test::utils::setup};
use aztec::protocol::{address::AztecAddress, traits::{FromField, ToField}};

/// The stored pair address can be read after construction.
#[test]
unconstrained fn constructor_stores_pair_address() {
    let (mut env, lp_address, pair, _outsider) = setup();
    let lp = SigalSwapLPToken::at(lp_address);

    let stored: Field = env.view_public( lp.get_pair());
    assert_eq(stored, pair.to_field());
}

/// Constructor rejects the zero address as pair.
#[test(should_fail_with = "pair cannot be zero")]
unconstrained fn constructor_rejects_zero_pair() {
    let mut env = aztec::test::helpers::test_environment::TestEnvironment::new();
    let deployer = env.create_contract_account();

    let lp_init =
        SigalSwapLPToken::interface().constructor(AztecAddress::from_field(0));
    let _ =
        env.deploy("@sigalswap_lp_token/SigalSwapLPToken").with_public_initializer(deployer, lp_init);
}

/// The paired pair can call mint_to_public successfully.
#[test]
unconstrained fn pair_can_mint_to_public() {
    let (mut env, lp_address, pair, _outsider) = setup();
    let lp = SigalSwapLPToken::at(lp_address);
    let recipient = env.create_contract_account();

    env.call_public(pair, lp.mint_to_public(recipient, 1000 as u128));

    let bal: u128 = env.view_public( lp.balance_of_public(recipient));
    assert_eq(bal, 1000 as u128);

    let supply: u128 = env.view_public( lp.total_supply());
    assert_eq(supply, 1000 as u128);
}

/// A non-pair caller cannot call mint_to_public -- reverts with ONLY_PAIR.
#[test(should_fail_with = "ONLY_PAIR")]
unconstrained fn non_pair_cannot_mint_to_public() {
    let (mut env, lp_address, _pair, outsider) = setup();
    let lp = SigalSwapLPToken::at(lp_address);
    let recipient = env.create_contract_account();

    env.call_public(outsider, lp.mint_to_public(recipient, 1000 as u128));
}

/// Multiple mints from the pair accumulate total_supply correctly.
#[test]
unconstrained fn multiple_mints_accumulate_supply() {
    let (mut env, lp_address, pair, _outsider) = setup();
    let lp = SigalSwapLPToken::at(lp_address);
    let r1 = env.create_contract_account();
    let r2 = env.create_contract_account();

    env.call_public(pair, lp.mint_to_public(r1, 500 as u128));
    env.call_public(pair, lp.mint_to_public(r2, 750 as u128));

    let supply: u128 = env.view_public( lp.total_supply());
    assert_eq(supply, 1250 as u128);

    let b1: u128 = env.view_public( lp.balance_of_public(r1));
    assert_eq(b1, 500 as u128);

    let b2: u128 = env.view_public( lp.balance_of_public(r2));
    assert_eq(b2, 750 as u128);
}

/// A non-pair caller cannot call finalize_mint_to_private -- reverts ONLY_PAIR
/// before the partial note is touched. Direct canary on the ONLY_PAIR gate;
/// the existing mint_to_public test covers the same assertion line, but a
/// future refactor that splits the gating between the two paths (helper
/// extraction, etc.) would not be caught without this canary.
#[test(should_fail_with = "ONLY_PAIR")]
unconstrained fn non_pair_cannot_finalize_mint_to_private() {
    let (mut env, lp_address, _pair, outsider) = setup();
    let lp = SigalSwapLPToken::at(lp_address);

    // Outsider prepares a partial note for itself. The exact contents don't
    // matter -- the ONLY_PAIR assert in finalize_mint_to_private fires before
    // partial_note.complete() is called.
    let pn = env.call_private(outsider, lp.prepare_private_balance_increase(outsider));

    // Outsider attempts the public finalize. msg_sender = outsider != stored
    // pair, so the ONLY_PAIR assertion reverts.
    env.call_public(outsider, lp.finalize_mint_to_private(100 as u128, pn));
}
