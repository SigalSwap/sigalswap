// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 SigalSwap LLC. All rights reserved.
// Licensed under the Business Source License 1.1. See LICENSE in this directory.

// QueuedAction: Timelock action struct for governance
// Used by the Factory contract (separate package) for timelocked admin operations.
//
// Timelocked operations (48-hour delay):
// - Fee tier whitelist changes
// - Protocol fee percentage
// - feeTo address changes
// - Admin address rotation


use aztec::protocol::traits::{Deserialize, Packable, Serialize};
use std::meta::derive;

/// Delay before a queued action can be executed (48 hours in seconds)
pub global TIMELOCK_DELAY: u64 = 172800;

/// Window after the delay during which the action can be executed (7 days in seconds)
pub global EXECUTION_WINDOW: u64 = 604800;

#[derive(Deserialize, Eq, Packable, Serialize)]
pub struct QueuedAction {
    /// Hash identifying the action (poseidon2 of action type + parameters)
    pub action_hash: Field,
    /// Timestamp after which the action can be executed
    pub execute_after: u64,
    /// Timestamp after which the action expires and can no longer be executed
    pub expires_at: u64,
    /// Whether this action is still pending (not yet executed or cancelled)
    pub is_active: bool,
}
