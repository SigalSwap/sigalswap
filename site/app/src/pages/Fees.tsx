// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { useTranslation } from "react-i18next";
import { Badge } from "@/components/ui/badge";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

const FEE_TIERS = [
  { bps: 5, label: "0.05%", purpose: "Stable pairs", active: true },
  { bps: 25, label: "0.25%", purpose: "Standard pairs", active: true },
  { bps: 100, label: "1.00%", purpose: "Exotic / volatile pairs", active: true },
];

const PROTOCOL_MARKUP = 0;
const UI_FEE_BPS = 0;

function FeeCard({ title, description, rate, status }: {
  title: string; description: string; rate: string; status: "active" | "inactive";
}) {
  const { t } = useTranslation();
  return (
    <div className="rounded-xl border border-border bg-card p-5 space-y-3">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-medium">{title}</h3>
        <Badge variant={status === "active" ? "default" : "secondary"} className="text-xs">
          {status === "active" ? t("fees.active") : t("fees.inactive")}
        </Badge>
      </div>
      <p className="text-sm text-muted-foreground">{description}</p>
      <p className="text-2xl font-mono font-bold">{rate}</p>
    </div>
  );
}

export function Fees() {
  const { t } = useTranslation();

  return (
    <div className="max-w-3xl mx-auto space-y-8">
      <div>
        <h1 className="text-2xl font-bold">{t("fees.title")}</h1>
        <p className="mt-2 text-muted-foreground">{t("fees.subtitle")}</p>
      </div>

      <div className="grid gap-4 sm:grid-cols-3">
        <FeeCard title={t("fees.lpFeeTitle")} description={t("fees.lpFeeDescription")} rate="Tier-based" status="active" />
        <FeeCard title={t("fees.protocolFeeTitle")} description={t("fees.protocolFeeDescription")} rate={PROTOCOL_MARKUP > 0 ? `${PROTOCOL_MARKUP}%` : t("fees.off")} status={PROTOCOL_MARKUP > 0 ? "active" : "inactive"} />
        <FeeCard title={t("fees.uiFeeTitle")} description={t("fees.uiFeeDescription")} rate={UI_FEE_BPS > 0 ? `${(UI_FEE_BPS / 100).toFixed(2)}%` : t("fees.off")} status={UI_FEE_BPS > 0 ? "active" : "inactive"} />
      </div>

      <section aria-labelledby="tiers-heading">
        <h2 id="tiers-heading" className="text-lg font-semibold mb-4">{t("fees.feeTiers")}</h2>
        <div className="rounded-xl border border-border bg-card">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>{t("fees.tier")}</TableHead>
                <TableHead>Use case</TableHead>
                <TableHead className="text-right">{t("fees.lpRate")}</TableHead>
                <TableHead className="text-right">{t("fees.protocolRate")}</TableHead>
                <TableHead className="text-right">{t("fees.uiRate")}</TableHead>
                <TableHead className="text-right">{t("fees.traderPays")}</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {FEE_TIERS.map((tier) => {
                const protocolBps = PROTOCOL_MARKUP > 0 ? Math.round(tier.bps * PROTOCOL_MARKUP / 100) : 0;
                const totalBps = tier.bps + protocolBps + UI_FEE_BPS;
                return (
                  <TableRow key={tier.bps}>
                    <TableCell className="font-mono font-medium">{tier.label}</TableCell>
                    <TableCell className="text-muted-foreground">{tier.purpose}</TableCell>
                    <TableCell className="text-right font-mono">{tier.label}</TableCell>
                    <TableCell className="text-right font-mono">{protocolBps > 0 ? `${(protocolBps / 100).toFixed(2)}%` : "—"}</TableCell>
                    <TableCell className="text-right font-mono">{UI_FEE_BPS > 0 ? `${(UI_FEE_BPS / 100).toFixed(2)}%` : "—"}</TableCell>
                    <TableCell className="text-right font-mono font-medium">{(totalBps / 100).toFixed(2)}%</TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        </div>
      </section>

      <section className="rounded-xl border border-border bg-card p-5 space-y-3" aria-labelledby="settings-heading">
        <h2 id="settings-heading" className="text-sm font-medium">{t("fees.currentSettings")}</h2>
        <div className="grid grid-cols-2 gap-4 text-sm">
          <div>
            <span className="text-muted-foreground">{t("fees.protocolFee")}</span>
            <p className="font-mono font-medium mt-0.5">{PROTOCOL_MARKUP > 0 ? `${PROTOCOL_MARKUP}%` : t("fees.off")}</p>
          </div>
          <div>
            <span className="text-muted-foreground">{t("fees.uiFeeTitle")}</span>
            <p className="font-mono font-medium mt-0.5">{UI_FEE_BPS > 0 ? `${(UI_FEE_BPS / 100).toFixed(2)}%` : t("fees.off")}</p>
          </div>
        </div>
      </section>
    </div>
  );
}
