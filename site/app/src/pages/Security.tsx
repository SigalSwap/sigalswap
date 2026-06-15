// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { Trans, useTranslation } from "react-i18next";
import { Shield, AlertTriangle, Bug, Code, Mail } from "lucide-react";

const link = "text-primary hover:underline";

export function Security() {
  const { t } = useTranslation();

  return (
    <div className="max-w-3xl mx-auto space-y-10">
      <div>
        <h1 className="text-2xl font-bold">{t("security.title")}</h1>
        <p className="mt-2 text-muted-foreground">{t("security.subtitle")}</p>
      </div>

      {/* Audit status */}
      <section aria-labelledby="audit-heading" className="space-y-3">
        <div className="flex items-center gap-2">
          <Shield className="h-5 w-5 text-warning" aria-hidden="true" />
          <h2 id="audit-heading" className="text-lg font-semibold">{t("security.auditStatus")}</h2>
        </div>
        <p className="text-muted-foreground">{t("security.auditBody")}</p>
      </section>

      {/* Network risks */}
      <section aria-labelledby="network-heading" className="space-y-3">
        <div className="flex items-center gap-2">
          <AlertTriangle className="h-5 w-5 text-destructive" aria-hidden="true" />
          <h2 id="network-heading" className="text-lg font-semibold">{t("security.networkRisks")}</h2>
        </div>
        <p className="text-muted-foreground">{t("security.networkRisksIntro")}</p>
        <ul className="space-y-2 text-sm text-muted-foreground list-disc pl-5">
          <li>{t("security.networkRisk1")}</li>
          <li className="text-destructive">{t("security.networkRisk2")}</li>
          <li>{t("security.networkRisk3")}</li>
          <li>{t("security.networkRisk4")}</li>
        </ul>
      </section>

      {/* Contract risks */}
      <section aria-labelledby="contract-heading" className="space-y-3">
        <div className="flex items-center gap-2">
          <Bug className="h-5 w-5 text-warning" aria-hidden="true" />
          <h2 id="contract-heading" className="text-lg font-semibold">{t("security.contractRisks")}</h2>
        </div>
        <p className="text-muted-foreground">{t("security.contractRisksIntro")}</p>
        <ul className="space-y-2 text-sm text-muted-foreground list-disc pl-5">
          <li>{t("security.contractRisk1")}</li>
          <li>{t("security.contractRisk2")}</li>
          <li>{t("security.contractRisk3")}</li>
          <li>{t("security.contractRisk4")}</li>
        </ul>
      </section>

      {/* Recommendation */}
      <section className="rounded-xl border border-warning/30 bg-warning/5 p-5 space-y-2">
        <h2 className="text-base font-semibold">{t("security.recommendation")}</h2>
        <p className="text-sm text-muted-foreground">{t("security.recommendationBody")}</p>
      </section>

      {/* Responsible disclosure */}
      <section aria-labelledby="disclosure-heading" className="space-y-3">
        <div className="flex items-center gap-2">
          <Mail className="h-5 w-5 text-primary" aria-hidden="true" />
          <h2 id="disclosure-heading" className="text-lg font-semibold">{t("security.disclosure")}</h2>
        </div>
        <p className="text-muted-foreground">{t("security.disclosureBody")}</p>
        <p className="font-mono text-sm">{t("security.disclosureEmail")}</p>
        <p className="text-sm text-muted-foreground">{t("security.disclosureResponse")}</p>
      </section>

      {/* Contract addresses */}
      <section aria-labelledby="contracts-heading" className="space-y-3">
        <div className="flex items-center gap-2">
          <Code className="h-5 w-5 text-primary" aria-hidden="true" />
          <h2 id="contracts-heading" className="text-lg font-semibold">{t("security.contracts")}</h2>
        </div>
        <p className="text-muted-foreground">{t("security.contractsBody")}</p>
      </section>

      {/* Source code */}
      <section className="space-y-3">
        <h2 className="text-lg font-semibold">{t("security.sourceCode")}</h2>
        <p className="text-muted-foreground">
          <Trans i18nKey="security.sourceCodeBody" components={{
            github: <a href="https://github.com/SigalSwap" target="_blank" rel="noopener noreferrer" className={link} />,
          }} />
        </p>
      </section>
    </div>
  );
}
