// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 SigalSwap LLC. All rights reserved.
// Licensed under the Business Source License 1.1. See LICENSE in this directory.

// SafeMath: explicit underflow check on u128 subtraction.
//
// Noir's u128 panics on underflow at the language level; this wrapper adds
// a targeted error message at the protocol's named call sites.

/// Safe subtraction with underflow check
/// Reverts if a < b (would underflow)
pub fn safe_sub(a: u128, b: u128) -> u128 {
    assert(b <= a, "safe_sub: underflow");
    a - b
}

#[test]
fn test_safe_sub_basic() {
    assert(safe_sub(5, 3) == 2);
    assert(safe_sub(100, 100) == 0);
    assert(safe_sub(1000, 1) == 999);
}

#[test]
fn test_safe_sub_zero() {
    assert(safe_sub(12345, 0) == 12345);
    assert(safe_sub(0, 0) == 0);
}

#[test(should_fail_with = "safe_sub: underflow")]
fn test_safe_sub_underflow() {
    let _ = safe_sub(3, 5);
}
