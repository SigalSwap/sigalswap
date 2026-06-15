// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { Link } from "react-router-dom";
import { Trans, useTranslation } from "react-i18next";
import { DocsLayout } from "@/components/DocsLayout";

const link = "text-primary hover:underline";

export function DocsGettingStarted() {
  const { t } = useTranslation();

  return (
    <DocsLayout>
      <h1>{t("docs.gettingStartedTitle")}</h1>
      <p>{t("docs.gettingStartedIntro")}</p>

      <ol>
        <li>
          <strong>{t("docs.gettingStartedStep1Title")}</strong>
          <p className="mt-1">
            <Trans i18nKey="docs.gettingStartedStep1Body" components={{
              azguard: <a href="https://chromewebstore.google.com/detail/azguard-wallet/pliilpflcmabdiapdeihifihkbdfnbmn" target="_blank" rel="noopener noreferrer" className={link} />,
              obsidion: <a href="https://app.obsidion.xyz/" target="_blank" rel="noopener noreferrer" className={link} />,
            }} />
          </p>
        </li>
        <li>
          <strong>{t("docs.gettingStartedStep2Title")}</strong>
          <p className="mt-1">{t("docs.gettingStartedStep2Body")}</p>
        </li>
        <li>
          <strong>{t("docs.gettingStartedStep3Title")}</strong>
          <p className="mt-1">
            <Trans i18nKey="docs.gettingStartedStep3Body" components={{
              ecosystem: <Link to="/ecosystem" className={link} />,
            }} />
          </p>
        </li>
        <li>
          <strong>{t("docs.gettingStartedStep4Title")}</strong>
          <p className="mt-1">
            <Trans i18nKey="docs.gettingStartedStep4Body" components={{
              swap: <Link to="/swap" className={link} />,
            }} />
          </p>
        </li>
      </ol>
    </DocsLayout>
  );
}
