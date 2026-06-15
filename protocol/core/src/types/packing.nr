// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 SigalSwap LLC. All rights reserved.
// Licensed under the Business Source License 1.1. See LICENSE in this directory.

// Storage packing utilities for SigalSwap.
//
// Packs multiple u112-capped values into a single BN254 Field to reduce
// storage slot count. Each eliminated slot saves 33,140 gas (SSTORE) + 1,290
// gas (SLOAD) per access.
//
// Pattern: pack as `a * 2^112 + b`, unpack via unconstrained hint + Field verify.
// This is the same hint-and-verify pattern used in wide.nr for mul_div.
//
// Safety: The Field equation `a * Q112 + b == packed` has a unique solution
// when a < Q112 and b < Q112, because Q112^2 = 2^224 < BN254 modulus (~2^254).
// The range checks on a and b guarantee this uniqueness.
//
// Three typed wrappers (ReservesPacked, TwapFractions, FlagsPacked) implement
// `Packable` so storage slots can be declared as the typed shape rather than a
// bare `Field`. Each pack/unpack delegates to the lower-level helpers below.
// The wrappers don't change storage layout (all are 1 Field on the wire); they
// only move pack/unpack from imperative call sites to a typed boundary.

use aztec::protocol::traits::Packable;

/// Q112 = 2^112, the packing boundary.
pub global Q112: u128 = 5192296858534827628530496329220096;

/// Q112 as Field (used in pack/unpack equations).
global Q112_F: Field = 5192296858534827628530496329220096;

/// MAX_U112 = 2^112 - 1, the maximum value for each packed component.
pub global MAX_U112: u128 = 5192296858534827628530496329220095;

// ================================================================
// Core pack/unpack for a pair of u112 values
// ================================================================

/// Pack two u112 values into a single Field. Asserts both inputs are
/// <= MAX_U112; callers do not need a separate range check before calling.
pub fn pack_u112_pair(a: u128, b: u128) -> Field {
    assert(a <= MAX_U112, "PACK_A_OVERFLOW");
    assert(b <= MAX_U112, "PACK_B_OVERFLOW");
    (a as Field) * Q112_F + (b as Field)
}

/// Unpack a Field into two u112 values.
/// Uses unconstrained hint + constrained Field equation for verification.
pub fn unpack_u112_pair(packed: Field) -> (u128, u128) {
    // Safety: __decompose is an unconstrained hint. The constrained checks below
    // verify correctness: the Field equation guarantees a*Q112+b == packed, and
    // the range checks guarantee uniqueness (a < Q112, b < Q112).
    let (a, b) = unsafe { __decompose(packed) };
    assert((a as Field) * Q112_F + (b as Field) == packed, "UNPACK_VERIFY");
    assert(a <= MAX_U112, "UNPACK_A_OVERFLOW");
    assert(b <= MAX_U112, "UNPACK_B_OVERFLOW");
    (a, b)
}

/// Unconstrained decomposition: extract two u112 values from a packed Field.
/// Returns (high, low) where packed = high * 2^112 + low.
unconstrained fn __decompose(packed: Field) -> (u128, u128) {
    let bytes: [u8; 32] = packed.to_be_bytes::<32>();

    // BN254 Field in big-endian 32 bytes:
    //   bytes[0..4]  = bits 224-255 (should be 0 for valid packed values)
    //   bytes[4..18] = bits 112-223 = high component (14 bytes = 112 bits)
    //   bytes[18..32] = bits 0-111 = low component (14 bytes = 112 bits)
    let mut high: u128 = 0;
    for i in 0..14 {
        high = high * 256 + bytes[4 + i] as u128;
    }

    let mut low: u128 = 0;
    for i in 0..14 {
        low = low * 256 + bytes[18 + i] as u128;
    }

    (high, low)
}

// ================================================================
// Flags packing: is_paused, locked, protocol_fee_active, protocol_fee_percent
// Packed into a single Field as: percent * 8 + flags_bits
// flags_bits: bit 0 = is_paused, bit 1 = locked, bit 2 = protocol_fee_active
// Total max: 100 * 8 + 7 = 807, fits trivially in one Field.
// ================================================================

/// Pack control flags into a single Field.
pub fn pack_flags(is_paused: bool, locked: bool, protocol_fee_active: bool, protocol_fee_percent: u32) -> Field {
    assert(protocol_fee_percent <= 100, "PACK_PERCENT_OVERFLOW");
    let flags = (is_paused as u32) + (locked as u32) * 2 + (protocol_fee_active as u32) * 4;
    ((protocol_fee_percent * 8 + flags) as Field)
}

/// Unpack control flags from a single Field.
pub fn unpack_flags(packed: Field) -> (bool, bool, bool, u32) {
    let val = packed as u32;
    let flags = val % 8;
    let percent = val / 8;
    let is_paused = (flags & 1) != 0;
    let locked = (flags & 2) != 0;
    let protocol_fee_active = (flags & 4) != 0;
    (is_paused, locked, protocol_fee_active, percent)
}

// ================================================================
// Typed wrappers
// ================================================================

/// Two u112 reserve amounts packed into one Field. Used by SigalSwapPair for
/// both `packed_reserves` (live reserves) and `packed_reserves_last` (the
/// reserves snapshot at the last protocol-fee K-growth baseline).
#[derive(Eq)]
pub struct ReservesPacked {
    pub reserve0: u128,
    pub reserve1: u128,
}

impl ReservesPacked {
    /// True when both reserves are zero. Used at the protocol-fee K-growth
    /// baseline clear site (when fee toggles off we wipe reserves_last to 0).
    pub fn is_zero(self) -> bool {
        (self.reserve0 == 0 as u128) & (self.reserve1 == 0 as u128)
    }

    /// Reserves of all-zero. Convenience for the wipe sites.
    pub fn zero() -> Self {
        Self { reserve0: 0 as u128, reserve1: 0 as u128 }
    }
}

impl Packable for ReservesPacked {
    let N: u32 = 1;

    fn pack(self) -> [Field; 1] {
        [pack_u112_pair(self.reserve0, self.reserve1)]
    }

    fn unpack(packed: [Field; 1]) -> Self {
        let (a, b) = unpack_u112_pair(packed[0]);
        Self { reserve0: a, reserve1: b }
    }
}

/// Two u112 TWAP cumulative-price fractional accumulators packed into one Field.
/// Integer parts of cumulative prices live in separate storage slots; this
/// wrapper covers only the < 1.0 fractional residue that completes the
/// accumulator.
pub struct TwapFractions {
    pub price0_cumul_frac: u128,
    pub price1_cumul_frac: u128,
}

impl Packable for TwapFractions {
    let N: u32 = 1;

    fn pack(self) -> [Field; 1] {
        [pack_u112_pair(self.price0_cumul_frac, self.price1_cumul_frac)]
    }

    fn unpack(packed: [Field; 1]) -> Self {
        let (a, b) = unpack_u112_pair(packed[0]);
        Self { price0_cumul_frac: a, price1_cumul_frac: b }
    }
}

/// Pair control flags + protocol-fee percent packed into one Field. Layout
/// matches pack_flags/unpack_flags below: protocol_fee_percent * 8 + 3-bit
/// flag mask (bit 0 = is_paused, bit 1 = locked, bit 2 = protocol_fee_active).
pub struct FlagsPacked {
    pub is_paused: bool,
    pub locked: bool,
    pub protocol_fee_active: bool,
    pub protocol_fee_percent: u32,
}

impl Packable for FlagsPacked {
    let N: u32 = 1;

    fn pack(self) -> [Field; 1] {
        [pack_flags(self.is_paused, self.locked, self.protocol_fee_active, self.protocol_fee_percent)]
    }

    fn unpack(packed: [Field; 1]) -> Self {
        let (p, l, a, pct) = unpack_flags(packed[0]);
        Self { is_paused: p, locked: l, protocol_fee_active: a, protocol_fee_percent: pct }
    }
}

// ================================================================
// Unit Tests
// ================================================================

// --- u112 pair pack/unpack ---

#[test]
fn test_pack_unpack_zeros() {
    let packed = pack_u112_pair(0, 0);
    let (a, b) = unpack_u112_pair(packed);
    assert_eq(a, 0);
    assert_eq(b, 0);
}

#[test]
fn test_pack_unpack_ones() {
    let packed = pack_u112_pair(1, 1);
    let (a, b) = unpack_u112_pair(packed);
    assert_eq(a, 1);
    assert_eq(b, 1);
}

#[test]
fn test_pack_unpack_max_both() {
    let packed = pack_u112_pair(MAX_U112, MAX_U112);
    let (a, b) = unpack_u112_pair(packed);
    assert_eq(a, MAX_U112);
    assert_eq(b, MAX_U112);
}

#[test]
fn test_pack_unpack_max_high_zero_low() {
    let packed = pack_u112_pair(MAX_U112, 0);
    let (a, b) = unpack_u112_pair(packed);
    assert_eq(a, MAX_U112);
    assert_eq(b, 0);
}

#[test]
fn test_pack_unpack_zero_high_max_low() {
    let packed = pack_u112_pair(0, MAX_U112);
    let (a, b) = unpack_u112_pair(packed);
    assert_eq(a, 0);
    assert_eq(b, MAX_U112);
}

#[test]
fn test_pack_unpack_asymmetric() {
    let packed = pack_u112_pair(12345, 67890);
    let (a, b) = unpack_u112_pair(packed);
    assert_eq(a, 12345);
    assert_eq(b, 67890);
}

#[test]
fn test_pack_unpack_realistic_reserves() {
    // 100 ETH (100e18) and 200,000 USDC (200_000e6)
    let r0: u128 = 100000000000000000000;
    let r1: u128 = 200000000000;
    let packed = pack_u112_pair(r0, r1);
    let (a, b) = unpack_u112_pair(packed);
    assert_eq(a, r0);
    assert_eq(b, r1);
}

#[test]
fn test_pack_unpack_large_realistic() {
    // Near-max realistic pool: 1 trillion tokens with 18 decimals
    let r0: u128 = 1000000000000000000000000000000; // 1e30
    let r1: u128 = 999999999999999999999999999999;
    let packed = pack_u112_pair(r0, r1);
    let (a, b) = unpack_u112_pair(packed);
    assert_eq(a, r0);
    assert_eq(b, r1);
}

#[test]
fn test_pack_unpack_one_zero() {
    let packed = pack_u112_pair(1, 0);
    let (a, b) = unpack_u112_pair(packed);
    assert_eq(a, 1);
    assert_eq(b, 0);
}

#[test]
fn test_pack_unpack_zero_one() {
    let packed = pack_u112_pair(0, 1);
    let (a, b) = unpack_u112_pair(packed);
    assert_eq(a, 0);
    assert_eq(b, 1);
}

#[test]
fn test_pack_unpack_powers_of_two() {
    // Test boundary at 2^64 (u64 max + 1)
    let val: u128 = 18446744073709551616; // 2^64
    let packed = pack_u112_pair(val, val);
    let (a, b) = unpack_u112_pair(packed);
    assert_eq(a, val);
    assert_eq(b, val);
}

#[test]
fn test_pack_unpack_q112_minus_two() {
    // One below max
    let val = MAX_U112 - 1;
    let packed = pack_u112_pair(val, val);
    let (a, b) = unpack_u112_pair(packed);
    assert_eq(a, val);
    assert_eq(b, val);
}

#[test]
fn test_pack_deterministic() {
    // Same inputs always produce the same packed value
    let p1 = pack_u112_pair(1000, 2000);
    let p2 = pack_u112_pair(1000, 2000);
    assert_eq(p1, p2);
}

#[test]
fn test_pack_different_values_different_results() {
    let p1 = pack_u112_pair(1000, 2000);
    let p2 = pack_u112_pair(2000, 1000);
    assert(p1 != p2);
}

#[test]
fn test_pack_commutative_breaks() {
    // Verify that (a, b) != (b, a) when a != b -- the pack is NOT commutative
    let (a1, b1) = unpack_u112_pair(pack_u112_pair(100, 200));
    let (a2, b2) = unpack_u112_pair(pack_u112_pair(200, 100));
    assert_eq(a1, 100);
    assert_eq(b1, 200);
    assert_eq(a2, 200);
    assert_eq(b2, 100);
}

// --- Flags pack/unpack ---

#[test]
fn test_flags_all_false_zero() {
    let packed = pack_flags(false, false, false, 0);
    let (paused, locked, fee_active, percent) = unpack_flags(packed);
    assert_eq(paused, false);
    assert_eq(locked, false);
    assert_eq(fee_active, false);
    assert_eq(percent, 0);
}

#[test]
fn test_flags_all_true_max() {
    let packed = pack_flags(true, true, true, 100);
    let (paused, locked, fee_active, percent) = unpack_flags(packed);
    assert_eq(paused, true);
    assert_eq(locked, true);
    assert_eq(fee_active, true);
    assert_eq(percent, 100);
}

#[test]
fn test_flags_paused_only() {
    let packed = pack_flags(true, false, false, 0);
    let (paused, locked, fee_active, percent) = unpack_flags(packed);
    assert_eq(paused, true);
    assert_eq(locked, false);
    assert_eq(fee_active, false);
    assert_eq(percent, 0);
}

#[test]
fn test_flags_locked_only() {
    let packed = pack_flags(false, true, false, 0);
    let (paused, locked, fee_active, percent) = unpack_flags(packed);
    assert_eq(paused, false);
    assert_eq(locked, true);
    assert_eq(fee_active, false);
    assert_eq(percent, 0);
}

#[test]
fn test_flags_fee_active_only() {
    let packed = pack_flags(false, false, true, 0);
    let (paused, locked, fee_active, percent) = unpack_flags(packed);
    assert_eq(paused, false);
    assert_eq(locked, false);
    assert_eq(fee_active, true);
    assert_eq(percent, 0);
}

#[test]
fn test_flags_percent_only() {
    let packed = pack_flags(false, false, false, 50);
    let (paused, locked, fee_active, percent) = unpack_flags(packed);
    assert_eq(paused, false);
    assert_eq(locked, false);
    assert_eq(fee_active, false);
    assert_eq(percent, 50);
}

#[test]
fn test_flags_percent_20_fee_active() {
    // The common production config: 20% protocol fee, active
    let packed = pack_flags(false, false, true, 20);
    let (paused, locked, fee_active, percent) = unpack_flags(packed);
    assert_eq(paused, false);
    assert_eq(locked, false);
    assert_eq(fee_active, true);
    assert_eq(percent, 20);
}

#[test]
fn test_flags_paused_and_locked() {
    // Emergency state: paused + locked
    let packed = pack_flags(true, true, false, 0);
    let (paused, locked, fee_active, percent) = unpack_flags(packed);
    assert_eq(paused, true);
    assert_eq(locked, true);
    assert_eq(fee_active, false);
    assert_eq(percent, 0);
}

#[test]
fn test_flags_round_trip_all_combos() {
    // Test all 8 boolean combinations with percent = 42
    for flags_val in 0..8 {
        let p = (flags_val & 1) != 0;
        let l = (flags_val & 2) != 0;
        let f = (flags_val & 4) != 0;
        let packed = pack_flags(p, l, f, 42);
        let (p2, l2, f2, pct) = unpack_flags(packed);
        assert_eq(p, p2);
        assert_eq(l, l2);
        assert_eq(f, f2);
        assert_eq(pct, 42);
    }
}

#[test]
fn test_flags_boundary_percents() {
    // Test percent values at boundaries
    for pct_val in [0, 1, 20, 50, 99, 100] {
        let packed = pack_flags(true, false, true, pct_val);
        let (paused, locked, fee_active, percent) = unpack_flags(packed);
        assert_eq(paused, true);
        assert_eq(locked, false);
        assert_eq(fee_active, true);
        assert_eq(percent, pct_val);
    }
}
