// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { useEffect, useState, useCallback } from "react";
import { useContractRead } from "@/hooks/useSigalSwap";

export interface PairData {
  reserves: { reserve0: bigint; reserve1: bigint } | null;
  loading: boolean;
  error: string | null;
  refetch: () => void;
}

/**
 * Fetch reserves for a pair via the wallet's execute_utility API.
 */
export function usePairReserves(pairAddress: string | null): PairData {
  const { read, ready } = useContractRead();
  const [reserves, setReserves] = useState<{ reserve0: bigint; reserve1: bigint } | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);

  const refetch = useCallback(() => setTick((t) => t + 1), []);

  useEffect(() => {
    if (!ready || !pairAddress) {
      setReserves(null);
      return;
    }

    let cancelled = false;
    setLoading(true);
    setError(null);

    (async () => {
      try {
        const result = await read(pairAddress, "get_reserves");
        if (!cancelled) {
          setReserves({
            reserve0: BigInt(result.reserve0 ?? result[0] ?? 0),
            reserve1: BigInt(result.reserve1 ?? result[1] ?? 0),
          });
        }
      } catch (e) {
        if (!cancelled) {
          setError(e instanceof Error ? e.message : "Failed to fetch reserves");
        }
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();

    return () => { cancelled = true; };
  }, [ready, pairAddress, read, tick]);

  return { reserves, loading, error, refetch };
}
