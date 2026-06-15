// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { useTranslation } from "react-i18next";
import { Shield, Zap, EyeOff, Users, Blocks } from "lucide-react";
import { DocsLayout } from "@/components/DocsLayout";

function FeatureCard({
  icon: Icon,
  title,
  body,
}: {
  icon: React.ElementType;
  title: string;
  body: string;
}) {
  return (
    <div className="rounded-lg border border-border bg-card p-4 space-y-2">
      <div className="flex items-center gap-2">
        <Icon className="h-4 w-4 text-primary shrink-0" aria-hidden="true" />
        <h3 className="text-sm font-medium text-foreground leading-none !my-0">{title}</h3>
      </div>
      <p className="text-sm">{body}</p>
    </div>
  );
}

export function DocsOverview() {
  const { t } = useTranslation();

  return (
    <DocsLayout>
      <h1>{t("docs.overviewTitle")}</h1>
      <p className="text-lg">{t("docs.overviewIntro")}</p>

      {/* Protection from bots */}
      <h2>{t("docs.overviewProtection")}</h2>
      <p>{t("docs.overviewProtectionIntro")}</p>

      <div className="space-y-3 not-prose">
        <FeatureCard
          icon={Shield}
          title={t("docs.overviewSandwich")}
          body={t("docs.overviewSandwichBody")}
        />
        <FeatureCard
          icon={Zap}
          title={t("docs.overviewFrontrun")}
          body={t("docs.overviewFrontrunBody")}
        />
        <FeatureCard
          icon={EyeOff}
          title={t("docs.overviewJIT")}
          body={t("docs.overviewJITBody")}
        />
      </div>

      <p>{t("docs.overviewLevelField")}</p>

      {/* LP privacy */}
      <h2>{t("docs.overviewLPPrivacy")}</h2>
      <p>{t("docs.overviewLPPrivacyBody")}</p>

      {/* Composability */}
      <h2>{t("docs.overviewComposability")}</h2>
      <p>{t("docs.overviewComposabilityBody")}</p>

      {/* Defense layers */}
      <h2>{t("docs.overviewDefense")}</h2>
      <div className="not-prose rounded-lg border border-border bg-card overflow-hidden">
        {[
          { icon: EyeOff, text: t("docs.overviewDefensePrivate") },
          { icon: Zap, text: t("docs.overviewDefenseSequencer") },
          { icon: Users, text: t("docs.overviewDefenseDecentralized") },
          { icon: Shield, text: t("docs.overviewDefenseAttestation") },
          { icon: Blocks, text: t("docs.overviewDefenseNoMEV") },
        ].map(({ icon: Icon, text }, i) => (
          <div
            key={i}
            className="flex items-start gap-3 px-4 py-3 text-sm text-muted-foreground border-b border-border last:border-b-0"
          >
            <Icon className="h-4 w-4 text-primary shrink-0 mt-0.5" aria-hidden="true" />
            <span>{text}</span>
          </div>
        ))}
      </div>
      <p>{t("docs.overviewDefenseFooter")}</p>

      {/* How it's built */}
      <h2>{t("docs.overviewHow")}</h2>
      <p>{t("docs.overviewHowBody")}</p>
    </DocsLayout>
  );
}
