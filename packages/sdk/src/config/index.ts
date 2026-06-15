// SPDX-License-Identifier: MIT
// Copyright (c) 2026 SigalSwap LLC

import { AztecAddress } from '@aztec/aztec.js/addresses';
import { MAX_INTERFACE_FEE_BIPS } from '../constants.js';
import { SigalSwapConfigurationError } from '../errors.js';

export type Environment = 'local' | 'testnet' | 'production';

export interface SigalSwapConfig {
  /** Aztec node URL */
  nodeUrl: string;
  /** Environment identifier */
  environment: Environment;
  /** Interface fee recipient (LLC wallet address). Omit or empty for no fee. */
  feeRecipient?: string;
  /** Interface fee in basis points (0-500). 0 = no fee. Contract caps at 500 (5%). */
  feeBips?: number;
}

/** Validate a SigalSwapConfig at construction time. */
export function validateConfig(config: SigalSwapConfig): void {
  if (!config.nodeUrl) {
    throw new SigalSwapConfigurationError(
      'SigalSwap: nodeUrl is required. Provide the Aztec node URL in your config, '
      + 'e.g. { nodeUrl: "http://localhost:8080", environment: "local" }',
    );
  }
  if (config.feeBips !== undefined) {
    // Contract caps interface fee at MAX_INTERFACE_FEE_BIPS (5%); SDK mirrors that cap.
    if (!Number.isInteger(config.feeBips) || config.feeBips < 0 || config.feeBips > MAX_INTERFACE_FEE_BIPS) {
      throw new SigalSwapConfigurationError(
        `SigalSwap: feeBips must be an integer in [0, ${MAX_INTERFACE_FEE_BIPS}], got ${config.feeBips}`,
      );
    }
  }
  if (config.feeBips !== undefined && config.feeBips > 0 && !config.feeRecipient) {
    throw new SigalSwapConfigurationError('SigalSwap: feeBips > 0 requires a feeRecipient address');
  }
  // Parse feeRecipient whenever it's set, regardless of feeBips. A
  // misformatted address must surface here (config-validation time), not
  // later when SigalSwapRouter's constructor parses it on the first
  // client.router() call -- by then the user is debugging the wrong layer.
  if (config.feeRecipient) {
    try {
      AztecAddress.fromString(config.feeRecipient);
    } catch {
      throw new SigalSwapConfigurationError(`SigalSwap: feeRecipient is not a valid Aztec address: ${config.feeRecipient}`);
    }
  }
}

export const LOCAL_CONFIG: Readonly<SigalSwapConfig> = Object.freeze({
  nodeUrl: 'http://localhost:8080',
  environment: 'local' as const,
  feeBips: 0,
});

/** Testnet config template. Spread and set `nodeUrl` before use: `{ ...TESTNET_CONFIG, nodeUrl: '...' }` */
export const TESTNET_CONFIG: Readonly<SigalSwapConfig> = Object.freeze({
  nodeUrl: '', // Must be set to Aztec Alpha Network endpoint before use
  environment: 'testnet' as const,
  feeBips: 0,
});

/** Production config template. Spread and set `nodeUrl`, `feeRecipient`, `feeBips` before use. */
export const PRODUCTION_CONFIG: Readonly<SigalSwapConfig> = Object.freeze({
  nodeUrl: '', // Must be set to Aztec mainnet endpoint before use
  environment: 'production' as const,
  // feeRecipient and feeBips must be set before use
});
