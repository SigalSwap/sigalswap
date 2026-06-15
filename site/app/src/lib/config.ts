// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

/**
 * Site configuration derived from environment variables.
 * Maps VITE_* env vars to the shape expected by @sigalswap/sdk.
 *
 * Env files:
 *   .env.local      — local Aztec sandbox (npm run dev)
 *   .env.testnet    — Aztec testnet (npm run dev:testnet)
 *   .env.production — mainnet / alpha network (npm run build)
 */

export type Environment = "local" | "testnet" | "production";

export interface DeployedPair {
  address: string;
  token0Address: string;
  token0Symbol: string;
  token1Address: string;
  token1Symbol: string;
  lpTokenAddress: string;
  feeTierBps: number;
}

export interface SiteConfig {
  environment: Environment;
  nodeUrl: string;
  factoryAddress: string;
  routerAddress: string;
  feeRecipient: string;
  feeBips: number;
  deployedPairs: DeployedPair[];
}

/** Load deployed pairs from VITE_PAIR_{n}_* env vars. */
function loadDeployedPairs(): DeployedPair[] {
  const pairs: DeployedPair[] = [];
  for (let i = 0; i < 10; i++) {
    const addr = import.meta.env[`VITE_PAIR_${i}_ADDRESS`];
    if (!addr) break;
    pairs.push({
      address: addr,
      token0Address: import.meta.env[`VITE_PAIR_${i}_TOKEN0_ADDRESS`] ?? "",
      token0Symbol: import.meta.env[`VITE_PAIR_${i}_TOKEN0_SYMBOL`] ?? `T0`,
      token1Address: import.meta.env[`VITE_PAIR_${i}_TOKEN1_ADDRESS`] ?? "",
      token1Symbol: import.meta.env[`VITE_PAIR_${i}_TOKEN1_SYMBOL`] ?? `T1`,
      lpTokenAddress: import.meta.env[`VITE_PAIR_${i}_LP_TOKEN_ADDRESS`] ?? "",
      feeTierBps: Number(import.meta.env[`VITE_PAIR_${i}_FEE_TIER_BPS`] ?? 25),
    });
  }
  return pairs;
}

export const config: SiteConfig = {
  environment: (import.meta.env.VITE_ENVIRONMENT as Environment) ?? "local",
  nodeUrl: import.meta.env.VITE_NODE_URL ?? "http://localhost:8080",
  factoryAddress: import.meta.env.VITE_FACTORY_ADDRESS ?? "",
  routerAddress: import.meta.env.VITE_ROUTER_ADDRESS ?? "",
  feeRecipient: import.meta.env.VITE_FEE_RECIPIENT ?? "",
  feeBips: Number(import.meta.env.VITE_FEE_BIPS ?? 0),
  deployedPairs: loadDeployedPairs(),
};

export const isLocal = config.environment === "local";
export const isTestnet = config.environment === "testnet";
export const isProduction = config.environment === "production";

/**
 * Whether the SDK can be initialized (requires node URL at minimum).
 */
export const isSDKReady = config.nodeUrl !== "";
