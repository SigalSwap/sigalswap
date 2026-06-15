// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { useState } from "react";
import { Link, useParams, Navigate } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { ArrowLeft, Coins, ArrowDown, Lock, Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { TermsGate } from "@/components/TermsGate";
import { Badge } from "@/components/ui/badge";
import { Slider } from "@/components/ui/slider";
import { SwapSettings } from "@/components/SwapSettings";
import { usePools, findPool } from "@/hooks/usePools";
import { useRemoveLiquidity } from "@/hooks/useLiquidity";
import { useTokenBalance } from "@/hooks/useTokenBalance";

const PERCENT_PRESETS = [25, 50, 75, 100];

export function RemoveLiquidity() {
  const { t } = useTranslation();
  const { pair } = useParams<{ pair: string }>();
  const { pools } = usePools();
  const pool = pair ? findPool(pools, pair) : undefined;
  const { removeLiquidity, pending, error: removeError, clearError } = useRemoveLiquidity();

  const [percent, setPercent] = useState(0);
  const [slippage, setSlippage] = useState("0.5");
  const [deadline, setDeadline] = useState("20");

  // LP token balance (must be called before early returns)
  const { balance: lpBalance } = useTokenBalance(pool?.lpTokenAddress ?? null);

  if (!pool) return <Navigate to="/pools" replace />;

  const pairLabel = `${pool.token0Symbol}/${pool.token1Symbol}`;
  const hasPosition = lpBalance != null && lpBalance > 0n;

  const r0 = pool.reserve0 != null ? Number(pool.reserve0) / 1e18 : 0;
  const r1 = pool.reserve1 != null ? Number(pool.reserve1) / 1e18 : 0;

  // Estimate receive amounts from LP balance
  const lpBalNum = lpBalance != null ? Number(lpBalance) / 1e18 : 0;
  const receiveToken0 = lpBalNum * percent / 100;
  const receiveToken1 = lpBalNum * percent / 100;
  const hasAmount = percent > 0;

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
            <h1 className="text-base font-medium">{t("pools.removeLiquidityTitle")}</h1>
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

          <div className="px-4 pb-4 space-y-4">
            {/* Amount section */}
            <div className="rounded-lg bg-background p-5 space-y-4">
              <div className="flex items-center justify-between">
                <span className="text-xs text-muted-foreground">
                  {t("pools.amount")}
                </span>
              </div>
              <p
                className="text-4xl font-mono font-bold text-center"
                aria-live="polite"
              >
                {percent}%
              </p>

              {/* Slider */}
              <Slider
                value={[percent]}
                onValueChange={([val]) => setPercent(val)}
                max={100}
                step={1}
                aria-label={t("pools.amount")}
                className="py-2"
              />

              {/* Preset buttons */}
              <div className="flex items-center gap-2">
                {PERCENT_PRESETS.map((p) => (
                  <Button
                    key={p}
                    variant={percent === p ? "default" : "secondary"}
                    size="sm"
                    onClick={() => setPercent(p)}
                    className="flex-1"
                  >
                    {p === 100 ? t("swap.max") : `${p}%`}
                  </Button>
                ))}
              </div>
            </div>

            {/* Arrow */}
            <div className="flex justify-center">
              <div className="p-2 rounded-lg bg-secondary border border-border">
                <ArrowDown className="h-4 w-4 text-muted-foreground" aria-hidden="true" />
              </div>
            </div>

            {/* You will receive */}
            <div className="rounded-lg bg-background p-4 space-y-3">
              <span className="text-xs text-muted-foreground">
                {t("pools.youWillReceive")}
              </span>
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-2">
                  <div className="flex h-6 w-6 items-center justify-center rounded-full bg-secondary">
                    <Coins className="h-3 w-3 text-muted-foreground" aria-hidden="true" />
                  </div>
                  <span className="text-sm">{pool.token0Symbol}</span>
                </div>
                <span className="text-lg font-mono font-medium">
                  {receiveToken0 > 0 ? receiveToken0.toFixed(4) : "0"}
                </span>
              </div>
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-2">
                  <div className="flex h-6 w-6 items-center justify-center rounded-full bg-secondary">
                    <Coins className="h-3 w-3 text-muted-foreground" aria-hidden="true" />
                  </div>
                  <span className="text-sm">{pool.token1Symbol}</span>
                </div>
                <span className="text-lg font-mono font-medium">
                  {receiveToken1 > 0 ? receiveToken1.toFixed(2) : "0"}
                </span>
              </div>
            </div>

            {removeError && (
              <div className="rounded-lg bg-destructive/10 px-3 py-2 text-xs text-destructive">
                {removeError}
              </div>
            )}
            {/* Remove button */}
            {hasAmount && hasPosition ? (
              <TermsGate onAccepted={async () => {
                clearError();
                const liquidity = BigInt(Math.floor(lpBalNum * percent / 100 * 1e18));
                const slippageBps = BigInt(Math.round(parseFloat(slippage) * 100));
                const expected0 = BigInt(Math.floor(receiveToken0 * 1e18));
                const expected1 = BigInt(Math.floor(receiveToken1 * 1e18));
                try {
                  await removeLiquidity({
                    pairAddress: pool.pairAddress,
                    token0Address: pool.token0Address,
                    token1Address: pool.token1Address,
                    lpTokenAddress: pool.lpTokenAddress,
                    liquidity,
                    amount0Min: expected0 * (10000n - slippageBps) / 10000n,
                    amount1Min: expected1 * (10000n - slippageBps) / 10000n,
                    deadline: Math.floor(Date.now() / 1000) + parseInt(deadline) * 60,
                  });
                  setPercent(0);
                } catch { /* error displayed via removeError */ }
              }}>
                <Button className="w-full" size="lg" disabled={pending}>
                  {pending ? (
                    <>
                      <Loader2 className="h-4 w-4 animate-spin" aria-hidden="true" />
                      {t("pools.removing")}
                    </>
                  ) : `${t("pools.confirmRemove")} ${percent}%`}
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
