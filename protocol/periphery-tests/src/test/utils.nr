use sigalswap_periphery::SigalSwapRouter;
use abusive_pair::AbusivePair;
use aztec::{
    protocol::{address::AztecAddress, traits::ToField},
    test::helpers::{
        authwit::add_private_authwit_from_call, test_environment::TestEnvironment, txe_oracles,
    },
};
use mock_factory::MockFactory;
use sigalswap_core::SigalSwapPair;
use sigalswap_lp_token::SigalSwapLPToken;
use token::Token;

/// Authwit nonce used across all test operations.
pub(crate) global AUTHWIT_NONCE: Field = 1;

/// Deploy an LP Token at the pair's derived LP address. Uses
/// `txe_oracles::deploy` with secret=0 so salt=1, deployer=zero, and
/// keys=default match the pair's canonical derivation. The deploy oracle
/// runs the public initializer implicitly as part of instance creation.
unconstrained fn deploy_lp_token_for_pair(
    _env: TestEnvironment,
    _admin: AztecAddress,
    pair_address: AztecAddress,
) -> AztecAddress {
    let args: [Field; 1] = [pair_address.to_field()];
    let instance = txe_oracles::deploy(
        "@sigalswap_lp_token/SigalSwapLPToken",
        "constructor",
        args,
        0,
        1,
        AztecAddress::zero(),
    );
    instance.to_address()
}

/// Deploy a MockFactory. Pairs are registered via separate
/// `register_pair_in_mock_factory` calls so multi-hop setups can register
/// each hop's pair by its own (token0, token1) tuple.
pub(crate) unconstrained fn deploy_mock_factory(
    mut env: TestEnvironment,
    admin: AztecAddress,
) -> AztecAddress {
    let mock_factory_init = MockFactory::interface().constructor();
    env.deploy("@mock_factory/MockFactory").with_public_initializer(admin, mock_factory_init)
}

/// Pre-register `pair_address` in the mock factory under the full
/// `(token0, token1, fee_tier_bps, version)` tuple so the router's
/// PAIR_NOT_REGISTERED check passes. The fee_tier and version are read from the
/// pair's own `get_config` -- the same source the router reads when it queries
/// `get_pair_versioned_public` -- so the registration always matches the
/// router's query and the test exercises the full-tuple key (mirroring the real
/// factory). The mock defensively sorts the tokens, so callers don't need
/// canonical order.
pub(crate) unconstrained fn register_pair_in_mock_factory(
    mut env: TestEnvironment,
    admin: AztecAddress,
    mock_factory_address: AztecAddress,
    token0: AztecAddress,
    token1: AztecAddress,
    pair_address: AztecAddress,
) {
    let cfg = env.view_public(SigalSwapPair::at(pair_address).get_config());
    env.call_public(
        admin,
        MockFactory::at(mock_factory_address).set_registered_pair(
            token0,
            token1,
            cfg.fee_tier_bps,
            cfg.version,
            pair_address,
        ),
    );
}

/// Deploy a single-pair stack: 2 tokens, 1 LP token, 1 pair, 1 mock factory,
/// 1 router. The mock factory pre-registers `pair_address` so router-mediated
/// flows pass the PAIR_NOT_REGISTERED check.
/// Returns (env, router, pair, token0, token1, lp, admin).
pub(crate) unconstrained fn setup_single_pair() -> (
    TestEnvironment,
    AztecAddress,
    AztecAddress,
    AztecAddress,
    AztecAddress,
    AztecAddress,
    AztecAddress,
) {
    let mut env = TestEnvironment::new();
    let admin = env.create_contract_account();

    // Deploy two tokens, then sort their addresses for the pair's canonical-
    // ordering invariant.
    let token_a = deploy_token(env, admin, "TokenA0000000000000000000000000", "TKA0000000000000000000000000000");
    let token_b = deploy_token(env, admin, "TokenB1111111111111111111111111", "TKB1111111111111111111111111111");
    let (token0_address, token1_address) =
        if (token_a.to_field() as u128) < (token_b.to_field() as u128) {
            (token_a, token_b)
        } else {
            (token_b, token_a)
        };

    // Deploy pair. LP Token address is derived inside the pair's constructor;
    // we deploy the LP Token at that address.
    let fee_tier_bps: u32 = 25;
    let pair_init = SigalSwapPair::interface().constructor(
        token0_address, token1_address, admin, fee_tier_bps,
    );
    let pair_address = env.deploy("@sigalswap_core/SigalSwapPair").with_public_initializer(admin, pair_init);

    let lp_address = deploy_lp_token_for_pair(env, admin, pair_address);

    // Deploy mock factory and register the pair under its config.token0
    // (the sorted-smaller token).
    let factory_address = deploy_mock_factory(env, admin);
    register_pair_in_mock_factory(env, admin, factory_address, token0_address, token1_address, pair_address);

    // Deploy router pointing at the mock factory.
    let router_init = SigalSwapRouter::interface().constructor(factory_address);
    let router_address = env.deploy("@sigalswap_periphery/SigalSwapRouter").with_public_initializer(admin, router_init);

    (env, router_address, pair_address, token0_address, token1_address, lp_address, admin)
}

/// Deploy a two-pair stack for multi-hop testing: 3 tokens (A, B, C), 2 pairs (AB, BC), 1 router.
/// Returns (env, router, pair_ab, pair_bc, token_a, token_b, token_c, admin).
pub(crate) unconstrained fn setup_multi_hop() -> (
    TestEnvironment,
    AztecAddress,
    AztecAddress,
    AztecAddress,
    AztecAddress,
    AztecAddress,
    AztecAddress,
    AztecAddress,
) {
    let mut env = TestEnvironment::new();
    let admin = env.create_contract_account();

    let token_a = deploy_token(env, admin, "TokenA0000000000000000000000000", "TKA0000000000000000000000000000");
    let token_b = deploy_token(env, admin, "TokenB1111111111111111111111111", "TKB1111111111111111111111111111");
    let token_c = deploy_token(env, admin, "TokenC2222222222222222222222222", "TKC2222222222222222222222222222");

    let fee_tier_bps: u32 = 25;

    // Each pair must be deployed with its own tokens sorted (token0 < token1).
    // The two pair-orderings are computed independently -- a token that is
    // "smaller" inside one pair may be "larger" inside another.
    let (pair_ab_t0, pair_ab_t1) =
        if (token_a.to_field() as u128) < (token_b.to_field() as u128) {
            (token_a, token_b)
        } else {
            (token_b, token_a)
        };
    let (pair_bc_t0, pair_bc_t1) =
        if (token_b.to_field() as u128) < (token_c.to_field() as u128) {
            (token_b, token_c)
        } else {
            (token_c, token_b)
        };

    // Deploy pair A/B and its LP Token
    let pair_ab_init = SigalSwapPair::interface().constructor(
        pair_ab_t0, pair_ab_t1, admin, fee_tier_bps,
    );
    let pair_ab = env.deploy("@sigalswap_core/SigalSwapPair").with_public_initializer(admin, pair_ab_init);
    let _lp_ab = deploy_lp_token_for_pair(env, admin, pair_ab);

    // Deploy pair B/C and its LP Token
    let pair_bc_init = SigalSwapPair::interface().constructor(
        pair_bc_t0, pair_bc_t1, admin, fee_tier_bps,
    );
    let pair_bc = env.deploy("@sigalswap_core/SigalSwapPair").with_public_initializer(admin, pair_bc_init);
    let _lp_bc = deploy_lp_token_for_pair(env, admin, pair_bc);

    // Deploy mock factory and register each pair under its config.token0
    // (the sorted-smaller token in each pair's ordering).
    let factory_address = deploy_mock_factory(env, admin);
    register_pair_in_mock_factory(env, admin, factory_address, pair_ab_t0, pair_ab_t1, pair_ab);
    register_pair_in_mock_factory(env, admin, factory_address, pair_bc_t0, pair_bc_t1, pair_bc);

    // Deploy router pointing at the mock factory.
    let router_init = SigalSwapRouter::interface().constructor(factory_address);
    let router_address = env.deploy("@sigalswap_periphery/SigalSwapRouter").with_public_initializer(admin, router_init);

    (env, router_address, pair_ab, pair_bc, token_a, token_b, token_c, admin)
}

unconstrained fn deploy_token(
    mut env: TestEnvironment,
    admin: AztecAddress,
    name: str<31>,
    symbol: str<31>,
) -> AztecAddress {
    let init = Token::interface().constructor(admin, name, symbol, 18);
    env.deploy("@token_contract/Token").with_public_initializer(admin, init)
}

/// Add liquidity to a pair via the pair contract directly (not through router).
pub(crate) unconstrained fn add_liquidity(
    env: TestEnvironment,
    pair_address: AztecAddress,
    token0_address: AztecAddress,
    token1_address: AztecAddress,
    minter: AztecAddress,
    provider: AztecAddress,
    amount0_max: u128,
    amount1_max: u128,
) {
    let token0 = Token::at(token0_address);
    let token1 = Token::at(token1_address);
    let pair = SigalSwapPair::at(pair_address);

    env.call_private(minter, token0.mint_to_private(provider, amount0_max));
    env.call_private(minter, token1.mint_to_private(provider, amount1_max));

    let transfer0_call = token0.transfer_to_public_and_prepare_private_balance_increase(
        provider, pair_address, amount0_max, AUTHWIT_NONCE,
    );
    add_private_authwit_from_call(env, provider, pair_address, transfer0_call);

    let transfer1_call = token1.transfer_to_public_and_prepare_private_balance_increase(
        provider, pair_address, amount1_max, AUTHWIT_NONCE,
    );
    add_private_authwit_from_call(env, provider, pair_address, transfer1_call);

    env.call_private(
        provider,
        pair.add_liquidity(amount0_max, amount1_max, 0, 0, AUTHWIT_NONCE),
    );
}

/// Deploy a single-pair stack with a real pair that is NOT registered in
/// the mock factory. Canaries that exercise the router's
/// PAIR_NOT_REGISTERED guard use this to ensure the factory check fires
/// rather than a deeper assertion. Otherwise mirrors `setup_single_pair`.
/// Returns (env, router, pair, token0, token1, lp, admin).
pub(crate) unconstrained fn setup_unregistered_pair() -> (
    TestEnvironment,
    AztecAddress,
    AztecAddress,
    AztecAddress,
    AztecAddress,
    AztecAddress,
    AztecAddress,
) {
    let mut env = TestEnvironment::new();
    let admin = env.create_contract_account();

    let token_a = deploy_token(env, admin, "TokenA0000000000000000000000000", "TKA0000000000000000000000000000");
    let token_b = deploy_token(env, admin, "TokenB1111111111111111111111111", "TKB1111111111111111111111111111");
    let (token0_address, token1_address) =
        if (token_a.to_field() as u128) < (token_b.to_field() as u128) {
            (token_a, token_b)
        } else {
            (token_b, token_a)
        };

    let fee_tier_bps: u32 = 25;
    let pair_init = SigalSwapPair::interface().constructor(
        token0_address, token1_address, admin, fee_tier_bps,
    );
    let pair_address = env.deploy("@sigalswap_core/SigalSwapPair").with_public_initializer(admin, pair_init);

    let lp_address = deploy_lp_token_for_pair(env, admin, pair_address);

    // Deploy mock factory but DO NOT register the pair.
    let factory_address = deploy_mock_factory(env, admin);

    let router_init = SigalSwapRouter::interface().constructor(factory_address);
    let router_address = env.deploy("@sigalswap_periphery/SigalSwapRouter").with_public_initializer(admin, router_init);

    (env, router_address, pair_address, token0_address, token1_address, lp_address, admin)
}

/// Deploy a stack tailored to the swap_payment_callback abuse canaries:
/// 2 tokens, the AbusivePair fixture (no real pair), MockFactory pre-loaded
/// to "register" the abusive pair so the router's PAIR_NOT_REGISTERED check
/// passes, and the router. AbusivePair's `swap_exact_out_public` selector
/// matches the real pair's so the router's typed call dispatches to it.
/// AbusivePair does NOT implement `get_config()`, so router entries that
/// query it before the factory check (the swap entries) will revert at the
/// `get_config` step rather than reaching the factory check; the existing
/// callback canaries that exercise `swap_payment_callback` directly bypass
/// this entirely. No pool seeding is needed -- abuse fires in the callback
/// before any swap math runs.
pub(crate) unconstrained fn setup_abusive_pair() -> (
    TestEnvironment,
    AztecAddress, // router
    AztecAddress, // abusive pair (deployed at this address)
    AztecAddress, // token0
    AztecAddress, // token1
    AztecAddress, // admin
) {
    let mut env = TestEnvironment::new();
    let admin = env.create_contract_account();

    let token0_address = deploy_token(env, admin, "TokenA0000000000000000000000000", "TKA0000000000000000000000000000");
    let token1_address = deploy_token(env, admin, "TokenB1111111111111111111111111", "TKB1111111111111111111111111111");

    let abusive_init = AbusivePair::interface().constructor();
    let abusive_pair_address =
        env.deploy("@abusive_pair/AbusivePair").with_public_initializer(admin, abusive_init);

    // Wire the abusive pair to claim it trades (token0, token1). The
    // router's PATH_TOKEN_MISMATCH and PAIR_NOT_REGISTERED checks both
    // read the pair's reported tokens; the registry below must register
    // under the same tuple so both checks pass and execution reaches
    // `swap_exact_out_public` where the callback abuse modes fire.
    env.call_public(
        admin,
        AbusivePair::at(abusive_pair_address).set_tokens(token0_address, token1_address),
    );

    let factory_address = deploy_mock_factory(env, admin);
    register_pair_in_mock_factory(
        env, admin, factory_address, token0_address, token1_address, abusive_pair_address,
    );

    let router_init = SigalSwapRouter::interface().constructor(factory_address);
    let router_address =
        env.deploy("@sigalswap_periphery/SigalSwapRouter").with_public_initializer(admin, router_init);

    (env, router_address, abusive_pair_address, token0_address, token1_address, admin)
}
