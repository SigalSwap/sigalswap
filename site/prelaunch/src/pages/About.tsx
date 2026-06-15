// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { useTranslation, Trans } from "react-i18next";
import { Logo } from "@/components/Logo";

export function About() {
  const { t } = useTranslation();

  return (
    <div className="max-w-2xl mx-auto space-y-8 py-8">
      <div className="text-center space-y-4">
        <Logo size={64} className="mx-auto" />
        <h1 className="text-3xl font-bold">{t("about.title")}</h1>
        <p className="text-lg text-muted-foreground">{t("about.subtitle")}</p>
      </div>

      <article className="space-y-6 text-base leading-relaxed text-muted-foreground">
        <p>
          <Trans
            i18nKey="about.loreOrigin"
            components={{
              name: <strong className="text-foreground" />,
            }}
          />
        </p>
        <p>
          <Trans
            i18nKey="about.loreHistory"
            components={{
              phrase: <em className="text-foreground" />,
            }}
          />
        </p>
        <p>
          <Trans
            i18nKey="about.loreMeaning"
            components={{
              sovereignty: <strong className="text-foreground" />,
            }}
          />
        </p>
        <p>{t("about.loreToday")}</p>
      </article>
    </div>
  );
}
