// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { useState, useCallback, useMemo } from "react";
import { useTranslation } from "react-i18next";
import { TermsGate } from "@/components/TermsGate";
import {
  ArrowDownUp,
  ChevronDown,
  Shield,
  Lock,
  Coins,
  ChevronRight,
  Loader2,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import {
  Collapsible,
  CollapsibleContent,
  CollapsibleTrigger,
} from "@/components/ui/collapsible";
import { cn } from "@/lib/utils";
import { TokenSelector } from "@/components/TokenSelector";
import { SwapSettings } from "@/components/SwapSettings";
import { usePools, type PoolInfo } from "@/hooks/usePools";
import { useSwap } from "@/hooks/useSwap";
import { useTokenBalance } from "@/hooks/useTokenBalance";
import { useWallet } from "@/hooks/useWallet";
import { computeAmountOut } from "@/lib/aztec-rpc";
import { type Token } from "@/lib/utils";

/** Derive the available token list from deployed pairs. */
function tokensFromPools(pools: PoolInfo[]): Token[] {
  const seen = new Set<string>();
  const tokens: Token[] = [];
  for (const pool of pools) {
    if (!seen.has(pool.token0Symbol)) {
      seen.add(pool.token0Symbol);
      tokens.push({
        symbol: pool.token0Symbol,
        name: pool.token0Symbol,
        decimals: 18,
        address: pool.token0Address,
      });
    }
    if (!seen.has(pool.token1Symbol)) {
      seen.add(pool.token1Symbol);
      tokens.push({
        symbol: pool.token1Symbol,
        name: pool.token1Symbol,
        decimals: 18,
        address: pool.token1Address,
      });
    }
  }
  return tokens;
}

/** Find the pool that matches a token pair (in either direction). */
function findPoolForPair(
  pools: PoolInfo[],
  tokenA: string,
  tokenB: string,
): { pool: PoolInfo; reversed: boolean } | null {
  for (const pool of pools) {
    if (pool.token0Address === tokenA && pool.token1Address === tokenB)
      return { pool, reversed: false };
    if (pool.token1Address === tokenA && pool.token0Address === tokenB)
      return { pool, reversed: true };
  }
  return null;
}

function TokenButton({
  token,
  label,
}: {
  token: Token | null;
  label: string;
}) {
  return (
    <button
      className="flex items-center gap-2 rounded-lg bg-secondary px-3 py-1.5 text-sm font-medium transition-colors hover:bg-secondary/80 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
    >
      {token ? (
        <>
          <div className="flex h-5 w-5 items-center justify-center rounded-full bg-background">
            <Coins className="h-3 w-3 text-muted-foreground" aria-hidden="true" />
          </div>
          {token.symbol}
        </>
      ) : (
        <span className="text-primary">{label}</span>
      )}
      <ChevronDown className="h-3 w-3 text-muted-foreground" aria-hidden="true" />
    </button>
  );
}

export function SwapCard() {
  const { t } = useTranslation();
  const { pools } = usePools();
  const { swap: executeSwap, swapping, error: swapError, clearError } = useSwap();
  const { connected } = useWallet();

  const tokens = useMemo(() => tokensFromPools(pools), [pools]);

  const [tokenIn, setTokenIn] = useState<Token | null>(null);
  const [tokenOut, setTokenOut] = useState<Token | null>(null);
  const [amountIn, setAmountIn] = useState("");
  const [slippage, setSlippage] = useState("0.5");
  const [deadline, setDeadline] = useState("20");
  const [detailsOpen, setDetailsOpen] = useState(false);

  // Auto-select first pair if tokens aren't set
  const effectiveTokenIn = tokenIn ?? tokens[0] ?? null;
  const effectiveTokenOut = tokenOut ?? tokens[1] ?? null;

  // Token balances
  const { balance: balanceIn } = useTokenBalance(effectiveTokenIn?.address ?? null);
  const balanceInDisplay = balanceIn != null ? (Number(balanceIn) / 1e18).toFixed(4) : "—";

  // Find the matching pool for this token pair
  const match =
    effectiveTokenIn && effectiveTokenOut
      ? findPoolForPair(pools, effectiveTokenIn.address, effectiveTokenOut.address)
      : null;

  const feeBps = match?.pool.feeTierBps ?? 25;
  const parsedAmountIn = parseFloat(amountIn) || 0;

  const reserveIn = match
    ? (match.reversed ? match.pool.reserve1 : match.pool.reserve0)
    : null;
  const reserveOut = match
    ? (match.reversed ? match.pool.reserve0 : match.pool.reserve1)
    : null;

  // Compute quote from public reserves (read via direct node RPC, no wallet needed)
  const amountOutNum = useMemo(() => {
    if (!match || !reserveIn || !reserveOut || parsedAmountIn <= 0) return 0;
    const scaledIn = BigInt(Math.floor(parsedAmountIn * 1e18));
    const totalFeeBps = feeBps + Math.floor(feeBps * 0.2); // LP fee + protocol markup
    const out = computeAmountOut(scaledIn, reserveIn, reserveOut, totalFeeBps);
    return Number(out) / 1e18;
  }, [match, reserveIn, reserveOut, parsedAmountIn, feeBps]);
  const amountOut =
    amountOutNum > 0
      ? amountOutNum < 0.01
        ? amountOutNum.toFixed(6)
        : amountOutNum.toFixed(4)
      : "";

  const rate =
    reserveIn != null && reserveOut != null && reserveIn > 0n
      ? Number(reserveOut) / Number(reserveIn)
      : 0;

  const hasInput = amountIn !== "" && parsedAmountIn > 0;

  const handleSwapDirection = useCallback(() => {
    setTokenIn(effectiveTokenOut);
    setTokenOut(effectiveTokenIn);
    setAmountIn(amountOut);
  }, [effectiveTokenIn, effectiveTokenOut, amountOut]);

  const lpFeeBps = feeBps;
  const protocolFeeBps = Math.floor(feeBps * 0.2); // 20% protocol markup
  const uiFeeBps = 0;
  const totalFeeBps = lpFeeBps + protocolFeeBps + uiFeeBps;
  const minReceived = hasInput && amountOutNum > 0
    ? (amountOutNum * (1 - parseFloat(slippage) / 100)).toFixed(4)
    : "—";

  const handleSwap = useCallback(async () => {
    if (!match || !effectiveTokenIn || !effectiveTokenOut || !hasInput) return;

    clearError();

    try {
      const amountInScaled = BigInt(Math.floor(parsedAmountIn * 1e18));
      const amountOutMinScaled = BigInt(
        Math.floor(amountOutNum * (1 - parseFloat(slippage) / 100) * 1e18),
      );

      await executeSwap({
        pairAddress: match.pool.pairAddress,
        tokenInAddress: effectiveTokenIn.address,
        tokenOutAddress: effectiveTokenOut.address,
        amountIn: amountInScaled,
        amountOutMin: amountOutMinScaled,
        deadline: Math.floor(Date.now() / 1000) + parseInt(deadline) * 60,
      });

      // Reset on success
      setAmountIn("");
    } catch {
      // Error is already set in useSwap
    }
  }, [match, effectiveTokenIn, effectiveTokenOut, hasInput, parsedAmountIn, amountOutNum, slippage, deadline, executeSwap, clearError]);

  return (
    <div className="w-full max-w-[460px]">
      <div className="rounded-xl bg-card border border-border">
        <div className="flex items-center justify-between px-5 pt-4 pb-2">
          <span className="text-base font-medium">{t("swap.title")}</span>
          <div className="flex items-center gap-1">
            <Tooltip>
              <TooltipTrigger asChild>
                <div className="flex items-center gap-1 rounded-md px-2 py-1">
                  <Lock className="h-3.5 w-3.5 text-primary" aria-hidden="true" />
                  <span className="text-xs text-primary">{t("common.private")}</span>
                </div>
              </TooltipTrigger>
              <TooltipContent>
                <p>{t("swap.amountsShielded")}</p>
              </TooltipContent>
            </Tooltip>
            <SwapSettings
              slippage={slippage}
              onSlippageChange={setSlippage}
              deadline={deadline}
              onDeadlineChange={setDeadline}
            />
          </div>
        </div>

        <div className="px-4 pb-4 space-y-1">
          {/* Input token */}
          <div className="rounded-lg bg-background p-4">
            <div className="flex items-center justify-between mb-2">
              <span className="text-xs text-muted-foreground">
                {t("swap.youPay")}
              </span>
              <span className="text-xs text-muted-foreground font-mono">
                {t("swap.balance")}: {balanceInDisplay}
              </span>
            </div>
            <div className="flex items-center gap-3">
              <input
                type="text"
                inputMode="decimal"
                placeholder="0"
                value={amountIn}
                onChange={(e) => {
                  const val = e.target.value;
                  if (val === "" || /^\d*\.?\d*$/.test(val)) {
                    setAmountIn(val);
                  }
                }}
                className="flex-1 bg-transparent text-2xl font-mono font-medium outline-none placeholder:text-muted-foreground/50"
                aria-label={`${t("swap.youPay")} amount`}
              />
              {effectiveTokenIn && (
                <TokenSelector
                  selected={effectiveTokenIn}
                  onSelect={setTokenIn}
                  disabledSymbol={effectiveTokenOut?.symbol}
                  trigger={
                    <TokenButton token={effectiveTokenIn} label={t("swap.selectToken")} />
                  }
                />
              )}
            </div>
          </div>

          {/* Swap direction */}
          <div className="flex justify-center -my-3 relative z-10">
            <button
              onClick={handleSwapDirection}
              className="rounded-lg border border-border bg-card p-2 transition-colors hover:bg-secondary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
              aria-label={t("swap.swapDirection")}
            >
              <ArrowDownUp className="h-4 w-4 text-muted-foreground" aria-hidden="true" />
            </button>
          </div>

          {/* Output token */}
          <div className="rounded-lg bg-background p-4">
            <div className="flex items-center justify-between mb-2">
              <span className="text-xs text-muted-foreground">
                {t("swap.youReceive")}
              </span>
              <span className="flex items-center gap-1 text-xs text-muted-foreground">
                <Shield className="h-3 w-3 text-primary" aria-hidden="true" />
                {t("common.private")}
              </span>
            </div>
            <div className="flex items-center gap-3">
              <span
                className={cn(
                  "flex-1 text-2xl font-mono font-medium",
                  !amountOut && "text-muted-foreground/50",
                )}
                aria-label={`${t("swap.youReceive")} amount`}
                aria-live="polite"
              >
                {amountOut || "0"}
              </span>
              {effectiveTokenOut && (
                <TokenSelector
                  selected={effectiveTokenOut}
                  onSelect={setTokenOut}
                  disabledSymbol={effectiveTokenIn?.symbol}
                  trigger={
                    <TokenButton token={effectiveTokenOut} label={t("swap.selectToken")} />
                  }
                />
              )}
            </div>
          </div>

          {/* No pool warning */}
          {effectiveTokenIn && effectiveTokenOut && !match && (
            <div className="rounded-lg bg-destructive/10 px-3 py-2 text-xs text-destructive">
              {t("swap.noPool")}
            </div>
          )}

          {/* Price & details */}
          {hasInput && match && (
            <Collapsible open={detailsOpen} onOpenChange={setDetailsOpen}>
              <CollapsibleTrigger asChild>
                <button className="flex w-full items-center justify-between rounded-lg px-3 py-2.5 text-xs text-muted-foreground transition-colors hover:bg-background focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring">
                  <span className="font-mono">
                    1 {effectiveTokenIn?.symbol} ={" "}
                    {rate < 0.01
                      ? rate.toFixed(6)
                      : rate.toLocaleString(undefined, {
                          maximumFractionDigits: 4,
                        })}{" "}
                    {effectiveTokenOut?.symbol}
                  </span>
                  <ChevronRight
                    className={cn(
                      "h-3.5 w-3.5 transition-transform",
                      detailsOpen && "rotate-90",
                    )}
                    aria-hidden="true"
                  />
                </button>
              </CollapsibleTrigger>
              <CollapsibleContent>
                <div className="space-y-2 rounded-lg bg-background px-3 py-3 text-xs">
                  <div className="flex justify-between">
                    <span className="text-muted-foreground">{t("swap.priceImpact")}</span>
                    <span className="text-success font-mono">{"<0.01%"}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-muted-foreground">{t("swap.minimumReceived")}</span>
                    <span className="font-mono">{minReceived} {effectiveTokenOut?.symbol}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-muted-foreground">
                      {t("swap.lpFee")} ({(lpFeeBps / 100).toFixed(2)}%)
                    </span>
                    <span className="font-mono">
                      {((parsedAmountIn * lpFeeBps) / 10000).toFixed(6)} {effectiveTokenIn?.symbol}
                    </span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-muted-foreground">
                      {t("swap.protocolFee")} ({(protocolFeeBps / 100).toFixed(2)}%)
                    </span>
                    <span className="font-mono">
                      {((parsedAmountIn * protocolFeeBps) / 10000).toFixed(6)} {effectiveTokenIn?.symbol}
                    </span>
                  </div>
                  <div className="flex justify-between border-t border-border pt-2">
                    <span className="text-muted-foreground font-medium">{t("swap.totalFee")}</span>
                    <span className="font-mono font-medium">{(totalFeeBps / 100).toFixed(2)}%</span>
                  </div>
                </div>
              </CollapsibleContent>
            </Collapsible>
          )}

          {/* Swap error */}
          {swapError && (
            <div className="rounded-lg bg-destructive/10 px-3 py-2 text-xs text-destructive">
              {swapError}
            </div>
          )}

          {/* Action button */}
          {!connected ? (
            <Button className="w-full mt-2" size="lg" disabled>
              {t("swap.connectWallet")}
            </Button>
          ) : hasInput && match ? (
            <TermsGate onAccepted={handleSwap}>
              <Button className="w-full mt-2" size="lg" disabled={swapping}>
                {swapping ? (
                  <>
                    <Loader2 className="h-4 w-4 animate-spin" aria-hidden="true" />
                    {t("swap.swapping")}
                  </>
                ) : (
                  t("swap.reviewSwap")
                )}
              </Button>
            </TermsGate>
          ) : (
            <Button className="w-full mt-2" size="lg" disabled>
              {t("swap.enterAmount")}
            </Button>
          )}
        </div>
      </div>

      {/* Privacy footer */}
      <div className="flex items-center justify-center gap-2 mt-4 text-xs text-muted-foreground">
        <Lock className="h-3 w-3 text-primary" aria-hidden="true" />
        <span>{t("swap.amountsShielded")}</span>
      </div>
    </div>
  );
}
