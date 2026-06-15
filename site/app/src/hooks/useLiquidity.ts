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

function randomNonce(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
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

// ================================================================
// Add Liquidity
// ================================================================

export interface AddLiquidityParams {
  pairAddress: string;
  token0Address: string;
  token1Address: string;
  lpTokenAddress: string;
  amount0Max: bigint;
  amount1Max: bigint;
  amount0Min: bigint;
  amount1Min: bigint;
  deadline: number;
}

export function useAddLiquidity() {
  const { activeWallet, address } = useWallet();
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const addLiquidity = useCallback(async (params: AddLiquidityParams) => {
    if (!activeWallet || !address) throw new Error("Wallet not connected");

    setPending(true);
    setError(null);

    try {
      const account = getCaipAccount(address);
      const nonce = randomNonce();

      // Single send_transaction with authwit actions + add_liquidity call
      await executeOps(activeWallet, [{
        kind: "send_transaction",
        account,
        actions: [
          {
            kind: "add_private_authwit",
            content: {
              kind: "call",
              caller: config.routerAddress,
              contract: params.token0Address,
              method: "transfer_to_public_and_prepare_private_balance_increase",
              args: [address, params.pairAddress, params.amount0Max.toString(), nonce],
            },
          },
          {
            kind: "add_private_authwit",
            content: {
              kind: "call",
              caller: config.routerAddress,
              contract: params.token1Address,
              method: "transfer_to_public_and_prepare_private_balance_increase",
              args: [address, params.pairAddress, params.amount1Max.toString(), nonce],
            },
          },
          {
            kind: "call",
            contract: config.routerAddress,
            method: "add_liquidity",
            args: [
              params.pairAddress,
              params.token0Address,
              params.token1Address,
              params.lpTokenAddress,
              params.amount0Max.toString(),
              params.amount1Max.toString(),
              params.amount0Min.toString(),
              params.amount1Min.toString(),
              params.deadline,
              nonce,
            ],
          },
        ],
      }]);
    } catch (e) {
      const msg = e instanceof Error ? e.message : "Add liquidity failed";
      setError(msg);
      throw e;
    } finally {
      setPending(false);
    }
  }, [activeWallet, address]);

  const clearError = useCallback(() => setError(null), []);
  return { addLiquidity, pending, error, clearError, ready: activeWallet !== null };
}

// ================================================================
// Remove Liquidity
// ================================================================

export interface RemoveLiquidityParams {
  pairAddress: string;
  token0Address: string;
  token1Address: string;
  lpTokenAddress: string;
  liquidity: bigint;
  amount0Min: bigint;
  amount1Min: bigint;
  deadline: number;
}

export function useRemoveLiquidity() {
  const { activeWallet, address } = useWallet();
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const removeLiquidity = useCallback(async (params: RemoveLiquidityParams) => {
    if (!activeWallet || !address) throw new Error("Wallet not connected");

    setPending(true);
    setError(null);

    try {
      const account = getCaipAccount(address);
      const nonce = randomNonce();

      // Single send_transaction with authwit action + remove_liquidity call
      await executeOps(activeWallet, [{
        kind: "send_transaction",
        account,
        actions: [
          {
            kind: "add_private_authwit",
            content: {
              kind: "call",
              caller: config.routerAddress,
              contract: params.lpTokenAddress,
              method: "transfer_to_public",
              args: [address, params.pairAddress, params.liquidity.toString(), nonce],
            },
          },
          {
            kind: "call",
            contract: config.routerAddress,
            method: "remove_liquidity",
            args: [
              params.pairAddress,
              params.token0Address,
              params.token1Address,
              params.lpTokenAddress,
              params.liquidity.toString(),
              params.amount0Min.toString(),
              params.amount1Min.toString(),
            params.deadline,
            nonce,
          ],
        }],
      }]);
    } catch (e) {
      const msg = e instanceof Error ? e.message : "Remove liquidity failed";
      setError(msg);
      throw e;
    } finally {
      setPending(false);
    }
  }, [activeWallet, address]);

  const clearError = useCallback(() => setError(null), []);
  return { removeLiquidity, pending, error, clearError, ready: activeWallet !== null };
}
