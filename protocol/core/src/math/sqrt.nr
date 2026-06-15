// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 SigalSwap LLC. All rights reserved.
// Licensed under the Business Source License 1.1. See LICENSE in this directory.

// Math utilities: sqrt (Babylonian method) and min.
// Integer square root over the constant-product reserves.
//
// Noir requires compile-time bounded loops, so the Babylonian method
// uses a fixed iteration count. For u128, convergence is guaranteed
// within 128 iterations (each iteration halves the error).

/// Returns the smaller of two u128 values
pub fn min(x: u128, y: u128) -> u128 {
    if x < y { x } else { y }
}

/// Integer square root using the Babylonian method
/// Returns floor(sqrt(y))
///
/// Algorithm:
///   Start with guess x = y/2 + 1
///   Iterate: x_new = (y/x + x) / 2
///   Stop when x_new >= x (convergence)
///
/// For y <= 3, returns 1 (if y != 0) or 0 (if y == 0)
pub fn sqrt(y: u128) -> u128 {
    if y > 3 {
        let mut z: u128 = y;
        let mut x: u128 = y / 2 + 1;
        // Babylonian iteration: converges in O(log(bits)) steps.
        // 128 iterations is more than enough for u128.
        for _ in 0..128 {
            if x < z {
                z = x;
                x = (y / x + x) / 2;
            }
        }
        z
    } else if y != 0 {
        1
    } else {
        0
    }
}

// ============================================
// Unit Tests
// ============================================

// --- min tests ---

#[test]
fn test_min_first_smaller() {
    assert(min(3, 5) == 3);
}

#[test]
fn test_min_second_smaller() {
    assert(min(10, 2) == 2);
}

#[test]
fn test_min_equal() {
    assert(min(7, 7) == 7);
}

#[test]
fn test_min_zero() {
    assert(min(0, 5) == 0);
    assert(min(5, 0) == 0);
}

#[test]
fn test_min_both_zero() {
    assert(min(0, 0) == 0);
}

// --- sqrt tests ---

#[test]
fn test_sqrt_zero() {
    assert(sqrt(0) == 0);
}

#[test]
fn test_sqrt_one() {
    assert(sqrt(1) == 1);
}

#[test]
fn test_sqrt_two() {
    assert(sqrt(2) == 1); // floor(1.414...) = 1
}

#[test]
fn test_sqrt_three() {
    assert(sqrt(3) == 1); // floor(1.732...) = 1
}

#[test]
fn test_sqrt_four() {
    assert(sqrt(4) == 2);
}

#[test]
fn test_sqrt_perfect_squares() {
    assert(sqrt(9) == 3);
    assert(sqrt(16) == 4);
    assert(sqrt(25) == 5);
    assert(sqrt(100) == 10);
    assert(sqrt(144) == 12);
    assert(sqrt(10000) == 100);
}

#[test]
fn test_sqrt_non_perfect_squares() {
    assert(sqrt(5) == 2);   // floor(2.236) = 2
    assert(sqrt(8) == 2);   // floor(2.828) = 2
    assert(sqrt(10) == 3);  // floor(3.162) = 3
    assert(sqrt(99) == 9);  // floor(9.949) = 9
    assert(sqrt(101) == 10); // floor(10.049) = 10
}

#[test]
fn test_sqrt_large_perfect_square() {
    // 1_000_000^2 = 1_000_000_000_000
    assert(sqrt(1000000000000) == 1000000);
}

#[test]
fn test_sqrt_large_value() {
    // sqrt(2^64) = 2^32 = 4_294_967_296
    let val: u128 = 0x10000000000000000; // 2^64
    assert(sqrt(val) == 4294967296);
}

#[test]
fn test_sqrt_floor_property() {
    // For any n, sqrt(n)^2 <= n < (sqrt(n)+1)^2
    let n: u128 = 1234567;
    let s = sqrt(n);
    assert(s * s <= n);
    assert((s + 1) * (s + 1) > n);
}

#[test]
fn test_sqrt_amm_realistic() {
    // Realistic AMM scenario: sqrt(amount0 * amount1) for initial liquidity
    // e.g., 1000 tokens * 1000 tokens = 1_000_000
    assert(sqrt(1000000) == 1000);

    // Larger deposit: 1_000_000 * 2_000_000 = 2_000_000_000_000
    // sqrt(2_000_000_000_000) = 1_414_213 (floor)
    let product: u128 = 2000000000000;
    let s = sqrt(product);
    assert(s == 1414213);
    assert(s * s <= product);
    assert((s + 1) * (s + 1) > product);
}
