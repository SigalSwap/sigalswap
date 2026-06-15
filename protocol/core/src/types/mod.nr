// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 SigalSwap LLC. All rights reserved.
// Licensed under the Business Source License 1.1. See LICENSE in this directory.

// Type definitions for SigalSwap
//
// PairConfig:    Immutable pair configuration (tokens, factory, fee tier)
// QueuedAction:  Timelock action struct for governance (used by Factory)

mod pair_config;
mod queued_action;
pub mod packing;

pub use pair_config::PairConfig;
pub use queued_action::{QueuedAction, TIMELOCK_DELAY, EXECUTION_WINDOW};
pub use packing::{
    pack_u112_pair, unpack_u112_pair, pack_flags, unpack_flags, MAX_U112,
    ReservesPacked, TwapFractions, FlagsPacked,
};
