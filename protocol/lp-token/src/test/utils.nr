use crate::SigalSwapLPToken;
use aztec::{
    protocol::address::AztecAddress,
    test::helpers::test_environment::TestEnvironment,
};

/// Deploys a fresh SigalSwapLPToken paired with a stand-in "pair" account.
/// Returns (env, lp_token_address, pair, outsider).
///
/// The stand-in `pair` is just a regular test account; from the LP Token's
/// perspective, msg_sender == stored pair is all that's checked on mint
/// paths, so a normal account as the pair is sufficient for auth tests.
pub(crate) unconstrained fn setup() -> (
    TestEnvironment,
    AztecAddress,
    AztecAddress,
    AztecAddress,
) {
    let mut env = TestEnvironment::new();
    let pair = env.create_contract_account();
    let outsider = env.create_contract_account();

    let lp_init = SigalSwapLPToken::interface().constructor(pair);
    let lp_address = env
        .deploy("@sigalswap_lp_token/SigalSwapLPToken")
        .with_public_initializer(pair, lp_init);

    (env, lp_address, pair, outsider)
}
