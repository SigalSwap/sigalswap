// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { Link } from "react-router-dom";
import { Trans, useTranslation } from "react-i18next";
import { DocsLayout } from "@/components/DocsLayout";

const link = "text-primary hover:underline";

export function DocsFAQ() {
  const { t } = useTranslation();

  return (
    <DocsLayout>
      <h1>{t("docs.faqTitle")}</h1>

      <div className="space-y-6">
        <div>
          <h2 className="text-base">{t("docs.faqSafe")}</h2>
          <p>
            <Trans i18nKey="docs.faqSafeBody" components={{
              security: <Link to="/security" className={link} />,
            }} />
          </p>
        </div>
        <div>
          <h2 className="text-base">{t("docs.faqDifferent")}</h2>
          <p>{t("docs.faqDifferentBody")}</p>
        </div>
        <div>
          <h2 className="text-base">{t("docs.faqFrontRunning")}</h2>
          <p>{t("docs.faqFrontRunningBody")}</p>
        </div>
        <div>
          <h2 className="text-base">{t("docs.faqAztecDown")}</h2>
          <p>{t("docs.faqAztecDownBody")}</p>
        </div>
        <div>
          <h2 className="text-base">{t("docs.faqTokens")}</h2>
          <p>
            <Trans i18nKey="docs.faqTokensBody" components={{
              pools: <Link to="/pools" className={link} />,
            }} />
          </p>
        </div>
        <div>
          <h2 className="text-base">{t("docs.faqCost")}</h2>
          <p>{t("docs.faqCostBody")}</p>
        </div>
      </div>
    </DocsLayout>
  );
}
