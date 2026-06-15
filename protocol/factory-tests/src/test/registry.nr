use sigalswap_factory::{SigalSwapFactory, helpers::{compute_class_id_version_param, compute_clear_slot_param}};
use crate::test::utils::{setup, setup_with_pair, deploy_pair, deploy_mock_pair_v2, CANONICAL_PAIR_SALT, advance_past_timelock};
use aztec::{
    protocol::{address::AztecAddress, traits::FromField},
    test::helpers::txe_oracles,
};
use sigalswap_core::SigalSwapPair;

// Action type IDs (must stay in sync with main.nr globals).
global ACTION_SET_PAIR_CLASS_ID: Field = 7;
global ACTION_CLEAR_PAIR_SLOT: Field = 8;

// ============================================
// Factory Pair Registry & Enumeration Tests
// ============================================
// ============================================
// Versioning tests
// ============================================
/// set_pair_class_id rejects version == 0 on the first call.
#[test(should_fail_with = "INVALID_VERSION")]
unconstrained fn test_first_call_version_zero_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    env.call_public(admin, factory.set_pair_class_id(0xAAAA as Field, 0));
}
// ============================================
// clear_pair_slot tests
// ============================================
// NOTE: NEW_LATEST_NOT_REGISTERED is not reachable in tests without a second
// VERSION-baked bytecode (the check requires current_latest > 1, i.e. a
// successful v2 registration at the base, which requires bytecode with
// `pub global VERSION: u32 = 2`). The assertion is still valuable as an
// in-contract invariant -- it prevents admin operator errors from pointing
// latest_pair at a zero address -- but is exercised at the source level.
/// `queue_clear_pair_slot` rejects with NO_PAIR_AT_BASE when the base
/// has never been registered. Distinct error for a distinct failure mode --
/// admin tooling diagnostics should get the right reason.
#[test(should_fail_with = "NO_PAIR_AT_BASE")]
unconstrained fn test_clear_pair_slot_no_pair_at_base_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);

    // No pairs registered; queue_time_latest is 0.
    let t_a = AztecAddress::from_field(100);
    let t_b = AztecAddress::from_field(200);
    let some_pair = AztecAddress::from_field(300);
    env.call_public(
        admin,
        factory.queue_clear_pair_slot(some_pair, t_a, t_b, 25, 0),
    );
}
// ============================================
// Factory-inert / pre-bless state
// ============================================
/// A fresh factory reports pair_class_version == 0 before any blessing.
/// This lets SDKs detect an uninitialized factory without attempting a
/// register_pair call.
#[test]
unconstrained fn test_get_pair_class_version_zero_on_fresh_factory() {
    let (mut env, factory_address, _admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    assert_eq(env.execute_utility(factory.get_pair_class_version()), 0);
}
// ============================================
// Boundary guards on queue-side
// ============================================

/// queue_set_pair_class_id rejects calls before the bootstrap blessing has
/// happened. Without this guard, an admin could queue a v2 change against
/// a never-blessed pair_class_id, eat the 48-hour window, and discover at
/// execute time that the strict-greater check fails. CLASS_ID_NOT_SET_YET
/// surfaces the precondition cleanly at queue time.
#[test(should_fail_with = "CLASS_ID_NOT_SET_YET")]
unconstrained fn test_queue_set_pair_class_id_before_bootstrap_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    env.call_public(admin, factory.queue_set_pair_class_id(0xAAAA as Field, 1));
}

/// set_pair_class_id rejects the zero class id. The first-call branch is
/// otherwise immediate-mode and would write zero into pair_class_id storage,
/// which the queue-side guard later interprets as "never blessed" and would
/// strand the registry.
#[test(should_fail_with = "ZERO_CLASS_ID")]
unconstrained fn test_set_pair_class_id_zero_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    env.call_public(admin, factory.set_pair_class_id(0 as Field, 1));
}

/// queue_set_pair_class_id rejects the zero class id symmetrically with the
/// immediate-set path. Bootstrap requires set_pair_class_id directly so this
/// path requires a prior blessing; we set v1 first, then queue a v2 with
/// class_id=0.
#[test(should_fail_with = "ZERO_CLASS_ID")]
unconstrained fn test_queue_set_pair_class_id_zero_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    env.call_public(admin, factory.set_pair_class_id(0xAAAA as Field, 1));
    env.call_public(admin, factory.queue_set_pair_class_id(0 as Field, 2));
}

/// queue_set_pair_class_id rejects versions that don't strictly advance the
/// current pair_class_version. Without the queue-side guard, admin would burn
/// a 48-hour window on a doomed action and the failure would only surface at
/// execute time.
#[test(should_fail_with = "VERSION_NOT_INCREASING")]
unconstrained fn test_queue_set_pair_class_id_non_advancing_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    env.call_public(admin, factory.set_pair_class_id(0xAAAA as Field, 3));
    // Same version (3) -- not strictly greater.
    env.call_public(admin, factory.queue_set_pair_class_id(0xBBBB as Field, 3));
}

/// queue_set_pair_class_id rejects versions at the saturation boundary.
/// Leaves headroom below u32::MAX so the monotonic strict-greater check
/// always has at least one future version to assign. Practically unbounded
/// in normal use; the guard catches accidental MAX-value passes.
#[test(should_fail_with = "VERSION_SATURATED")]
unconstrained fn test_queue_set_pair_class_id_saturated_version_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    env.call_public(admin, factory.set_pair_class_id(0xAAAA as Field, 1));
    env.call_public(admin, factory.queue_set_pair_class_id(0xBBBB as Field, 0xffffffff));
}

/// set_pair_class_id rejects versions at the saturation boundary on the
/// immediate-set (first-call) path too. Symmetric with the queue-side guard.
#[test(should_fail_with = "VERSION_SATURATED")]
unconstrained fn test_first_call_set_pair_class_id_saturated_version_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    env.call_public(admin, factory.set_pair_class_id(0xAAAA as Field, 0xffffffff));
}

/// queue_set_pair_class_id rejects re-queuing the same (class_id, version)
/// tuple while a queue entry is still live. The action hash binds both
/// fields so distinct (class_id, version) pairs queue independently; the
/// no-overlap check prevents double-arming the same action.
#[test(should_fail_with = "ALREADY_QUEUED")]
unconstrained fn test_queue_set_pair_class_id_already_queued_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    env.call_public(admin, factory.set_pair_class_id(0xAAAA as Field, 1));
    env.call_public(admin, factory.queue_set_pair_class_id(0xBBBB as Field, 2));
    // Re-queue same args -- existing slot is non-zero.
    env.call_public(admin, factory.queue_set_pair_class_id(0xBBBB as Field, 2));
}

/// set_pair_class_id (subsequent path) reverts NOT_QUEUED when admin calls
/// directly without queuing first. After bootstrap, the function takes the
/// timelock branch and reconstructs the action hash from the (class_id,
/// version) tuple via compute_class_id_version_param; if that hash isn't
/// queued, NOT_QUEUED fires. This is the canary for the action_param
/// composition unique to set_pair_class_id -- a refactor that drifts the
/// queue/execute hash composition would surface here even though existing
/// upgrade.nr happy-path tests would still pass.
#[test(should_fail_with = "NOT_QUEUED")]
unconstrained fn test_set_pair_class_id_subsequent_requires_queue() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    // Bootstrap at v1 (immediate path).
    env.call_public(admin, factory.set_pair_class_id(0xAAAA as Field, 1));
    // Direct call to v2 without queueing -- NOT_QUEUED fires.
    env.call_public(admin, factory.set_pair_class_id(0xBBBB as Field, 2));
}

// ============================================
// Pair enumeration getters
// ============================================

/// Pair-enumeration getters after a single registration. `setup_with_pair`
/// registers exactly one pair, so every enumeration view must agree: one pair
/// ever registered, one indexed base, and both the historical (`get_pair_at`)
/// and current (`get_latest_pair_at_index`) lookups resolve index 0 to that
/// pair. These utility getters back the SDK's pool-list walk; without a direct
/// test, a refactor of the `pair_by_index` / `base_by_index` write paths could
/// desync the indices from registration and the SDK would enumerate the wrong
/// or missing pools while every other registry test still passed.
#[test]
unconstrained fn test_pair_enumeration_getters_after_single_register() {
    let (mut env, factory_address, pair_address, _t0, _t1, _admin) = setup_with_pair();
    let factory = SigalSwapFactory::at(factory_address);

    assert_eq(env.execute_utility(factory.get_pair_count()), 1);
    assert_eq(env.execute_utility(factory.get_pair_at(0)), pair_address);
    assert_eq(env.execute_utility(factory.get_indexed_base_count()), 1);
    assert_eq(env.execute_utility(factory.get_latest_pair_at_index(0)), pair_address);
}

/// `get_pair_at` reverts cleanly past the historical count rather than returning
/// a zero / garbage address. The SDK relies on `INDEX_OUT_OF_BOUNDS` as the
/// terminator for its enumeration walk; if the bound check were dropped, the
/// walk would read uninitialized slots instead of stopping.
#[test(should_fail_with = "INDEX_OUT_OF_BOUNDS")]
unconstrained fn test_get_pair_at_out_of_bounds_reverts() {
    let (mut env, factory_address, _pair, _t0, _t1, _admin) = setup_with_pair();
    let factory = SigalSwapFactory::at(factory_address);
    // Only index 0 exists after a single registration.
    let _ = env.execute_utility(factory.get_pair_at(1));
}
