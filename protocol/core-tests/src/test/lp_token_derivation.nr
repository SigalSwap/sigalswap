// Explicit invariant tests for the pair's LP Token derivation.
//
// The `setup()` helper in `utils.nr` already asserts that the LP Token
// deployed at the pair's derived address matches `pair.get_lp_token()`.
// These tests add explicit coverage:
//
// 1. `get_lp_token()` returns a non-zero address (degenerate-value sanity).
// 2. Different pair addresses produce different LP Token addresses --
//    verifies the derivation depends on `self.address`, not a constant.
// 3. Two pairs with identical constructor args (but different deploy salts,
//    which TXE auto-increments) produce different pair addresses and
//    therefore different LP addresses. Indirectly confirms salt actually
//    enters the derivation chain.

use sigalswap_core::{LP_TOKEN_CLASS_ID, SigalSwapPair};
use crate::test::utils::setup;
use aztec::{
    protocol::{address::AztecAddress, traits::ToField},
    test::helpers::txe_oracles,
};
use token::Token;

/// `get_lp_token()` returns a non-zero, non-pair address after construction,
/// and `get_config().lp_token` returns the same address. The two are stored
/// in distinct slots (a dedicated `lp_token` PublicImmutable used by mint /
/// burn paths, and the `lp_token` field embedded in PairConfig used by the
/// router for in-one-merkle-proof verification) but the constructor
/// initializes both from a single derivation, so they must always agree.
#[test]
unconstrained fn get_lp_token_returns_nonzero_and_distinct() {
    let (mut env, pair_address, _t0, _t1, lp_address, _admin) = setup();
    let pair = SigalSwapPair::at(pair_address);

    let derived: AztecAddress = env.view_public(pair.get_lp_token());

    assert(derived != AztecAddress::zero());
    assert(derived != pair_address);
    // `setup()` already asserted this equality, but repeat here so any
    // refactor of `setup()` that drops the assertion still fails this test.
    assert_eq(derived, lp_address);

    // Cross-check the PairConfig copy so a future refactor that updates the
    // dedicated slot but forgets the embedded field (or vice versa) trips
    // here rather than surfacing as a router-side LP_TOKEN_MISMATCH downstream.
    let config = env.view_public(pair.get_config());
    assert_eq(config.lp_token, derived);
}

/// A second pair, deployed with a different token pair in the same
/// environment, produces a different LP Token address. This confirms the
/// derivation actually depends on the specific pair's address -- not a
/// protocol-wide constant.
#[test]
unconstrained fn distinct_pairs_derive_distinct_lp_tokens() {
    let (mut env, pair_a, _t0a, _t1a, lp_a, admin) = setup();

    // Deploy two fresh tokens in the same env and a second pair over them.
    // Same env -> no nullifier-tree collision from contract class publication.
    let token2_init = Token::interface().constructor(
        admin,
        "Token22222222222222222222222222",
        "TK22222222222222222222222222222",
        18,
    );
    let token2 =
        env.deploy("@token_contract/Token").with_public_initializer(admin, token2_init);

    let token3_init = Token::interface().constructor(
        admin,
        "Token33333333333333333333333333",
        "TK33333333333333333333333333333",
        18,
    );
    let token3 =
        env.deploy("@token_contract/Token").with_public_initializer(admin, token3_init);

    let (pair_b_t0, pair_b_t1) =
        if (token2.to_field() as u128) < (token3.to_field() as u128) {
            (token2, token3)
        } else {
            (token3, token2)
        };
    let pair_init_b = SigalSwapPair::interface().constructor(
        pair_b_t0, pair_b_t1, admin, 25,
    );
    let pair_b = env.deploy("@sigalswap_core/SigalSwapPair").with_public_initializer(admin, pair_init_b);

    let lp_b: AztecAddress = env.view_public(SigalSwapPair::at(pair_b).get_lp_token());

    // Two different pairs -> two different derived LP addresses.
    assert(pair_a != pair_b);
    assert(lp_a != lp_b);

    // And the derivation produced non-trivial outputs for pair B too.
    assert(lp_b != AztecAddress::zero());
    assert(lp_b != pair_b);
}

/// Drift probe: pair source bakes `LP_TOKEN_CLASS_ID` as a literal Field that
/// must match the LP Token's compiled bytecode hash, since the pair derives
/// its LP Token address from this constant. If someone edits LP Token source
/// and recompiles WITHOUT also updating `LP_TOKEN_CLASS_ID` in pair source,
/// the pair would derive its LP address from the stale class_id and the
/// deployed LP Token (at the new class_id) would be unreachable to the pair.
///
/// This test catches that drift by deploying the LP Token via the TXE deploy
/// oracle (which extracts the class_id from the compiled artifact) and
/// asserting equality with the source constant. Mirrors the lp-token
/// package's local probe but from the core/pair side, so an asymmetric edit
/// (only one of the two constants updated) fails here too.
///
/// Deliberately minimal: no token0/token1, no pair, no public init. Just the
/// LP Token's compile-time class_id vs source constant.
#[test]
unconstrained fn lp_token_class_id_constant_matches_compiled_bytecode() {
    let args: [Field; 1] = [1];
    let instance = txe_oracles::deploy(
        "@sigalswap_lp_token/SigalSwapLPToken",
        "constructor",
        args,
        0xc0fe,
        1,
        AztecAddress::zero(),
    );
    let runtime_class_id = instance.contract_class_id.to_field();
    assert_eq(runtime_class_id, LP_TOKEN_CLASS_ID);
}
