// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { useTranslation } from "react-i18next";
import { Shield, Eye, EyeOff } from "lucide-react";
import { DocsLayout } from "@/components/DocsLayout";

export function DocsHowItWorks() {
  const { t } = useTranslation();

  return (
    <DocsLayout>
      <h1>{t("docs.howItWorksTitle")}</h1>

      <h2>{t("docs.howPublicVsPrivate")}</h2>
      <div className="grid gap-4 sm:grid-cols-2 not-prose">
        <div className="rounded-lg border border-border bg-card p-4 space-y-3">
          <div className="flex items-center gap-2 text-sm font-medium text-foreground">
            <Eye className="h-4 w-4 text-muted-foreground" aria-hidden="true" />
            Public
          </div>
          <ul className="space-y-1.5 text-sm text-muted-foreground list-disc pl-4">
            <li>{t("docs.howPublicReserves")}</li>
            <li>{t("docs.howPublicSupply")}</li>
            <li>{t("docs.howPublicFees")}</li>
          </ul>
        </div>
        <div className="rounded-lg border border-primary/30 bg-card p-4 space-y-3">
          <div className="flex items-center gap-2 text-sm font-medium text-foreground">
            <EyeOff className="h-4 w-4 text-primary" aria-hidden="true" />
            Private
          </div>
          <ul className="space-y-1.5 text-sm text-muted-foreground list-disc pl-4">
            <li>{t("docs.howPrivateSwaps")}</li>
            <li>{t("docs.howPrivateLP")}</li>
            <li>{t("docs.howPrivateHistory")}</li>
          </ul>
        </div>
      </div>

      <h2>{t("docs.howAMMTitle")}</h2>
      <p>{t("docs.howAMMBody")}</p>

      <h2>{t("docs.howPrivacyTitle")}</h2>
      <p>{t("docs.howPrivacyBody")}</p>
    </DocsLayout>
  );
}
