// Coverage for `register_pair`'s 14 distinct revert paths.
//
// Of the 14:
//   - 10 unique messages are reachable in TXE and tested below with exact
//     `should_fail_with` assertions (ZERO_ADDRESS appears at three arg
//     positions and is tested at each, so 12 test functions total). This
//     count includes VERSION_NOT_ADVANCING, exercised via a salt=2 "cousin
//     pair" -- see test_register_cousin_pair_same_version_reverts.
//   - 4 are not directly testable and explicitly documented:
//
//       * REENTRANT_REGISTER_PAIR -- defends against a future blessed pair
//         bytecode whose `set_protocol_fee` re-enters the factory during
//         `register_pair`'s outbound call. Today's pair has no outbound
//         call from `set_protocol_fee` so the lock is unreachable. Testing
//         it organically would require a `reentrant_pair` fixture contract
//         that calls `factory.register_pair` from `set_protocol_fee`, which
//         creates a build-graph cycle (the fixture depends on the factory
//         interface; factory's tests would depend on the fixture). The lock
//         body is small enough to verify by reading.
//
//       * LP_TOKEN_WRONG_CLASS -- defends against Aztec's contract-instance
//         class_id update primitive being used to swap an LP Token's bytecode
//         out from under the factory. Reaching the precondition organically
//         would require either invoking that primitive (no test infra exposes
//         it cleanly) or engineering an address collision (computationally
//         infeasible).
//
//       * IDENTICAL_TOKENS -- the pair constructor asserts `token0 != token1`,
//         so a pair with identical tokens cannot be deployed via SigalSwap's
//         blessed bytecode. The factory check is defense-in-depth against a
//         future blessed bytecode that drops the pair-side constraint.
//
//       * PAIR_EXISTS -- by design unreachable in well-formed governance state:
//         the strict-greater `VERSION_NOT_ADVANCING` check (in factory `register_pair`) fires
//         first on any same-version re-registration at the same base, and
//         `pair_class_version` is monotonic across `set_pair_class_id`. Kept
//         for defense in depth.

use sigalswap_factory::SigalSwapFactory;
use crate::test::utils::{deploy_lp_token, deploy_mock_pair_v2, deploy_pair, deploy_pair_with_salt, setup, setup_with_pair, CANONICAL_PAIR_SALT};
use aztec::{
    protocol::{address::AztecAddress, traits::{FromField, ToField}},
    test::helpers::txe_oracles,
};

// ============================================
// Pre-address-check branches (no real pair needed)
// ============================================

/// REGISTRATION_PAUSED: admin pauses registration; subsequent register_pair
/// reverts before doing any work, regardless of arg validity.
#[test(should_fail_with = "REGISTRATION_PAUSED")]
unconstrained fn test_register_pair_paused_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    env.call_public(admin, factory.pause_registration());

    let dummy = AztecAddress::from_field(0xabc);
    let t0 = AztecAddress::from_field(0x100);
    let t1 = AztecAddress::from_field(0x200);
    env.call_public(
        admin,
        factory.register_pair(dummy, t0, t1, 25, CANONICAL_PAIR_SALT),
    );
}

/// VERSION_NOT_ADVANCING: a "cousin" pair -- an alternate canonical instance
/// of the blessed bytecode at the same (token0, token1, fee_tier) base but a
/// non-canonical salt (salt = 2) -- lands at a different address, so it clears
/// PAIR_ADDRESS_ALREADY_REGISTERED and PAIR_NOT_CANONICAL. Registering it at
/// the base's current (already-latest) version trips the strict-greater guard.
#[test(should_fail_with = "VERSION_NOT_ADVANCING")]
unconstrained fn test_register_cousin_pair_same_version_reverts() {
    let (mut env, factory_address, _pair, token0, token1, admin) = setup_with_pair();

    // Alternate canonical instance at salt = 2 (same blessed class, same base,
    // different address).
    let (cousin, _cousin_class) =
        deploy_pair_with_salt(&mut env, admin, token0, token1, factory_address, 25, 2);
    // Its LP Token must exist at the cousin's derived address so register_pair
    // gets past the LP-deployment check and reaches the version guard.
    let _cousin_lp = deploy_lp_token(&mut env, admin, cousin);

    let factory = SigalSwapFactory::at(factory_address);
    // pair_salt = 2 so the factory reconstructs the cousin's canonical address.
    env.call_public(
        admin,
        factory.register_pair(cousin, token0, token1, 25, 2),
    );
}

/// ZERO_ADDRESS for pair_address.
#[test(should_fail_with = "ZERO_ADDRESS")]
unconstrained fn test_register_pair_zero_pair_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);

    let t0 = AztecAddress::from_field(0x100);
    let t1 = AztecAddress::from_field(0x200);
    env.call_public(
        admin,
        factory.register_pair(AztecAddress::zero(), t0, t1, 25, CANONICAL_PAIR_SALT),
    );
}

/// ZERO_ADDRESS for token0.
#[test(should_fail_with = "ZERO_ADDRESS")]
unconstrained fn test_register_pair_zero_token0_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);

    let dummy = AztecAddress::from_field(0xabc);
    let t1 = AztecAddress::from_field(0x200);
    env.call_public(
        admin,
        factory.register_pair(dummy, AztecAddress::zero(), t1, 25, CANONICAL_PAIR_SALT),
    );
}

/// ZERO_ADDRESS for token1.
#[test(should_fail_with = "ZERO_ADDRESS")]
unconstrained fn test_register_pair_zero_token1_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);

    let dummy = AztecAddress::from_field(0xabc);
    let t0 = AztecAddress::from_field(0x100);
    env.call_public(
        admin,
        factory.register_pair(dummy, t0, AztecAddress::zero(), 25, CANONICAL_PAIR_SALT),
    );
}

/// PAIR_CLASS_ID_NOT_SET: register_pair before admin has called
/// set_pair_class_id. The address-match step needs an expected class to
/// reconstruct against; without it, the check refuses to proceed.
#[test(should_fail_with = "PAIR_CLASS_ID_NOT_SET")]
unconstrained fn test_register_pair_no_class_id_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);

    let dummy = AztecAddress::from_field(0xabc);
    let t0 = AztecAddress::from_field(0x100);
    let t1 = AztecAddress::from_field(0x200);
    env.call_public(
        admin,
        factory.register_pair(dummy, t0, t1, 25, CANONICAL_PAIR_SALT),
    );
}

// ============================================
// Post-address-check branches (need a real canonical pair)
// ============================================

/// PAIR_NOT_CANONICAL: caller-supplied pair_address doesn't equal the
/// factory's reconstruction from declared inputs. Triggered by passing a
/// pair_salt that doesn't match the actual deploy salt.
#[test(should_fail_with = "PAIR_NOT_CANONICAL")]
unconstrained fn test_register_pair_non_canonical_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);

    // Deploy a fresh pair with the canonical salt, then attempt to register
    // it under a mutated salt so the factory's address reconstruction
    // diverges from pair_address. (Cannot reuse a setup_with_pair pair
    // because that pair_address would already be in the `registered` map,
    // which trips the address-level one-shot guard before reaching the
    // canonical-address check.)
    let t0 = AztecAddress::from_field(0x100);
    let t1 = AztecAddress::from_field(0x200);
    let (pair_address, class_id) = deploy_pair(&mut env, admin, t0, t1, factory_address, 25);
    let _lp = deploy_lp_token(&mut env, admin, pair_address);
    env.call_public(admin, factory.set_pair_class_id(class_id, 1));

    env.call_public(
        admin,
        factory.register_pair(pair_address, t0, t1, 25, CANONICAL_PAIR_SALT + 1),
    );
}

/// LP_TOKEN_NOT_DEPLOYED: pair is canonically deployed but its derived LP
/// Token slot is empty. Address-match passes; the is_deployed check fails.
#[test(should_fail_with = "LP_TOKEN_NOT_DEPLOYED")]
unconstrained fn test_register_pair_no_lp_token_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);

    let t0 = AztecAddress::from_field(0x100);
    let t1 = AztecAddress::from_field(0x200);
    let (pair_address, class_id) = deploy_pair(&mut env, admin, t0, t1, factory_address, 25);

    // Bless the class so PAIR_CLASS_ID_NOT_SET / PAIR_NOT_CANONICAL pass.
    env.call_public(admin, factory.set_pair_class_id(class_id, 1));

    // Skip deploy_lp_token -- the factory should reject because the pair's
    // derived LP Token address has no contract.
    env.call_public(
        admin,
        factory.register_pair(pair_address, t0, t1, 25, CANONICAL_PAIR_SALT),
    );
}

/// INVALID_FEE_TIER: pair deployed with a fee_tier that admin never added
/// to the whitelist. The factory's allowed_fee_tiers map returns false.
#[test(should_fail_with = "INVALID_FEE_TIER")]
unconstrained fn test_register_pair_invalid_fee_tier_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);

    let t0 = AztecAddress::from_field(0x100);
    let t1 = AztecAddress::from_field(0x200);
    let bogus_tier: u32 = 17; // not 5/25/100 (the auto-whitelisted tiers)

    let (pair_address, class_id) = deploy_pair(&mut env, admin, t0, t1, factory_address, bogus_tier);
    let _lp = deploy_lp_token(&mut env, admin, pair_address);
    env.call_public(admin, factory.set_pair_class_id(class_id, 1));

    env.call_public(
        admin,
        factory.register_pair(pair_address, t0, t1, bogus_tier, CANONICAL_PAIR_SALT),
    );
}

/// TOKENS_NOT_SORTED: pair deployed with token0 > token1 (sort reversed).
/// Factory rejects to enforce the invariant that pair_key derivation is
/// canonical for each unordered pair.
#[test(should_fail_with = "TOKENS_NOT_SORTED")]
unconstrained fn test_register_pair_tokens_not_sorted_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);

    // Reverse-sorted: 0x200 > 0x100.
    let t0 = AztecAddress::from_field(0x200);
    let t1 = AztecAddress::from_field(0x100);

    let (pair_address, class_id) = deploy_pair(&mut env, admin, t0, t1, factory_address, 25);
    let _lp = deploy_lp_token(&mut env, admin, pair_address);
    env.call_public(admin, factory.set_pair_class_id(class_id, 1));

    env.call_public(
        admin,
        factory.register_pair(pair_address, t0, t1, 25, CANONICAL_PAIR_SALT),
    );
}

/// VERSION_MISMATCH: admin blesses MockPairV2's class_id at version 1, but
/// MockPairV2's source pins VERSION = 2. The factory's cross-check between
/// pair.get_version() and pair_class_version reports the mismatch.
#[test(should_fail_with = "VERSION_MISMATCH")]
unconstrained fn test_register_pair_version_mismatch_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);

    let t0 = AztecAddress::from_field(0x100);
    let t1 = AztecAddress::from_field(0x200);
    let (pair_address, class_id) = deploy_mock_pair_v2(&mut env, admin, t0, t1, factory_address, 25);
    let _lp = deploy_lp_token(&mut env, admin, pair_address);

    // Bless the v2-bytecode class_id at version 1 -- a deliberate operator
    // error to exercise the cross-check.
    env.call_public(admin, factory.set_pair_class_id(class_id, 1));

    env.call_public(
        admin,
        factory.register_pair(pair_address, t0, t1, 25, CANONICAL_PAIR_SALT),
    );
}

/// PAIR_ADDRESS_ALREADY_REGISTERED: registration is one-shot per pair address.
/// After admin clears the pair (zeroing routing pointers but preserving the
/// `registered` flag), any attempt to re-register the same contract address
/// reverts at entry. This is the address-level permanence that prevents a
/// cleared pair from being permissionlessly un-cleared via re-registration.
#[test(should_fail_with = "PAIR_ADDRESS_ALREADY_REGISTERED")]
unconstrained fn test_register_pair_clear_then_re_register_reverts() {
    let (mut env, factory_address, pair_address, t0, t1, admin) = setup_with_pair();
    let factory = SigalSwapFactory::at(factory_address);

    // Fully clear the pair (rollback target = 0, so the base ends with no
    // routable pair).
    env.call_public(admin, factory.queue_clear_pair_slot(pair_address, t0, t1, 25, 0));
    crate::test::utils::advance_past_timelock(&mut env);
    env.call_public(admin, factory.execute_clear_pair_slot(pair_address, t0, t1, 25, 0));

    // Without the address-level guard, this would succeed: pairs[pair_key] == 0
    // (just cleared), latest_version[base] == 0 (just cleared), pair_class_version
    // is still 1, so expected_version (1) > current_latest (0) passes, and every
    // address/class/LP-token check still matches the original pair. The
    // `registered[pair_address] == true` assert at the top of register_pair is
    // what closes this hole.
    env.call_public(
        admin,
        factory.register_pair(pair_address, t0, t1, 25, CANONICAL_PAIR_SALT),
    );
}
