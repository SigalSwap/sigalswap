// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { useState, useCallback } from "react";
import { Link, useParams, Navigate } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { ArrowLeft, Coins, Shield, Plus, Lock, Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { TermsGate } from "@/components/TermsGate";
import { Badge } from "@/components/ui/badge";
import { Separator } from "@/components/ui/separator";
import { SwapSettings } from "@/components/SwapSettings";
import { usePools, findPool } from "@/hooks/usePools";
import { useAddLiquidity } from "@/hooks/useLiquidity";
import { useTokenBalance } from "@/hooks/useTokenBalance";

export function AddLiquidity() {
  const { t } = useTranslation();
  const { pair } = useParams<{ pair: string }>();
  const { pools } = usePools();
  const pool = pair ? findPool(pools, pair) : undefined;
  const { addLiquidity, pending, error: liqError, clearError } = useAddLiquidity();

  const [amount0, setAmount0] = useState("");
  const [amount1, setAmount1] = useState("");
  const [slippage, setSlippage] = useState("0.5");
  const [deadline, setDeadline] = useState("20");

  // Hooks must be called before early returns
  const { balance: bal0 } = useTokenBalance(pool?.token0Address ?? null);
  const { balance: bal1 } = useTokenBalance(pool?.token1Address ?? null);
  const bal0Display = bal0 != null ? (Number(bal0) / 1e18).toFixed(4) : "—";
  const bal1Display = bal1 != null ? (Number(bal1) / 1e18).toFixed(4) : "—";

  if (!pool) return <Navigate to="/pools" replace />;

  const r0 = pool.reserve0 != null ? Number(pool.reserve0) / 1e18 : 0;
  const r1 = pool.reserve1 != null ? Number(pool.reserve1) / 1e18 : 0;
  const pairLabel = `${pool.token0Symbol}/${pool.token1Symbol}`;
  const price = r0 > 0 ? r1 / r0 : 0;
  const inversePrice = r1 > 0 ? r0 / r1 : 0;

  // Auto-fill the second amount based on current ratio
  function handleAmount0Change(val: string) {
    if (val === "" || /^\d*\.?\d*$/.test(val)) {
      setAmount0(val);
      const num = parseFloat(val);
      if (!isNaN(num) && num > 0) {
        setAmount1((num * price).toFixed(2));
      } else {
        setAmount1("");
      }
    }
  }

  function handleAmount1Change(val: string) {
    if (val === "" || /^\d*\.?\d*$/.test(val)) {
      setAmount1(val);
      const num = parseFloat(val);
      if (!isNaN(num) && num > 0) {
        setAmount0((num * inversePrice).toFixed(6));
      } else {
        setAmount0("");
      }
    }
  }

  const hasInput = amount0 !== "" && amount1 !== "" && parseFloat(amount0) > 0;

  const newAmount0 = parseFloat(amount0) || 0;
  const shareOfPool = hasInput && r0 > 0
    ? ((newAmount0 / (r0 + newAmount0)) * 100).toFixed(2)
    : "0";

  return (
    <div className="flex flex-col items-center py-8 sm:py-12">
      <div className="w-full max-w-[460px] space-y-4">
        {/* Back link */}
        <Link
          to={`/pools/${pool.id}`}
          className="inline-flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground transition-colors"
        >
          <ArrowLeft className="h-4 w-4" aria-hidden="true" />
          {pairLabel}
        </Link>

        {/* Card */}
        <div className="rounded-xl bg-card border border-border">
          <div className="flex items-center justify-between px-5 pt-4 pb-2">
            <h1 className="text-base font-medium">{t("pools.addLiquidityTitle")}</h1>
            <div className="flex items-center gap-2">
              <Badge variant="secondary" className="font-mono text-xs">
                {(pool.feeTierBps / 100).toFixed(2)}%
              </Badge>
              <SwapSettings
                slippage={slippage}
                onSlippageChange={setSlippage}
                deadline={deadline}
                onDeadlineChange={setDeadline}
              />
            </div>
          </div>

          <div className="px-4 pb-4 space-y-3">
            {/* Deposit amounts label */}
            <span className="text-xs text-muted-foreground">
              {t("pools.depositAmounts")}
            </span>

            {/* Token 0 input */}
            <div className="rounded-lg bg-background p-4">
              <div className="flex items-center justify-between mb-2">
                <div className="flex items-center gap-2">
                  <div className="flex h-6 w-6 items-center justify-center rounded-full bg-secondary">
                    <Coins className="h-3 w-3 text-muted-foreground" aria-hidden="true" />
                  </div>
                  <span className="text-sm font-medium">{pool.token0Symbol}</span>
                </div>
                <span className="text-xs text-muted-foreground font-mono">
                  {t("swap.balance")}: {bal0Display}
                </span>
              </div>
              <input
                type="text"
                inputMode="decimal"
                placeholder="0"
                value={amount0}
                onChange={(e) => handleAmount0Change(e.target.value)}
                className="w-full bg-transparent text-2xl font-mono font-medium outline-none placeholder:text-muted-foreground/50"
                aria-label={`${pool.token0Symbol} ${t("pools.amount")}`}
              />
            </div>

            {/* Plus icon */}
            <div className="flex justify-center">
              <div className="p-2 rounded-lg bg-secondary border border-border">
                <Plus className="h-4 w-4 text-muted-foreground" aria-hidden="true" />
              </div>
            </div>

            {/* Token 1 input */}
            <div className="rounded-lg bg-background p-4">
              <div className="flex items-center justify-between mb-2">
                <div className="flex items-center gap-2">
                  <div className="flex h-6 w-6 items-center justify-center rounded-full bg-secondary">
                    <Coins className="h-3 w-3 text-muted-foreground" aria-hidden="true" />
                  </div>
                  <span className="text-sm font-medium">{pool.token1Symbol}</span>
                </div>
                <span className="text-xs text-muted-foreground font-mono">
                  {t("swap.balance")}: {bal1Display}
                </span>
              </div>
              <input
                type="text"
                inputMode="decimal"
                placeholder="0"
                value={amount1}
                onChange={(e) => handleAmount1Change(e.target.value)}
                className="w-full bg-transparent text-2xl font-mono font-medium outline-none placeholder:text-muted-foreground/50"
                aria-label={`${pool.token1Symbol} ${t("pools.amount")}`}
              />
            </div>

            {/* Prices and pool share */}
            <div className="rounded-lg bg-background p-4 space-y-2 text-xs">
              <span className="text-muted-foreground font-medium">
                {t("pools.pricesAndPool")}
              </span>
              <div className="grid grid-cols-3 gap-3 pt-1">
                <div className="text-center space-y-1">
                  <p className="font-mono font-medium">
                    {price < 0.01 ? price.toFixed(6) : price.toFixed(2)}
                  </p>
                  <p className="text-muted-foreground">
                    {pool.token1Symbol} per {pool.token0Symbol}
                  </p>
                </div>
                <div className="text-center space-y-1">
                  <p className="font-mono font-medium">
                    {inversePrice < 0.01 ? inversePrice.toFixed(6) : inversePrice.toFixed(4)}
                  </p>
                  <p className="text-muted-foreground">
                    {pool.token0Symbol} per {pool.token1Symbol}
                  </p>
                </div>
                <div className="text-center space-y-1">
                  <p className="font-mono font-medium">{shareOfPool}%</p>
                  <p className="text-muted-foreground">{t("pools.shareOfPool")}</p>
                </div>
              </div>
            </div>

            {/* Supply button */}
            {liqError && (
              <div className="rounded-lg bg-destructive/10 px-3 py-2 text-xs text-destructive">
                {liqError}
              </div>
            )}
            {hasInput ? (
              <TermsGate onAccepted={async () => {
                clearError();
                const a0 = BigInt(Math.floor(parseFloat(amount0) * 1e18));
                const a1 = BigInt(Math.floor(parseFloat(amount1) * 1e18));
                try {
                  await addLiquidity({
                    pairAddress: pool.pairAddress,
                    token0Address: pool.token0Address,
                    token1Address: pool.token1Address,
                    lpTokenAddress: pool.lpTokenAddress,
                    amount0Max: a0,
                    amount1Max: a1,
                    amount0Min: a0 * (10000n - BigInt(Math.round(parseFloat(slippage) * 100))) / 10000n,
                    amount1Min: a1 * (10000n - BigInt(Math.round(parseFloat(slippage) * 100))) / 10000n,
                    deadline: Math.floor(Date.now() / 1000) + parseInt(deadline) * 60,
                  });
                  setAmount0("");
                  setAmount1("");
                } catch { /* error displayed via liqError */ }
              }}>
                <Button className="w-full" size="lg" disabled={pending}>
                  {pending ? (
                    <>
                      <Loader2 className="h-4 w-4 animate-spin" aria-hidden="true" />
                      {t("pools.supplying")}
                    </>
                  ) : t("pools.supplyLiquidity")}
                </Button>
              </TermsGate>
            ) : (
              <Button className="w-full" size="lg" disabled>
                {t("swap.enterAmount")}
              </Button>
            )}
          </div>
        </div>

        {/* Privacy notice */}
        <div className="flex items-center justify-center gap-2 text-xs text-muted-foreground">
          <Lock className="h-3 w-3 text-primary" aria-hidden="true" />
          <span>{t("pools.positionPrivate")}</span>
        </div>
      </div>
    </div>
  );
}
