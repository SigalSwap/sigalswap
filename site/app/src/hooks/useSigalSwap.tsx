// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

/**
 * Contract interaction hooks using the common wallet interface.
 *
 * These hooks work with any wallet that implements AztecWalletProvider —
 * Azguard, Obsidion, AZIP-6963 wallets, or any future wallet.
 */

import { useCallback } from "react";
import { useWallet } from "@/hooks/useWallet";
import { config } from "@/lib/config";
import type { Operation, OpResult } from "@/lib/wallet";

const CHAIN_IDS: Record<string, string> = {
  local: "aztec:0",
  testnet: "aztec:1674512022",
  production: "aztec:1674512022",
};

function getChainId(): string {
  return CHAIN_IDS[config.environment] ?? CHAIN_IDS.local;
}

function getCaipAccount(address: string): string {
  // If already in CAIP format, return as-is
  if (address.startsWith("aztec:")) return address;
  return `${getChainId()}:${address}`;
}

/**
 * Execute operations through the wallet and unwrap results.
 */
async function executeOps(
  wallet: { execute: (ops: Operation[]) => Promise<OpResult[]> },
  operations: Operation[],
): Promise<any[]> {
  const results = await wallet.execute(operations);
  return results.map((r) => {
    if (r.error) throw new Error(r.error.message);
    return r.value;
  });
}

/**
 * Hook for calling view/utility functions on contracts.
 */
export function useContractRead() {
  const { activeWallet, address } = useWallet();

  const read = useCallback(async (
    contractAddress: string,
    method: string,
    args: any[] = [],
  ) => {
    if (!activeWallet || !address) throw new Error("Wallet not connected");

    const op = {
      kind: "simulate_views" as const,
      account: getCaipAccount(address),
      calls: [{
        kind: "call" as const,
        contract: contractAddress,
        method,
        args,
      }],
    };
    console.log("[SigalSwap] read:", method, "on", contractAddress.slice(0, 10) + "...");
    const results = await activeWallet.execute([op]);
    const r = results[0];
    if (r.error) {
      console.error("[SigalSwap] read error:", method, r.error);
      throw new Error(r.error.message);
    }
    // simulate_views result is { encoded: string[][], decoded: unknown[] }
    // We called with one call, so decoded[0] is our result
    const viewResult = r.value;
    const decoded = viewResult?.decoded?.[0] ?? viewResult;
    console.log("[SigalSwap] read result:", method, decoded);
    return decoded;
  }, [activeWallet, address]);

  return { read, ready: activeWallet !== null };
}

/**
 * Hook for sending transactions to contracts.
 */
export function useContractWrite() {
  const { activeWallet, address } = useWallet();

  const write = useCallback(async (
    contractAddress: string,
    method: string,
    args: any[] = [],
    actions: any[] = [],
  ) => {
    if (!activeWallet || !address) throw new Error("Wallet not connected");

    const [result] = await executeOps(activeWallet, [{
      kind: "send_transaction",
      account: getCaipAccount(address),
      actions: [
        ...actions,
        { kind: "call", contract: contractAddress, method, args },
      ],
    }]);

    return result;
  }, [activeWallet, address]);

  return { write, ready: activeWallet !== null };
}

/**
 * Hook for creating auth witnesses.
 */
export function useCreateAuthWit() {
  const { activeWallet, address } = useWallet();

  const createAuthWit = useCallback(async (intent: any) => {
    if (!activeWallet || !address) throw new Error("Wallet not connected");

    const [result] = await executeOps(activeWallet, [{
      kind: "aztec_createAuthWit",
      account: getCaipAccount(address),
      messageHashOrIntent: intent,
    }]);

    return result;
  }, [activeWallet, address]);

  return { createAuthWit, ready: activeWallet !== null };
}
