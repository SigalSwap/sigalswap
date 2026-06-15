use sigalswap_factory::{SigalSwapFactory, helpers::compute_action_hash};
use crate::test::utils::{deploy_pair, setup, setup_with_pair, CANONICAL_PAIR_SALT};
use aztec::{
    protocol::{address::AztecAddress, traits::{FromField, ToField}},
    test::helpers::{test_environment::TestEnvironment, txe_oracles},
};
use sigalswap_core::SigalSwapPair;

// ============================================
// Factory Admin & Timelock Tests
// ============================================

/// Non-admin rejected on immediate action (pause_registration).
#[test(should_fail_with = "ONLY_ADMIN")]
unconstrained fn test_non_admin_pause_registration() {
    let (mut env, factory_address, _admin) = setup();
    let attacker = env.create_contract_account();

    env.call_public(attacker, SigalSwapFactory::at(factory_address).pause_registration());
}

/// Non-admin rejected on timelocked queue (queue_set_fee_to).
#[test(should_fail_with = "ONLY_ADMIN")]
unconstrained fn test_non_admin_queue_action() {
    let (mut env, factory_address, _admin) = setup();
    let attacker = env.create_contract_account();
    let fake_fee_to = AztecAddress::from_field(999);

    env.call_public(
        attacker,
        SigalSwapFactory::at(factory_address).queue_set_fee_to(fake_fee_to),
    );
}

/// Non-admin rejected on timelocked execute (set_fee_to).
#[test(should_fail_with = "ONLY_ADMIN")]
unconstrained fn test_non_admin_execute_action() {
    let (mut env, factory_address, _admin) = setup();
    let attacker = env.create_contract_account();
    let fake_fee_to = AztecAddress::from_field(999);

    env.call_public(
        attacker,
        SigalSwapFactory::at(factory_address).set_fee_to(fake_fee_to),
    );
}

/// Admin CAN pause_registration successfully.
#[test]
unconstrained fn test_admin_pause_registration() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);

    env.call_public(admin, factory.pause_registration());

    assert_eq(env.execute_utility(factory.is_registration_paused()), true);
}
/// Timelock: execute before delay reverts with "TIMELOCK_NOT_ELAPSED".
#[test(should_fail_with = "TIMELOCK_NOT_ELAPSED")]
unconstrained fn test_timelock_too_early() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    // Bootstrap fee_to so subsequent set_fee_to takes the timelocked path.
    let initial_fee_to = env.create_contract_account();
    env.call_public(admin, factory.set_fee_to(initial_fee_to));
    let new_fee_to = env.create_contract_account();

    // Queue the action
    env.call_public(admin, factory.queue_set_fee_to(new_fee_to));

    // Try to execute immediately -- should fail (need 48 hours)
    env.call_public(admin, factory.set_fee_to(new_fee_to));
}

/// Timelock: full queue-wait-execute flow succeeds after 48 hours.
#[test]
unconstrained fn test_timelock_full_flow() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    // Bootstrap fee_to so subsequent set_fee_to takes the timelocked path.
    let initial_fee_to = env.create_contract_account();
    env.call_public(admin, factory.set_fee_to(initial_fee_to));
    let new_fee_to = env.create_contract_account();

    // Queue the action
    env.call_public(admin, factory.queue_set_fee_to(new_fee_to));

    // Advance past 48-hour delay (172800 seconds)
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(172801);

    // Execute -- should succeed now
    env.call_public(admin, factory.set_fee_to(new_fee_to));

    // Verify the change took effect
    assert_eq(env.execute_utility(factory.get_fee_to()), new_fee_to);
}

/// Timelock: cancel_action prevents execution.
///
/// Cancel also emits ActionCancelledEvent. TXE can't inspect events directly,
/// but the cancel_action call succeeding here proves the emit did not revert
/// (see core/src/test/events.nr for the same pattern).
#[test(should_fail_with = "NOT_QUEUED")]
unconstrained fn test_timelock_cancel() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    // Bootstrap fee_to so subsequent set_fee_to takes the timelocked path.
    let initial_fee_to = env.create_contract_account();
    env.call_public(admin, factory.set_fee_to(initial_fee_to));
    let new_fee_to = env.create_contract_account();

    // Queue the action
    env.call_public(admin, factory.queue_set_fee_to(new_fee_to));

    // Cancel it. cancel_action takes (action_type, value); action_type for
    // set_fee_to is 1, value is the fee_to address as a Field. Factory
    // recomputes the hash internally.
    env.call_public(admin, factory.cancel_action(1 as Field, new_fee_to.to_field()));

    // Advance past delay
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(172801);

    // Execute should fail -- action was cancelled
    env.call_public(admin, factory.set_fee_to(new_fee_to));
}

/// cancel_action by a non-admin is rejected.
#[test(should_fail_with = "ONLY_ADMIN")]
unconstrained fn test_cancel_action_only_admin() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    let initial_fee_to = env.create_contract_account();
    env.call_public(admin, factory.set_fee_to(initial_fee_to));
    let attacker = env.create_contract_account();
    let new_fee_to = env.create_contract_account();

    env.call_public(admin, factory.queue_set_fee_to(new_fee_to));

    env.call_public(attacker, factory.cancel_action(1 as Field, new_fee_to.to_field()));
}

/// cancel_action on a non-queued action reverts NOT_QUEUED before any event emit.
#[test(should_fail_with = "NOT_QUEUED")]
unconstrained fn test_cancel_action_not_queued() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);

    // Random (action_type, value) that was never queued -- the factory
    // recomputes the hash and finds no timelock entry.
    env.call_public(admin, factory.cancel_action(1 as Field, 999 as Field));
}

/// Timelock: executing past the delay + window reverts ACTION_EXPIRED.
/// A queued action has a fixed execution window; once it closes, the action
/// is void even if never cancelled. This protects against stale queued
/// actions being executed long after their context has changed (e.g., an
/// old fee-to change that no longer reflects governance intent).
#[test(should_fail_with = "ACTION_EXPIRED")]
unconstrained fn test_timelock_action_expired() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    // Bootstrap fee_to so subsequent set_fee_to takes the timelocked path.
    let initial_fee_to = env.create_contract_account();
    env.call_public(admin, factory.set_fee_to(initial_fee_to));
    let new_fee_to = env.create_contract_account();

    env.call_public(admin, factory.queue_set_fee_to(new_fee_to));

    // Advance past delay + window. DELAY = 172800 (48h), WINDOW = 604800 (7d).
    // +1 to cross the inclusive upper bound.
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(172800 + 604800 + 1);

    env.call_public(admin, factory.set_fee_to(new_fee_to));
}

// ============================================
// Coverage: public surface not exercised by the generic set_fee_to tests
// ============================================

/// Full happy-path for protocol_fee_percent governance: queue, wait, execute,
/// verify the stored percent reflects the new value.
#[test]
unconstrained fn test_queue_execute_set_protocol_fee_percent() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);

    env.call_public(admin, factory.queue_set_protocol_fee_percent(50));
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(172801);
    env.call_public(admin, factory.execute_set_protocol_fee_percent(50));

    let (_fee_to, percent, _enabled) = env.execute_utility(factory.get_protocol_fee_config());
    assert_eq(percent, 50);
}

/// Full happy-path for protocol_fee_enabled governance. Default percent is 20
/// (non-zero) so enabling passes the ACTIVE_WITH_ZERO_PERCENT check.
#[test]
unconstrained fn test_queue_execute_set_protocol_fee_enabled() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    let initial_fee_to = env.create_contract_account();
    env.call_public(admin, factory.set_fee_to(initial_fee_to));

    env.call_public(admin, factory.queue_set_protocol_fee_enabled(true));
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(172801);
    env.call_public(admin, factory.execute_set_protocol_fee_enabled(true));

    let (_fee_to, _percent, enabled) = env.execute_utility(factory.get_protocol_fee_config());
    assert_eq(enabled, true);
}

/// queue_set_protocol_fee_percent rejects percent=0 while fees are enabled.
/// This is the queue-side ACTIVE_WITH_ZERO_PERCENT check.
#[test(should_fail_with = "ACTIVE_WITH_ZERO_PERCENT")]
unconstrained fn test_queue_set_protocol_fee_percent_zero_while_enabled_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    let initial_fee_to = env.create_contract_account();
    env.call_public(admin, factory.set_fee_to(initial_fee_to));

    // Enable fees first (default percent is 20).
    env.call_public(admin, factory.queue_set_protocol_fee_enabled(true));
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(172801);
    env.call_public(admin, factory.execute_set_protocol_fee_enabled(true));

    // Now try to set percent=0 -- must revert at queue time.
    env.call_public(admin, factory.queue_set_protocol_fee_percent(0));
}

/// execute_set_protocol_fee_percent rejects percent=0 if admin enables fees
/// in between the queue and execute of the percent change. Tests that the
/// authoritative check at execute time also fires.
#[test(should_fail_with = "ACTIVE_WITH_ZERO_PERCENT")]
unconstrained fn test_execute_set_protocol_fee_percent_zero_while_enabled_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    let initial_fee_to = env.create_contract_account();
    env.call_public(admin, factory.set_fee_to(initial_fee_to));

    // Queue percent=0 while fees are disabled (queue check passes).
    env.call_public(admin, factory.queue_set_protocol_fee_percent(0));

    // Before execute: enable fees (percent is still 20 = default, so this
    // enable passes). Now execute the queued percent=0 -- execute-side
    // ACTIVE_WITH_ZERO_PERCENT fires.
    env.call_public(admin, factory.queue_set_protocol_fee_enabled(true));
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(172801);
    env.call_public(admin, factory.execute_set_protocol_fee_enabled(true));
    env.call_public(admin, factory.execute_set_protocol_fee_percent(0));
}

/// queue_set_protocol_fee_enabled rejects enabling while percent is 0.
#[test(should_fail_with = "ACTIVE_WITH_ZERO_PERCENT")]
unconstrained fn test_queue_set_protocol_fee_enabled_while_percent_zero_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);

    // Drop percent to 0 first (enabled is false by default, so this passes).
    env.call_public(admin, factory.queue_set_protocol_fee_percent(0));
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(172801);
    env.call_public(admin, factory.execute_set_protocol_fee_percent(0));

    // Now try to enable fees -- queue-side ACTIVE_WITH_ZERO_PERCENT fires.
    env.call_public(admin, factory.queue_set_protocol_fee_enabled(true));
}

/// execute_set_protocol_fee_enabled rejects enabling if percent dropped to 0
/// between queue and execute.
#[test(should_fail_with = "ACTIVE_WITH_ZERO_PERCENT")]
unconstrained fn test_execute_set_protocol_fee_enabled_while_percent_zero_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    let initial_fee_to = env.create_contract_account();
    env.call_public(admin, factory.set_fee_to(initial_fee_to));

    // Queue enable while percent=20 (default, passes queue-side check).
    env.call_public(admin, factory.queue_set_protocol_fee_enabled(true));

    // Before execute: drop percent to 0 via a separate timelocked change.
    env.call_public(admin, factory.queue_set_protocol_fee_percent(0));
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(172801);
    env.call_public(admin, factory.execute_set_protocol_fee_percent(0));

    // Now execute the enable -- execute-side ACTIVE_WITH_ZERO_PERCENT fires.
    env.call_public(admin, factory.execute_set_protocol_fee_enabled(true));
}

/// Full happy-path for add_fee_tier: queue + execute + verify whitelist.
#[test]
unconstrained fn test_queue_execute_add_fee_tier() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    let new_tier: u32 = 50;

    // Sanity: tier is not allowed by default.
    assert_eq(env.execute_utility(factory.is_fee_tier_allowed(new_tier)), false);

    env.call_public(admin, factory.queue_add_fee_tier(new_tier));
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(172801);
    env.call_public(admin, factory.execute_add_fee_tier(new_tier));

    assert_eq(env.execute_utility(factory.is_fee_tier_allowed(new_tier)), true);
}

/// Full happy-path for remove_fee_tier: queue + execute + verify removal.
#[test]
unconstrained fn test_queue_execute_remove_fee_tier() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    let tier: u32 = 25; // 25 bps is pre-registered by default

    // Sanity: tier is allowed by default.
    assert_eq(env.execute_utility(factory.is_fee_tier_allowed(tier)), true);

    env.call_public(admin, factory.queue_remove_fee_tier(tier));
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(172801);
    env.call_public(admin, factory.execute_remove_fee_tier(tier));

    assert_eq(env.execute_utility(factory.is_fee_tier_allowed(tier)), false);
}

/// Admin rotation: after queue + execute, old admin loses privileges and
/// new admin gains them.
#[test(should_fail_with = "ONLY_ADMIN")]
unconstrained fn test_admin_rotation_old_admin_loses_privileges() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    let new_admin = env.create_contract_account();

    env.call_public(admin, factory.queue_set_admin(new_admin));
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(172801);
    env.call_public(admin, factory.execute_set_admin(new_admin));

    // Old admin should now be rejected by ONLY_ADMIN.
    env.call_public(admin, factory.pause_registration());
}

/// Admin rotation happy path: verify the admin storage was updated and the
/// new admin can act.
#[test]
unconstrained fn test_admin_rotation_new_admin_can_act() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    let new_admin = env.create_contract_account();

    env.call_public(admin, factory.queue_set_admin(new_admin));
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(172801);
    env.call_public(admin, factory.execute_set_admin(new_admin));

    assert_eq(env.execute_utility(factory.get_admin()), new_admin);

    // New admin can pause.
    env.call_public(new_admin, factory.pause_registration());
    assert_eq(env.execute_utility(factory.is_registration_paused()), true);
}

/// Unpause toggles the registration_paused flag back to false.
#[test]
unconstrained fn test_unpause_registration() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);

    env.call_public(admin, factory.pause_registration());
    assert_eq(env.execute_utility(factory.is_registration_paused()), true);

    env.call_public(admin, factory.unpause_registration());
    assert_eq(env.execute_utility(factory.is_registration_paused()), false);
}
/// Non-admin cannot call unpause_registration.
#[test(should_fail_with = "ONLY_ADMIN")]
unconstrained fn test_non_admin_unpause_registration_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    let attacker = env.create_contract_account();

    env.call_public(admin, factory.pause_registration());
    env.call_public(attacker, factory.unpause_registration());
}

// ============================================
// Governance edge-case coverage
// ============================================

/// Executing a never-queued action reverts NOT_QUEUED.
#[test(should_fail_with = "NOT_QUEUED")]
unconstrained fn test_execute_without_queue_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    // Bootstrap fee_to so subsequent set_fee_to takes the timelocked path.
    let initial_fee_to = env.create_contract_account();
    env.call_public(admin, factory.set_fee_to(initial_fee_to));
    let new_fee_to = env.create_contract_account();

    // No queue_set_fee_to was called -- execute must reject.
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(172801);
    env.call_public(admin, factory.set_fee_to(new_fee_to));
}

/// Queue one value, try to execute a different value -- the different value
/// hashes to a different timelock slot and reads back 0 => NOT_QUEUED.
/// Ensures the action hash binds value, not just action_type.
#[test(should_fail_with = "NOT_QUEUED")]
unconstrained fn test_execute_wrong_value_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    let initial_fee_to = env.create_contract_account();
    env.call_public(admin, factory.set_fee_to(initial_fee_to));
    let queued_fee_to = env.create_contract_account();
    let different_fee_to = env.create_contract_account();

    env.call_public(admin, factory.queue_set_fee_to(queued_fee_to));
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(172801);

    // Admin tries to execute with a DIFFERENT value than queued. The action
    // hash is different, the read is 0, and NOT_QUEUED fires.
    env.call_public(admin, factory.set_fee_to(different_fee_to));
}

/// Executing the same action twice: first succeeds, second reverts NOT_QUEUED
/// because the execute path zeroes the timelock entry.
#[test(should_fail_with = "NOT_QUEUED")]
unconstrained fn test_double_execute_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    // Bootstrap fee_to so subsequent set_fee_to takes the timelocked path.
    let initial_fee_to = env.create_contract_account();
    env.call_public(admin, factory.set_fee_to(initial_fee_to));
    let new_fee_to = env.create_contract_account();

    env.call_public(admin, factory.queue_set_fee_to(new_fee_to));
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(172801);
    env.call_public(admin, factory.set_fee_to(new_fee_to));

    // Second execute with identical args -- slot was zeroed, NOT_QUEUED fires.
    env.call_public(admin, factory.set_fee_to(new_fee_to));
}

/// Queuing the same action twice (identical params) reverts ALREADY_QUEUED.
/// Prevents timestamp refresh via double-queue, which could slide the
/// execution window.
#[test(should_fail_with = "ALREADY_QUEUED")]
unconstrained fn test_queue_same_action_twice_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    // Bootstrap fee_to so subsequent set_fee_to takes the timelocked path.
    let initial_fee_to = env.create_contract_account();
    env.call_public(admin, factory.set_fee_to(initial_fee_to));
    let new_fee_to = env.create_contract_account();

    env.call_public(admin, factory.queue_set_fee_to(new_fee_to));
    env.call_public(admin, factory.queue_set_fee_to(new_fee_to));
}

/// queue_set_protocol_fee_percent rejects values above 100.
#[test(should_fail_with = "PERCENT_TOO_HIGH")]
unconstrained fn test_queue_set_protocol_fee_percent_above_100_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);

    env.call_public(admin, factory.queue_set_protocol_fee_percent(101));
}

/// queue_set_fee_to rejects the zero address.
#[test(should_fail_with = "ZERO_ADDRESS")]
unconstrained fn test_queue_set_fee_to_zero_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);

    env.call_public(admin, factory.queue_set_fee_to(AztecAddress::zero()));
}

/// queue_set_admin rejects the zero address.
#[test(should_fail_with = "ZERO_ADDRESS")]
unconstrained fn test_queue_set_admin_zero_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);

    env.call_public(admin, factory.queue_set_admin(AztecAddress::zero()));
}

/// queue_add_fee_tier rejects tier_bps == 0 (degenerate, no-fee pool).
#[test(should_fail_with = "INVALID_FEE_TIER")]
unconstrained fn test_queue_add_fee_tier_zero_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);

    env.call_public(admin, factory.queue_add_fee_tier(0));
}

/// queue_add_fee_tier rejects tier_bps >= 5000 (50% fee is the hard cap).
#[test(should_fail_with = "INVALID_FEE_TIER")]
unconstrained fn test_queue_add_fee_tier_at_cap_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);

    // 5000 bps (50%) is the exclusive upper bound; should revert.
    env.call_public(admin, factory.queue_add_fee_tier(5000));
}

/// queue_add_fee_tier rejects tier_bps far above the cap.
#[test(should_fail_with = "INVALID_FEE_TIER")]
unconstrained fn test_queue_add_fee_tier_way_above_cap_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);

    env.call_public(admin, factory.queue_add_fee_tier(10000));
}

/// Execute at exactly `queued_at + TIMELOCK_DELAY` succeeds (inclusive lower
/// bound on the execution window).
#[test]
unconstrained fn test_execute_at_exact_delay_boundary_succeeds() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    // Bootstrap fee_to so subsequent set_fee_to takes the timelocked path.
    let initial_fee_to = env.create_contract_account();
    env.call_public(admin, factory.set_fee_to(initial_fee_to));
    let new_fee_to = env.create_contract_account();

    env.call_public(admin, factory.queue_set_fee_to(new_fee_to));
    txe_oracles::advance_blocks_by(1);
    // Exactly TIMELOCK_DELAY = 172800 seconds later.
    txe_oracles::advance_timestamp_by(172800);
    env.call_public(admin, factory.set_fee_to(new_fee_to));

    assert_eq(env.execute_utility(factory.get_fee_to()), new_fee_to);
}

/// Execute at exactly the end of the window
/// (`queued_at + TIMELOCK_DELAY + TIMELOCK_WINDOW`) still succeeds (inclusive
/// upper bound).
#[test]
unconstrained fn test_execute_at_end_of_window_succeeds() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    // Bootstrap fee_to so subsequent set_fee_to takes the timelocked path.
    let initial_fee_to = env.create_contract_account();
    env.call_public(admin, factory.set_fee_to(initial_fee_to));
    let new_fee_to = env.create_contract_account();

    env.call_public(admin, factory.queue_set_fee_to(new_fee_to));
    txe_oracles::advance_blocks_by(1);
    // Exactly at DELAY + WINDOW = 172800 + 604800 = 777600 seconds later.
    txe_oracles::advance_timestamp_by(172800 + 604800);
    env.call_public(admin, factory.set_fee_to(new_fee_to));

    assert_eq(env.execute_utility(factory.get_fee_to()), new_fee_to);
}

/// After admin rotation, a previously-queued action by the OLD admin is still
/// executable by the NEW admin. The timelock keys off action hash, not
/// submitter -- so rotations don't invalidate pending actions. Governance
/// continuity invariant.
#[test]
unconstrained fn test_admin_rotation_preserves_queued_actions() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    let initial_fee_to = env.create_contract_account();
    env.call_public(admin, factory.set_fee_to(initial_fee_to));
    let new_admin = env.create_contract_account();
    let new_fee_to = env.create_contract_account();

    // Old admin queues a fee_to change.
    env.call_public(admin, factory.queue_set_fee_to(new_fee_to));

    // Rotate admin (also requires timelock).
    env.call_public(admin, factory.queue_set_admin(new_admin));
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(172801);
    env.call_public(admin, factory.execute_set_admin(new_admin));

    // New admin executes the queued fee_to change (still within window).
    env.call_public(new_admin, factory.set_fee_to(new_fee_to));

    assert_eq(env.execute_utility(factory.get_fee_to()), new_fee_to);
}

/// Cancel with a different value than queued reverts NOT_QUEUED -- the
/// cancel path also recomputes the action hash from (type, value), so a
/// mismatched value resolves to a different slot.
#[test(should_fail_with = "NOT_QUEUED")]
unconstrained fn test_cancel_with_wrong_value_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    let initial_fee_to = env.create_contract_account();
    env.call_public(admin, factory.set_fee_to(initial_fee_to));
    let queued_fee_to = env.create_contract_account();
    let different_fee_to = env.create_contract_account();

    env.call_public(admin, factory.queue_set_fee_to(queued_fee_to));
    env.call_public(
        admin,
        factory.cancel_action(1 as Field, different_fee_to.to_field()),
    );
}

/// After cancel, the slot is zeroed so a fresh queue of the same action is
/// allowed. Verifies cancel actually clears state (not just blocks execute).
#[test]
unconstrained fn test_cancel_then_requeue_succeeds() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    // Bootstrap fee_to so subsequent set_fee_to takes the timelocked path.
    let initial_fee_to = env.create_contract_account();
    env.call_public(admin, factory.set_fee_to(initial_fee_to));
    let new_fee_to = env.create_contract_account();

    env.call_public(admin, factory.queue_set_fee_to(new_fee_to));
    env.call_public(admin, factory.cancel_action(1 as Field, new_fee_to.to_field()));

    // Re-queue should succeed (ALREADY_QUEUED would fire if cancel didn't clear).
    env.call_public(admin, factory.queue_set_fee_to(new_fee_to));

    // And the fresh queue still requires a full delay before execute.
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(172801);
    env.call_public(admin, factory.set_fee_to(new_fee_to));

    assert_eq(env.execute_utility(factory.get_fee_to()), new_fee_to);
}

// ============================================
// Bootstrap + fee_to invariant
// ============================================

/// First call to set_fee_to from the post-deploy zero state is immediate
/// (no timelock needed). Same first-call-immediate pattern as
/// set_pair_class_id.
#[test]
unconstrained fn test_set_fee_to_first_call_is_immediate() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    let initial_fee_to = env.create_contract_account();

    // No queue. Direct call must succeed because fee_to is currently zero.
    env.call_public(admin, factory.set_fee_to(initial_fee_to));

    assert_eq(env.execute_utility(factory.get_fee_to()), initial_fee_to);
}

/// Subsequent set_fee_to (after bootstrap) requires queue + timelock --
/// a direct call without queueing reverts NOT_QUEUED.
#[test(should_fail_with = "NOT_QUEUED")]
unconstrained fn test_set_fee_to_subsequent_requires_queue() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    let initial_fee_to = env.create_contract_account();
    let new_fee_to = env.create_contract_account();

    env.call_public(admin, factory.set_fee_to(initial_fee_to));

    // No queue for the change -- direct call on the subsequent-change path
    // reverts NOT_QUEUED.
    env.call_public(admin, factory.set_fee_to(new_fee_to));
}

/// queue_set_fee_to before the initial bootstrap rejects -- admin must
/// use the immediate set_fee_to path to initialize, not the queue.
#[test(should_fail_with = "USE_IMMEDIATE_SET_FOR_INITIAL")]
unconstrained fn test_queue_set_fee_to_before_bootstrap_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    let target = env.create_contract_account();

    env.call_public(admin, factory.queue_set_fee_to(target));
}

/// queue_set_protocol_fee_enabled(true) with fee_to=zero rejects. The
/// admin must bootstrap fee_to first; enabling fees with fee_to=zero
/// would silently burn protocol-fee LP to the zero address.
#[test(should_fail_with = "ACTIVE_WITH_ZERO_FEE_TO")]
unconstrained fn test_queue_enable_fees_with_zero_fee_to_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);

    env.call_public(admin, factory.queue_set_protocol_fee_enabled(true));
}

// Note: no test for `execute_set_protocol_fee_enabled(true)` with
// `fee_to == zero` directly. Reaching that state in isolation would
// require queueing enable_fees when fee_to was non-zero and then
// zeroing fee_to before execute -- but `set_fee_to(zero)` is rejected
// at every entry, so the state is unreachable. The execute-side
// assertion is belt-and-suspenders against a future refactor that
// introduces a new zeroing path; the queue-side test above is the
// reachable canary for this invariant.


// ============================================
// pause_pair / unpause_pair registration guard
// ============================================

/// pause_pair on an address that was never registered through this factory
/// reverts PAIR_NOT_REGISTERED. Mirrors sync_protocol_fee's guard so admin
/// typo or stale list cannot pause a knockoff pair that bakes our factory
/// address into its constructor.
#[test(should_fail_with = "PAIR_NOT_REGISTERED")]
unconstrained fn test_pause_pair_unregistered_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    let stranger = env.create_contract_account();

    env.call_public(admin, factory.pause_pair(stranger));
}

/// unpause_pair on an unregistered address reverts PAIR_NOT_REGISTERED.
/// Symmetric with pause_pair so admin can't typo-unpause a knockoff
/// into a state they didn't intend.
#[test(should_fail_with = "PAIR_NOT_REGISTERED")]
unconstrained fn test_unpause_pair_unregistered_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    let stranger = env.create_contract_account();

    env.call_public(admin, factory.unpause_pair(stranger));
}

/// pause_pair happy path: factory->pair set_pause(true) flips the pair-side
/// is_paused flag. The cross-contract call is the load-bearing primitive for
/// emergency response; without this canary, a future refactor that breaks the
/// outbound call (wrong selector, stale interface, pair-side rejection) would
/// pass the registration-guard tests above but silently fail at incident time.
#[test]
unconstrained fn test_pause_pair_happy_path() {
    let (mut env, factory_address, pair_address, _t0, _t1, admin) = setup_with_pair();
    let factory = SigalSwapFactory::at(factory_address);
    let pair = SigalSwapPair::at(pair_address);

    let before = env.execute_utility(pair.is_paused_view());
    assert_eq(before, false);

    env.call_public(admin, factory.pause_pair(pair_address));

    let after = env.execute_utility(pair.is_paused_view());
    assert_eq(after, true);
}

/// unpause_pair happy path: pause then unpause round-trip. Locks in the
/// symmetric outbound call so a future refactor of the factory->pair
/// set_pause(false) path is caught at test time.
#[test]
unconstrained fn test_unpause_pair_happy_path() {
    let (mut env, factory_address, pair_address, _t0, _t1, admin) = setup_with_pair();
    let factory = SigalSwapFactory::at(factory_address);
    let pair = SigalSwapPair::at(pair_address);

    env.call_public(admin, factory.pause_pair(pair_address));
    assert_eq(env.execute_utility(pair.is_paused_view()), true);

    env.call_public(admin, factory.unpause_pair(pair_address));
    assert_eq(env.execute_utility(pair.is_paused_view()), false);
}

/// pause_pair by a non-admin reverts. The ONLY_ADMIN check is shared with
/// the rest of the privileged surface, but pause_pair is uniquely
/// load-bearing for emergency response so the gate gets its own canary.
#[test(should_fail_with = "ONLY_ADMIN")]
unconstrained fn test_pause_pair_only_admin() {
    let (mut env, factory_address, pair_address, _t0, _t1, _admin) = setup_with_pair();
    let factory = SigalSwapFactory::at(factory_address);
    let attacker = env.create_contract_account();

    env.call_public(attacker, factory.pause_pair(pair_address));
}

/// unpause_pair by a non-admin reverts.
#[test(should_fail_with = "ONLY_ADMIN")]
unconstrained fn test_unpause_pair_only_admin() {
    let (mut env, factory_address, pair_address, _t0, _t1, admin) = setup_with_pair();
    let factory = SigalSwapFactory::at(factory_address);
    let attacker = env.create_contract_account();

    env.call_public(admin, factory.pause_pair(pair_address));
    env.call_public(attacker, factory.unpause_pair(pair_address));
}


// ============================================
// sync_protocol_fee
// ============================================

/// sync_protocol_fee happy path: admin changes the global percent, then syncs
/// the pair, and the pair's protocol_fee_percent reflects the new global.
/// This is the load-bearing factory->pair pipeline for cascading fee changes
/// across the whole registry; without a happy-path canary, a factory-side
/// change that allows an invalid combination would silently break every
/// pair's next sync.
#[test]
unconstrained fn test_sync_protocol_fee_happy_path() {
    let (mut env, factory_address, pair_address, _t0, _t1, admin) = setup_with_pair();
    let factory = SigalSwapFactory::at(factory_address);
    let pair = SigalSwapPair::at(pair_address);

    // setup_with_pair already pushed the constructor defaults
    // (fee_to=zero, percent=20, enabled=false) at register_pair time.
    let (_r0, _r1, _ts, _is_paused, percent_before, _active_before) =
        env.execute_utility(pair.get_pair_state());
    assert_eq(percent_before, 20);

    // Queue + execute a percent change at the factory.
    env.call_public(admin, factory.queue_set_protocol_fee_percent(50));
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(172801);
    env.call_public(admin, factory.execute_set_protocol_fee_percent(50));

    // Pair still sees the old percent until sync runs.
    let (_r0, _r1, _ts, _is_paused, percent_pre_sync, _active_pre) =
        env.execute_utility(pair.get_pair_state());
    assert_eq(percent_pre_sync, 20);

    // Sync pushes factory globals into the pair.
    env.call_public(admin, factory.sync_protocol_fee(pair_address));

    let (_r0, _r1, _ts, _is_paused, percent_after, _active_after) =
        env.execute_utility(pair.get_pair_state());
    assert_eq(percent_after, 50);
}

/// Idempotent sync: calling `sync_protocol_fee` against a pair that already
/// matches the factory's config completes cleanly (no revert, pair state
/// unchanged). The factory-side `ProtocolFeeSyncedEvent` is emitted on every
/// successful call regardless of whether the pair-side state actually
/// changed -- this canary pins the call's success on the no-op path so the
/// admin-action audit trail stays whole. Direct event emission cannot be
/// asserted from the test crate (aztec-nr's `discover_event_at` is
/// `pub(crate)` and unreachable from a downstream contract); the SDK's
/// `events.test.ts` field-shape canary covers the emitted-event ABI.
#[test]
unconstrained fn test_sync_protocol_fee_idempotent_completes() {
    let (mut env, factory_address, pair_address, _t0, _t1, admin) = setup_with_pair();
    let factory = SigalSwapFactory::at(factory_address);
    let pair = SigalSwapPair::at(pair_address);

    // setup_with_pair already pushed the constructor defaults to the pair at
    // register_pair time, so the pair and factory are already in sync.
    let (_r0, _r1, _ts, _is_paused, percent_before, _active_before) =
        env.execute_utility(pair.get_pair_state());

    // First call: pair was already synced. Must not revert.
    env.call_public(admin, factory.sync_protocol_fee(pair_address));

    // Second call: still synced. Also must not revert.
    env.call_public(admin, factory.sync_protocol_fee(pair_address));

    // State unchanged after both no-op syncs.
    let (_r0, _r1, _ts, _is_paused, percent_after, _active_after) =
        env.execute_utility(pair.get_pair_state());
    assert_eq(percent_after, percent_before);
}

/// sync_protocol_fee on an unregistered address reverts. Mirrors the
/// pause_pair/unpause_pair guard so a stale list or admin typo can't push
/// fee config into a stranger pair that bakes our factory address into its
/// constructor.
#[test(should_fail_with = "PAIR_NOT_REGISTERED")]
unconstrained fn test_sync_protocol_fee_unregistered_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    let stranger = env.create_contract_account();

    env.call_public(admin, factory.sync_protocol_fee(stranger));
}

/// sync_protocol_fee by a non-admin reverts.
#[test(should_fail_with = "ONLY_ADMIN")]
unconstrained fn test_sync_protocol_fee_only_admin() {
    let (mut env, factory_address, pair_address, _t0, _t1, _admin) = setup_with_pair();
    let factory = SigalSwapFactory::at(factory_address);
    let attacker = env.create_contract_account();

    env.call_public(attacker, factory.sync_protocol_fee(pair_address));
}


// ============================================
// register_pair coverage smoke test
// ============================================

/// Smoke test: setup_with_pair completes (canonical pair deployed via
/// txe_oracles::deploy with secret=0, LP Token deployed at derived address,
/// class_id blessed at version 1, register_pair called). If this passes,
/// the TXE canonical-pair pattern works and the more targeted reject-branch
/// tests below are reachable.
#[test]
unconstrained fn test_register_pair_canonical_smoke() {
    let (mut env, factory_address, pair_address, t0, t1, _admin) = setup_with_pair();
    let factory = SigalSwapFactory::at(factory_address);

    // The pair should now appear via get_pair (latest version at the base).
    let resolved = env.execute_utility(factory.get_pair(t0, t1, 25));
    assert_eq(resolved, pair_address);
}

// ============================================
// Symmetric guard tests
// ============================================

/// queue_remove_fee_tier rejects tier_bps == 0 -- symmetric with queue_add.
#[test(should_fail_with = "INVALID_FEE_TIER")]
unconstrained fn test_queue_remove_fee_tier_zero_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    env.call_public(admin, factory.queue_remove_fee_tier(0));
}

/// queue_remove_fee_tier rejects tier_bps >= 5000 -- symmetric with queue_add.
#[test(should_fail_with = "INVALID_FEE_TIER")]
unconstrained fn test_queue_remove_fee_tier_at_cap_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    env.call_public(admin, factory.queue_remove_fee_tier(5000));
}

/// queue_remove_fee_tier rejects a never-added tier -- closes a no-op
/// execute path that would otherwise burn a 48-hour delay and emit a
/// misleading FeeTierRemovedEvent without state change.
#[test(should_fail_with = "TIER_NOT_ALLOWED")]
unconstrained fn test_queue_remove_fee_tier_never_added_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    // 7 bps was never added to the default whitelist (5/25/100).
    env.call_public(admin, factory.queue_remove_fee_tier(7));
}

/// queue_clear_pair_slot rejects pair_address that doesn't match latest_pair[base].
/// Mirrors execute-side NOT_LATEST so the typo surfaces immediately, not after
/// the 48-hour delay.
#[test(should_fail_with = "NOT_LATEST")]
unconstrained fn test_queue_clear_pair_slot_wrong_pair_reverts() {
    let (mut env, factory_address, _real_pair, t0, t1, admin) = setup_with_pair();
    let factory = SigalSwapFactory::at(factory_address);
    let stranger = AztecAddress::from_field(0xdead);

    // setup_with_pair registered the real pair at version 1; stranger is
    // not the latest. Queue-time NOT_LATEST should fire before the 48h
    // delay would.
    env.call_public(
        admin,
        factory.queue_clear_pair_slot(stranger, t0, t1, 25, 0),
    );
}

/// Smoke: get_indexed_base_count and get_active_pair_count both return 0
/// on a fresh factory (no pairs yet). Verifies the iteration in
/// get_active_pair_count handles the empty-base case (loop body never runs).
#[test]
unconstrained fn test_get_active_and_indexed_pair_counts_empty_factory() {
    let (mut env, factory_address, _admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);

    let indexed = env.execute_utility(factory.get_indexed_base_count());
    let active = env.execute_utility(factory.get_active_pair_count());
    assert_eq(indexed, 0);
    assert_eq(active, 0);
}

// ============================================
// Fee-tier whitelist drain prevention
// ============================================

/// queue_remove_fee_tier rejects when only one tier remains. Admin who
/// genuinely wants to block all new registrations should use
/// pause_registration -- removing the last tier would brick register_pair
/// for a 48h timelock cycle with the wrong error code.
#[test(should_fail_with = "LAST_FEE_TIER")]
unconstrained fn test_queue_remove_last_fee_tier_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);

    // Drain to the last tier: queue + execute remove for two of the three
    // default tiers (5, 25). Then attempt to queue removal of the third (100).
    env.call_public(admin, factory.queue_remove_fee_tier(5));
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(172801);
    env.call_public(admin, factory.execute_remove_fee_tier(5));

    env.call_public(admin, factory.queue_remove_fee_tier(25));
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(172801);
    env.call_public(admin, factory.execute_remove_fee_tier(25));

    // Only tier 100 remains. Queueing its removal should revert.
    env.call_public(admin, factory.queue_remove_fee_tier(100));
}

/// execute_remove_fee_tier rejects when only one tier remains, even if
/// queue-side guard was bypassed (e.g. multi-queue race where multiple
/// removals were queued before any executed). Authoritative check.
#[test(should_fail_with = "LAST_FEE_TIER")]
unconstrained fn test_execute_remove_last_fee_tier_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);

    // Queue all three removals back-to-back (count is still 3 when each
    // queue runs, so all pass the queue-side guard).
    env.call_public(admin, factory.queue_remove_fee_tier(5));
    env.call_public(admin, factory.queue_remove_fee_tier(25));
    env.call_public(admin, factory.queue_remove_fee_tier(100));
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(172801);

    // Execute first two -- count drops 3 -> 2 -> 1.
    env.call_public(admin, factory.execute_remove_fee_tier(5));
    env.call_public(admin, factory.execute_remove_fee_tier(25));

    // Third execute would drain the whitelist; authoritative guard fires.
    env.call_public(admin, factory.execute_remove_fee_tier(100));
}

/// Sanity: removing two of three tiers and adding one back keeps the count
/// consistent and lets register_pair resolve the remaining whitelist.
#[test]
unconstrained fn test_fee_tier_count_round_trip() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);

    env.call_public(admin, factory.queue_remove_fee_tier(5));
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(172801);
    env.call_public(admin, factory.execute_remove_fee_tier(5));
    // count = 2 (25, 100). Add 200 bps as a fresh tier.
    env.call_public(admin, factory.queue_add_fee_tier(200));
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(172801);
    env.call_public(admin, factory.execute_add_fee_tier(200));
    // count = 3 (25, 100, 200). 25 still allowed.
    assert_eq(env.execute_utility(factory.is_fee_tier_allowed(25)), true);
    assert_eq(env.execute_utility(factory.is_fee_tier_allowed(200)), true);
    assert_eq(env.execute_utility(factory.is_fee_tier_allowed(5)), false);
}

// ============================================
// Timelock status views (get_timelock, get_timelock_params)
// ============================================

/// `get_timelock_params` returns the compile-time globals (172800, 604800).
#[test]
unconstrained fn test_get_timelock_params() {
    let (mut env, factory_address, _admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    let (delay, window) = env.execute_utility(factory.get_timelock_params());
    assert_eq(delay, 172800 as u64);
    assert_eq(window, 604800 as u64);
}

/// `get_timelock` returns 0 for an action that was never queued.
#[test]
unconstrained fn test_get_timelock_zero_when_not_queued() {
    let (mut env, factory_address, _admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    // ACTION_SET_FEE_TO = 1; arbitrary value; never queued.
    let action_hash = compute_action_hash(1 as Field, 0xdead as Field);
    assert_eq(env.execute_utility(factory.get_timelock(action_hash)), 0 as u64);
}

/// Queue -> get -> execute -> get round trip: queued returns nonzero, executed clears.
#[test]
unconstrained fn test_get_timelock_round_trip() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);

    // Bootstrap fee_to so queue_set_fee_to takes the timelocked path.
    let initial_fee_to = env.create_contract_account();
    env.call_public(admin, factory.set_fee_to(initial_fee_to));

    let new_fee_to = env.create_contract_account();
    let action_hash = compute_action_hash(1 as Field, new_fee_to.to_field());

    // Queue action -- timelock slot now nonzero.
    env.call_public(admin, factory.queue_set_fee_to(new_fee_to));
    let queued_at = env.execute_utility(factory.get_timelock(action_hash));
    assert(queued_at > 0 as u64);

    // Advance past the delay and execute.
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(172801);
    env.call_public(admin, factory.set_fee_to(new_fee_to));

    // Slot is cleared post-execution.
    assert_eq(env.execute_utility(factory.get_timelock(action_hash)), 0 as u64);
}

/// Queue -> cancel: timelock slot also clears on cancellation.
#[test]
unconstrained fn test_get_timelock_clears_on_cancel() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);

    let initial_fee_to = env.create_contract_account();
    env.call_public(admin, factory.set_fee_to(initial_fee_to));

    let new_fee_to = env.create_contract_account();
    let action_hash = compute_action_hash(1 as Field, new_fee_to.to_field());

    env.call_public(admin, factory.queue_set_fee_to(new_fee_to));
    assert(env.execute_utility(factory.get_timelock(action_hash)) > 0 as u64);

    env.call_public(admin, factory.cancel_action(1 as Field, new_fee_to.to_field()));
    assert_eq(env.execute_utility(factory.get_timelock(action_hash)), 0 as u64);
}

// ============================================
// TIER_ALREADY_ALLOWED + ZERO_ADMIN canaries
// ============================================

/// queue_add_fee_tier rejects an already-allowed tier -- closes the no-op
/// execute path that would otherwise burn a 48-hour delay and emit a
/// misleading FeeTierAddedEvent without state change. Symmetric to the
/// existing `TIER_NOT_ALLOWED` guard on `queue_remove_fee_tier`.
#[test(should_fail_with = "TIER_ALREADY_ALLOWED")]
unconstrained fn test_queue_add_fee_tier_already_allowed_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    // 25 bps is in the default whitelist (5/25/100).
    env.call_public(admin, factory.queue_add_fee_tier(25));
}

/// Re-add of an already-removed tier (re-adding 25 after removing it) is a
/// legitimate add path and must succeed. Verifies the TIER_ALREADY_ALLOWED
/// guard doesn't over-block valid re-adds; it only catches the
/// no-op-on-allowed case.
#[test]
unconstrained fn test_queue_add_fee_tier_after_removal_succeeds() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);

    // Add a 4th tier first so we satisfy LAST_FEE_TIER (count >= 2).
    // Default whitelist is 5/25/100; queueing+executing add(50) brings count to 4.
    env.call_public(admin, factory.queue_add_fee_tier(50));
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(172801);
    env.call_public(admin, factory.execute_add_fee_tier(50));

    // Remove tier 25.
    env.call_public(admin, factory.queue_remove_fee_tier(25));
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(172801);
    env.call_public(admin, factory.execute_remove_fee_tier(25));

    // Re-add 25: state is `allowed_fee_tiers[25] = false` after removal, so
    // the TIER_ALREADY_ALLOWED queue-side assert passes and the re-add succeeds.
    env.call_public(admin, factory.queue_add_fee_tier(25));
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(172801);
    env.call_public(admin, factory.execute_add_fee_tier(25));
}

/// Constructor rejects the zero address as admin. With `admin = zero`, every
/// privileged surface (`queue_*`, `execute_*`, `pause_pair`, etc.) gates on
/// `msg_sender == admin` and no real account satisfies this -- the factory
/// is permanently bricked. The constructor assert closes the deployer-typo
/// footgun before any state lands.
#[test(should_fail_with = "ZERO_ADMIN")]
unconstrained fn test_factory_constructor_zero_admin_reverts() {
    let mut env = TestEnvironment::new();
    let admin = env.create_contract_account();
    let factory_init = SigalSwapFactory::interface().constructor(AztecAddress::zero());
    let _factory = env.deploy("@sigalswap_factory/SigalSwapFactory").with_public_initializer(admin, factory_init);
}


// ============================================
// Per-function timelock-assert canaries
// ============================================
// Each timelocked execute function inlines its own NOT_QUEUED /
// TIMELOCK_NOT_ELAPSED / ACTION_EXPIRED triple (no shared helper). The
// canaries below pin each function's branch so a future copy-paste refactor
// that touches just one execute path -- e.g. drops the upper-window check
// from execute_clear_pair_slot to ship "emergency-grade" slot clearing --
// gets caught at test time rather than after deploy. The set_fee_to family
// has these covered above; the canaries below cover the remaining seven
// timelocked execute functions.
//
// Window arithmetic: TIMELOCK_DELAY = 172800 (48h),
// TIMELOCK_WINDOW = 604800 (7d). Past-expiry advance = DELAY + WINDOW + 1.

global PAST_EXPIRY_TIMESTAMP_ADVANCE: u64 = 172800 + 604800 + 1;

// --- execute_set_protocol_fee_percent ---

#[test(should_fail_with = "NOT_QUEUED")]
unconstrained fn test_execute_set_protocol_fee_percent_not_queued_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    env.call_public(admin, factory.execute_set_protocol_fee_percent(50));
}

#[test(should_fail_with = "TIMELOCK_NOT_ELAPSED")]
unconstrained fn test_execute_set_protocol_fee_percent_too_early_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    env.call_public(admin, factory.queue_set_protocol_fee_percent(50));
    env.call_public(admin, factory.execute_set_protocol_fee_percent(50));
}

#[test(should_fail_with = "ACTION_EXPIRED")]
unconstrained fn test_execute_set_protocol_fee_percent_expired_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    env.call_public(admin, factory.queue_set_protocol_fee_percent(50));
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(PAST_EXPIRY_TIMESTAMP_ADVANCE);
    env.call_public(admin, factory.execute_set_protocol_fee_percent(50));
}

// --- execute_set_protocol_fee_enabled ---

#[test(should_fail_with = "NOT_QUEUED")]
unconstrained fn test_execute_set_protocol_fee_enabled_not_queued_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    env.call_public(admin, factory.execute_set_protocol_fee_enabled(false));
}

#[test(should_fail_with = "TIMELOCK_NOT_ELAPSED")]
unconstrained fn test_execute_set_protocol_fee_enabled_too_early_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    env.call_public(admin, factory.queue_set_protocol_fee_enabled(false));
    env.call_public(admin, factory.execute_set_protocol_fee_enabled(false));
}

#[test(should_fail_with = "ACTION_EXPIRED")]
unconstrained fn test_execute_set_protocol_fee_enabled_expired_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    env.call_public(admin, factory.queue_set_protocol_fee_enabled(false));
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(PAST_EXPIRY_TIMESTAMP_ADVANCE);
    env.call_public(admin, factory.execute_set_protocol_fee_enabled(false));
}

// --- execute_set_admin ---

#[test(should_fail_with = "NOT_QUEUED")]
unconstrained fn test_execute_set_admin_not_queued_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    let new_admin = env.create_contract_account();
    env.call_public(admin, factory.execute_set_admin(new_admin));
}

#[test(should_fail_with = "TIMELOCK_NOT_ELAPSED")]
unconstrained fn test_execute_set_admin_too_early_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    let new_admin = env.create_contract_account();
    env.call_public(admin, factory.queue_set_admin(new_admin));
    env.call_public(admin, factory.execute_set_admin(new_admin));
}

#[test(should_fail_with = "ACTION_EXPIRED")]
unconstrained fn test_execute_set_admin_expired_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    let new_admin = env.create_contract_account();
    env.call_public(admin, factory.queue_set_admin(new_admin));
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(PAST_EXPIRY_TIMESTAMP_ADVANCE);
    env.call_public(admin, factory.execute_set_admin(new_admin));
}

// --- execute_add_fee_tier ---

#[test(should_fail_with = "NOT_QUEUED")]
unconstrained fn test_execute_add_fee_tier_not_queued_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    // 7 bps not in default whitelist (5/25/100); INVALID_FEE_TIER doesn't
    // fire (0 < 7 < 5000).
    env.call_public(admin, factory.execute_add_fee_tier(7));
}

#[test(should_fail_with = "TIMELOCK_NOT_ELAPSED")]
unconstrained fn test_execute_add_fee_tier_too_early_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    env.call_public(admin, factory.queue_add_fee_tier(7));
    env.call_public(admin, factory.execute_add_fee_tier(7));
}

#[test(should_fail_with = "ACTION_EXPIRED")]
unconstrained fn test_execute_add_fee_tier_expired_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    env.call_public(admin, factory.queue_add_fee_tier(7));
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(PAST_EXPIRY_TIMESTAMP_ADVANCE);
    env.call_public(admin, factory.execute_add_fee_tier(7));
}

// --- execute_remove_fee_tier ---

#[test(should_fail_with = "NOT_QUEUED")]
unconstrained fn test_execute_remove_fee_tier_not_queued_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    // 25 bps is in default whitelist; INVALID_FEE_TIER doesn't fire.
    env.call_public(admin, factory.execute_remove_fee_tier(25));
}

#[test(should_fail_with = "TIMELOCK_NOT_ELAPSED")]
unconstrained fn test_execute_remove_fee_tier_too_early_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    env.call_public(admin, factory.queue_remove_fee_tier(25));
    env.call_public(admin, factory.execute_remove_fee_tier(25));
}

#[test(should_fail_with = "ACTION_EXPIRED")]
unconstrained fn test_execute_remove_fee_tier_expired_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    env.call_public(admin, factory.queue_remove_fee_tier(25));
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(PAST_EXPIRY_TIMESTAMP_ADVANCE);
    env.call_public(admin, factory.execute_remove_fee_tier(25));
}

// --- execute_clear_pair_slot ---
//
// NOT_QUEUED uses a fresh factory: the timelock check fires at the top of
// the function before any state-validation guards (NOT_LATEST,
// NEW_LATEST_NOT_LOWER, etc.) so we can pass dummy args. The TIMELOCK_NOT_ELAPSED
// and ACTION_EXPIRED tests need a registered pair to pass the queue-side
// state checks, so they use setup_with_pair.

#[test(should_fail_with = "NOT_QUEUED")]
unconstrained fn test_execute_clear_pair_slot_not_queued_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    let pair = AztecAddress::from_field(0xdead);
    let t0 = AztecAddress::from_field(100);
    let t1 = AztecAddress::from_field(200);
    env.call_public(admin, factory.execute_clear_pair_slot(pair, t0, t1, 25, 0));
}

#[test(should_fail_with = "TIMELOCK_NOT_ELAPSED")]
unconstrained fn test_execute_clear_pair_slot_too_early_reverts() {
    let (mut env, factory_address, pair_address, t0, t1, admin) = setup_with_pair();
    let factory = SigalSwapFactory::at(factory_address);
    env.call_public(admin, factory.queue_clear_pair_slot(pair_address, t0, t1, 25, 0));
    env.call_public(admin, factory.execute_clear_pair_slot(pair_address, t0, t1, 25, 0));
}

#[test(should_fail_with = "ACTION_EXPIRED")]
unconstrained fn test_execute_clear_pair_slot_expired_reverts() {
    let (mut env, factory_address, pair_address, t0, t1, admin) = setup_with_pair();
    let factory = SigalSwapFactory::at(factory_address);
    env.call_public(admin, factory.queue_clear_pair_slot(pair_address, t0, t1, 25, 0));
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(PAST_EXPIRY_TIMESTAMP_ADVANCE);
    env.call_public(admin, factory.execute_clear_pair_slot(pair_address, t0, t1, 25, 0));
}

// --- set_pair_class_id (subsequent path) ---
//
// NOT_QUEUED is covered in registry.nr (the action_param composition is
// unique to this function and lives with the other class_id revert canaries).
// TIMELOCK_NOT_ELAPSED + ACTION_EXPIRED go here for symmetry with the other
// timelocked execute paths.

#[test(should_fail_with = "TIMELOCK_NOT_ELAPSED")]
unconstrained fn test_set_pair_class_id_subsequent_too_early_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    // Bootstrap immediate path at v1.
    env.call_public(admin, factory.set_pair_class_id(0xAAAA as Field, 1));
    // Queue v2; do NOT advance.
    env.call_public(admin, factory.queue_set_pair_class_id(0xBBBB as Field, 2));
    env.call_public(admin, factory.set_pair_class_id(0xBBBB as Field, 2));
}

#[test(should_fail_with = "ACTION_EXPIRED")]
unconstrained fn test_set_pair_class_id_subsequent_expired_reverts() {
    let (mut env, factory_address, admin) = setup();
    let factory = SigalSwapFactory::at(factory_address);
    env.call_public(admin, factory.set_pair_class_id(0xAAAA as Field, 1));
    env.call_public(admin, factory.queue_set_pair_class_id(0xBBBB as Field, 2));
    txe_oracles::advance_blocks_by(1);
    txe_oracles::advance_timestamp_by(PAST_EXPIRY_TIMESTAMP_ADVANCE);
    env.call_public(admin, factory.set_pair_class_id(0xBBBB as Field, 2));
}
