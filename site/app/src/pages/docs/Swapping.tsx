// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { useTranslation } from "react-i18next";
import { DocsLayout } from "@/components/DocsLayout";

export function DocsSwapping() {
  const { t } = useTranslation();

  return (
    <DocsLayout>
      <h1>{t("docs.swappingTitle")}</h1>
      <p>{t("docs.swappingIntro")}</p>

      <ol>
        <li>{t("docs.swappingStep1")}</li>
        <li>{t("docs.swappingStep2")}</li>
        <li>{t("docs.swappingStep3")}</li>
        <li>{t("docs.swappingStep4")}</li>
      </ol>

      <h2>{t("docs.swappingSlippage")}</h2>
      <p>{t("docs.swappingSlippageBody")}</p>

      <h2>{t("docs.swappingDeadline")}</h2>
      <p>{t("docs.swappingDeadlineBody")}</p>

      <h2>{t("docs.swappingPrivacy")}</h2>
      <p>{t("docs.swappingPrivacyBody")}</p>
    </DocsLayout>
  );
}
