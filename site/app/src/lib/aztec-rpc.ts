// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

/**
 * Direct Aztec node RPC client for reading public contract state.
 *
 * This module reads public storage slots directly from the Aztec node,
 * bypassing the wallet/PXE entirely. No wallet connection required.
 *
 * Use this for:
 * - Pool reserves, config, prices (public state)
 * - Factory pair registry (public state)
 * - Any data that doesn't require private decryption
 *
 * Do NOT use this for:
 * - Private balances (need wallet PXE to decrypt notes)
 * - Sending transactions (need wallet for proving/signing)
 * - Private events (need wallet to decrypt)
 */

import { config } from "@/lib/config";

// ================================================================
// Low-level RPC
// ================================================================

let requestId = 0;

async function rpc(method: string, params: any[]): Promise<any> {
  const res = await fetch(config.nodeUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      method: `node_${method}`,
      params,
      id: ++requestId,
    }),
  });
  const data = await res.json();
  if (data.error) {
    throw new Error(data.error.message ?? "RPC error");
  }
  return data.result;
}

function toHex(n: number | bigint): string {
  return "0x" + BigInt(n).toString(16).padStart(64, "0");
}

function fromHex(hex: string): bigint {
  return BigInt(hex);
}

// ================================================================
// Public storage reader
// ================================================================

/**
 * Read a single public storage slot from a contract.
 */
export async function readPublicStorage(contract: string, slot: number | bigint): Promise<bigint> {
  const result = await rpc("getPublicStorageAt", ["latest", contract, toHex(slot)]);
  return fromHex(result);
}

// ================================================================
// Pair contract reader
// ================================================================

// Storage slots (from compiled artifact)
const PAIR_SLOTS = {
  token0: 1,
  token1: 2,
  liquidityToken: 3,
  factory: 4,
  feeTierBps: 5,
  // slot 6 is initialization-related
  packedReserves: 7,
  blockTimestampLast: 8,
  price0CumulInt: 9,
  price1CumulInt: 10,
  packedTwapFrac: 11,
  packedReservesLast: 12,
  feeTo: 13,
  packedFlags: 14,
} as const;

const U112_MASK = (1n << 112n) - 1n;

function unpackU112Pair(packed: bigint): { high: bigint; low: bigint } {
  return {
    high: (packed >> 112n) & U112_MASK,
    low: packed & U112_MASK,
  };
}

export interface PairReserves {
  reserve0: bigint;
  reserve1: bigint;
}

export interface PairConfig {
  token0: string;
  token1: string;
  liquidityToken: string;
  factory: string;
  feeTierBps: number;
}

/**
 * Read pair reserves directly from the node. No wallet needed.
 */
export async function readPairReserves(pairAddress: string): Promise<PairReserves> {
  const packed = await readPublicStorage(pairAddress, PAIR_SLOTS.packedReserves);
  const { high, low } = unpackU112Pair(packed);
  return { reserve0: high, reserve1: low };
}

/**
 * Read pair configuration directly from the node. No wallet needed.
 */
export async function readPairConfig(pairAddress: string): Promise<PairConfig> {
  const [token0, token1, lp, factory, feeBps] = await Promise.all([
    readPublicStorage(pairAddress, PAIR_SLOTS.token0),
    readPublicStorage(pairAddress, PAIR_SLOTS.token1),
    readPublicStorage(pairAddress, PAIR_SLOTS.liquidityToken),
    readPublicStorage(pairAddress, PAIR_SLOTS.factory),
    readPublicStorage(pairAddress, PAIR_SLOTS.feeTierBps),
  ]);
  return {
    token0: "0x" + token0.toString(16).padStart(64, "0"),
    token1: "0x" + token1.toString(16).padStart(64, "0"),
    liquidityToken: "0x" + lp.toString(16).padStart(64, "0"),
    factory: "0x" + factory.toString(16).padStart(64, "0"),
    feeTierBps: Number(feeBps),
  };
}

/**
 * Read the packed flags to check if the pair is paused.
 */
export async function readPairFlags(pairAddress: string): Promise<{
  isPaused: boolean;
  isLocked: boolean;
  protocolFeeActive: boolean;
  protocolFeePercent: number;
}> {
  const packed = await readPublicStorage(pairAddress, PAIR_SLOTS.packedFlags);
  const n = Number(packed);
  return {
    isPaused: (n & 1) !== 0,
    isLocked: (n & 2) !== 0,
    protocolFeeActive: (n & 4) !== 0,
    protocolFeePercent: Math.floor(n / 8),
  };
}

// ================================================================
// AMM math (mirrors the contract's get_amount_out)
// ================================================================

/**
 * Compute swap output using the constant product formula.
 * This is the same math the pair contract's get_amount_out uses.
 * We compute it locally from public reserves to avoid needing a PXE.
 */
export function computeAmountOut(
  amountIn: bigint,
  reserveIn: bigint,
  reserveOut: bigint,
  feeBps: number,
): bigint {
  if (reserveIn === 0n || reserveOut === 0n || amountIn <= 0n) return 0n;
  const feeAdjusted = amountIn * BigInt(10000 - feeBps);
  const numerator = feeAdjusted * reserveOut;
  const denominator = reserveIn * 10000n + feeAdjusted;
  if (denominator === 0n) return 0n;
  return numerator / denominator;
}

// ================================================================
// Node info
// ================================================================

export async function getBlockNumber(): Promise<number> {
  return await rpc("getBlockNumber", []);
}

export async function isNodeReady(): Promise<boolean> {
  try {
    await rpc("isReady", []);
    return true;
  } catch {
    return false;
  }
}
