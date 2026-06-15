use sigalswap_factory::SigalSwapFactory;
use aztec::{
    protocol::{
        address::AztecAddress,
        traits::{FromField, ToField},
    },
    test::helpers::{test_environment::TestEnvironment, txe_oracles},
};
use mock_pair_v2::MockPairV2;
use sigalswap_core::SigalSwapPair;
use sigalswap_lp_token::SigalSwapLPToken;

/// Canonical pair salt used by factory tests. TXE hardcodes `salt: Fr.ONE`
/// for all deploys via its deploy oracle; this constant is passed to
/// `register_pair` so the factory's address-match calculation agrees with
/// the TXE-deployed pair's actual address.
pub(crate) global CANONICAL_PAIR_SALT: Field = 1;

/// Deploy the factory with an admin account.
/// Returns (env, factory_address, admin).
pub(crate) unconstrained fn setup() -> (TestEnvironment, AztecAddress, AztecAddress) {
    let mut env = TestEnvironment::new();
    let admin = env.create_contract_account();

    let factory_init = SigalSwapFactory::interface().constructor(admin);
    let factory_address =
        env.deploy("@sigalswap_factory/SigalSwapFactory").with_public_initializer(admin, factory_init);

    (env, factory_address, admin)
}


/// Deploy a SigalSwapPair using the canonical-inputs path TXE provides via
/// `txe_oracles::deploy(secret=0)`. This produces an instance whose address
/// uses `PublicKeys::default()` and salt=Fr.ONE, matching the factory's
/// address-match computation in `register_pair`. The public initializer
/// (`constructor`) is then run via `env.call_public` so storage is
/// initialized. Returns (pair_address, class_id).
pub(crate) unconstrained fn deploy_pair(
    env: &mut TestEnvironment,
    admin: AztecAddress,
    token0: AztecAddress,
    token1: AztecAddress,
    factory: AztecAddress,
    fee_tier_bps: u32,
) -> (AztecAddress, Field) {
    let args: [Field; 4] = [
        token0.to_field(),
        token1.to_field(),
        factory.to_field(),
        fee_tier_bps as Field,
    ];
    let instance = txe_oracles::deploy(
        "@sigalswap_core/SigalSwapPair",
        "constructor",
        args,
        0,
        1,
        AztecAddress::zero(),
    );
    let pair_address = instance.to_address();
    let class_id = instance.contract_class_id.to_field();

    // Run the public initializer so storage is set up (TXE deploy_oracle
    // registers the instance but does not execute the constructor body).
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).constructor(token0, token1, factory, fee_tier_bps),
    );

    (pair_address, class_id)
}

/// Deploy a SigalSwapPair at a caller-chosen `salt` (the canonical helper
/// uses salt = 1). Used to stage a "cousin" pair: an alternate canonical
/// instance of the blessed bytecode at the same (token0, token1, fee_tier)
/// base but a different address, so the registry's same-base/same-version
/// guard can be exercised. Mirrors `deploy_pair` exactly except for the salt.
pub(crate) unconstrained fn deploy_pair_with_salt(
    env: &mut TestEnvironment,
    admin: AztecAddress,
    token0: AztecAddress,
    token1: AztecAddress,
    factory: AztecAddress,
    fee_tier_bps: u32,
    salt: Field,
) -> (AztecAddress, Field) {
    let args: [Field; 4] = [
        token0.to_field(),
        token1.to_field(),
        factory.to_field(),
        fee_tier_bps as Field,
    ];
    let instance = txe_oracles::deploy(
        "@sigalswap_core/SigalSwapPair",
        "constructor",
        args,
        0,
        salt,
        AztecAddress::zero(),
    );
    let pair_address = instance.to_address();
    let class_id = instance.contract_class_id.to_field();

    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).constructor(token0, token1, factory, fee_tier_bps),
    );

    (pair_address, class_id)
}

/// Deploy the LP Token at the address the pair derived for itself. Uses
/// `txe_oracles::deploy` with secret=0 so salt=1 and keys=default align with
/// the pair's derivation constants (`LP_TOKEN_SALT = 1`). Then runs the
/// public constructor so storage is initialized.
pub(crate) unconstrained fn deploy_lp_token(
    env: &mut TestEnvironment,
    admin: AztecAddress,
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
    let lp_address = instance.to_address();
    env.call_public(
        admin,
        SigalSwapLPToken::at(lp_address).constructor(pair_address),
    );
    lp_address
}

/// Full registry setup: deploy factory, deploy a pair via canonical inputs,
/// deploy the pair's LP Token at its derived address, set class ID, register.
/// Returns (env, factory_address, pair_address, token0, token1, admin).
pub(crate) unconstrained fn setup_with_pair() -> (
    TestEnvironment,
    AztecAddress,
    AztecAddress,
    AztecAddress,
    AztecAddress,
    AztecAddress,
) {
    let (mut env, factory_address, admin) = setup();

    // Fixed token addresses suffice for registry tests; no need for real
    // Token contracts (the factory only uses the addresses as keys).
    let token0 = AztecAddress::from_field(100);
    let token1 = AztecAddress::from_field(200);
    let fee_tier_bps: u32 = 25;

    let (pair_address, class_id) = deploy_pair(
        &mut env, admin, token0, token1, factory_address, fee_tier_bps,
    );

    // Deploy the LP Token at the pair's derived LP address. `register_pair`'s
    // `is_deployed` check will find this.
    let _lp_address = deploy_lp_token(&mut env, admin, pair_address);

    // Bless the pair's class_id at version 1 (pair source pins VERSION = 1).
    let factory = SigalSwapFactory::at(factory_address);
    env.call_public(admin, factory.set_pair_class_id(class_id, 1));

    // Register the pair with canonical pair_salt.
    env.call_public(
        admin,
        factory.register_pair(pair_address, token0, token1, fee_tier_bps, CANONICAL_PAIR_SALT),
    );

    (env, factory_address, pair_address, token0, token1, admin)
}

/// Deploy a MockPairV2 test fixture (version 2 bytecode) using the same
/// canonical-input pattern as `deploy_pair`. Returns (pair_address, class_id).
pub(crate) unconstrained fn deploy_mock_pair_v2(
    env: &mut TestEnvironment,
    admin: AztecAddress,
    token0: AztecAddress,
    token1: AztecAddress,
    factory: AztecAddress,
    fee_tier_bps: u32,
) -> (AztecAddress, Field) {
    let args: [Field; 4] = [
        token0.to_field(),
        token1.to_field(),
        factory.to_field(),
        fee_tier_bps as Field,
    ];
    let instance = txe_oracles::deploy(
        "@mock_pair_v2/MockPairV2",
        "constructor",
        args,
        0,
        1,
        AztecAddress::zero(),
    );
    let pair_address = instance.to_address();
    let class_id = instance.contract_class_id.to_field();

    env.call_public(
        admin,
        MockPairV2::at(pair_address).constructor(token0, token1, factory, fee_tier_bps),
    );

    (pair_address, class_id)
}

/// Advance blocks + timestamp past the 48-hour timelock delay so a queued
/// governance action becomes executable. Convenience wrapper used across
/// upgrade-path tests.
pub(crate) unconstrained fn advance_past_timelock(_env: &mut TestEnvironment) {
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(172801);
}
