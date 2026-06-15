// SPDX-License-Identifier: MIT
// Copyright (c) 2026 SigalSwap LLC

import { AztecAddress } from '@aztec/aztec.js/addresses';

import type { SigalSwapPairContract } from './artifacts/SigalSwapPair.js';
import type { SigalSwapFactoryContract } from './artifacts/SigalSwapFactory.js';

/**
 * Result of a pair-vs-factory cross-check.
 *
 * `verified` is true iff the factory reports the supplied pair address as
 * registered at the pair's self-reported `(tokens, feeTier, version)` slot.
 * `registeredAt` carries whatever the factory returned (zero on missing
 * registration, a different address on impersonation), so callers that
 * need to surface "factory has X here" in an error message have it.
 */
export interface PairRegistrationCheck {
  verified: boolean;
  registeredAt: AztecAddress;
  /** Set when the cross-check itself failed (revert, network error). */
  reason?: string;
  /**
   * The pair config read during the check (token0, token1, lpToken), returned
   * so a caller that also needs the config (e.g. the router's consistency
   * check) can reuse this read instead of issuing a second `get_config`
   * simulate. Undefined when the check itself failed before reading config.
   */
  config?: { token0: AztecAddress; token1: AztecAddress; lpToken: AztecAddress };
}

/**
 * Cross-check that a pair address is genuinely registered in the factory
 * at the pair's self-reported version.
 *
 * The pair's `get_config()` is self-reported and a malicious clone can lie
 * consistently; the consistency-check helpers (`assertSingleHopConsistency`,
 * `assertTokensMatchPair`) read the same self-report and pass against a
 * lying pair. This helper closes the circle by asking the factory whether
 * THAT version of the pair is registered at THAT slot.
 *
 * Returns instead of throwing so callers can decide their own error shape.
 * The `SigalSwapClient.verifyPair()` boolean wrapper and the router's
 * pre-tx assertion both use this.
 */
export async function checkPairRegistration(
  pairAddress: AztecAddress,
  pairContract: SigalSwapPairContract,
  factoryContract: SigalSwapFactoryContract,
  senderAddress: AztecAddress,
): Promise<PairRegistrationCheck> {
  try {
    const { result: config } = await pairContract.methods
      .get_config()
      .simulate({ from: senderAddress });
    const { result: registered } = await factoryContract.methods
      .get_pair_versioned(
        config.token0,
        config.token1,
        Number(config.fee_tier_bps),
        Number(config.version),
      )
      .simulate({ from: senderAddress });
    return {
      verified: registered.equals(pairAddress),
      registeredAt: registered,
      config: {
        token0: config.token0,
        token1: config.token1,
        lpToken: config.lp_token,
      },
    };
  } catch (err) {
    return {
      verified: false,
      registeredAt: AztecAddress.zero(),
      reason: err instanceof Error ? err.message : String(err),
    };
  }
}
