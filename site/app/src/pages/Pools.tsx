// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { Link } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { Plus, Coins, Shield } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { formatUsd } from "@/lib/utils";
import { usePools } from "@/hooks/usePools";

export function Pools() {
  const { t } = useTranslation();
  const { pools, loading } = usePools();

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold">{t("pools.title")}</h1>
        <Button asChild>
          <Link to={pools.length > 0 ? `/pools/${pools[0].id}/add` : "/pools"}>
            <Plus className="h-4 w-4" aria-hidden="true" />
            {t("pools.newPosition")}
          </Link>
        </Button>
      </div>

      {/* Pool table */}
      <div className="rounded-xl border border-border bg-card">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>{t("pools.pair")}</TableHead>
              <TableHead>{t("pools.feeTier")}</TableHead>
              <TableHead className="">{t("pools.tvl")}</TableHead>
              <TableHead className="">{t("pools.volume24h")}</TableHead>
              <TableHead className="">{t("pools.apr")}</TableHead>
              <TableHead className="">
                <span className="flex items-center gap-1">
                  <Shield className="h-3 w-3 text-primary" aria-hidden="true" />
                  {t("pools.yourLiquidity")}
                </span>
              </TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {pools.length === 0 && (
              <TableRow>
                <TableCell colSpan={6} className="text-center text-sm text-muted-foreground py-8">
                  {t("pools.noPools")}
                </TableCell>
              </TableRow>
            )}
            {pools.map((pool) => {
              const r0 = pool.reserve0 != null ? Number(pool.reserve0) / 1e18 : null;
              const r1 = pool.reserve1 != null ? Number(pool.reserve1) / 1e18 : null;
              return (
                <TableRow key={pool.id} className="group">
                  <TableCell>
                    <Link
                      to={`/pools/${pool.id}`}
                      className="flex items-center gap-3 font-medium group-hover:text-primary transition-colors"
                      aria-label={`${pool.token0Symbol}/${pool.token1Symbol} ${t("pools.viewPool")}`}
                    >
                      <div className="flex -space-x-2">
                        <div className="flex h-7 w-7 items-center justify-center rounded-full bg-secondary border-2 border-card z-10">
                          <Coins className="h-3.5 w-3.5 text-muted-foreground" aria-hidden="true" />
                        </div>
                        <div className="flex h-7 w-7 items-center justify-center rounded-full bg-secondary border-2 border-card">
                          <Coins className="h-3.5 w-3.5 text-muted-foreground" aria-hidden="true" />
                        </div>
                      </div>
                      <span>
                        {pool.token0Symbol}/{pool.token1Symbol}
                      </span>
                    </Link>
                  </TableCell>
                  <TableCell>
                    <Badge variant="secondary" className="font-mono text-xs">
                      {(pool.feeTierBps / 100).toFixed(2)}%
                    </Badge>
                  </TableCell>
                  <TableCell className="font-mono">
                    {pool.loading ? "..." : r0 != null && r1 != null
                      ? formatUsd(r0 + r1)
                      : <span className="text-muted-foreground">—</span>}
                  </TableCell>
                  <TableCell className="font-mono">
                    <span className="text-muted-foreground">—</span>
                  </TableCell>
                  <TableCell className="font-mono text-success">
                    <span className="text-muted-foreground">—</span>
                  </TableCell>
                  <TableCell className="font-mono">
                    <span className="text-muted-foreground">—</span>
                  </TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
      </div>
    </div>
  );
}
