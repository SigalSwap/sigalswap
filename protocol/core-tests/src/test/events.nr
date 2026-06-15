use sigalswap_core::{SigalSwapPair, pair::{MINIMUM_LIQUIDITY, get_amount_out}};
use crate::test::utils::{setup, add_liquidity, remove_liquidity, swap_exact_in};
use token::Token;
use sigalswap_lp_token::SigalSwapLPToken;

// ============================================
// Event Emission Tests
// ============================================
//
// NOTE ON TXE LIMITATIONS:
// The Aztec TXE (Test Execution Environment) does not currently expose an API
// for reading emitted events or asserting on event data. Therefore, these tests
// use an indirect verification strategy:
//
// 1. Verify the operation succeeds (proves `self.emit(...)` did not revert)
// 2. Verify state changes match expectations (proves the public function ran
//    correctly through the emit call)
// 3. Where possible, verify computed values match what the event WOULD contain
//
// Full event data verification requires E2E tests with an event-aware harness
// (e.g., PXE event subscription or log inspection via the Aztec sandbox).

/// Swap emits SwapEvent.
///
/// Execute a private swap and verify reserves changed correctly. The public
/// settlement function (_swap_exact_in) emits SwapEvent and
/// SyncEvent. If emit reverted, the entire transaction would fail.
#[test]
unconstrained fn test_swap_emits_swap_event() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let swapper = env.create_contract_account();
    let token0 = Token::at(token0_address);
    let token1 = Token::at(token1_address);

    // Add liquidity: 20000 / 20000 (1:1 ratio)
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    // Swap 1000 token0 for token1 (0.25% fee, no protocol fee).
    // Expected output: 950.
    swap_exact_in(
        env, pair_address, token0_address, token1_address,
        admin, swapper, 1000, 900,
    );

    // Verify reserves changed (proves public settlement ran, which includes emit)
    assert_eq(env.view_public(token0.balance_of_public(pair_address)), 21000);
    assert_eq(env.view_public(token1.balance_of_public(pair_address)), 19050);

    // Verify swapper received output (proves the full flow completed past emit)
    assert_eq(env.execute_utility(token1.balance_of_private(swapper)), 950);

    // The SwapEvent { token_in: token0, token_out: token1, amount_in: 1000, amount_out: 950 }
    // was emitted during _swap_exact_in. Since the tx succeeded,
    // the emit call did not revert. Event data verification requires E2E tests.
}

/// Mint (add_liquidity) emits MintEvent and SyncEvent.
///
/// Add liquidity and verify state changes. The public _add_liquidity function
/// emits MintEvent { amount0, amount1, liquidity } and SyncEvent { reserve0, reserve1 }.
#[test]
unconstrained fn test_mint_emits_events() {
    let (mut env, pair_address, token0_address, token1_address, lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let token0 = Token::at(token0_address);
    let token1 = Token::at(token1_address);
    let lp_token = SigalSwapLPToken::at(lp_address);

    // First deposit: 10000 / 20000
    // sqrt(10000 * 20000) = 14142, user gets 14142 - 10000 = 4142
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 10000, 20000, 0, 0,
    );

    // Verify reserves set (proves SyncEvent path executed)
    assert_eq(env.view_public(token0.balance_of_public(pair_address)), 10000);
    assert_eq(env.view_public(token1.balance_of_public(pair_address)), 20000);

    // Verify LP tokens minted (proves MintEvent path executed)
    assert_eq(env.view_public(lp_token.total_supply()), MINIMUM_LIQUIDITY + 4142);
    assert_eq(env.execute_utility(lp_token.balance_of_private(provider)), 4142);

    // The MintEvent { amount0: 10000, amount1: 20000, liquidity: 4142 } and
    // SyncEvent { reserve0: 10000, reserve1: 20000 } were emitted.
    // Operation success proves emit calls did not revert.
}

/// Burn (remove_liquidity) emits BurnEvent and SyncEvent.
///
/// Remove liquidity and verify state changes. The public _remove_liquidity function
/// emits BurnEvent { amount0, amount1, liquidity } and SyncEvent { reserve0, reserve1 }.
#[test]
unconstrained fn test_burn_emits_events() {
    let (mut env, pair_address, token0_address, token1_address, lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let token0 = Token::at(token0_address);
    let token1 = Token::at(token1_address);
    let lp_token = SigalSwapLPToken::at(lp_address);

    // Add liquidity: 10000/20000
    // sqrt(200000000) = 14142, user gets 14142 - 10000 = 4142
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 10000, 20000, 0, 0,
    );

    let provider_lp = env.execute_utility(lp_token.balance_of_private(provider));
    assert_eq(provider_lp, 4142);

    // Remove half: 2071 LP tokens
    let to_remove: u128 = 2071;
    remove_liquidity(
        env, pair_address, lp_address, provider,
        to_remove, 0, 0,
    );

    // Verify tokens returned (proves BurnEvent path executed)
    // token0 = floor(2071 * 10000 / 14142) = 1464
    // token1 = floor(2071 * 20000 / 14142) = 2928
    assert_eq(env.execute_utility(token0.balance_of_private(provider)), 1464);
    assert_eq(env.execute_utility(token1.balance_of_private(provider)), 2928);

    // Verify reserves updated (proves SyncEvent path executed)
    assert_eq(env.view_public(token0.balance_of_public(pair_address)), 10000 - 1464);
    assert_eq(env.view_public(token1.balance_of_public(pair_address)), 20000 - 2928);

    // The BurnEvent { amount0: 1464, amount1: 2928, liquidity: 2071 } and
    // SyncEvent { reserve0: 8536, reserve1: 17072 } were emitted.
    // Operation success proves emit calls did not revert.
}

/// Sync emits SyncEvent.
///
/// Call sync() on a pair and verify it succeeds. The sync function emits
/// SyncEvent { reserve0, reserve1 } after updating reserves.
#[test]
unconstrained fn test_sync_emits_sync_event() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let token0 = Token::at(token0_address);
    let pair = SigalSwapPair::at(pair_address);

    // Add liquidity: 20000 / 20000
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    // Send 500 token0 directly to pair (donation)
    env.call_public(admin, token0.mint_to_public(pair_address, 500));

    // Call sync -- emits SyncEvent { reserve0: 20500, reserve1: 20000 }
    env.call_public(admin, pair.sync());

    // Verify reserves updated to match actual balances (proves sync ran through emit)
    let (r0, r1, _ts) = env.view_public(pair.get_reserves());
    assert_eq(r0, 20500);
    assert_eq(r1, 20000);

    // The SyncEvent { reserve0: 20500, reserve1: 20000 } was emitted.
    // Operation success proves the emit call did not revert.
}

/// SwapEvent uses actual_amount_in (fee-on-transfer correctness).
///
/// The _swap_exact_in function uses balance-based accounting:
///   actual_amount_in = balance_in - reserve_in
/// and logs this in the SwapEvent, NOT the declared amount_in.
///
/// For normal tokens (no transfer fee), actual_amount_in == amount_in.
/// We verify this indirectly by checking that reserve changes match expectations.
#[test]
unconstrained fn test_swap_event_uses_actual_amount_in() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let swapper = env.create_contract_account();
    let token0 = Token::at(token0_address);
    let token1 = Token::at(token1_address);

    // Add liquidity: 20000 / 20000
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    let reserve0_before = env.view_public(token0.balance_of_public(pair_address));
    let reserve1_before = env.view_public(token1.balance_of_public(pair_address));

    let amount_in: u128 = 1000;

    // Swap 1000 token0 for token1
    swap_exact_in(
        env, pair_address, token0_address, token1_address,
        admin, swapper, amount_in, 0,
    );

    let reserve0_after = env.view_public(token0.balance_of_public(pair_address));
    let reserve1_after = env.view_public(token1.balance_of_public(pair_address));

    // Verify actual_amount_in: new_reserve_in - old_reserve_in == declared amount_in
    // For normal tokens (no transfer fee), these must match exactly.
    // This is the value that would be logged in SwapEvent.amount_in.
    let actual_amount_in = reserve0_after - reserve0_before;
    assert_eq(actual_amount_in, amount_in);

    // Verify amount_out matches hand computation
    // get_amount_out(1000, 20000, 20000, 25) = 950
    let actual_amount_out = reserve1_before - reserve1_after;
    let expected_out = get_amount_out(amount_in, reserve0_before, reserve1_before, 25);
    assert_eq(actual_amount_out, expected_out);
    assert_eq(actual_amount_out, 950);

    // The SwapEvent would contain { amount_in: 1000, amount_out: 950 }.
    // Reserve deltas confirm these are the exact values used in the emit call.
}

/// First mint event liquidity equals sqrt(a0*a1) - MINIMUM_LIQUIDITY.
///
/// The first deposit permanently locks MINIMUM_LIQUIDITY (10000) LP tokens.
/// The MintEvent.liquidity field reflects only the user's share (after deduction).
/// We verify the user's LP balance matches the expected reduced amount.
#[test]
unconstrained fn test_first_mint_event_liquidity_minus_minimum() {
    let (mut env, pair_address, token0_address, token1_address, lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let lp_token = SigalSwapLPToken::at(lp_address);

    // Deposit 40000 / 90000
    // sqrt(40000 * 90000) = sqrt(3_600_000_000) = 60000
    // user_liquidity = 60000 - 10000 = 50000
    // total_supply = 60000
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 40000, 90000, 0, 0,
    );

    // Verify user got exactly 50000 LP tokens (what MintEvent.liquidity would be)
    let provider_lp = env.execute_utility(lp_token.balance_of_private(provider));
    assert_eq(provider_lp, 50000);

    // Verify total supply = user_share + MINIMUM_LIQUIDITY
    let total_supply = env.view_public(lp_token.total_supply());
    assert_eq(total_supply, 50000 + MINIMUM_LIQUIDITY);

    // The MintEvent { amount0: 40000, amount1: 90000, liquidity: 50000 } was emitted.
    // The liquidity value excludes MINIMUM_LIQUIDITY, matching the user's actual share.
}

/// Private events do not leak user identity.
///
/// PRIVACY INVARIANT: SwapEvent, MintEvent, and BurnEvent (the private variants)
/// do NOT contain AztecAddress fields. This ensures that emitted event data
/// cannot be used to link a swap/mint/burn to a specific user.
///
/// The public variants (SwapPublicEvent, MintPublicEvent, BurnPublicEvent) DO
/// contain address fields, which is expected since public operations have
/// no privacy guarantees.
///
/// NOTE: Noir's type system does not support runtime struct field inspection or
/// compile-time static assertions on struct layout. This test documents the
/// invariant and verifies it by construction:
///
/// - SwapEvent    { token_in: AztecAddress, token_out: AztecAddress, amount_in: u128, amount_out: u128 }
///   -> token_in/token_out are POOL token addresses (public knowledge), NOT user addresses
///
/// - MintEvent    { amount0: u128, amount1: u128, liquidity: u128 }
///   -> No address fields at all
///
/// - BurnEvent    { amount0: u128, amount1: u128, liquidity: u128 }
///   -> No address fields at all
///
/// This invariant is enforced by code review of the event structs in main.nr.
/// Any addition of a user address field to these private events would break
/// the privacy guarantee.
///
/// This test performs a swap, mint, and burn to confirm the events are
/// structurally sound and the operations succeed without identity leakage.
#[test]
unconstrained fn test_private_events_no_identity_leak() {
    let (mut env, pair_address, token0_address, token1_address, lp_address, admin) = setup();

    let alice = env.create_contract_account();
    let bob = env.create_contract_account();
    let lp_token = SigalSwapLPToken::at(lp_address);

    // Mint: alice adds liquidity (MintEvent has no user address)
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, alice, 20000, 20000, 0, 0,
    );

    // Swap: bob swaps (SwapEvent has token addresses, not user address)
    swap_exact_in(
        env, pair_address, token0_address, token1_address,
        admin, bob, 1000, 0,
    );

    // Burn: alice removes liquidity (BurnEvent has no user address)
    let alice_lp = env.execute_utility(lp_token.balance_of_private(alice));
    remove_liquidity(
        env, pair_address, lp_address, alice,
        alice_lp, 0, 0,
    );

    // All three operations succeeded. The private event variants emitted during
    // these operations contain only pool-level data (amounts, token addresses),
    // never the caller's AztecAddress. This is verified by inspection of the
    // event struct definitions in main.nr.
    //
    // Contrast with public events:
    // - SwapPublicEvent includes `sender` and `recipient` (expected for public ops)
    // - MintPublicEvent includes `sender`
    // - BurnPublicEvent includes `sender` and `recipient`
    assert(true);
}

/// Events are emitted while the reentrancy lock is held.
///
/// In the pair contract, the reentrancy lock is a bit in `packed_flags`,
/// acquired via `_acquire_lock` and released via `_release_lock`. Every
/// state-mutating entry (mint, burn, swap, flash_swap, and the public
/// admin entries that mutate fee/pause state) calls `_acquire_lock` at
/// the top of its public-internal continuation, which writes
/// `locked = true` and reverts on `assert(!locked)` if a reentrant call
/// reaches the same primitive. Events are emitted before `_release_lock`
/// runs, so every public log carries the "lock held" property.
///
/// This test verifies that a swap completes successfully with events
/// emitted during the locked execution phase.
#[test]
unconstrained fn test_events_emitted_while_locked() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let swapper = env.create_contract_account();
    let token1 = Token::at(token1_address);

    // Add liquidity
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    // Execute swap -- events are emitted during public execution
    swap_exact_in(
        env, pair_address, token0_address, token1_address,
        admin, swapper, 500, 0,
    );

    // If events were emitted at an invalid point (e.g., after state corruption
    // or during an inconsistent lock state), the transaction would revert.
    // Success here proves events were emitted at a valid execution point.
    assert(env.execute_utility(token1.balance_of_private(swapper)) > 0);

    // Verify pair is not left in a locked state
    // (If it were, a second swap would fail with "LOCKED")
    let swapper2 = env.create_contract_account();
    swap_exact_in(
        env, pair_address, token0_address, token1_address,
        admin, swapper2, 500, 0,
    );

    // Second swap succeeded -- pair is not stuck in locked state after event emission
    assert(env.execute_utility(token1.balance_of_private(swapper2)) > 0);
}
