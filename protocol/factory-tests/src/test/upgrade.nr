// Upgrade-path tests for the factory's pair versioning system. Exercises
// the v1 -> v2 lifecycle using the MockPairV2 test fixture (VERSION = 2)
// alongside the canonical SigalSwapPair (VERSION = 1) to verify that
// version progression, in-place upgrades, rollback, and multi-base
// isolation all behave correctly.
//
// Fixture details: see /protocol/test-contracts/mock-pair-v2/src/main.nr.
// The mock pins VERSION = 2 and implements exactly the surface area
// `register_pair` touches (constructor, get_version, set_protocol_fee).

use sigalswap_factory::SigalSwapFactory;
use crate::test::utils::{
    advance_past_timelock, deploy_lp_token, deploy_mock_pair_v2, deploy_pair, setup,
    setup_with_pair, CANONICAL_PAIR_SALT,
};
use aztec::{
    protocol::{address::AztecAddress, traits::{FromField, ToField}},
    test::helpers::txe_oracles,
};
use sigalswap_core::SigalSwapPair;

// ============================================
// Fixture smoke test
// ============================================

/// MockPairV2 deploys cleanly via the canonical-inputs path and reports
/// VERSION = 2. If this fails, the upgrade tests below are pointless.
#[test]
unconstrained fn test_mock_pair_v2_smoke() {
    let (mut env, _factory_address, admin) = setup();
    let factory_address = AztecAddress::from_field(0xfff);
    let t0 = AztecAddress::from_field(0x100);
    let t1 = AztecAddress::from_field(0x200);

    let (pair_address, _class_id) =
        deploy_mock_pair_v2(&mut env, admin, t0, t1, factory_address, 25);
    let actual_version = env.view_public(
        SigalSwapPair::at(pair_address).get_version(),
    );
    assert_eq(actual_version, 2);
}

// ============================================
// Happy path: v2 on a fresh base
// ============================================

/// Bless v2 first (no v1 ever registered), deploy a MockPairV2 instance, and
/// register it at a fresh base. The base ends up with latest_version = 2.
#[test]
unconstrained fn test_register_v2_at_fresh_base() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);

    let t0 = AztecAddress::from_field(0x100);
    let t1 = AztecAddress::from_field(0x200);
    let (pair_address, class_id) =
        deploy_mock_pair_v2(&mut env, admin, t0, t1, factory_address, 25);
    let _lp = deploy_lp_token(&mut env, admin, pair_address);

    // First-call set_pair_class_id is immediate (no timelock). Bless at v2.
    env.call_public(admin, factory.set_pair_class_id(class_id, 2));
    env.call_public(
        admin,
        factory.register_pair(pair_address, t0, t1, 25, CANONICAL_PAIR_SALT),
    );

    // Latest version at the base should be 2.
    let resolved = env.execute_utility(factory.get_pair(t0, t1, 25));
    assert_eq(resolved, pair_address);
    let latest_v = env.execute_utility(factory.get_latest_version(t0, t1, 25));
    assert_eq(latest_v, 2);
}

// ============================================
// Happy path: in-place upgrade at an existing base
// ============================================

/// Register a v1 pair, then bless v2, register a v2 pair at the same base.
/// Latest moves from 1 to 2; v1 stays in the historical pair_key slot.
#[test]
unconstrained fn test_inplace_upgrade_v1_to_v2() {
    let (mut env, factory_address, v1_pair, t0, t1, admin) = setup_with_pair();
    let factory = SigalSwapFactory::at(factory_address);

    // Bless v2. set_pair_class_id requires a timelock for subsequent calls
    // (first call was setup_with_pair's immediate-blessing of v1).
    let (v2_pair, v2_class_id) =
        deploy_mock_pair_v2(&mut env, admin, t0, t1, factory_address, 25);
    let _lp_v2 = deploy_lp_token(&mut env, admin, v2_pair);

    env.call_public(admin, factory.queue_set_pair_class_id(v2_class_id, 2));
    advance_past_timelock(&mut env);
    env.call_public(admin, factory.set_pair_class_id(v2_class_id, 2));

    env.call_public(
        admin,
        factory.register_pair(v2_pair, t0, t1, 25, CANONICAL_PAIR_SALT),
    );

    // Latest now points to v2.
    assert_eq(env.execute_utility(factory.get_pair(t0, t1, 25)), v2_pair);
    assert_eq(env.execute_utility(factory.get_latest_version(t0, t1, 25)), 2);

    // Historical lookup still resolves v1 at version 1.
    assert_eq(env.execute_utility(factory.get_pair_versioned(t0, t1, 25, 1)), v1_pair);
    assert_eq(env.execute_utility(factory.get_pair_versioned(t0, t1, 25, 2)), v2_pair);

    // base_seen invariant: an in-place upgrade reuses the existing
    // base_by_index slot rather than appending. Without the sticky flag,
    // re-registering at the same base would double-count the base in
    // the latest-only enumeration.
    assert_eq(env.execute_utility(factory.get_indexed_base_count()), 1);
}

// ============================================
// Post-upgrade guards
// ============================================

/// After upgrading to v2, attempting to re-register the same v2 pair at the
/// same base reverts. The address-level one-shot guard
/// (`PAIR_ADDRESS_ALREADY_REGISTERED`) fires on the second attempt, blocking
/// re-registration of any contract that has already been registered through
/// this factory.
#[test(should_fail_with = "PAIR_ADDRESS_ALREADY_REGISTERED")]
unconstrained fn test_post_upgrade_re_register_v2_reverts() {
    let (mut env, factory_address, _v1_pair, t0, t1, admin) = setup_with_pair();
    let factory = SigalSwapFactory::at(factory_address);

    let (v2_pair, v2_class_id) =
        deploy_mock_pair_v2(&mut env, admin, t0, t1, factory_address, 25);
    let _lp_v2 = deploy_lp_token(&mut env, admin, v2_pair);

    env.call_public(admin, factory.queue_set_pair_class_id(v2_class_id, 2));
    advance_past_timelock(&mut env);
    env.call_public(admin, factory.set_pair_class_id(v2_class_id, 2));

    env.call_public(
        admin,
        factory.register_pair(v2_pair, t0, t1, 25, CANONICAL_PAIR_SALT),
    );

    // Second register at the same v2 address -- the address-level one-shot
    // guard fires before any other check.
    env.call_public(
        admin,
        factory.register_pair(v2_pair, t0, t1, 25, CANONICAL_PAIR_SALT),
    );
}

// ============================================
// Rollback via clear_pair_slot
// ============================================

/// Upgrade v1 -> v2 at a base, then queue + execute a clear_pair_slot that
/// rolls back to v1 (new_latest_version = 1). The v2 pair_key slot is
/// emptied and latest_pair points back to v1.
#[test]
unconstrained fn test_rollback_v2_to_v1_via_clear_slot() {
    let (mut env, factory_address, v1_pair, t0, t1, admin) = setup_with_pair();
    let factory = SigalSwapFactory::at(factory_address);

    let (v2_pair, v2_class_id) =
        deploy_mock_pair_v2(&mut env, admin, t0, t1, factory_address, 25);
    let _lp_v2 = deploy_lp_token(&mut env, admin, v2_pair);
    env.call_public(admin, factory.queue_set_pair_class_id(v2_class_id, 2));
    advance_past_timelock(&mut env);
    env.call_public(admin, factory.set_pair_class_id(v2_class_id, 2));
    env.call_public(
        admin,
        factory.register_pair(v2_pair, t0, t1, 25, CANONICAL_PAIR_SALT),
    );
    assert_eq(env.execute_utility(factory.get_pair(t0, t1, 25)), v2_pair);

    // Queue + advance + execute clear_pair_slot to roll back to v1.
    env.call_public(admin, factory.queue_clear_pair_slot(v2_pair, t0, t1, 25, 1));
    advance_past_timelock(&mut env);
    env.call_public(admin, factory.execute_clear_pair_slot(v2_pair, t0, t1, 25, 1));

    // Latest now points back at v1; v2 slot is cleared.
    assert_eq(env.execute_utility(factory.get_pair(t0, t1, 25)), v1_pair);
    assert_eq(env.execute_utility(factory.get_latest_version(t0, t1, 25)), 1);
    assert_eq(env.execute_utility(factory.get_pair_versioned(t0, t1, 25, 2)), AztecAddress::zero());
    assert_eq(env.execute_utility(factory.get_pair_versioned(t0, t1, 25, 1)), v1_pair);
}

// ============================================
// Multi-base isolation post-upgrade
// ============================================

/// Bless v2; register v1 at base A and v2 at base B. The two bases stay
/// independent: each base's latest_version reflects only its own history.
/// Specifically, registering v2 at base B does NOT touch base A, even
/// though both registrations happened after v2 was blessed globally.
#[test]
unconstrained fn test_multi_base_isolation_after_upgrade() {
    let (mut env, factory_address, base_a_v1, ta0, ta1, admin) = setup_with_pair();
    let factory = SigalSwapFactory::at(factory_address);

    // Bless v2 globally.
    let tb0 = AztecAddress::from_field(0x300);
    let tb1 = AztecAddress::from_field(0x400);
    let (base_b_v2, v2_class_id) =
        deploy_mock_pair_v2(&mut env, admin, tb0, tb1, factory_address, 25);
    let _lp_b = deploy_lp_token(&mut env, admin, base_b_v2);

    env.call_public(admin, factory.queue_set_pair_class_id(v2_class_id, 2));
    advance_past_timelock(&mut env);
    env.call_public(admin, factory.set_pair_class_id(v2_class_id, 2));

    // Register v2 at base B only. Base A retains v1 latest.
    env.call_public(
        admin,
        factory.register_pair(base_b_v2, tb0, tb1, 25, CANONICAL_PAIR_SALT),
    );

    assert_eq(env.execute_utility(factory.get_pair(ta0, ta1, 25)), base_a_v1);
    assert_eq(env.execute_utility(factory.get_latest_version(ta0, ta1, 25)), 1);
    assert_eq(env.execute_utility(factory.get_pair(tb0, tb1, 25)), base_b_v2);
    assert_eq(env.execute_utility(factory.get_latest_version(tb0, tb1, 25)), 2);
}
