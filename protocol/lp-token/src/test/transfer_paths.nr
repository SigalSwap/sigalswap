use crate::{SigalSwapLPToken, test::utils::setup};
use aztec::protocol::{address::AztecAddress, traits::ToField};
use aztec::authwit::auth::compute_inner_authwit_hash;
use aztec::hash::hash_args;
use aztec::test::helpers::authwit::add_private_authwit_from_call;

// ============================================
// LP-token-side transfer / burn canaries
// ============================================
// The transfer family (`transfer`, `transfer_in_public`, `transfer_to_public`,
// `burn_private`, `prepare_private_balance_increase`+`finalize_transfer_to_private`)
// is exercised end-to-end via the pair's mint/swap/remove_liquidity flows in
// the core test suite. These canaries pin the lp-token-internal contract so
// a future refactor that splits gating between paths (helper extraction,
// partial-note shape change, authwit nonce handling) doesn't pass the
// pair-driven tests while breaking lp-token invariants silently. The
// `transfer` event-emission path is single-sourced (only `transfer` emits
// `LPTransfer`); without a direct canary, removing or generalizing that
// path would not be caught.

/// Seed `holder`'s private balance via the pair-only mint-to-private path.
/// Pair prepares the partial note (so the baked completer is `pair`) and
/// pair finalizes (msg_sender == completer matches). Mirrors the production
/// flow from `_add_liquidity` where the pair's private execution prepares
/// and its public continuation finalizes.
unconstrained fn seed_private_balance(
    env: aztec::test::helpers::test_environment::TestEnvironment,
    lp_address: AztecAddress,
    pair: AztecAddress,
    holder: AztecAddress,
    amount: u128,
) {
    let lp = SigalSwapLPToken::at(lp_address);
    let pn = env.call_private(pair, lp.prepare_private_balance_increase(holder));
    env.call_public(pair, lp.finalize_mint_to_private(amount, pn));
}

/// `transfer` is the only path that emits `LPTransfer`. A `transfer` from a
/// holder with sufficient private balance moves `amount` to the recipient.
///
/// State-only canary: this asserts balance + supply movement; it does NOT
/// directly verify `LPTransfer` emission. The aztec-nr `discover_event_at`
/// API that would let us assert emission is `pub(crate)` inside aztec-nr,
/// so it isn't callable from a contract test crate. Event emission is
/// observed end-to-end via the router fee-distribution traces in periphery
/// integration tests.
#[test]
unconstrained fn transfer_moves_balance_and_emits_lp_transfer() {
    let (mut env, lp_address, pair, _outsider) = setup();
    let lp = SigalSwapLPToken::at(lp_address);

    let holder = env.create_contract_account();
    let recipient = env.create_contract_account();

    seed_private_balance(env, lp_address, pair, holder, 1000 as u128);

    env.call_private(holder, lp.transfer(recipient, 400 as u128));

    let holder_bal: u128 = env.execute_utility(lp.balance_of_private(holder));
    assert_eq(holder_bal, 600 as u128);

    let recipient_bal: u128 = env.execute_utility(lp.balance_of_private(recipient));
    assert_eq(recipient_bal, 400 as u128);

    // Total supply unchanged; transfer is balance-conserving.
    let supply: u128 = env.view_public(lp.total_supply());
    assert_eq(supply, 1000 as u128);
}

/// `transfer_in_public` debits the sender, credits the recipient, and leaves
/// total supply untouched. Mirrors the standard ERC-20 public transfer
/// semantic.
#[test]
unconstrained fn transfer_in_public_round_trip() {
    let (mut env, lp_address, pair, _outsider) = setup();
    let lp = SigalSwapLPToken::at(lp_address);

    let sender = env.create_contract_account();
    let recipient = env.create_contract_account();

    env.call_public(pair, lp.mint_to_public(sender, 1000 as u128));
    assert_eq(env.view_public(lp.balance_of_public(sender)), 1000 as u128);

    // Self-call sends with nonce=0 (no authwit needed for own balance).
    env.call_public(sender, lp.transfer_in_public(sender, recipient, 250 as u128, 0));

    assert_eq(env.view_public(lp.balance_of_public(sender)), 750 as u128);
    assert_eq(env.view_public(lp.balance_of_public(recipient)), 250 as u128);
    assert_eq(env.view_public(lp.total_supply()), 1000 as u128);
}

/// `burn_private` debits the holder's private balance and decreases total
/// supply by the burned amount. The pair's `_remove_liquidity` flow drives
/// this in production; the canary here pins the lp-token-internal accounting.
#[test]
unconstrained fn burn_private_reduces_balance_and_supply() {
    let (mut env, lp_address, pair, _outsider) = setup();
    let lp = SigalSwapLPToken::at(lp_address);

    let holder = env.create_contract_account();
    seed_private_balance(env, lp_address, pair, holder, 1000 as u128);
    assert_eq(env.view_public(lp.total_supply()), 1000 as u128);

    // Self-burn: nonce=0 (no authwit needed since msg_sender == from).
    env.call_private(holder, lp.burn_private(holder, 400 as u128, 0));

    let bal: u128 = env.execute_utility(lp.balance_of_private(holder));
    assert_eq(bal, 600 as u128);

    let supply: u128 = env.view_public(lp.total_supply());
    assert_eq(supply, 600 as u128);
}

/// `transfer_to_public` flips a private balance into the recipient's public
/// balance and conserves total supply. The path is the public-spend ramp
/// for LPs that want to move their position through public DeFi.
#[test]
unconstrained fn transfer_to_public_flips_balance_conserves_supply() {
    let (mut env, lp_address, pair, _outsider) = setup();
    let lp = SigalSwapLPToken::at(lp_address);

    let holder = env.create_contract_account();
    let recipient = env.create_contract_account();

    seed_private_balance(env, lp_address, pair, holder, 1000 as u128);

    // Self-call: msg_sender == from, nonce=0 is fine.
    env.call_private(holder, lp.transfer_to_public(holder, recipient, 300 as u128, 0));

    let priv_bal: u128 = env.execute_utility(lp.balance_of_private(holder));
    assert_eq(priv_bal, 700 as u128);

    assert_eq(env.view_public(lp.balance_of_public(recipient)), 300 as u128);
    assert_eq(env.view_public(lp.total_supply()), 1000 as u128);
}

/// `prepare_private_balance_increase` + `finalize_transfer_to_private`
/// round-trip: the prepared partial note must be completed by the same
/// account that prepared the corresponding public-side debit. Calling
/// `finalize_transfer_to_private` from an outsider who never prepared a
/// matching partial note must revert (the public-side `from_balance.sub`
/// underflows since the outsider has no public balance to draw from).
#[test(should_fail)]
unconstrained fn finalize_transfer_to_private_mismatched_completer_reverts() {
    let (mut env, lp_address, _pair, outsider) = setup();
    let lp = SigalSwapLPToken::at(lp_address);

    let holder = env.create_contract_account();

    // Holder prepares a partial note for themselves. The completer in the
    // partial note is captured at preparation time as `holder` (the
    // msg_sender of `prepare_private_balance_increase`).
    let pn = env.call_private(holder, lp.prepare_private_balance_increase(holder));

    // Outsider attempts to finalize. `_finalize_transfer_to_private` reads
    // `msg_sender` and decrements that account's public balance -- outsider
    // has zero public balance, so the `sub(amount)` underflows.
    env.call_public(outsider, lp.finalize_transfer_to_private(100 as u128, pn));
}

// ============================================
// Edge cases: self-transfer and zero-amount
// ============================================
//
// Self-transfer (from == to) and zero-amount calls are degenerate inputs
// that no honest UI should produce, but malformed clients can. The
// canaries below pin the contract's response so accounting cannot drift
// into a state where (a) self-transfer leaks or duplicates balance, or
// (b) zero-amount calls quietly bypass an internal precondition that a
// later refactor depends on.

/// Self-transfer via `transfer` is balance-conserving. The path subtracts
/// from `from`, returns any change to `from`, and then adds `amount` to
/// `to`; when from == to those add-backs cancel the subtract, so the
/// holder's balance is unchanged. Total supply is also unchanged.
#[test]
unconstrained fn transfer_self_preserves_balance_and_supply() {
    let (mut env, lp_address, pair, _outsider) = setup();
    let lp = SigalSwapLPToken::at(lp_address);

    let holder = env.create_contract_account();
    seed_private_balance(env, lp_address, pair, holder, 1000 as u128);

    env.call_private(holder, lp.transfer(holder, 400 as u128));

    let bal: u128 = env.execute_utility(lp.balance_of_private(holder));
    assert_eq(bal, 1000 as u128);

    let supply: u128 = env.view_public(lp.total_supply());
    assert_eq(supply, 1000 as u128);
}

/// Zero-amount `transfer` reverts. `subtract_balance` calls `try_sub(0,
/// max_notes)` which consumes no notes and returns 0, then asserts
/// `subtracted > 0` with "Balance too low". This guards against a future
/// refactor that drops the assert and lets an empty subtract slip into
/// the add path -- where it would mint balance to `to` from nowhere.
#[test(should_fail_with = "Balance too low")]
unconstrained fn transfer_zero_amount_reverts() {
    let (mut env, lp_address, pair, _outsider) = setup();
    let lp = SigalSwapLPToken::at(lp_address);

    let holder = env.create_contract_account();
    let recipient = env.create_contract_account();
    seed_private_balance(env, lp_address, pair, holder, 1000 as u128);

    env.call_private(holder, lp.transfer(recipient, 0 as u128));
}

/// Zero-amount `transfer_in_public` is a no-op: `sub(0)` and `add(0)`
/// both leave the underlying public-balance Field unchanged, and total
/// supply is untouched. The path doesn't gate zero-amount, so this pins
/// the no-op semantics rather than a revert.
#[test]
unconstrained fn transfer_in_public_zero_amount_noop() {
    let (mut env, lp_address, pair, _outsider) = setup();
    let lp = SigalSwapLPToken::at(lp_address);

    let sender = env.create_contract_account();
    let recipient = env.create_contract_account();

    env.call_public(pair, lp.mint_to_public(sender, 1000 as u128));

    env.call_public(sender, lp.transfer_in_public(sender, recipient, 0 as u128, 0));

    assert_eq(env.view_public(lp.balance_of_public(sender)), 1000 as u128);
    assert_eq(env.view_public(lp.balance_of_public(recipient)), 0 as u128);
    assert_eq(env.view_public(lp.total_supply()), 1000 as u128);
}

/// Zero-amount `transfer_in_private` is a no-op: PrivateSet `sub(0)` and
/// `add(0)` deliver-no-op without altering the recipient's note set. Pin
/// the holder's private balance and total supply post-call.
#[test]
unconstrained fn transfer_in_private_zero_amount_noop() {
    let (mut env, lp_address, pair, _outsider) = setup();
    let lp = SigalSwapLPToken::at(lp_address);

    let sender = env.create_contract_account();
    let recipient = env.create_contract_account();
    seed_private_balance(env, lp_address, pair, sender, 1000 as u128);

    env.call_private(sender, lp.transfer_in_private(sender, recipient, 0 as u128, 0));

    let sender_bal: u128 = env.execute_utility(lp.balance_of_private(sender));
    assert_eq(sender_bal, 1000 as u128);

    let recipient_bal: u128 = env.execute_utility(lp.balance_of_private(recipient));
    assert_eq(recipient_bal, 0 as u128);

    let supply: u128 = env.view_public(lp.total_supply());
    assert_eq(supply, 1000 as u128);
}

/// Zero-amount `transfer_to_private` reverts at the partial-note layer.
/// The public-side `sub(0)` would succeed, but `_finalize_transfer_to_private`
/// completes a `PartialUintNote` whose framework-level invariant rejects a
/// zero value: aztec-nr asserts `value != 0` on completion. The canary pins
/// this behavior so a future framework change that relaxes the partial-note
/// guard doesn't silently let zero-value notes enter the LP-token's note
/// set, where they would clutter the recipient's set without representing
/// any real position.
#[test(should_fail_with = "Cannot complete a PartialUintNote with a value of 0")]
unconstrained fn transfer_to_private_zero_amount_reverts() {
    let (mut env, lp_address, _pair, _outsider) = setup();
    let lp = SigalSwapLPToken::at(lp_address);

    let sender = env.create_contract_account();
    let recipient = env.create_contract_account();

    env.call_private(sender, lp.transfer_to_private(recipient, 0 as u128));
}

// ============================================
// Multi-note recursion (subtract_balance -> _recurse_subtract_balance)
// ============================================
//
// Every canary above seeds a holder with a single note, so the first
// `try_sub` always satisfies the amount and `subtract_balance` returns via
// its base case (subtracted >= amount). The recursive arm
// (`_recurse_subtract_balance`, reached when one call's notes under-cover the
// amount) is never exercised. These canaries seed several distinct notes (one
// per mint-to-private finalize) so a `transfer` whose amount exceeds what
// INITIAL_TRANSFER_CALL_MAX_NOTES (2) notes can cover forces the recursion.
// They pin the change accumulation across recursion levels: a refactor that
// mis-accumulates change (adds change at each level, or returns the wrong
// remaining) would silently mint or burn private balance while passing every
// single-note canary above.

/// `transfer` across the recursion boundary. Holder has three value-10 notes
/// (total 30). A transfer of 25 exceeds what the 2 notes the initial call can
/// read cover, so it recurses once: try_sub(25, 2) consumes 20, recurse with
/// remaining 5, the recursive try_sub(5, 8) consumes the third note (10) and
/// returns change 5. Holder ends at 5, recipient at 25, supply unchanged.
#[test]
unconstrained fn transfer_recurses_across_multiple_notes() {
    let (mut env, lp_address, pair, _outsider) = setup();
    let lp = SigalSwapLPToken::at(lp_address);

    let holder = env.create_contract_account();
    let recipient = env.create_contract_account();

    // Three separate mint-to-private finalizes -> three distinct notes.
    seed_private_balance(env, lp_address, pair, holder, 10 as u128);
    seed_private_balance(env, lp_address, pair, holder, 10 as u128);
    seed_private_balance(env, lp_address, pair, holder, 10 as u128);

    env.call_private(holder, lp.transfer(recipient, 25 as u128));

    let holder_bal: u128 = env.execute_utility(lp.balance_of_private(holder));
    assert_eq(holder_bal, 5 as u128);

    let recipient_bal: u128 = env.execute_utility(lp.balance_of_private(recipient));
    assert_eq(recipient_bal, 25 as u128);

    let supply: u128 = env.view_public(lp.total_supply());
    assert_eq(supply, 30 as u128);
}

/// Self-transfer across the recursion boundary. Same three-note holder, but
/// `transfer(holder, 25)`. The recursion consumes the notes, returns change 5
/// to the holder, then adds 25 back to the holder; the net is a no-op
/// (balance and supply unchanged), confirming the change + amount re-credit
/// exactly conserve the holder's balance even through a recursion level.
#[test]
unconstrained fn transfer_self_recurses_preserves_balance() {
    let (mut env, lp_address, pair, _outsider) = setup();
    let lp = SigalSwapLPToken::at(lp_address);

    let holder = env.create_contract_account();
    seed_private_balance(env, lp_address, pair, holder, 10 as u128);
    seed_private_balance(env, lp_address, pair, holder, 10 as u128);
    seed_private_balance(env, lp_address, pair, holder, 10 as u128);

    env.call_private(holder, lp.transfer(holder, 25 as u128));

    let bal: u128 = env.execute_utility(lp.balance_of_private(holder));
    assert_eq(bal, 30 as u128);

    let supply: u128 = env.view_public(lp.total_supply());
    assert_eq(supply, 30 as u128);
}

// ============================================
// LP-exit fragmentation limit (>16-note positions)
// ============================================
//
// The pair's `remove_liquidity` debits the LP via `transfer_to_public`, which
// uses the framework's NON-recursive `BalanceSet::sub`. Unlike `transfer` (which
// recurses via `_recurse_subtract_balance`), `sub` reads at most
// MAX_NOTE_HASH_READ_REQUESTS_PER_CALL (16 in v4.3.0) notes in a single call.
// Each `add_liquidity` mints exactly one note, so a holder who built a position
// across more than 16 adds cannot exit the FULL position in one call: the 16
// readable notes under-cover the amount and `sub` reverts "Balance too low".
// This is a self-inflicted, recoverable condition (no external attacker, no
// value loss) -- documented in lp-token/README.md and the SDK removeLiquidity
// docstring -- but it had no regression guard. These two canaries pin both the
// limit and the documented chunked-exit recovery, so a future framework cap
// change or a path refactor that silently breaks (or silently masks) LP exits
// is caught.

/// 17 notes of value 10 (total 170). A full-position `transfer_to_public(170)`
/// can read only 16 notes (=160 < 170) and reverts "Balance too low".
#[test(should_fail_with = "Balance too low")]
unconstrained fn transfer_to_public_full_exit_over_16_notes_reverts() {
    let (mut env, lp_address, pair, _outsider) = setup();
    let lp = SigalSwapLPToken::at(lp_address);

    let holder = env.create_contract_account();
    let recipient = env.create_contract_account();

    for _ in 0..17 {
        seed_private_balance(env, lp_address, pair, holder, 10 as u128);
    }

    env.call_private(holder, lp.transfer_to_public(holder, recipient, 170 as u128, 0));
}

/// Documented recovery for the >16-note limit: exit in chunks each covered by
/// <= 16 notes. Chunk 1 (160) consumes the 16 readable notes; chunk 2 (10) exits
/// the 17th. The full position reaches the recipient's public balance and total
/// supply is conserved -- a fragmented LP can always recover by chunking.
#[test]
unconstrained fn transfer_to_public_chunked_exit_over_16_notes_succeeds() {
    let (mut env, lp_address, pair, _outsider) = setup();
    let lp = SigalSwapLPToken::at(lp_address);

    let holder = env.create_contract_account();
    let recipient = env.create_contract_account();

    for _ in 0..17 {
        seed_private_balance(env, lp_address, pair, holder, 10 as u128);
    }

    env.call_private(holder, lp.transfer_to_public(holder, recipient, 160 as u128, 0));
    env.call_private(holder, lp.transfer_to_public(holder, recipient, 10 as u128, 0));

    let holder_bal: u128 = env.execute_utility(lp.balance_of_private(holder));
    assert_eq(holder_bal, 0 as u128);

    assert_eq(env.view_public(lp.balance_of_public(recipient)), 170 as u128);
    assert_eq(env.view_public(lp.total_supply()), 170 as u128);
}

// ============================================
// cancel_authwit: revoke a previously-issued authwit
// ============================================
//
// `cancel_authwit(inner_hash)` lets an owner pre-emptively burn the authwit
// nullifier for a specific action, so a third party that was granted that
// authwit can no longer consume it. The nullifier is
// `compute_authwit_nullifier(msg_sender, inner_hash)`, the exact value the
// `#[authorize_once]` macro would push when the authorized call is consumed
// (see aztec-nr `assert_inner_hash_valid_authwit`). By pushing it first, the
// owner makes the later consumption attempt a double-spend of that nullifier,
// which reverts. This is the only test of `cancel_authwit` protocol-wide.
//
// We use `transfer_in_private` (a `#[authorize_once("from","authwit_nonce")]`
// private path) as the action being revoked. The inner hash is recomputed the
// same way `add_private_authwit_from_call` derives it:
//   inner_hash = compute_inner_authwit_hash([caller, selector, hash_args(args)])
// where `caller` is the authorized third party (operator) and `args` are the
// transfer_in_private arguments. We register the authwit, cancel it, then have
// the operator attempt the transfer.
//
// `should_fail` (rather than a pinned string): the consumption attempt pushes a
// nullifier that already exists in the tree (inserted by cancel_authwit), so the
// revert originates in the kernel/protocol layer as a duplicate-nullifier
// rejection whose exact wording is framework-version-dependent. Pinning the
// property (the cancelled authwit cannot be used) is the goal, not the string.

/// Owner grants operator an authwit to move the owner's private LP via
/// `transfer_in_private`, then `cancel_authwit` revokes it; the operator's
/// subsequent transfer attempt fails because the cancellation already consumed
/// (nullified) that authwit's inner hash.
#[test(should_fail)]
unconstrained fn cancel_authwit_blocks_subsequent_use() {
    let (mut env, lp_address, pair, _outsider) = setup();
    let lp = SigalSwapLPToken::at(lp_address);

    let owner = env.create_contract_account();
    let operator = env.create_contract_account();
    let recipient = env.create_contract_account();

    // Owner holds private LP that the operator would move on their behalf.
    seed_private_balance(env, lp_address, pair, owner, 1000 as u128);

    // The action the operator is being authorized for: pull 400 of owner's
    // private LP to `recipient`. AUTHWIT_NONCE is any nonzero nonce (0 is
    // reserved for self-calls that bypass authwit).
    let authwit_nonce: Field = 1;
    let transfer_call =
        lp.transfer_in_private(owner, recipient, 400 as u128, authwit_nonce);

    // Recompute the inner hash exactly as add_private_authwit_from_call does,
    // binding the operator as the authorized caller.
    let inner_hash = compute_inner_authwit_hash([
        operator.to_field(),
        transfer_call.selector.to_field(),
        hash_args(transfer_call.args),
    ]);

    // Owner authorizes the operator for this call.
    add_private_authwit_from_call(env, owner, operator, transfer_call);

    // Owner revokes it: cancel_authwit runs as the owner (msg_sender == owner),
    // pushing compute_authwit_nullifier(owner, inner_hash).
    env.call_private(owner, lp.cancel_authwit(inner_hash));

    // Operator now attempts the authorized transfer. Consuming the authwit
    // would push the SAME nullifier the cancel already inserted -> revert.
    env.call_private(
        operator,
        lp.transfer_in_private(owner, recipient, 400 as u128, authwit_nonce),
    );
}

// ============================================
// finalize_transfer_to_private_from_private
// ============================================
//
// `finalize_transfer_to_private_from_private(from, partial_note, amount,
// authwit_nonce)` subtracts `amount` from `from`'s PRIVATE balance and then
// completes a previously prepared `PartialUintNote` from private state,
// crediting the note's recipient. It is the all-private analogue of the
// public `finalize_transfer_to_private` ramp: the debit side lives in the
// note set rather than `public_balances`, and the credit side completes the
// partial note via `complete_from_private` (the completer is the call's
// msg_sender, which must match the account that prepared the partial note).
//
// The function has zero internal callers and had zero tests protocol-wide.
// These two tests exercise it end-to-end.

/// Self-finalize (from == completer, nonce 0): the holder prepares a partial
/// note for `recipient`, then finalizes it against their own private balance.
/// Because msg_sender == from, the authorize_once gate is satisfied with
/// nonce 0 (no authwit needed). The holder's private balance drops by `amount`,
/// the recipient's rises by `amount`, and total supply is conserved (this path
/// moves balance, it does not mint or burn).
///
/// This is the reliable canary on the function's core mechanic (private
/// subtract + complete_from_private) -- it uses a single authwit-free private
/// finalize, so it does not depend on TXE's multi-call authwit-state tracking.
#[test]
unconstrained fn finalize_transfer_to_private_from_private_self_moves_balance() {
    let (mut env, lp_address, pair, _outsider) = setup();
    let lp = SigalSwapLPToken::at(lp_address);

    let holder = env.create_contract_account();
    let recipient = env.create_contract_account();

    seed_private_balance(env, lp_address, pair, holder, 1000 as u128);

    // Holder prepares the partial note for the recipient. The completer baked
    // into the note is the prepare msg_sender = holder, which must match the
    // finalize msg_sender below.
    let pn = env.call_private(holder, lp.prepare_private_balance_increase(recipient));

    // Self-finalize: msg_sender == from == holder, so nonce 0 bypasses authwit.
    env.call_private(
        holder,
        lp.finalize_transfer_to_private_from_private(holder, pn, 300 as u128, 0),
    );

    let holder_bal: u128 = env.execute_utility(lp.balance_of_private(holder));
    assert_eq(holder_bal, 700 as u128);

    let recipient_bal: u128 = env.execute_utility(lp.balance_of_private(recipient));
    assert_eq(recipient_bal, 300 as u128);

    let supply: u128 = env.view_public(lp.total_supply());
    assert_eq(supply, 1000 as u128);
}

// Third-party-authorized finalize (completer != from, via authwit) is NOT run
// as a TXE #[test]. The intended scenario: `from` seeds 1000 private LP; the
// `completer` prepares a partial note for `recipient`; `from` authorizes the
// completer (add_private_authwit_from_call) to run
// finalize_transfer_to_private_from_private(from, pn, 250, nonce); the completer
// executes it, leaving from = 750, recipient = 250, supply = 1000.
//
// TXE cannot reproduce this: the cross-account partial note prepared by the
// completer is not retrievable inside the finalize call's context (the call
// reverts with "Failed to get a note"), the same TXE note-state limitation the
// periphery suite documents for multi-call private sequences. The function's
// core subtract-and-complete mechanic IS exercised end-to-end by the self-path
// test above (from == completer), and the body is byte-identical to the
// vendored v4.3.0 reference Token's finalize_transfer_to_private_from_private,
// so the authwit hop is the only untested delta.
