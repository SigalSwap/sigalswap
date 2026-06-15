// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { Link } from "react-router-dom";
import { useTranslation } from "react-i18next";
import {
  Shield,
  Zap,
  Blocks,
  Eye,
  EyeOff,
  Wallet,
  ArrowDownUp,
  ArrowRight,
  CheckCircle,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { Separator } from "@/components/ui/separator";

export function Home() {
  const { t } = useTranslation();

  return (
    <div className="flex flex-col items-center">
      <section className="flex min-h-[calc(100vh-4rem)] flex-col items-center justify-center px-6 py-12 text-center" aria-labelledby="hero-heading">
        <div className="max-w-2xl space-y-6">
          <h1 id="hero-heading" className="text-5xl sm:text-6xl font-bold tracking-tight">
            {t("home.heroTitle")}
          </h1>
          <p className="text-xl text-muted-foreground leading-relaxed">
            {t("home.heroSubtitle")}
          </p>
        </div>
      </section>

      <section className="w-full max-w-5xl px-6 py-16" aria-labelledby="why-heading">
        <h2 id="why-heading" className="text-3xl font-bold text-center mb-12">
          {t("home.whySigalSwap")}
        </h2>
        <div className="grid gap-6 sm:grid-cols-2 lg:grid-cols-4">
          {[
            { icon: Shield, title: t("home.propSandwichTitle"), body: t("home.propSandwichBody") },
            { icon: Zap, title: t("home.propFrontrunTitle"), body: t("home.propFrontrunBody") },
            { icon: EyeOff, title: t("home.propLPTitle"), body: t("home.propLPBody") },
            { icon: Blocks, title: t("home.propComposableTitle"), body: t("home.propComposableBody") },
          ].map(({ icon: Icon, title, body }) => (
            <div key={title} className="rounded-xl border border-border bg-card p-5 space-y-3">
              <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-primary/10">
                <Icon className="h-5 w-5 text-primary" aria-hidden="true" />
              </div>
              <h3 className="text-sm font-semibold">{title}</h3>
              <p className="text-sm text-muted-foreground leading-relaxed">{body}</p>
            </div>
          ))}
        </div>
      </section>

      <section className="w-full max-w-3xl px-6 py-16" aria-labelledby="visibility-heading">
        <h2 id="visibility-heading" className="text-2xl font-bold text-center mb-10">
          {t("home.publicVsPrivate")}
        </h2>
        <div className="grid gap-4 sm:grid-cols-2">
          <div className="rounded-xl border border-border bg-card p-6 space-y-4">
            <div className="flex items-center gap-2">
              <Eye className="h-5 w-5 text-muted-foreground" aria-hidden="true" />
              <h3 className="font-semibold">{t("home.publicLabel")}</h3>
            </div>
            <ul className="space-y-2.5">
              {[t("home.publicReserves"), t("home.publicSupply"), t("home.publicFees")].map((item) => (
                <li key={item} className="flex items-center gap-2 text-sm text-muted-foreground">
                  <CheckCircle className="h-4 w-4 text-muted-foreground/50 shrink-0" aria-hidden="true" />
                  {item}
                </li>
              ))}
            </ul>
          </div>
          <div className="rounded-xl border border-primary/30 bg-card p-6 space-y-4">
            <div className="flex items-center gap-2">
              <EyeOff className="h-5 w-5 text-primary" aria-hidden="true" />
              <h3 className="font-semibold">{t("home.privateLabel")}</h3>
            </div>
            <ul className="space-y-2.5">
              {[t("home.privateSwaps"), t("home.privatePositions"), t("home.privateHistory")].map((item) => (
                <li key={item} className="flex items-center gap-2 text-sm text-muted-foreground">
                  <Shield className="h-4 w-4 text-primary shrink-0" aria-hidden="true" />
                  {item}
                </li>
              ))}
            </ul>
          </div>
        </div>
      </section>

      <section className="w-full max-w-4xl px-6 py-16" aria-labelledby="how-heading">
        <h2 id="how-heading" className="text-2xl font-bold text-center mb-12">
          {t("home.howItWorks")}
        </h2>
        <div className="grid gap-8 sm:grid-cols-3">
          {[
            { icon: Wallet, num: "1", title: t("home.step1Title"), body: t("home.step1Body") },
            { icon: ArrowDownUp, num: "2", title: t("home.step2Title"), body: t("home.step2Body") },
            { icon: CheckCircle, num: "3", title: t("home.step3Title"), body: t("home.step3Body") },
          ].map(({ icon: Icon, num, title, body }) => (
            <div key={num} className="text-center space-y-4">
              <div className="mx-auto flex h-14 w-14 items-center justify-center rounded-full bg-primary/10">
                <Icon className="h-6 w-6 text-primary" aria-hidden="true" />
              </div>
              <div className="flex items-center justify-center gap-2">
                <span className="flex h-6 w-6 items-center justify-center rounded-full bg-secondary text-xs font-mono font-bold">
                  {num}
                </span>
                <h3 className="font-semibold">{title}</h3>
              </div>
              <p className="text-sm text-muted-foreground leading-relaxed">{body}</p>
            </div>
          ))}
        </div>

        <Link
          to="/docs/overview"
          className="mt-10 block w-full max-w-md mx-auto rounded-xl border border-border bg-card p-5 text-center transition-colors hover:border-primary/40 hover:bg-card/80"
        >
          <p className="text-sm text-muted-foreground leading-relaxed">
            {t("home.learnMoreBody")}
          </p>
          <span className="inline-flex items-center gap-1.5 mt-3 text-sm font-medium text-link">
            {t("home.learnMoreLink")}
            <ArrowRight className="h-3.5 w-3.5" aria-hidden="true" />
          </span>
        </Link>
      </section>

      <section className="w-full max-w-2xl px-6 py-20 text-center" aria-labelledby="cta-heading">
        <Separator className="mb-20" />
        <h2 id="cta-heading" className="text-3xl font-bold mb-4">
          {t("home.ctaTitle")}
        </h2>
        <p className="text-lg text-muted-foreground mb-8">
          {t("home.ctaBody")}
        </p>
        <Button asChild size="lg">
          <Link to="/docs/overview">
            {t("home.ctaButton")}
          </Link>
        </Button>
      </section>
    </div>
  );
}
