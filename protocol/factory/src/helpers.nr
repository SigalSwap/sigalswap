// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 SigalSwap LLC. All rights reserved.
// Licensed under the Business Source License 1.1. See LICENSE in this directory.

use aztec::protocol::{address::AztecAddress, hash::poseidon2_hash, traits::{FromField, ToField}};

/// Compute a deterministic base key for a (token0, token1, fee_tier) pool.
/// The base key identifies a pool slot independent of pair version; the factory
/// uses it to look up `latest_version` and `latest_pair` for the pool.
pub fn compute_base_key(
    token0: AztecAddress,
    token1: AztecAddress,
    fee_tier_bps: u32,
) -> Field {
    let (t0, t1) = if token0.to_field() as u128 < token1.to_field() as u128 {
        (token0, token1)
    } else {
        (token1, token0)
    };
    poseidon2_hash([t0.to_field(), t1.to_field(), fee_tier_bps as Field])
}

/// Compute a deterministic pair key for a (token0, token1, fee_tier, version)
/// registration. Different versions at the same base produce different pair
/// keys, so multiple bytecode versions can coexist in the `pairs` map without
/// collision; the factory's `latest_pair` points to the most recent one.
pub fn compute_pair_key(
    token0: AztecAddress,
    token1: AztecAddress,
    fee_tier_bps: u32,
    version: u32,
) -> Field {
    let (t0, t1) = if token0.to_field() as u128 < token1.to_field() as u128 {
        (token0, token1)
    } else {
        (token1, token0)
    };
    poseidon2_hash([t0.to_field(), t1.to_field(), fee_tier_bps as Field, version as Field])
}

/// Compute a deterministic action hash for timelock operations.
pub fn compute_action_hash(action_type: Field, param: Field) -> Field {
    poseidon2_hash([action_type, param])
}

/// Compute the `param` Field for a set_pair_class_id timelock action.
/// Packs (class_id, version) so two queued blessings with the same class_id
/// but different versions map to distinct action hashes and cannot collide
/// in the timelock map.
pub fn compute_class_id_version_param(class_id: Field, version: u32) -> Field {
    poseidon2_hash([class_id, version as Field])
}

/// Compute the `param` Field for a clear_pair_slot timelock action. Packs
/// the pair address, the base-identifying (token0, token1, fee_tier), and the
/// admin-declared `new_latest_version` so the full intent is committed at
/// queue time and cannot be altered before execute.
pub fn compute_clear_slot_param(
    pair_address: AztecAddress,
    token0: AztecAddress,
    token1: AztecAddress,
    fee_tier_bps: u32,
    new_latest_version: u32,
) -> Field {
    let (t0, t1) = if token0.to_field() as u128 < token1.to_field() as u128 {
        (token0, token1)
    } else {
        (token1, token0)
    };
    poseidon2_hash([
        pair_address.to_field(),
        t0.to_field(),
        t1.to_field(),
        fee_tier_bps as Field,
        new_latest_version as Field,
    ])
}

// ============================================
// Unit Tests
// ============================================

// --- base_key ---

#[test]
fn test_base_key_sorted_order() {
    // (A, B) and (B, A) should produce the same key
    let a = AztecAddress::from_field(100);
    let b = AztecAddress::from_field(200);
    let key_ab = compute_base_key(a, b, 25);
    let key_ba = compute_base_key(b, a, 25);
    assert(key_ab == key_ba);
}

#[test]
fn test_base_key_deterministic() {
    let a = AztecAddress::from_field(100);
    let b = AztecAddress::from_field(200);
    assert(compute_base_key(a, b, 25) == compute_base_key(a, b, 25));
}

#[test]
fn test_base_key_different_fee_tiers() {
    let a = AztecAddress::from_field(100);
    let b = AztecAddress::from_field(200);
    assert(compute_base_key(a, b, 25) != compute_base_key(a, b, 100));
}

#[test]
fn test_base_key_different_tokens() {
    let a = AztecAddress::from_field(100);
    let b = AztecAddress::from_field(200);
    let c = AztecAddress::from_field(300);
    assert(compute_base_key(a, b, 25) != compute_base_key(a, c, 25));
}

// --- pair_key (versioned) ---

#[test]
fn test_pair_key_sorted_order() {
    let a = AztecAddress::from_field(100);
    let b = AztecAddress::from_field(200);
    assert(compute_pair_key(a, b, 25, 1) == compute_pair_key(b, a, 25, 1));
}

#[test]
fn test_pair_key_different_versions() {
    // Same tokens + tier at different versions MUST produce different keys.
    // This is the central invariant that lets the factory store multiple pair
    // versions at the same (tokens, tier) slot without collision.
    let a = AztecAddress::from_field(100);
    let b = AztecAddress::from_field(200);
    assert(compute_pair_key(a, b, 25, 1) != compute_pair_key(a, b, 25, 2));
    assert(compute_pair_key(a, b, 25, 1) != compute_pair_key(a, b, 25, 3));
    assert(compute_pair_key(a, b, 25, 2) != compute_pair_key(a, b, 25, 3));
}

#[test]
fn test_pair_key_independent_of_base_key() {
    // pair_key (with version) and base_key (without) must produce different
    // Field values for any realistic input -- they live in separate maps.
    // Poseidon2 of 3 inputs vs 4 inputs is extremely unlikely to collide,
    // but we verify for the canonical test inputs.
    let a = AztecAddress::from_field(100);
    let b = AztecAddress::from_field(200);
    assert(compute_base_key(a, b, 25) != compute_pair_key(a, b, 25, 1));
}

// --- action hash ---

#[test]
fn test_action_hash_deterministic() {
    assert(compute_action_hash(1, 42) == compute_action_hash(1, 42));
}

#[test]
fn test_action_hash_different_types() {
    assert(compute_action_hash(1, 42) != compute_action_hash(2, 42));
}

#[test]
fn test_action_hash_different_params() {
    assert(compute_action_hash(1, 42) != compute_action_hash(1, 99));
}

// --- class_id_version param ---

#[test]
fn test_class_id_version_param_different_versions() {
    // Same class_id at different versions must produce distinct params so
    // that separately queued (class_id, v1) and (class_id, v2) blessings
    // can't collide in the timelock map.
    assert(
        compute_class_id_version_param(0xAAAA as Field, 1)
            != compute_class_id_version_param(0xAAAA as Field, 2),
    );
}

#[test]
fn test_class_id_version_param_different_class_ids() {
    assert(
        compute_class_id_version_param(0xAAAA as Field, 1)
            != compute_class_id_version_param(0xBBBB as Field, 1),
    );
}

// --- clear_slot param ---

#[test]
fn test_clear_slot_param_distinguishes_target() {
    let pair_a = AztecAddress::from_field(1);
    let pair_b = AztecAddress::from_field(2);
    let t0 = AztecAddress::from_field(100);
    let t1 = AztecAddress::from_field(200);
    assert(
        compute_clear_slot_param(pair_a, t0, t1, 25, 1)
            != compute_clear_slot_param(pair_b, t0, t1, 25, 1),
    );
}

#[test]
fn test_clear_slot_param_distinguishes_new_latest() {
    let pair = AztecAddress::from_field(1);
    let t0 = AztecAddress::from_field(100);
    let t1 = AztecAddress::from_field(200);
    assert(
        compute_clear_slot_param(pair, t0, t1, 25, 1)
            != compute_clear_slot_param(pair, t0, t1, 25, 0),
    );
}

#[test]
fn test_clear_slot_param_sorted_tokens() {
    // Token order shouldn't matter for the base identification portion of
    // the param -- mirrors compute_base_key's behavior.
    let pair = AztecAddress::from_field(1);
    let t0 = AztecAddress::from_field(100);
    let t1 = AztecAddress::from_field(200);
    assert(
        compute_clear_slot_param(pair, t0, t1, 25, 0)
            == compute_clear_slot_param(pair, t1, t0, 25, 0),
    );
}
