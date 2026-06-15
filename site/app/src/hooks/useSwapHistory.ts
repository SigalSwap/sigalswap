// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { useEffect, useState, useCallback } from "react";
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

export type SwapDirection = "exact_in" | "exact_out";

export interface SwapHistoryEntry {
  tokenIn: string;
  tokenOut: string;
  direction: SwapDirection;
  /**
   * For exact_in: the actual input consumed.
   * For exact_out: the user's authorized upper bound (amount_in_max). The
   * actual input is recoverable from the refund partial note in the same tx
   * or from the public SwapEvent; the UI should label this as "up to".
   */
  amountIn: string;
  /**
   * For exact_in: the slippage floor (amount_out_min).
   * For exact_out: the exact output requested.
   */
  amountOut: string;
}

/**
 * Query the user's private swap events from the pair and router contracts.
 *
 * Swap events are split by direction:
 *   - Pair: PrivateSwapExactInEvent / PrivateSwapExactOutEvent
 *   - Router: RouterSwapExactInEvent / RouterSwapExactOutEvent
 *
 * For exact-out swaps the event carries the user's upper bound (amount_in_max),
 * not the actual input consumed. The caller should display it as "up to X".
 */
export function useSwapHistory(): {
  swaps: SwapHistoryEntry[];
  loading: boolean;
  error: string | null;
  refetch: () => void;
} {
  const { activeWallet, address } = useWallet();
  const [swaps, setSwaps] = useState<SwapHistoryEntry[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);

  const refetch = useCallback(() => setTick((t) => t + 1), []);

  useEffect(() => {
    if (!activeWallet || !address || config.deployedPairs.length === 0) {
      setSwaps([]);
      return;
    }

    let cancelled = false;
    setLoading(true);
    setError(null);

    (async () => {
      try {
        const chain = getChainId();
        const allSwaps: SwapHistoryEntry[] = [];

        type EventQuery = {
          contract: string;
          eventName: string;
          direction: SwapDirection;
          fieldNames: string[];
        };

        const exactInFields = ["token_in", "token_out", "amount_in", "amount_out_min"];
        const exactOutFields = ["token_in", "token_out", "amount_in_max", "amount_out"];
        const eventQueries: EventQuery[] = [];

        // Pair contracts: direct swaps (both directions)
        for (const pair of config.deployedPairs) {
          eventQueries.push({
            contract: pair.address,
            eventName: "PrivateSwapExactInEvent",
            direction: "exact_in",
            fieldNames: exactInFields,
          });
          eventQueries.push({
            contract: pair.address,
            eventName: "PrivateSwapExactOutEvent",
            direction: "exact_out",
            fieldNames: exactOutFields,
          });
        }

        // Router: router-mediated swaps (both directions)
        if (config.routerAddress) {
          eventQueries.push({
            contract: config.routerAddress,
            eventName: "RouterSwapExactInEvent",
            direction: "exact_in",
            fieldNames: exactInFields,
          });
          eventQueries.push({
            contract: config.routerAddress,
            eventName: "RouterSwapExactOutEvent",
            direction: "exact_out",
            fieldNames: exactOutFields,
          });
        }

        for (const query of eventQueries) {
          const ops: Operation[] = [{
            kind: "aztec_getPrivateEvents",
            chain,
            eventMetadata: {
              contractAddress: query.contract,
              eventName: query.eventName,
              fieldNames: query.fieldNames,
            },
            eventFilter: {
              from: 0,
              limit: 50,
            },
          }];

          const results: OpResult[] = await activeWallet.execute(ops);
          const result = results[0];

          if (result.error) continue;

          const events = Array.isArray(result.value) ? result.value : [];
          for (const evt of events) {
            const amountInKey = query.direction === "exact_in" ? "amount_in" : "amount_in_max";
            const amountOutKey = query.direction === "exact_in" ? "amount_out_min" : "amount_out";
            allSwaps.push({
              tokenIn: evt.token_in?.toString?.() ?? evt[0]?.toString?.() ?? "",
              tokenOut: evt.token_out?.toString?.() ?? evt[1]?.toString?.() ?? "",
              direction: query.direction,
              amountIn: evt[amountInKey]?.toString?.() ?? evt[2]?.toString?.() ?? "0",
              amountOut: evt[amountOutKey]?.toString?.() ?? evt[3]?.toString?.() ?? "0",
            });
          }
        }

        if (!cancelled) {
          setSwaps(allSwaps);
        }
      } catch (e) {
        if (!cancelled) {
          setError(e instanceof Error ? e.message : "Failed to load swap history");
        }
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();

    return () => { cancelled = true; };
  }, [activeWallet, address, tick]);

  return { swaps, loading, error, refetch };
}
