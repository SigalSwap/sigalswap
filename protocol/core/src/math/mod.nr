// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 SigalSwap LLC. All rights reserved.
// Licensed under the Business Source License 1.1. See LICENSE in this directory.

// Math libraries for SigalSwap
// - safe_math: Underflow-safe subtraction
// - sqrt: Babylonian square root
// - fixed_point: UQ112x112 fixed-point for price accumulators

mod safe_math;
mod sqrt;
pub mod fixed_point;
pub mod wide;

// Re-export for convenient access
pub use safe_math::safe_sub;
pub use sqrt::{sqrt, min};
pub use fixed_point::{UQ112x112, encode, uqdiv, accumulate_price, decode, zero};
