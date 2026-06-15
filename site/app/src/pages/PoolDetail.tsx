// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { Link, useParams, Navigate } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { ArrowLeft, Coins, Shield, Plus, Minus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Progress } from "@/components/ui/progress";
import { formatUsd } from "@/lib/utils";
import { usePools, findPool } from "@/hooks/usePools";
import { useTokenBalance } from "@/hooks/useTokenBalance";
import { useContractRead } from "@/hooks/useSigalSwap";
import { Separator } from "@/components/ui/separator";

function StatCard({
  label,
  value,
  accent,
}: {
  label: string;
  value: string;
  accent?: boolean;
}) {
  return (
    <div className="rounded-lg bg-background p-4 space-y-1">
      <span className="text-xs text-muted-foreground">{label}</span>
      <p className={`text-lg font-mono font-medium ${accent ? "text-success" : ""}`}>
        {value}
      </p>
    </div>
  );
}

export function PoolDetail() {
  const { t } = useTranslation();
  const { pair } = useParams<{ pair: string }>();
  const { pools } = usePools();
  const pool = pair ? findPool(pools, pair) : undefined;

  // Hooks must be called before early returns
  const { balance: lpBalance } = useTokenBalance(pool?.lpTokenAddress ?? null);
  const { read, ready: readReady } = useContractRead();

  if (!pool) return <Navigate to="/pools" replace />;

  const pairLabel = `${pool.token0Symbol}/${pool.token1Symbol}`;
  const r0 = pool.reserve0 != null ? Number(pool.reserve0) / 1e18 : 0;
  const r1 = pool.reserve1 != null ? Number(pool.reserve1) / 1e18 : 0;
  const price = r0 > 0 ? r1 / r0 : 0;
  const hasPosition = lpBalance != null && lpBalance > 0n;
  const lpBalDisplay = lpBalance != null ? Number(lpBalance) / 1e18 : 0;

  return (
    <div className="max-w-3xl mx-auto space-y-6">
      {/* Back + header */}
      <div className="space-y-4">
        <Link
          to="/pools"
          className="inline-flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground transition-colors"
        >
          <ArrowLeft className="h-4 w-4" aria-hidden="true" />
          {t("pools.allPools")}
        </Link>

        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3">
            <div className="flex -space-x-2">
              <div className="flex h-9 w-9 items-center justify-center rounded-full bg-secondary border-2 border-background z-10">
                <Coins className="h-4 w-4 text-muted-foreground" aria-hidden="true" />
              </div>
              <div className="flex h-9 w-9 items-center justify-center rounded-full bg-secondary border-2 border-background">
                <Coins className="h-4 w-4 text-muted-foreground" aria-hidden="true" />
              </div>
            </div>
            <div>
              <h1 className="text-2xl font-bold">{pairLabel}</h1>
              <Badge variant="secondary" className="font-mono text-xs mt-0.5">
                {(pool.feeTierBps / 100).toFixed(2)}% {t("pools.feeTier").toLowerCase()}
              </Badge>
            </div>
          </div>
          <div className="flex items-center gap-2">
            <Button asChild variant="outline" size="sm">
              <Link to={`/pools/${pool.id}/remove`}>
                <Minus className="h-4 w-4" aria-hidden="true" />
                {t("pools.removeLiquidity")}
              </Link>
            </Button>
            <Button asChild size="sm">
              <Link to={`/pools/${pool.id}/add`}>
                <Plus className="h-4 w-4" aria-hidden="true" />
                {t("pools.addLiquidity")}
              </Link>
            </Button>
          </div>
        </div>
      </div>

      {/* Stats grid */}
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <StatCard label={t("pools.tvl")} value={r0 + r1 > 0 ? formatUsd(r0 + r1) : "—"} />
        <StatCard label={t("pools.volume24h")} value="—" />
        <StatCard label={t("pools.apr")} value="—" />
        <StatCard
          label={t("pools.currentPrice")}
          value={price > 0
            ? `${price < 0.01 ? price.toFixed(6) : price.toLocaleString(undefined, { maximumFractionDigits: 2 })} ${pool.token1Symbol}`
            : "—"}
        />
      </div>

      {/* Reserves */}
      <div className="rounded-xl border border-border bg-card p-5 space-y-4">
        <h2 className="text-sm font-medium">{t("pools.reserves")}</h2>
        <div className="space-y-3">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-2">
              <div className="flex h-6 w-6 items-center justify-center rounded-full bg-secondary">
                <Coins className="h-3 w-3 text-muted-foreground" aria-hidden="true" />
              </div>
              <span className="text-sm">{pool.token0Symbol}</span>
            </div>
            <span className="font-mono text-sm">
              {r0.toLocaleString(undefined, { maximumFractionDigits: 4 })}
            </span>
          </div>
          <Progress
            value={r0 + r1 > 0 ? (r0 / (r0 + r1)) * 100 : 50}
            className="h-2"
          />
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-2">
              <div className="flex h-6 w-6 items-center justify-center rounded-full bg-secondary">
                <Coins className="h-3 w-3 text-muted-foreground" aria-hidden="true" />
              </div>
              <span className="text-sm">{pool.token1Symbol}</span>
            </div>
            <span className="font-mono text-sm">
              {r1.toLocaleString(undefined, { maximumFractionDigits: 4 })}
            </span>
          </div>
        </div>
      </div>

      {/* Your position */}
      <div className="rounded-xl border border-border bg-card p-5 space-y-4">
        <div className="flex items-center gap-2">
          <Shield className="h-4 w-4 text-primary" aria-hidden="true" />
          <h2 className="text-sm font-medium">{t("pools.yourPosition")}</h2>
        </div>
        {hasPosition ? (
          <div className="space-y-3">
            <div className="grid grid-cols-2 gap-3">
              <div className="rounded-lg bg-background p-3 space-y-1">
                <span className="text-xs text-muted-foreground">{t("pools.lpTokens")}</span>
                <p className="font-mono font-medium">{lpBalDisplay.toFixed(4)}</p>
              </div>
              <div className="rounded-lg bg-background p-3 space-y-1">
                <span className="text-xs text-muted-foreground">{t("pools.poolShare")}</span>
                <p className="font-mono font-medium">—</p>
              </div>
            </div>
            <Separator />
            <p className="text-xs text-muted-foreground">
              {t("pools.positionPrivate")}
            </p>
          </div>
        ) : (
          <div className="text-center py-6">
            <p className="text-sm text-muted-foreground mb-4">
              You don't have a position in this pool yet.
            </p>
            <Button asChild size="sm">
              <Link to={`/pools/${pool.id}/add`}>
                <Plus className="h-4 w-4" aria-hidden="true" />
                {t("pools.addLiquidity")}
              </Link>
            </Button>
          </div>
        )}
      </div>
    </div>
  );
}

