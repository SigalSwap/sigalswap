// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { useEffect, useState, useCallback } from "react";
import { useContractRead } from "@/hooks/useSigalSwap";
import { useWallet } from "@/hooks/useWallet";

/**
 * Read a token's private balance for the connected wallet.
 */
export function useTokenBalance(tokenAddress: string | null): {
  balance: bigint | null;
  loading: boolean;
  error: string | null;
  refetch: () => void;
} {
  const { read, ready } = useContractRead();
  const { address } = useWallet();
  const [balance, setBalance] = useState<bigint | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);

  const refetch = useCallback(() => setTick((t) => t + 1), []);

  useEffect(() => {
    if (!ready || !tokenAddress || !address) {
      setBalance(null);
      return;
    }

    let cancelled = false;
    setLoading(true);
    setError(null);

    (async () => {
      try {
        const result = await read(tokenAddress, "balance_of_private", [address]);
        if (!cancelled) {
          setBalance(BigInt(result?.toString?.() ?? result ?? 0));
        }
      } catch (e) {
        if (!cancelled) {
          setError(e instanceof Error ? e.message : "Failed to fetch balance");
        }
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();

    return () => { cancelled = true; };
  }, [ready, tokenAddress, address, read, tick]);

  return { balance, loading, error, refetch };
}
