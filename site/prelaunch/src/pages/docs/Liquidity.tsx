// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { useTranslation } from "react-i18next";
import { DocsLayout } from "@/components/DocsLayout";

export function DocsLiquidity() {
  const { t } = useTranslation();

  return (
    <DocsLayout>
      <h1>{t("docs.liquidityTitle")}</h1>
      <p>{t("docs.liquidityIntro")}</p>

      <h2>{t("docs.liquidityHow")}</h2>
      <p>{t("docs.liquidityHowBody")}</p>

      <h2>{t("docs.liquidityAdd")}</h2>
      <p>{t("docs.liquidityAddBody")}</p>

      <h2>{t("docs.liquidityRemove")}</h2>
      <p>{t("docs.liquidityRemoveBody")}</p>

      <h2>{t("docs.liquidityIL")}</h2>
      <p>{t("docs.liquidityILBody")}</p>

      <h2>{t("docs.liquidityPrivacy")}</h2>
      <p>{t("docs.liquidityPrivacyBody")}</p>
    </DocsLayout>
  );
}
