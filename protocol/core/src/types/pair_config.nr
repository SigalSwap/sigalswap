// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 SigalSwap LLC. All rights reserved.
// Licensed under the Business Source License 1.1. See LICENSE in this directory.

// PairConfig: Immutable configuration for a SigalSwap trading pair
// Set once at initialization, never changes.
//
// All immutable config is packed into a single struct stored in
// PublicImmutable, so loading the config requires only a single merkle proof.
//
// LP tokens are managed by a separate SigalSwapLPToken contract (Noir lacks
// inheritance, so the pair can't be its own ERC20). The LP token's address is
// derived deterministically from the pair's own address in the constructor
// (closing the trust surface of accepting a caller-supplied LP token address)
// and stored both in the dedicated `lp_token` storage slot AND in this
// PairConfig so callers reading the config get the LP address in the same
// merkle proof.

use aztec::protocol::{address::AztecAddress, traits::{Deserialize, Packable, Serialize}};
use std::meta::derive;

#[derive(Deserialize, Eq, Packable, Serialize)]
pub struct PairConfig {
    /// Address of the first token in the pair (lower address)
    pub token0: AztecAddress,
    /// Address of the second token in the pair (higher address)
    pub token1: AztecAddress,
    /// Address of the factory that created this pair
    pub factory: AztecAddress,
    /// Fee tier in basis points (e.g., 25 = 0.25%, set at pair creation)
    pub fee_tier_bps: u32,
    /// Pair bytecode version. Populated from the compile-time VERSION global
    /// (see `core/src/main.nr`); NOT a constructor argument. Tied deterministically
    /// to the pair's class ID: any bytecode change that affects behavior bumps
    /// VERSION and therefore the class ID. The factory cross-checks this field
    /// against its admin-declared pair_class_version during register_pair so a
    /// mis-blessed class/version pairing is rejected before registration.
    pub version: u32,
    /// Derived LP Token address. Computed in the constructor from the pair's
    /// own address using the canonical-deploy inputs (`LP_TOKEN_SALT`,
    /// `deployer = AztecAddress::zero()`, `public_keys = PublicKeys::default()`,
    /// hardcoded `LP_TOKEN_CLASS_ID`). Stored here so router-side address
    /// verification can fetch token0/token1/lp_token in one merkle proof
    /// instead of two view calls.
    pub lp_token: AztecAddress,
}
