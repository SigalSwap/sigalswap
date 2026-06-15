// TXE-level router <-> pair integration tests.
//
// Scope and rationale
// -------------------
// These tests are a canary for the chain
// `user -> router (private) -> _execute_one_hop_* (public) ->
// pair.swap_exact_*_public -> router.swap_payment_callback`. A bug
// anywhere on this path surfaces here in seconds instead of taking
// minutes of SDK-E2E walltime. In particular, the pair's
// callback-target blocklist must NOT reject `callback_contract ==
// recipient`, because the router legitimately passes
// `(self.address, self.address)` for both fields -- if a future change
// adds `recipient` to the blocklist, the canary tests below fail with
// a different message, flagging the bug immediately.
//
// TXE limitation: full happy-path tests that seed liquidity via the
// existing `add_liquidity(...)` helper (which grants authwits under
// AUTHWIT_NONCE for the provider) and then attempt a subsequent swap
// authwit for a different account produce a `Nullifier read request at
// index 5 is reading an unknown nullifier` error during private
// simulation. The same swap flow works fine in isolation (confirmed by
// running `swap_exact_in` with no liquidity and observing the expected
// `INSUFFICIENT_LIQUIDITY` revert from the pair), so the router/pair
// plumbing is correct; the issue is in TXE's authwit state tracking
// across multiple `env.call_private` calls in a single test process.
//
// We work around this by testing revert paths that exercise the router
// end-to-end without needing seeded liquidity:
//   - The no-liquidity `INSUFFICIENT_LIQUIDITY` revert proves the full
//     callback validation chain in the pair runs without hitting
//     INVALID_CALLBACK_TARGET, which is the canary signal described
//     above.
//   - The expired-deadline revert proves the router's public continuation
//     is reached and its `context.timestamp() <= deadline` check fires.
//
// Happy-path + amount-correctness tests live in SDK E2E
// (`packages/sdk/src/e2e/`), which uses the real sandbox and doesn't share
// TXE's authwit-state quirk.

use sigalswap_periphery::{SigalSwapRouter, libraries::MAX_HOPS};
use crate::test::utils::{
    add_liquidity, setup_abusive_pair, setup_multi_hop, setup_single_pair,
    setup_unregistered_pair, AUTHWIT_NONCE,
};
use abusive_pair::AbusivePair;
use aztec::{
    protocol::{address::AztecAddress, traits::ToField},
    test::helpers::{
        authwit::add_private_authwit_from_call, test_environment::TestEnvironment,
    },
};
use token::Token;

// Large deadline passes TXE's synthetic-clock check for non-deadline tests.
global FAR_FUTURE_DEADLINE: u64 = 0xffffffff_ffffffff;

// Zero interface fee; the router caps at 500 bps regardless.
global NO_FEE_BIPS: u32 = 0;

// ============================================
// Callback-validation canary
// ============================================
//
// Without a `callback != recipient` assertion on the pair side, the swap
// below reverts with `INSUFFICIENT_LIQUIDITY` (no reserves seeded). If
// such an assertion were added, the pair would revert earlier with
// `INVALID_CALLBACK_TARGET` because the router passes
// `(self.address, self.address)` as `(recipient, callback_contract)`.
// A `should_fail_with` on `INSUFFICIENT_LIQUIDITY` therefore acts as
// the canary: adding an over-broad recipient check breaks this test
// with a different message, flagging the bug at TXE speed.

#[test(should_fail_with = "INSUFFICIENT_LIQUIDITY")]
unconstrained fn test_router_exact_in_reaches_pair_math() {
    let (mut env, router_address, pair_address, token0_address, token1_address, _lp, admin) =
        setup_single_pair();

    let swapper = env.create_contract_account();
    let token0 = Token::at(token0_address);

    env.call_private(admin, token0.mint_to_private(swapper, 1000));
    let transfer_call = token0.transfer_to_public(
        swapper, router_address, 1000 as u128, AUTHWIT_NONCE,
    );
    add_private_authwit_from_call(env, swapper, router_address, transfer_call);

    let router = SigalSwapRouter::at(router_address);
    env.call_private(swapper, router.swap_exact_in(
        pair_address, token0_address, token1_address,
        1000 as u128, 1 as u128, FAR_FUTURE_DEADLINE, AUTHWIT_NONCE,
        AztecAddress::zero(), NO_FEE_BIPS,
    ));
}

#[test(should_fail_with = "INSUFFICIENT_LIQUIDITY")]
unconstrained fn test_router_exact_out_reaches_pair_math() {
    let (mut env, router_address, pair_address, token0_address, token1_address, _lp, admin) =
        setup_single_pair();

    let swapper = env.create_contract_account();
    let token0 = Token::at(token0_address);

    env.call_private(admin, token0.mint_to_private(swapper, 1000));
    let transfer_call = token0.transfer_to_public_and_prepare_private_balance_increase(
        swapper, router_address, 1000 as u128, AUTHWIT_NONCE,
    );
    add_private_authwit_from_call(env, swapper, router_address, transfer_call);

    let router = SigalSwapRouter::at(router_address);
    env.call_private(swapper, router.swap_exact_out(
        pair_address, token0_address, token1_address,
        500 as u128, 1000 as u128, FAR_FUTURE_DEADLINE, AUTHWIT_NONCE,
        AztecAddress::zero(), NO_FEE_BIPS,
    ));
}

// ============================================
// Deadline-expired revert
// ============================================

#[test(should_fail_with = "EXPIRED")]
unconstrained fn test_router_exact_in_expired_deadline_reverts() {
    let (mut env, router_address, pair_address, token0_address, token1_address, _lp, admin) =
        setup_single_pair();

    let swapper = env.create_contract_account();
    let token0 = Token::at(token0_address);

    env.call_private(admin, token0.mint_to_private(swapper, 1000));
    let transfer_call = token0.transfer_to_public(
        swapper, router_address, 1000 as u128, AUTHWIT_NONCE,
    );
    add_private_authwit_from_call(env, swapper, router_address, transfer_call);

    let router = SigalSwapRouter::at(router_address);
    // Deadline of 1 is deeply in the past under TXE's synthetic clock; the
    // public continuation's `timestamp() <= deadline` check reverts EXPIRED
    // before the swap math runs.
    env.call_private(swapper, router.swap_exact_in(
        pair_address, token0_address, token1_address,
        1000 as u128, 1 as u128, 1 as u64, AUTHWIT_NONCE,
        AztecAddress::zero(), NO_FEE_BIPS,
    ));
}

// ============================================
// Address-mismatch canaries
// ============================================
//
// The router's add/remove-liquidity public continuations verify that
// the caller-supplied `token0` / `token1` / `liquidity_token` match the
// pair's authoritative values (via `pair.get_config()` and
// `pair.get_lp_token()`). Without these checks a malicious SDK could
// pass an attacker-controlled `liquidity_token`; the real pair would
// still mint real LP into the router's balance on the real LP Token
// (with no withdrawal path), and the user's private LP note would be
// finalized against the attacker's contract -- the deposit is lost.
// The wrong-token0/token1 variants are self-correcting post the pair's
// balance-delta check (no real deposit -> NO_TOKEN0_DEPOSIT), but these
// router-side asserts turn that indirect revert into an explicit
// TOKEN0_MISMATCH / TOKEN1_MISMATCH error at the boundary.
//
// Tests pass a valid-but-wrong Token contract as the mismatched
// argument so the private leg's transfer/prepare calls don't fail
// first for "contract not found" reasons -- the point is to reach the
// public continuation's assertion.

#[test(should_fail_with = "LP_TOKEN_MISMATCH")]
unconstrained fn test_router_add_liquidity_wrong_lp_token_reverts() {
    let (mut env, router_address, pair_address, token0_address, token1_address, _lp, admin) =
        setup_single_pair();

    let provider = env.create_contract_account();
    let token0 = Token::at(token0_address);
    let token1 = Token::at(token1_address);
    let router = SigalSwapRouter::at(router_address);

    env.call_private(admin, token0.mint_to_private(provider, 100000));
    env.call_private(admin, token1.mint_to_private(provider, 100000));

    // V2-router pattern: tokens are pulled from user into the router's
    // own public balance (not the pair's). Authwits target the router.
    let transfer0 = token0.transfer_to_public_and_prepare_private_balance_increase(
        provider, router_address, 100000 as u128, AUTHWIT_NONCE,
    );
    add_private_authwit_from_call(env, provider, router_address, transfer0);

    let transfer1 = token1.transfer_to_public_and_prepare_private_balance_increase(
        provider, router_address, 100000 as u128, AUTHWIT_NONCE,
    );
    add_private_authwit_from_call(env, provider, router_address, transfer1);

    // Pass token0 as liquidity_token: it is a valid Token contract (so the
    // private prepare_private_balance_increase dispatch succeeds), but it
    // is not the pair's real LP. The public continuation reverts at the
    // LP_TOKEN_MISMATCH assertion.
    env.call_private(provider, router.add_liquidity(
        pair_address, token0_address, token1_address,
        token0_address,
        100000 as u128, 100000 as u128, 0 as u128, 0 as u128,
        FAR_FUTURE_DEADLINE, AUTHWIT_NONCE,
    ));
}

// TOKEN0_MISMATCH / TOKEN1_MISMATCH are not covered by TXE tests.
// Exercising those asserts requires passing a *valid Token contract* as
// the wrong-position argument so the private leg's
// `transfer_to_public_and_prepare_private_balance_increase` dispatches
// successfully, which in turn requires the user to authwit-authorize that
// transfer. TXE's nullifier-tree state tracking is unreliable in the
// presence of two transfer-and-prepare authwit calls to different token
// contracts in the same tx -- the second call surfaces as "Nullifier
// read request at index N is reading an unknown nullifier" during
// private simulation. The same private-leg pattern works fine against
// the real sandbox; the TXE-only workaround would require either a
// tailored test harness or accepting no TXE coverage for these asserts.
// The verification infrastructure (pair.get_config() view call, the
// assertion block in _add_liquidity_single / _remove_liquidity_single)
// is covered by the LP_TOKEN_MISMATCH tests above and below; the
// TOKEN0_MISMATCH / TOKEN1_MISMATCH asserts use the exact same pattern
// just against different fields of the fetched PairConfig.

#[test(should_fail_with = "LP_TOKEN_MISMATCH")]
unconstrained fn test_router_remove_liquidity_wrong_lp_token_reverts() {
    let (mut env, router_address, pair_address, token0_address, token1_address, _lp, admin) =
        setup_single_pair();

    // No pool seeding needed: the LP_TOKEN_MISMATCH assert fires at the
    // router boundary before the pair's burn is attempted. Provider just
    // needs some token0 balance so the private-leg fake-LP transfer
    // dispatches successfully and the tx reaches the public continuation.
    let provider = env.create_contract_account();
    let token0 = Token::at(token0_address);
    let router = SigalSwapRouter::at(router_address);

    env.call_private(admin, token0.mint_to_private(provider, 1000));

    let transfer_as_lp = token0.transfer_to_public(
        provider, pair_address, 1000 as u128, AUTHWIT_NONCE,
    );
    add_private_authwit_from_call(env, provider, router_address, transfer_as_lp);

    // Pass token0 as liquidity_token. Public continuation asserts
    // liquidity_token == pair.get_lp_token() and reverts LP_TOKEN_MISMATCH.
    env.call_private(provider, router.remove_liquidity(
        pair_address, token0_address, token1_address,
        token0_address,
        1000 as u128, 0 as u128, 0 as u128,
        FAR_FUTURE_DEADLINE, AUTHWIT_NONCE,
    ));
}

// ============================================
// Exact-out multi-hop: cycle-to-final rejection
// ============================================
//
// The path validator rejects paths where the final output token appears
// anywhere earlier in the path -- `[A, B, C, A]` (cycle to initial) and
// `[A, B, C, B]` (hub-routing) both break the router's per-token refund
// logic. These tests exercise the private entry directly and assert the
// revert fires at the validator before any authwit consumption or token
// movement.

fn build_path(
    tokens: [AztecAddress],
) -> [AztecAddress; MAX_HOPS + 1] {
    let mut out: [AztecAddress; MAX_HOPS + 1] = [AztecAddress::zero(); MAX_HOPS + 1];
    for i in 0..MAX_HOPS + 1 {
        if i < tokens.len() {
            out[i] = tokens[i];
        }
    }
    out
}

fn build_pairs(
    addrs: [AztecAddress],
) -> [AztecAddress; MAX_HOPS] {
    let mut out: [AztecAddress; MAX_HOPS] = [AztecAddress::zero(); MAX_HOPS];
    for i in 0..MAX_HOPS {
        if i < addrs.len() {
            out[i] = addrs[i];
        }
    }
    out
}

#[test(should_fail_with = "FINAL_TOKEN_REPEATED")]
unconstrained fn test_router_exact_out_cyclic_path_reverts() {
    let (mut env, router_address, pair_ab, pair_bc, token_a, token_b, token_c, _admin) =
        setup_multi_hop();
    let router = SigalSwapRouter::at(router_address);
    let caller = env.create_contract_account();

    // [A, B, C, A] -- triangular cycle. pair[2] doesn't exist (there's
    // no C/A pair in setup_multi_hop); the validator rejects before
    // any pair interaction or authwit consumption.
    let path = build_path(&[token_a, token_b, token_c, token_a]);
    let pairs = build_pairs(&[pair_ab, pair_bc, AztecAddress::zero()]);

    env.call_private(caller, router.swap_exact_out_multi_hop(
        path, pairs, 4,
        100 as u128, 1000 as u128,
        FAR_FUTURE_DEADLINE, AUTHWIT_NONCE,
        AztecAddress::zero(), NO_FEE_BIPS,
    ));
}

#[test(should_fail_with = "FINAL_TOKEN_REPEATED")]
unconstrained fn test_router_exact_out_hub_path_reverts() {
    let (mut env, router_address, pair_ab, pair_bc, token_a, token_b, token_c, _admin) =
        setup_multi_hop();
    let router = SigalSwapRouter::at(router_address);
    let caller = env.create_contract_account();

    // [A, B, C, B] -- B appears as intermediate AND as final. Validator
    // rejects before any pair interaction.
    let path = build_path(&[token_a, token_b, token_c, token_b]);
    let pairs = build_pairs(&[pair_ab, pair_bc, AztecAddress::zero()]);

    env.call_private(caller, router.swap_exact_out_multi_hop(
        path, pairs, 4,
        100 as u128, 1000 as u128,
        FAR_FUTURE_DEADLINE, AUTHWIT_NONCE,
        AztecAddress::zero(), NO_FEE_BIPS,
    ));
}

// ============================================
// skim_to: permissionless stuck-balance recovery
// ============================================

/// Donating tokens to the router and then skimming them out works end to end:
/// router's balance moves to the recipient, recipient ends up holding the
/// donated amount in their public balance. Permissionless -- the caller is
/// neither the donor nor an admin.
#[test]
unconstrained fn test_router_skim_to_succeeds_with_donated_balance() {
    let (mut env, router_address, _pair, token0_address, _token1, _lp, admin) =
        setup_single_pair();

    let recipient = env.create_contract_account();
    let token0 = Token::at(token0_address);

    // Donor (admin) directly funds the router's public balance.
    env.call_public(admin, token0.mint_to_public(router_address, 12345 as u128));

    // Sanity: router holds the donation, recipient does not.
    assert_eq(env.view_public(token0.balance_of_public(router_address)), 12345 as u128);
    assert_eq(env.view_public(token0.balance_of_public(recipient)), 0 as u128);

    // Anyone can skim. Use a fresh account to prove no privileged caller is needed.
    let bystander = env.create_contract_account();
    let router = SigalSwapRouter::at(router_address);
    env.call_public(bystander, router.skim_to(token0_address, recipient));

    assert_eq(env.view_public(token0.balance_of_public(router_address)), 0 as u128);
    assert_eq(env.view_public(token0.balance_of_public(recipient)), 12345 as u128);
}

/// skim_to rejects the zero recipient: tokens transferred to address(0) are
/// permanently locked, so we fail-fast at the SDK boundary rather than letting
/// the caller silently nuke them.
#[test(should_fail_with = "ZERO_RECIPIENT")]
unconstrained fn test_router_skim_to_zero_recipient_reverts() {
    let (mut env, router_address, _pair, token0_address, _token1, _lp, admin) =
        setup_single_pair();
    let token0 = Token::at(token0_address);
    env.call_public(admin, token0.mint_to_public(router_address, 100 as u128));

    let router = SigalSwapRouter::at(router_address);
    env.call_public(admin, router.skim_to(token0_address, AztecAddress::zero()));
}

/// skim_to rejects calls when the router holds no balance of `token`. Caller
/// can pre-check via balance_of_public; surfacing the assertion here keeps
/// "successful skim" and "no-op skim" distinguishable.
#[test(should_fail_with = "NO_BALANCE")]
unconstrained fn test_router_skim_to_zero_balance_reverts() {
    let (mut env, router_address, _pair, token0_address, _token1, _lp, admin) =
        setup_single_pair();

    let recipient = env.create_contract_account();
    let router = SigalSwapRouter::at(router_address);
    // Router has zero token0 -- skim should revert.
    env.call_public(admin, router.skim_to(token0_address, recipient));
}

// ============================================
// swap_payment_callback adversarial canaries
// ============================================
//
// The router's swap_payment_callback is the most security-critical
// surface in the contract: it lets a pair pull tokens from the router's
// public balance during an active swap. Five assertions guard it. Each
// test below pins one assertion's failure mode so a change that weakens
// any of them surfaces here. Tests 1-2-4-5 use the AbusivePair fixture
// (modes 0, 1, 2, 3); test 3 dials the router's own callback directly
// from a fresh account.

/// Mode 0: pair callbacks for 2x amount_in_max. Router asserts
/// amount <= expected_callback_amount and reverts.
#[test(should_fail_with = "EXCESSIVE_CALLBACK_AMOUNT")]
unconstrained fn test_router_callback_overcharge_reverts() {
    let (mut env, router_address, abusive_pair_address, token0_address, token1_address, admin) =
        setup_abusive_pair();

    let abusive_pair = AbusivePair::at(abusive_pair_address);
    env.call_public(
        admin,
        abusive_pair.set_abuse_mode(0, AztecAddress::zero(), AztecAddress::zero()),
    );

    let swapper = env.create_contract_account();
    let token0 = Token::at(token0_address);
    env.call_private(admin, token0.mint_to_private(swapper, 1000));
    let transfer_call = token0.transfer_to_public_and_prepare_private_balance_increase(
        swapper, router_address, 1000 as u128, AUTHWIT_NONCE,
    );
    add_private_authwit_from_call(env, swapper, router_address, transfer_call);

    let router = SigalSwapRouter::at(router_address);
    env.call_private(swapper, router.swap_exact_out(
        abusive_pair_address, token0_address, token1_address,
        500 as u128, 1000 as u128, FAR_FUTURE_DEADLINE, AUTHWIT_NONCE,
        AztecAddress::zero(), NO_FEE_BIPS,
    ));
}

/// Mode 1: pair callbacks for the wrong token. Router asserts
/// token == expected_callback_token and reverts.
#[test(should_fail_with = "UNEXPECTED_TOKEN")]
unconstrained fn test_router_callback_wrong_token_reverts() {
    let (mut env, router_address, abusive_pair_address, token0_address, token1_address, admin) =
        setup_abusive_pair();

    let abusive_pair = AbusivePair::at(abusive_pair_address);
    // Wrong token is token1; expected is token0 (the swap input). Mode 1.
    env.call_public(
        admin,
        abusive_pair.set_abuse_mode(1, token1_address, AztecAddress::zero()),
    );

    let swapper = env.create_contract_account();
    let token0 = Token::at(token0_address);
    env.call_private(admin, token0.mint_to_private(swapper, 1000));
    let transfer_call = token0.transfer_to_public_and_prepare_private_balance_increase(
        swapper, router_address, 1000 as u128, AUTHWIT_NONCE,
    );
    add_private_authwit_from_call(env, swapper, router_address, transfer_call);

    let router = SigalSwapRouter::at(router_address);
    env.call_private(swapper, router.swap_exact_out(
        abusive_pair_address, token0_address, token1_address,
        500 as u128, 1000 as u128, FAR_FUTURE_DEADLINE, AUTHWIT_NONCE,
        AztecAddress::zero(), NO_FEE_BIPS,
    ));
}

/// No pair, no swap. A bystander dials the callback directly. The
/// router's hop_active flag is false outside an active swap, so the
/// first assertion fires.
#[test(should_fail_with = "NO_ACTIVE_HOP")]
unconstrained fn test_swap_payment_callback_outside_swap_reverts() {
    let mut env = TestEnvironment::new();
    let admin = env.create_contract_account();
    let router_init = SigalSwapRouter::interface().constructor(admin);
    let router_address =
        env.deploy("@sigalswap_periphery/SigalSwapRouter").with_public_initializer(admin, router_init);

    let bystander = env.create_contract_account();
    let router = SigalSwapRouter::at(router_address);
    env.call_public(bystander, router.swap_payment_callback(
        AztecAddress::zero().to_field(),
        AztecAddress::zero().to_field(),
        0 as Field,
    ));
}

/// Mode 2: pair callbacks with `pair = wrong_pair_address` (a different
/// address) while msg_sender remains the abusive pair. Router asserts
/// msg_sender == pair_addr and reverts.
#[test(should_fail_with = "UNAUTHORIZED_CALLBACK")]
unconstrained fn test_swap_payment_callback_wrong_pair_reverts() {
    let (mut env, router_address, abusive_pair_address, token0_address, token1_address, admin) =
        setup_abusive_pair();

    // wrong_pair = admin's address: any value distinct from abusive_pair_address
    // will trip the assertion. Using `admin` keeps the fixture inputs simple.
    let abusive_pair = AbusivePair::at(abusive_pair_address);
    env.call_public(
        admin,
        abusive_pair.set_abuse_mode(2, AztecAddress::zero(), admin),
    );

    let swapper = env.create_contract_account();
    let token0 = Token::at(token0_address);
    env.call_private(admin, token0.mint_to_private(swapper, 1000));
    let transfer_call = token0.transfer_to_public_and_prepare_private_balance_increase(
        swapper, router_address, 1000 as u128, AUTHWIT_NONCE,
    );
    add_private_authwit_from_call(env, swapper, router_address, transfer_call);

    let router = SigalSwapRouter::at(router_address);
    env.call_private(swapper, router.swap_exact_out(
        abusive_pair_address, token0_address, token1_address,
        500 as u128, 1000 as u128, FAR_FUTURE_DEADLINE, AUTHWIT_NONCE,
        AztecAddress::zero(), NO_FEE_BIPS,
    ));
}

/// Mode 4: pair invokes the callback twice within one hop. Each callback
/// individually clears the router's `<= expected_callback_amount` check;
/// the cumulative consumption blows past the amount the router was
/// authorized to spend. The refund subtraction `amount_in_max - consumed`
/// would underflow at the bytecode level (Noir panic with no labeled
/// message) -- the `assert(consumed <= amount_in_max,
/// "CONSUMED_EXCEEDS_REQUESTED")` guard converts it to a labeled revert.
///
/// Reachable only when the router holds pre-existing balance >= a second
/// `amount_in_max` of `token_in` so both callback transfers succeed; this
/// test mints that balance to the router public ahead of the swap to
/// simulate stuck-dust / donation conditions.
#[test(should_fail_with = "CONSUMED_EXCEEDS_REQUESTED")]
unconstrained fn test_router_callback_double_invoke_reverts() {
    let (mut env, router_address, abusive_pair_address, token0_address, token1_address, admin) =
        setup_abusive_pair();

    let abusive_pair = AbusivePair::at(abusive_pair_address);
    env.call_public(
        admin,
        abusive_pair.set_abuse_mode(4, AztecAddress::zero(), AztecAddress::zero()),
    );

    // Pre-fund router with an additional `amount_in_max` of token0 so the
    // second callback's transfer_in_public succeeds. Without this the test
    // reverts on insufficient balance instead of reaching the refund
    // subtraction guard.
    let token0 = Token::at(token0_address);
    env.call_public(admin, token0.mint_to_public(router_address, 1000 as u128));

    let swapper = env.create_contract_account();
    env.call_private(admin, token0.mint_to_private(swapper, 1000));
    let transfer_call = token0.transfer_to_public_and_prepare_private_balance_increase(
        swapper, router_address, 1000 as u128, AUTHWIT_NONCE,
    );
    add_private_authwit_from_call(env, swapper, router_address, transfer_call);

    let router = SigalSwapRouter::at(router_address);
    env.call_private(swapper, router.swap_exact_out(
        abusive_pair_address, token0_address, token1_address,
        500 as u128, 1000 as u128, FAR_FUTURE_DEADLINE, AUTHWIT_NONCE,
        AztecAddress::zero(), NO_FEE_BIPS,
    ));
}

/// Mode 3: pair callbacks with a Field amount > u128::MAX. Router's
/// `amount as u128 as Field == amount` round-trip fails because the
/// truncation produces a different Field value than the original.
#[test(should_fail_with = "AMOUNT_OVERFLOW")]
unconstrained fn test_swap_payment_callback_amount_overflow_reverts() {
    let (mut env, router_address, abusive_pair_address, token0_address, token1_address, admin) =
        setup_abusive_pair();

    let abusive_pair = AbusivePair::at(abusive_pair_address);
    env.call_public(
        admin,
        abusive_pair.set_abuse_mode(3, AztecAddress::zero(), AztecAddress::zero()),
    );

    let swapper = env.create_contract_account();
    let token0 = Token::at(token0_address);
    env.call_private(admin, token0.mint_to_private(swapper, 1000));
    let transfer_call = token0.transfer_to_public_and_prepare_private_balance_increase(
        swapper, router_address, 1000 as u128, AUTHWIT_NONCE,
    );
    add_private_authwit_from_call(env, swapper, router_address, transfer_call);

    let router = SigalSwapRouter::at(router_address);
    env.call_private(swapper, router.swap_exact_out(
        abusive_pair_address, token0_address, token1_address,
        500 as u128, 1000 as u128, FAR_FUTURE_DEADLINE, AUTHWIT_NONCE,
        AztecAddress::zero(), NO_FEE_BIPS,
    ));
}

// ============================================
// PAIR_NOT_REGISTERED: factory-registry trust boundary
// ============================================
//
// Each of the 6 router entries that take a `pair` (or `pairs[]`) argument
// queries the factory's `get_pair_versioned_public` view to confirm that
// the pair is the registered routing target for its self-reported
// (token0, token1, fee_tier_bps, version) slot. Without the check, a
// fully-fabricated pair contract whose `get_config()` returns
// internally-consistent lies could pass the router's pair-side address
// assertions; the factory's registry is the only authoritative source
// that can refute such a pair.
//
// `setup_unregistered_pair` deploys a real pair stack but skips the
// MockFactory registration step, so every router-mediated entry below
// reaches the factory check and trips PAIR_NOT_REGISTERED. A change that
// drops the factory query from any of the 6 entries surfaces here as
// a different revert reason (e.g. INSUFFICIENT_LIQUIDITY for swap entries,
// LP_TOKEN_MISMATCH for liquidity entries).

#[test(should_fail_with = "PAIR_NOT_REGISTERED")]
unconstrained fn test_router_add_liquidity_unregistered_pair_reverts() {
    let (mut env, router_address, pair_address, token0_address, token1_address, _lp, admin) =
        setup_unregistered_pair();

    let provider = env.create_contract_account();
    let token0 = Token::at(token0_address);
    let token1 = Token::at(token1_address);
    let router = SigalSwapRouter::at(router_address);

    env.call_private(admin, token0.mint_to_private(provider, 100000));
    env.call_private(admin, token1.mint_to_private(provider, 100000));

    let transfer0 = token0.transfer_to_public_and_prepare_private_balance_increase(
        provider, router_address, 100000 as u128, AUTHWIT_NONCE,
    );
    add_private_authwit_from_call(env, provider, router_address, transfer0);
    let transfer1 = token1.transfer_to_public_and_prepare_private_balance_increase(
        provider, router_address, 100000 as u128, AUTHWIT_NONCE,
    );
    add_private_authwit_from_call(env, provider, router_address, transfer1);

    // Pass `token0_address` as `liquidity_token`. The factory check fires
    // before any LP_TOKEN_MISMATCH check, and `liquidity_token` only enters
    // the private-leg flow as the prepare_private_balance_increase target
    // for LP refund -- using a real-but-wrong Token contract there avoids
    // the TXE nullifier-tracking quirk that surfaces when the LP partial
    // note's prepare collides with the two preceding token authwits.
    env.call_private(provider, router.add_liquidity(
        pair_address, token0_address, token1_address, token0_address,
        100000 as u128, 100000 as u128, 0 as u128, 0 as u128,
        FAR_FUTURE_DEADLINE, AUTHWIT_NONCE,
    ));
}

#[test(should_fail_with = "PAIR_NOT_REGISTERED")]
unconstrained fn test_router_remove_liquidity_unregistered_pair_reverts() {
    let (mut env, router_address, pair_address, token0_address, token1_address, _lp, admin) =
        setup_unregistered_pair();

    let provider = env.create_contract_account();
    let token0 = Token::at(token0_address);
    let router = SigalSwapRouter::at(router_address);

    // Pass `token0_address` as `liquidity_token` so the private leg's
    // `Token::at(liquidity_token).transfer_to_public(...)` dispatches against
    // a contract the user has minted balance on, and the matching authwit
    // is registered for that exact target. The router's factory check fires
    // in the public continuation BEFORE any LP_TOKEN_MISMATCH check, so the
    // wrong-but-real liquidity_token here is sufficient -- we just need the
    // private leg to succeed so execution reaches the public continuation.
    env.call_private(admin, token0.mint_to_private(provider, 1000));
    let transfer = token0.transfer_to_public(
        provider, pair_address, 1000 as u128, AUTHWIT_NONCE,
    );
    add_private_authwit_from_call(env, provider, router_address, transfer);

    env.call_private(provider, router.remove_liquidity(
        pair_address, token0_address, token1_address, token0_address,
        1000 as u128, 0 as u128, 0 as u128,
        FAR_FUTURE_DEADLINE, AUTHWIT_NONCE,
    ));
}

#[test(should_fail_with = "PAIR_NOT_REGISTERED")]
unconstrained fn test_router_swap_exact_in_unregistered_pair_reverts() {
    let (mut env, router_address, pair_address, token0_address, token1_address, _lp, admin) =
        setup_unregistered_pair();

    let swapper = env.create_contract_account();
    let token0 = Token::at(token0_address);
    env.call_private(admin, token0.mint_to_private(swapper, 1000));
    let transfer = token0.transfer_to_public(
        swapper, router_address, 1000 as u128, AUTHWIT_NONCE,
    );
    add_private_authwit_from_call(env, swapper, router_address, transfer);

    let router = SigalSwapRouter::at(router_address);
    env.call_private(swapper, router.swap_exact_in(
        pair_address, token0_address, token1_address,
        1000 as u128, 1 as u128, FAR_FUTURE_DEADLINE, AUTHWIT_NONCE,
        AztecAddress::zero(), NO_FEE_BIPS,
    ));
}

#[test(should_fail_with = "PAIR_NOT_REGISTERED")]
unconstrained fn test_router_swap_exact_out_unregistered_pair_reverts() {
    let (mut env, router_address, pair_address, token0_address, token1_address, _lp, admin) =
        setup_unregistered_pair();

    let swapper = env.create_contract_account();
    let token0 = Token::at(token0_address);
    env.call_private(admin, token0.mint_to_private(swapper, 1000));
    let transfer = token0.transfer_to_public_and_prepare_private_balance_increase(
        swapper, router_address, 1000 as u128, AUTHWIT_NONCE,
    );
    add_private_authwit_from_call(env, swapper, router_address, transfer);

    let router = SigalSwapRouter::at(router_address);
    env.call_private(swapper, router.swap_exact_out(
        pair_address, token0_address, token1_address,
        500 as u128, 1000 as u128, FAR_FUTURE_DEADLINE, AUTHWIT_NONCE,
        AztecAddress::zero(), NO_FEE_BIPS,
    ));
}

#[test(should_fail_with = "PAIR_NOT_REGISTERED")]
unconstrained fn test_router_swap_exact_in_multi_hop_unregistered_pair_reverts() {
    let (mut env, router_address, pair_address, token0_address, token1_address, _lp, admin) =
        setup_unregistered_pair();

    let swapper = env.create_contract_account();
    let token0 = Token::at(token0_address);
    env.call_private(admin, token0.mint_to_private(swapper, 1000));
    let transfer = token0.transfer_to_public(
        swapper, router_address, 1000 as u128, AUTHWIT_NONCE,
    );
    add_private_authwit_from_call(env, swapper, router_address, transfer);

    let path = build_path(&[token0_address, token1_address]);
    let pairs = build_pairs(&[pair_address]);

    let router = SigalSwapRouter::at(router_address);
    env.call_private(swapper, router.swap_exact_in_multi_hop(
        path, pairs, 2,
        1000 as u128, 1 as u128, FAR_FUTURE_DEADLINE, AUTHWIT_NONCE,
        AztecAddress::zero(), NO_FEE_BIPS,
    ));
}

#[test(should_fail_with = "PAIR_NOT_REGISTERED")]
unconstrained fn test_router_swap_exact_out_multi_hop_unregistered_pair_reverts() {
    let (mut env, router_address, pair_address, token0_address, token1_address, _lp, admin) =
        setup_unregistered_pair();

    let swapper = env.create_contract_account();
    let token0 = Token::at(token0_address);
    env.call_private(admin, token0.mint_to_private(swapper, 1000));
    let transfer = token0.transfer_to_public_and_prepare_private_balance_increase(
        swapper, router_address, 1000 as u128, AUTHWIT_NONCE,
    );
    add_private_authwit_from_call(env, swapper, router_address, transfer);

    let path = build_path(&[token0_address, token1_address]);
    let pairs = build_pairs(&[pair_address]);

    let router = SigalSwapRouter::at(router_address);
    env.call_private(swapper, router.swap_exact_out_multi_hop(
        path, pairs, 2,
        500 as u128, 1000 as u128, FAR_FUTURE_DEADLINE, AUTHWIT_NONCE,
        AztecAddress::zero(), NO_FEE_BIPS,
    ));
}

/// fee_recipient == router_address would make the interface-fee transfer a
/// no-op self-transfer while still subtracting fee_amount from the user's
/// output, leaking the difference into router public balance for
/// permissionless skim. The boundary assert closes the footgun cleanly.
#[test(should_fail_with = "FEE_RECIPIENT_IS_ROUTER")]
unconstrained fn test_router_swap_fee_recipient_is_router_reverts() {
    let (mut env, router_address, pair_address, token0_address, token1_address, _lp, admin) =
        setup_single_pair();

    let swapper = env.create_contract_account();
    let token0 = Token::at(token0_address);
    env.call_private(admin, token0.mint_to_private(swapper, 1000));
    let transfer = token0.transfer_to_public(
        swapper, router_address, 1000 as u128, AUTHWIT_NONCE,
    );
    add_private_authwit_from_call(env, swapper, router_address, transfer);

    let router = SigalSwapRouter::at(router_address);
    env.call_private(swapper, router.swap_exact_in(
        pair_address, token0_address, token1_address,
        1000 as u128, 1 as u128, FAR_FUTURE_DEADLINE, AUTHWIT_NONCE,
        router_address, // fee_recipient == router; the new assert reverts here
        100, // 1% interface fee, well within MAX_INTERFACE_FEE_BIPS
    ));
}

/// path = [A, B, C] but pairs = [pair_AB, pair_AB] -- pair[1]'s config has
/// tokens (A, B) but path[2] = C is in neither slot. Factory verification
/// passes (pair_AB IS registered); the new path-token assert catches the
/// mismatch at the router boundary instead of letting it revert deeper at
/// the pair's TOKEN_IN_IS_INVALID one hop later. The path-token check lives
/// in the public continuation (it reads each pair's config), so this test
/// must set up the token-pull authwit even though the call reverts before
/// any swap math runs.
#[test(should_fail_with = "PATH_TOKEN_MISMATCH")]
unconstrained fn test_router_multi_hop_path_token_mismatch_reverts() {
    let (mut env, router_address, pair_ab, _pair_bc, token_a, token_b, token_c, admin) =
        setup_multi_hop();
    let router = SigalSwapRouter::at(router_address);
    let swapper = env.create_contract_account();

    let token_a_handle = Token::at(token_a);
    env.call_private(admin, token_a_handle.mint_to_private(swapper, 1000));
    let transfer = token_a_handle.transfer_to_public(
        swapper, router_address, 100 as u128, AUTHWIT_NONCE,
    );
    add_private_authwit_from_call(env, swapper, router_address, transfer);

    let path = build_path(&[token_a, token_b, token_c]);
    let pairs = build_pairs(&[pair_ab, pair_ab, AztecAddress::zero()]);

    env.call_private(swapper, router.swap_exact_in_multi_hop(
        path, pairs, 3,
        100 as u128, 1 as u128,
        FAR_FUTURE_DEADLINE, AUTHWIT_NONCE,
        AztecAddress::zero(), NO_FEE_BIPS,
    ));
}

/// amount_in = 0 should fail-fast at the boundary so the user's authwit
/// nonce isn't burned on a no-op call. Representative canary for the
/// ZERO_INPUT_AMOUNT family of asserts; the same shape applies to
/// swap_exact_out (amount_in_max), the multi-hop variants, and add_liquidity
/// (both amount_max args).
#[test(should_fail_with = "ZERO_INPUT_AMOUNT")]
unconstrained fn test_router_swap_exact_in_zero_amount_reverts() {
    let (mut env, router_address, pair_address, token0_address, token1_address, _lp, _admin) =
        setup_single_pair();
    let swapper = env.create_contract_account();

    let router = SigalSwapRouter::at(router_address);
    env.call_private(swapper, router.swap_exact_in(
        pair_address, token0_address, token1_address,
        0 as u128, 0 as u128, FAR_FUTURE_DEADLINE, AUTHWIT_NONCE,
        AztecAddress::zero(), NO_FEE_BIPS,
    ));
}

/// amount_out = 0 on swap_exact_out should fail-fast at the boundary.
/// Sibling of test_router_swap_exact_in_zero_amount_reverts; ZERO_OUTPUT_AMOUNT
/// is its own assert family (swap_exact_out + swap_exact_out_multi_hop)
/// distinct from the ZERO_INPUT_AMOUNT family above.
#[test(should_fail_with = "ZERO_OUTPUT_AMOUNT")]
unconstrained fn test_router_swap_exact_out_zero_amount_reverts() {
    let (mut env, router_address, pair_address, token0_address, token1_address, _lp, _admin) =
        setup_single_pair();
    let swapper = env.create_contract_account();

    let router = SigalSwapRouter::at(router_address);
    env.call_private(swapper, router.swap_exact_out(
        pair_address, token0_address, token1_address,
        0 as u128, 1000 as u128, FAR_FUTURE_DEADLINE, AUTHWIT_NONCE,
        AztecAddress::zero(), NO_FEE_BIPS,
    ));
}

/// liquidity = 0 on remove_liquidity should fail-fast at the boundary so the
/// user's authwit nonce isn't burned on a doomed call. Without the assert,
/// the LP transfer no-ops, partial notes prepare, and the public continuation
/// eventually reverts with the pair's INSUFFICIENT_0_AMOUNT after consuming
/// all setup costs. Mirrors the ZERO_INPUT_AMOUNT / ZERO_OUTPUT_AMOUNT family.
#[test(should_fail_with = "ZERO_LIQUIDITY")]
unconstrained fn test_router_remove_liquidity_zero_amount_reverts() {
    let (mut env, router_address, pair_address, token0_address, token1_address, lp_address, _admin) =
        setup_single_pair();
    let provider = env.create_contract_account();

    let router = SigalSwapRouter::at(router_address);
    env.call_private(provider, router.remove_liquidity(
        pair_address, token0_address, token1_address, lp_address,
        0 as u128, 0 as u128, 0 as u128, FAR_FUTURE_DEADLINE, AUTHWIT_NONCE,
    ));
}

/// `(fee_bips > 0, fee_recipient = zero)` should fail-fast at validate_interface_fee_bips.
/// Without the new INVALID_FEE_CONFIG assert, the swap would proceed through
/// the private leg, the public continuation's `_deduct_interface_fee` would
/// short-circuit (silently waiving the fee), and the user would receive the
/// gross output -- frontend operator records expected revenue that never
/// arrived. The assert closes the misconfiguration footgun at the boundary
/// before authwit consumption.
#[test(should_fail_with = "INVALID_FEE_CONFIG")]
unconstrained fn test_router_swap_fee_bips_with_zero_recipient_reverts() {
    let (mut env, router_address, pair_address, token0_address, token1_address, _lp, _admin) =
        setup_single_pair();
    let swapper = env.create_contract_account();

    let router = SigalSwapRouter::at(router_address);
    env.call_private(swapper, router.swap_exact_in(
        pair_address, token0_address, token1_address,
        1000 as u128, 1 as u128, FAR_FUTURE_DEADLINE, AUTHWIT_NONCE,
        AztecAddress::zero(), // recipient = zero, but bps > 0 below
        100, // 1% interface fee
    ));
}

/// `factory = zero` at construction must revert. PublicImmutable.initialize
/// would otherwise commit to an unrecoverable bad value -- every
/// factory-verification round-trip would dispatch to a non-existent contract
/// and revert opaquely on every router entry. The constructor's ZERO_FACTORY
/// assert closes the deployer-typo footgun cleanly.
#[test(should_fail_with = "ZERO_FACTORY")]
unconstrained fn test_router_constructor_zero_factory_reverts() {
    let mut env = TestEnvironment::new();
    let admin = env.create_contract_account();
    let router_init = SigalSwapRouter::interface().constructor(AztecAddress::zero());
    let _router_address = env.deploy("@sigalswap_periphery/SigalSwapRouter").with_public_initializer(admin, router_init);
}
