// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { useEffect, useState, useCallback } from "react";
import { config, type DeployedPair } from "@/lib/config";
import { readPairReserves } from "@/lib/aztec-rpc";

export interface PoolInfo {
  /** Pair slug for routes, e.g. "eth-usdc" */
  id: string;
  /** Pair contract address */
  pairAddress: string;
  token0Symbol: string;
  token1Symbol: string;
  token0Address: string;
  token1Address: string;
  lpTokenAddress: string;
  feeTierBps: number;
  /** On-chain reserves (null until loaded) */
  reserve0: bigint | null;
  reserve1: bigint | null;
  loading: boolean;
  error: string | null;
}

function pairSlug(pair: DeployedPair): string {
  return `${pair.token0Symbol.toLowerCase()}-${pair.token1Symbol.toLowerCase()}`;
}

/**
 * Load all deployed pools and fetch their on-chain reserves.
 * Uses direct node RPC — no wallet connection required.
 */
export function usePools(): {
  pools: PoolInfo[];
  loading: boolean;
  refetch: () => void;
} {
  const [pools, setPools] = useState<PoolInfo[]>(() =>
    config.deployedPairs.map((p) => ({
      id: pairSlug(p),
      pairAddress: p.address,
      token0Symbol: p.token0Symbol,
      token1Symbol: p.token1Symbol,
      token0Address: p.token0Address,
      token1Address: p.token1Address,
      lpTokenAddress: p.lpTokenAddress,
      feeTierBps: p.feeTierBps,
      reserve0: null,
      reserve1: null,
      loading: false,
      error: null,
    })),
  );
  const [tick, setTick] = useState(0);

  const refetch = useCallback(() => setTick((t) => t + 1), []);

  useEffect(() => {
    if (config.deployedPairs.length === 0) return;

    let cancelled = false;

    setPools((prev) => prev.map((p) => ({ ...p, loading: true, error: null })));

    (async () => {
      const results = await Promise.allSettled(
        config.deployedPairs.map((pair) => readPairReserves(pair.address)),
      );

      if (cancelled) return;

      setPools((prev) =>
        prev.map((p, i) => {
          const result = results[i];
          if (result.status === "fulfilled") {
            return {
              ...p,
              reserve0: result.value.reserve0,
              reserve1: result.value.reserve1,
              loading: false,
              error: null,
            };
          }
          return {
            ...p,
            loading: false,
            error: result.reason?.message ?? "Failed to fetch reserves",
          };
        }),
      );
    })();

    return () => { cancelled = true; };
  }, [tick]);

  const loading = pools.some((p) => p.loading);
  return { pools, loading, refetch };
}

/** Find a pool by its slug (e.g. "eth-usdc"). */
export function findPool(pools: PoolInfo[], slug: string): PoolInfo | undefined {
  return pools.find((p) => p.id === slug);
}
