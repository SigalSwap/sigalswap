use sigalswap_core::SigalSwapPair;
use aztec::{
    protocol::{address::AztecAddress, traits::{FromField, ToField}},
    test::helpers::{authwit::add_private_authwit_from_call, test_environment::TestEnvironment, txe_oracles},
};
use sigalswap_lp_token::SigalSwapLPToken;
use token::Token;

/// Authwit nonce used across all test operations.
pub(crate) global AUTHWIT_NONCE: Field = 1;

/// Deploys the full SigalSwap stack: token0, token1, pair, and the LP Token
/// at the pair's derived address.
///
/// Returns (env, pair_address, token0, token1, lp_address, admin). The LP
/// address is DERIVED from the pair's address inside the pair's constructor;
/// we re-derive it here by reading `pair.get_lp_token()` and deploy the LP
/// Token at that address using canonical inputs (salt=0, universal deploy,
/// default keys). The asserted address-equality downstream of that deploy
/// guards the invariant that the SDK's canonical deploy inputs match the
/// pair-internal derivation; if they drift, this assertion fires.
///
/// NOTE: Factory is not deployed in these tests. Admin stands in as the
/// factory address so the pair's factory-only functions (set_pause,
/// set_protocol_fee) can be exercised directly from the admin account.
pub(crate) unconstrained fn setup() -> (
    TestEnvironment,
    AztecAddress,
    AztecAddress,
    AztecAddress,
    AztecAddress,
    AztecAddress,
) {
    let mut env = TestEnvironment::new();

    let admin = env.create_contract_account();

    // Deploy two tokens, then sort their addresses to satisfy the pair's
    // canonical-ordering invariant (token0 < token1). The names below are
    // positional within the pair, not tied to deploy order.
    let token_a = env.deploy("@token_contract/Token").with_public_initializer(
        admin,
        Token::interface().constructor(
            admin,
            "Token00000000000000000000000000",
            "TK00000000000000000000000000000",
            18,
        ),
    );
    let token_b = env.deploy("@token_contract/Token").with_public_initializer(
        admin,
        Token::interface().constructor(
            admin,
            "Token11111111111111111111111111",
            "TK11111111111111111111111111111",
            18,
        ),
    );
    let (token0_address, token1_address) =
        if (token_a.to_field() as u128) < (token_b.to_field() as u128) {
            (token_a, token_b)
        } else {
            (token_b, token_a)
        };

    // Deploy pair. Constructor derives its LP Token address from its own
    // address and caches it in PublicImmutable storage.
    // factory = admin so admin can call set_pause / set_protocol_fee directly.
    let fee_tier_bps: u32 = 25; // 0.25%
    let pair_init = SigalSwapPair::interface().constructor(
        token0_address,
        token1_address,
        admin,
        fee_tier_bps,
    );
    let pair_address = env.deploy("@sigalswap_core/SigalSwapPair").with_public_initializer(admin, pair_init);

    // Read the LP address the pair derived for itself.
    let derived_lp_address: AztecAddress =
        env.view_public(SigalSwapPair::at(pair_address).get_lp_token());

    // Deploy the LP Token at the derived address. TXE's `txe_oracles::deploy`
    // hardcodes salt=1 and deployer=zero; pair's `LP_TOKEN_SALT = 1` matches,
    // so the TXE deploy lands at the pair's derived address. The assertion
    // below guards against drift.
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

    // Run the LP Token's public constructor so its storage is initialized.
    env.call_public(
        admin,
        SigalSwapLPToken::at(lp_deployed_address).constructor(pair_address),
    );

    (env, pair_address, token0_address, token1_address, lp_deployed_address, admin)
}

/// Mint tokens to a user's private balance and set up authwits for add_liquidity.
/// Then call add_liquidity on the pair.
pub(crate) unconstrained fn add_liquidity(
    env: TestEnvironment,
    pair_address: AztecAddress,
    token0_address: AztecAddress,
    token1_address: AztecAddress,
    minter: AztecAddress,
    provider: AztecAddress,
    amount0_max: u128,
    amount1_max: u128,
    amount0_min: u128,
    amount1_min: u128,
) {
    let token0 = Token::at(token0_address);
    let token1 = Token::at(token1_address);
    let pair = SigalSwapPair::at(pair_address);

    // Mint tokens to provider's private balance
    env.call_private(minter, token0.mint_to_private(provider, amount0_max));
    env.call_private(minter, token1.mint_to_private(provider, amount1_max));

    // Set up authwits for the pair to transfer tokens on behalf of provider
    let transfer0_call = token0.transfer_to_public_and_prepare_private_balance_increase(
        provider,
        pair_address,
        amount0_max,
        AUTHWIT_NONCE,
    );
    add_private_authwit_from_call(env, provider, pair_address, transfer0_call);

    let transfer1_call = token1.transfer_to_public_and_prepare_private_balance_increase(
        provider,
        pair_address,
        amount1_max,
        AUTHWIT_NONCE,
    );
    add_private_authwit_from_call(env, provider, pair_address, transfer1_call);

    // Call add_liquidity
    env.call_private(
        provider,
        pair.add_liquidity(amount0_max, amount1_max, amount0_min, amount1_min, AUTHWIT_NONCE),
    );
}

/// Set up authwits and call remove_liquidity on the pair.
pub(crate) unconstrained fn remove_liquidity(
    env: TestEnvironment,
    pair_address: AztecAddress,
    lp_address: AztecAddress,
    provider: AztecAddress,
    liquidity: u128,
    amount0_min: u128,
    amount1_min: u128,
) {
    let lp_token = SigalSwapLPToken::at(lp_address);
    let pair = SigalSwapPair::at(pair_address);

    let transfer_call = lp_token.transfer_to_public(
        provider,
        pair_address,
        liquidity,
        AUTHWIT_NONCE,
    );
    add_private_authwit_from_call(env, provider, pair_address, transfer_call);

    env.call_private(
        provider,
        pair.remove_liquidity(liquidity, amount0_min, amount1_min, AUTHWIT_NONCE),
    );
}

/// Mint input tokens to `swapper`, set up authwit for the pair, and call
/// swap_exact_in with the declared (amount_in, amount_out_min). Infers
/// token_in/token_out from the order passed (first is input).
pub(crate) unconstrained fn swap_exact_in(
    env: TestEnvironment,
    pair_address: AztecAddress,
    token_in_address: AztecAddress,
    token_out_address: AztecAddress,
    minter: AztecAddress,
    swapper: AztecAddress,
    amount_in: u128,
    amount_out_min: u128,
) {
    let token_in = Token::at(token_in_address);
    let pair = SigalSwapPair::at(pair_address);

    env.call_private(minter, token_in.mint_to_private(swapper, amount_in));

    // Pair's swap_exact_in pulls input via Token::transfer_to_public.
    let transfer_call = token_in.transfer_to_public(
        swapper,
        pair_address,
        amount_in,
        AUTHWIT_NONCE,
    );
    add_private_authwit_from_call(env, swapper, pair_address, transfer_call);

    env.call_private(
        swapper,
        pair.swap_exact_in(
            token_in_address,
            token_out_address,
            amount_in,
            amount_out_min,
            AUTHWIT_NONCE,
        ),
    );
}

/// Mint amount_in_max input tokens, set up authwit, and call swap_exact_out.
pub(crate) unconstrained fn swap_exact_out(
    env: TestEnvironment,
    pair_address: AztecAddress,
    token_in_address: AztecAddress,
    token_out_address: AztecAddress,
    minter: AztecAddress,
    swapper: AztecAddress,
    amount_out: u128,
    amount_in_max: u128,
) {
    let token_in = Token::at(token_in_address);
    let pair = SigalSwapPair::at(pair_address);

    env.call_private(minter, token_in.mint_to_private(swapper, amount_in_max));

    let transfer_call = token_in.transfer_to_public_and_prepare_private_balance_increase(
        swapper,
        pair_address,
        amount_in_max,
        AUTHWIT_NONCE,
    );
    add_private_authwit_from_call(env, swapper, pair_address, transfer_call);

    env.call_private(
        swapper,
        pair.swap_exact_out(
            token_in_address,
            token_out_address,
            amount_out,
            amount_in_max,
            AUTHWIT_NONCE,
        ),
    );
}
