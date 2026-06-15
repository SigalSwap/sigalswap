// SPDX-License-Identifier: MIT
// Copyright (c) 2026 SigalSwap LLC

// SigalSwap Router Libraries
// Utility functions for the router contract.

use aztec::protocol::{address::AztecAddress, traits::{FromField, ToField}};

/// Maximum number of hops in a multi-hop swap path.
/// path_length = hops + 1 (e.g., A->B->C = 2 hops, path_length = 3)
pub global MAX_HOPS: u32 = 3;

/// Maximum interface fee the router will honor on any single swap, in basis
/// points (100 bps = 1%). Applied to the swap's output token after the final
/// hop. Capped here so a hostile frontend can't silently extract more than
/// a reasonable fee. Matches or beats consumer DEX norms (typically 0-100 bps).
pub global MAX_INTERFACE_FEE_BIPS: u32 = 500;

/// Sort two token addresses into canonical (token0, token1) order.
/// token0 is always the address with the smaller Field value.
/// This ensures (A,B) and (B,A) resolve to the same pair.
pub fn sort_tokens(token_a: AztecAddress, token_b: AztecAddress) -> (AztecAddress, AztecAddress) {
    assert(token_a != token_b, "IDENTICAL_TOKENS");
    assert(token_a != AztecAddress::zero(), "ZERO_ADDRESS");
    assert(token_b != AztecAddress::zero(), "ZERO_ADDRESS");

    if token_a.to_field() as u128 < token_b.to_field() as u128 {
        (token_a, token_b)
    } else {
        (token_b, token_a)
    }
}

/// Validate that `path_length` is in `[2, MAX_HOPS + 1]`. A length of 2 is
/// a single-hop path (one pair between token_in and token_out); the upper
/// bound is the router's fixed-size path array capacity.
pub fn validate_path_length(path_length: u32) {
    assert(path_length >= 2, "PATH_TOO_SHORT");
    assert(path_length <= (MAX_HOPS + 1) as u32, "PATH_TOO_LONG");
}

/// Validate the interface fee config: bps within `[0, MAX_INTERFACE_FEE_BIPS]`,
/// and recipient non-zero whenever bps > 0. The two-arg shape catches the
/// `(fee_bips > 0, fee_recipient = zero)` misconfiguration where the router's
/// `_deduct_interface_fee` short-circuit would silently waive the fee --
/// user receives gross output, frontend operator records expected fee
/// revenue that never arrived, no error signal. Reverting at the entry
/// surfaces the misconfiguration explicitly. The `(fee_bips = 0, recipient =
/// zero)` "skip fee" case remains the canonical opt-out.
pub fn validate_interface_fee_bips(fee_bips: u32, fee_recipient: AztecAddress) {
    assert(fee_bips <= MAX_INTERFACE_FEE_BIPS, "FEE_BIPS_TOO_HIGH");
    if fee_bips > 0 {
        assert(!fee_recipient.is_zero(), "INVALID_FEE_CONFIG");
    }
}

/// For exact-output multi-hop swaps only: assert that the final token
/// (`path[path_length - 1]`) does not appear anywhere else in the path.
///
/// Exact-output's per-hop refund logic uses balance-based measurement on
/// token0 (unused input) and on each intermediate token (any dust left
/// after the hop consumed it). When the final output token is also the
/// initial input or any intermediate, those refund loops drain the same
/// balance the final-output send is about to read, and the final-output
/// assertion fires on a zero balance. The whole tx reverts.
///
/// Exact-input doesn't have this issue (no change-refund step; input is
/// fully consumed at hop 0 and the final token is measured cleanly), so
/// this check is scoped to exact-out only. Triangular arbitrage
/// (e.g., `[A, B, C, A]`) remains possible via exact-input.
pub fn validate_path_no_cycle_to_final(
    path: [AztecAddress; MAX_HOPS + 1],
    path_length: u32,
) {
    let final_idx = path_length - 1;
    let final_token = path[final_idx];
    for i in 0..MAX_HOPS {
        if i < final_idx {
            assert(path[i] != final_token, "FINAL_TOKEN_REPEATED");
        }
    }
}

// ============================================
// Unit Tests
// ============================================

#[test]
fn test_sort_tokens_already_sorted() {
    let a = AztecAddress::from_field(100);
    let b = AztecAddress::from_field(200);
    let (t0, t1) = sort_tokens(a, b);
    assert(t0 == a);
    assert(t1 == b);
}

#[test]
fn test_sort_tokens_reversed() {
    let a = AztecAddress::from_field(100);
    let b = AztecAddress::from_field(200);
    let (t0, t1) = sort_tokens(b, a);
    assert(t0 == a);
    assert(t1 == b);
}

#[test]
fn test_sort_tokens_commutative() {
    let a = AztecAddress::from_field(555);
    let b = AztecAddress::from_field(111);
    let (t0_ab, t1_ab) = sort_tokens(a, b);
    let (t0_ba, t1_ba) = sort_tokens(b, a);
    assert(t0_ab == t0_ba);
    assert(t1_ab == t1_ba);
}

#[test]
fn test_sort_tokens_large_addresses() {
    let a = AztecAddress::from_field(0xFFFFFFFFFFFFFFFF);
    let b = AztecAddress::from_field(1);
    let (t0, t1) = sort_tokens(a, b);
    assert(t0 == b);
    assert(t1 == a);
}

#[test(should_fail_with = "IDENTICAL_TOKENS")]
fn test_sort_tokens_identical() {
    let a = AztecAddress::from_field(100);
    let _ = sort_tokens(a, a);
}

#[test(should_fail_with = "ZERO_ADDRESS")]
fn test_sort_tokens_zero_first() {
    let a = AztecAddress::zero();
    let b = AztecAddress::from_field(100);
    let _ = sort_tokens(a, b);
}

#[test(should_fail_with = "ZERO_ADDRESS")]
fn test_sort_tokens_zero_second() {
    let a = AztecAddress::from_field(100);
    let b = AztecAddress::zero();
    let _ = sort_tokens(a, b);
}

// ============================================
// Path length validation
// ============================================

#[test]
fn test_validate_path_length_single_hop() {
    // path_length = 2 is the minimum valid length (one pair between in/out).
    validate_path_length(2);
}

#[test]
fn test_validate_path_length_two_hops() {
    validate_path_length(3);
}

#[test]
fn test_validate_path_length_max_hops() {
    // MAX_HOPS + 1 is the maximum valid length.
    validate_path_length(MAX_HOPS + 1);
}

#[test(should_fail_with = "PATH_TOO_SHORT")]
fn test_validate_path_length_zero() {
    validate_path_length(0);
}

#[test(should_fail_with = "PATH_TOO_SHORT")]
fn test_validate_path_length_one() {
    // path_length = 1 is degenerate (single token, no swap). Reject.
    validate_path_length(1);
}

#[test(should_fail_with = "PATH_TOO_LONG")]
fn test_validate_path_length_above_max() {
    validate_path_length(MAX_HOPS + 2);
}

#[test(should_fail_with = "PATH_TOO_LONG")]
fn test_validate_path_length_way_above_max() {
    validate_path_length(100);
}

// ============================================
// Interface fee bips validation
// ============================================

// A non-zero stand-in address for tests that need a valid `fee_recipient`.
fn dummy_recipient() -> AztecAddress {
    AztecAddress::from_field(0x42)
}

#[test]
fn test_validate_interface_fee_bips_zero() {
    // Zero fee is allowed with any recipient (the recipient check is gated
    // on bps > 0). The canonical "skip fee" pattern uses (0, zero).
    validate_interface_fee_bips(0, AztecAddress::zero());
}

#[test]
fn test_validate_interface_fee_bips_zero_with_nonzero_recipient_allowed() {
    // (0, non-zero) is also allowed: the recipient is parsed but inert.
    // Useful for SDK contexts that pre-validate config without zeroing.
    validate_interface_fee_bips(0, dummy_recipient());
}

#[test]
fn test_validate_interface_fee_bips_typical() {
    // 30 bps (0.3%) is a common consumer DEX frontend fee.
    validate_interface_fee_bips(30, dummy_recipient());
}

#[test]
fn test_validate_interface_fee_bips_max() {
    validate_interface_fee_bips(MAX_INTERFACE_FEE_BIPS, dummy_recipient());
}

#[test(should_fail_with = "FEE_BIPS_TOO_HIGH")]
fn test_validate_interface_fee_bips_above_max() {
    validate_interface_fee_bips(MAX_INTERFACE_FEE_BIPS + 1, dummy_recipient());
}

#[test(should_fail_with = "FEE_BIPS_TOO_HIGH")]
fn test_validate_interface_fee_bips_1_percent_over() {
    validate_interface_fee_bips(600, dummy_recipient());
}

#[test(should_fail_with = "FEE_BIPS_TOO_HIGH")]
fn test_validate_interface_fee_bips_10_percent() {
    // 1000 bps = 10% -- well above the cap.
    validate_interface_fee_bips(1000, dummy_recipient());
}

#[test(should_fail_with = "FEE_BIPS_TOO_HIGH")]
fn test_validate_interface_fee_bips_100_percent() {
    validate_interface_fee_bips(10000, dummy_recipient());
}

#[test(should_fail_with = "INVALID_FEE_CONFIG")]
fn test_validate_interface_fee_bips_nonzero_with_zero_recipient_reverts() {
    // (bps > 0, recipient = zero) is the misconfiguration the new check
    // catches: without this assert, the public continuation's
    // `_deduct_interface_fee` short-circuit silently waives the fee.
    validate_interface_fee_bips(100, AztecAddress::zero());
}

#[test(should_fail_with = "INVALID_FEE_CONFIG")]
fn test_validate_interface_fee_bips_max_bps_with_zero_recipient_reverts() {
    // Boundary check: even at the bps cap the recipient must be non-zero.
    validate_interface_fee_bips(MAX_INTERFACE_FEE_BIPS, AztecAddress::zero());
}

// ============================================
// Exact-out path cycle validation
// ============================================

// Build a path array with the given tokens in the first slots, zero-padded.
// Helper to keep test bodies focused on the path shape, not array mechanics.
fn make_path(tokens: [AztecAddress]) -> [AztecAddress; MAX_HOPS + 1] {
    let mut out: [AztecAddress; MAX_HOPS + 1] = [AztecAddress::zero(); MAX_HOPS + 1];
    for i in 0..MAX_HOPS + 1 {
        if i < tokens.len() {
            out[i] = tokens[i];
        }
    }
    out
}

#[test]
fn test_validate_path_no_cycle_simple_two_hop() {
    // [A, B] -- single hop, final B, no repetition possible before it.
    let a = AztecAddress::from_field(1);
    let b = AztecAddress::from_field(2);
    validate_path_no_cycle_to_final(make_path(&[a, b]), 2);
}

#[test]
fn test_validate_path_no_cycle_three_hop_distinct() {
    // [A, B, C] -- all distinct.
    let a = AztecAddress::from_field(1);
    let b = AztecAddress::from_field(2);
    let c = AztecAddress::from_field(3);
    validate_path_no_cycle_to_final(make_path(&[a, b, c]), 3);
}

#[test]
fn test_validate_path_no_cycle_initial_repeats_intermediately() {
    // [A, B, A, C] -- A appears intermediately but final token (C) is distinct.
    // Legitimate for exact-out (e.g., a B/A pair with better price than direct
    // A/C). The check only restricts the final token, not intermediates.
    let a = AztecAddress::from_field(1);
    let b = AztecAddress::from_field(2);
    let c = AztecAddress::from_field(3);
    validate_path_no_cycle_to_final(make_path(&[a, b, a, c]), 4);
}

#[test(should_fail_with = "FINAL_TOKEN_REPEATED")]
fn test_validate_path_no_cycle_final_equals_initial() {
    // [A, B, C, A] -- triangular cycle. Rejects for exact-out because the
    // change refund and final-output send race for the same balance.
    let a = AztecAddress::from_field(1);
    let b = AztecAddress::from_field(2);
    let c = AztecAddress::from_field(3);
    validate_path_no_cycle_to_final(make_path(&[a, b, c, a]), 4);
}

#[test(should_fail_with = "FINAL_TOKEN_REPEATED")]
fn test_validate_path_no_cycle_final_equals_intermediate() {
    // [A, B, C, B] -- hub-routing. Rejects because intermediate-dust
    // refund consumes the final-output balance.
    let a = AztecAddress::from_field(1);
    let b = AztecAddress::from_field(2);
    let c = AztecAddress::from_field(3);
    validate_path_no_cycle_to_final(make_path(&[a, b, c, b]), 4);
}

#[test(should_fail_with = "FINAL_TOKEN_REPEATED")]
fn test_validate_path_no_cycle_two_hop_self() {
    // [A, A] -- single-hop "swap to self". Degenerate case caught by this
    // check even though pair-level token_in!=token_out would also catch it.
    let a = AztecAddress::from_field(1);
    validate_path_no_cycle_to_final(make_path(&[a, a]), 2);
}
