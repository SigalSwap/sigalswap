// SPDX-License-Identifier: MIT
// Copyright (c) 2026 SigalSwap LLC

import { Fr } from '@aztec/foundation/curves/bn254';

/**
 * Permanently-locked LP token amount on first mint, mirrored from the pair's
 * `MINIMUM_LIQUIDITY` global at `protocol/core/src/pair/mod.nr`.
 *
 * The contract subtracts this from the first depositor's LP mint and locks
 * the remainder at the LP Token's address-zero balance, so no one can drain
 * LP supply down to zero by burning the very last unit. Off-chain quoters
 * computing first-deposit LP-out should subtract this amount.
 */
export const MINIMUM_LIQUIDITY: bigint = 10000n;

/**
 * Timelock delay (seconds) before a queued governance action becomes
 * executable. Mirrored from `protocol/factory/src/main.nr`.
 *
 * 48 hours -- gives users a window to exit positions or audit the change
 * before it goes live.
 */
export const TIMELOCK_DELAY_SECONDS: bigint = 172800n;

/**
 * Timelock execution window (seconds) after the delay elapses, during which
 * the action may be executed. Mirrored from `protocol/factory/src/main.nr`.
 *
 * 7 days -- a queued action that isn't executed within this window expires
 * and must be re-queued (paying another full delay). Bounds the
 * "indefinitely-pending action" surface that an inattentive admin could
 * leave for an attacker to time.
 */
export const TIMELOCK_WINDOW_SECONDS: bigint = 604800n;

/**
 * Maximum interface fee in basis points that the router accepts on swaps.
 * Mirrored from `protocol/periphery/src/libraries/mod.nr`.
 *
 * 500 bps = 5%. Caps the surcharge an integrating frontend can layer on top
 * of the AMM fee without making the SDK look like a phishing surface for
 * runaway interface fees.
 */
export const MAX_INTERFACE_FEE_BIPS: number = 500;

/**
 * Salt used when deploying each pair's LP Token. Mirrored from
 * `protocol/core/src/main.nr`. Always equal to `Fr.ONE`.
 *
 * Required because the pair derives its LP Token's address using this salt
 * + the LP Token's class_id + canonical deploy inputs (`deployer = zero`,
 * `public_keys = default`). Any other salt lands the LP Token at an address
 * the pair cannot reach, breaking mint/burn flows. `createPair` uses this
 * value automatically; integrators deploying LP tokens manually must too.
 *
 * Same Field value as `CANONICAL_DEPLOY_SALT` (re-exported under both names
 * for clarity: this name matches the contract global, the other emphasizes
 * the deploy-time semantics).
 */
export const LP_TOKEN_SALT: Fr = new Fr(1n);

/**
 * Compile-time class_id of the LP Token contract, mirrored from
 * `protocol/core/src/main.nr`.
 *
 * Indexers and explorers use this to verify the contract instance at a
 * pair's derived LP Token address actually has the expected class_id; if
 * the LP Token bytecode is ever changed, this constant changes and the
 * pair's address derivation rotates accordingly. The `class_id_probe.nr`
 * test in the lp-token package + `lp_token_class_id_constant_matches_compiled_bytecode`
 * in core both fire if the value drifts from the compiled bytecode.
 */
export const LP_TOKEN_CLASS_ID: Fr = Fr.fromString(
  '0x18d88f757fa7311208ca30529ea9cd60c78a2823a0e287ec661cbdc7f193f26c',
);
