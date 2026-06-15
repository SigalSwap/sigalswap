// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { useTranslation } from "react-i18next";
import { DocsLayout } from "@/components/DocsLayout";

export function DocsFeesDoc() {
  const { t } = useTranslation();

  return (
    <DocsLayout>
      <h1>{t("docs.feesDocTitle")}</h1>
      <p>{t("docs.feesDocIntro")}</p>

      <h2>{t("docs.feesDocLP")}</h2>
      <p>{t("docs.feesDocLPBody")}</p>

      <h2>{t("docs.feesDocProtocol")}</h2>
      <p>{t("docs.feesDocProtocolBody")}</p>

      <h2>{t("docs.feesDocUI")}</h2>
      <p>{t("docs.feesDocUIBody")}</p>

      <h2>{t("docs.feesDocExample")}</h2>
      <p>{t("docs.feesDocExampleBody")}</p>
    </DocsLayout>
  );
}
