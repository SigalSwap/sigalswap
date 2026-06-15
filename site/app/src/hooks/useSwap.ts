// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { useState, useCallback } from "react";
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
  if (address.startsWith("aztec:")) return address;
  return `${getChainId()}:${address}`;
}

/** Generate a random 32-byte hex nonce (matches Noir's Field). */
function randomNonce(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  // Zero the top byte to keep it within the field modulus
  bytes[0] = 0;
  return "0x" + Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

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

export interface SwapParams {
  pairAddress: string;
  tokenInAddress: string;
  tokenOutAddress: string;
  amountIn: bigint;
  amountOutMin: bigint;
  deadline: number;
}

/**
 * Hook for executing a swap through the router contract.
 *
 * Handles the full flow:
 * 1. Create an authwit so the router can transfer the user's input tokens
 * 2. Send the swap transaction with the authwit nonce
 */
export function useSwap() {
  const { activeWallet, address } = useWallet();
  const [swapping, setSwapping] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const swap = useCallback(async (params: SwapParams) => {
    if (!activeWallet || !address) throw new Error("Wallet not connected");

    setSwapping(true);
    setError(null);

    try {
      const account = getCaipAccount(address);
      const nonce = randomNonce();

      // Single send_transaction with authwit action + swap call
      // The wallet creates the authwit automatically from the content
      await executeOps(activeWallet, [{
        kind: "send_transaction",
        account,
        actions: [
          {
            kind: "add_private_authwit",
            content: {
              kind: "call",
              caller: config.routerAddress,
              contract: params.tokenInAddress,
              method: "transfer_to_public",
              args: [
                address,                         // from (sender)
                config.routerAddress,             // to (router)
                params.amountIn.toString(),       // amount
                nonce,                            // nonce
              ],
            },
          },
          {
            kind: "call",
            contract: config.routerAddress,
            method: "swap_exact_in",
            args: [
              params.pairAddress,
              params.tokenInAddress,
              params.tokenOutAddress,
              params.amountIn.toString(),
              params.amountOutMin.toString(),
              params.deadline,
              nonce,
            ],
          },
        ],
      }]);
    } catch (e) {
      const msg = e instanceof Error ? e.message : "Swap failed";
      setError(msg);
      throw e;
    } finally {
      setSwapping(false);
    }
  }, [activeWallet, address]);

  const clearError = useCallback(() => setError(null), []);

  return { swap, swapping, error, clearError, ready: activeWallet !== null };
}
