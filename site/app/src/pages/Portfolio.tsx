// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { useState } from "react";
import { Link } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { Shield, Coins, ArrowRight } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { usePools } from "@/hooks/usePools";
import { useTokenBalance } from "@/hooks/useTokenBalance";
import { useSwapHistory } from "@/hooks/useSwapHistory";
import { useWallet } from "@/hooks/useWallet";
import { config } from "@/lib/config";

/** Displays LP balance for a single pool row. */
function PositionRow({ pool }: { pool: ReturnType<typeof usePools>["pools"][number] }) {
  const { balance } = useTokenBalance(pool.lpTokenAddress);
  const lpBal = balance != null ? Number(balance) / 1e18 : 0;

  if (balance == null || balance === 0n) return null;

  return (
    <TableRow>
      <TableCell>
        <div className="flex items-center gap-3 font-medium">
          <div className="flex -space-x-2">
            <div className="flex h-7 w-7 items-center justify-center rounded-full bg-secondary border-2 border-card z-10">
              <Coins className="h-3.5 w-3.5 text-muted-foreground" aria-hidden="true" />
            </div>
            <div className="flex h-7 w-7 items-center justify-center rounded-full bg-secondary border-2 border-card">
              <Coins className="h-3.5 w-3.5 text-muted-foreground" aria-hidden="true" />
            </div>
          </div>
          {pool.token0Symbol}/{pool.token1Symbol}
        </div>
      </TableCell>
      <TableCell className="text-right font-mono">
        {lpBal.toFixed(4)} LP
      </TableCell>
      <TableCell className="text-right">
        <Button asChild variant="outline" size="sm">
          <Link to={`/pools/${pool.id}`}>Manage</Link>
        </Button>
      </TableCell>
    </TableRow>
  );
}

/** Resolve a token address to its symbol from deployed pairs config. */
function tokenSymbol(address: string): string {
  for (const pair of config.deployedPairs) {
    if (pair.token0Address === address) return pair.token0Symbol;
    if (pair.token1Address === address) return pair.token1Symbol;
  }
  return address.slice(0, 8) + "...";
}

export function Portfolio() {
  const { t } = useTranslation();
  const { connected } = useWallet();
  const { pools } = usePools();
  const { swaps, loading: swapsLoading } = useSwapHistory();
  const [tab, setTab] = useState<"positions" | "swaps">("positions");

  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-2xl font-bold">{t("portfolio.title")}</h1>
        <div className="flex items-center gap-2 mt-1 text-xs text-muted-foreground">
          <Shield className="h-3 w-3 text-primary" aria-hidden="true" />
          <span>{t("portfolio.positionsPrivate")}</span>
        </div>
      </div>

      {!connected ? (
        <div className="rounded-xl border border-border bg-card p-8 text-center">
          <p className="text-sm text-muted-foreground">{t("portfolio.connectToView")}</p>
        </div>
      ) : (
        <>
          {/* Tab bar */}
          <div className="inline-flex gap-1 rounded-lg bg-secondary p-1" role="tablist">
            <button
              role="tab"
              aria-selected={tab === "positions"}
              onClick={() => setTab("positions")}
              className={`rounded-md px-6 py-2 text-sm font-medium transition-colors ${
                tab === "positions"
                  ? "bg-background text-foreground shadow-sm"
                  : "text-muted-foreground hover:text-foreground"
              }`}
            >
              {t("portfolio.positions")}
            </button>
            <button
              role="tab"
              aria-selected={tab === "swaps"}
              onClick={() => setTab("swaps")}
              className={`rounded-md px-6 py-2 text-sm font-medium transition-colors ${
                tab === "swaps"
                  ? "bg-background text-foreground shadow-sm"
                  : "text-muted-foreground hover:text-foreground"
              }`}
            >
              {t("portfolio.swapHistory")}
            </button>
          </div>

          {/* Positions tab */}
          {tab === "positions" && (
            <section aria-labelledby="positions-heading">
              {pools.length === 0 ? (
                <div className="rounded-xl border border-border bg-card p-8 text-center">
                  <p className="text-sm text-muted-foreground">{t("portfolio.noPositions")}</p>
                  <Button asChild className="mt-4" size="sm">
                    <Link to="/pools">{t("pools.title")}</Link>
                  </Button>
                </div>
              ) : (
                <div className="rounded-xl border border-border bg-card">
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHead>{t("portfolio.pair")}</TableHead>
                        <TableHead className="text-right">{t("portfolio.lpBalance")}</TableHead>
                        <TableHead className="text-right">{t("portfolio.manage")}</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {pools.map((pool) => (
                        <PositionRow key={pool.id} pool={pool} />
                      ))}
                    </TableBody>
                  </Table>
                </div>
              )}
            </section>
          )}

          {/* Swaps tab */}
          {tab === "swaps" && (
            <section aria-labelledby="swaps-heading">
              {swapsLoading ? (
                <div className="rounded-xl border border-border bg-card p-8 text-center">
                  <p className="text-sm text-muted-foreground">{t("portfolio.loadingSwaps")}</p>
                </div>
              ) : swaps.length === 0 ? (
                <div className="rounded-xl border border-border bg-card p-8 text-center">
                  <p className="text-sm text-muted-foreground">{t("portfolio.noSwaps")}</p>
                </div>
              ) : (
                <div className="rounded-xl border border-border bg-card">
                  <Table>
                    <TableHeader>
                      <TableRow>
                        <TableHead>{t("portfolio.from")}</TableHead>
                        <TableHead />
                        <TableHead>{t("portfolio.to")}</TableHead>
                      </TableRow>
                    </TableHeader>
                    <TableBody>
                      {swaps.map((swap, i) => {
                        const amountInStr = (Number(swap.amountIn) / 1e18).toFixed(4);
                        const amountOutStr = (Number(swap.amountOut) / 1e18).toFixed(4);
                        const inLabel = swap.direction === "exact_out"
                          ? `≤ ${amountInStr}`
                          : amountInStr;
                        const outLabel = swap.direction === "exact_in"
                          ? `${amountOutStr}+`
                          : amountOutStr;
                        return (
                          <TableRow key={i}>
                            <TableCell>
                              <span className="font-mono text-sm">
                                {inLabel} {tokenSymbol(swap.tokenIn)}
                              </span>
                            </TableCell>
                            <TableCell>
                              <ArrowRight className="h-4 w-4 text-muted-foreground" aria-hidden="true" />
                            </TableCell>
                            <TableCell>
                              <span className="font-mono text-sm">
                                {outLabel} {tokenSymbol(swap.tokenOut)}
                              </span>
                            </TableCell>
                          </TableRow>
                        );
                      })}
                    </TableBody>
                  </Table>
                </div>
              )}
            </section>
          )}
        </>
      )}
    </div>
  );
}
