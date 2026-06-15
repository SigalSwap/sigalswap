// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { useTranslation } from "react-i18next";
import {
  ArrowRight,
  Boxes,
  Code2,
  ExternalLink,
  FileCode,
  GitBranch,
  Package,
  Shield,
  Terminal,
  Zap,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";

function CodeBlock({ label, code }: { label: string; code: string }) {
  return (
    <figure className="rounded-lg border border-border bg-card overflow-hidden">
      <figcaption className="border-b border-border bg-secondary/40 px-4 py-2 text-xs font-medium text-muted-foreground">
        {label}
      </figcaption>
      <pre className="overflow-x-auto px-4 py-4 text-xs font-mono leading-relaxed text-foreground">
        <code>{code}</code>
      </pre>
    </figure>
  );
}

function Bullet({
  icon: Icon,
  title,
  body,
}: {
  icon: React.ElementType;
  title: string;
  body: string;
}) {
  return (
    <div className="flex gap-3">
      <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-md bg-primary/10">
        <Icon className="h-4 w-4 text-primary" aria-hidden="true" />
      </div>
      <div className="space-y-1">
        <h3 className="text-sm font-semibold leading-none">{title}</h3>
        <p className="text-sm text-muted-foreground leading-relaxed">{body}</p>
      </div>
    </div>
  );
}

const NARGO_TOML = `[dependencies]
sigalswap_core = { git = "https://github.com/SigalSwap/SigalSwap", tag = "v1.0.0", directory = "protocol/core" }`;

const NOIR_USAGE = `use dep::sigalswap_core::SigalSwapPair;

SigalSwapPair::at(pair_address).swap_exact_in_public(
    token_in, token_out, amount_in, min_out,
    recipient, callback_contract, callback_selector,
).call(&mut context);`;

const SDK_INSTALL = `npm install @sigalswap/sdk`;

const SDK_USAGE = `import { SigalSwapClient } from '@sigalswap/sdk';

const client = await SigalSwapClient.create({
  wallet,
  senderAddress: wallet.getAddress(),
  factoryAddress,
  routerAddress,
});

const pair = await client.pair(pairAddress);
const { reserve0, reserve1 } = await pair.getReserves();

const deadline = Math.floor(Date.now() / 1000) + 3600;
await client.router().swapSingleExactIn({
  pair: pairAddress,
  tokenIn: tokenA,
  tokenOut: tokenB,
  amountIn: 1000n,
  amountOutMin: 900n,
  deadline,
});`;

export function Builders() {
  const { t } = useTranslation();

  const featureKeys = [
    "whatYouGet1",
    "whatYouGet2",
    "whatYouGet3",
    "whatYouGet4",
    "whatYouGet5",
    "whatYouGet6",
    "whatYouGet7",
    "whatYouGet8",
  ] as const;

  const useCases = [
    {
      icon: Boxes,
      title: t("builders.useCaseVaultsTitle"),
      body: t("builders.useCaseVaultsBody"),
    },
    {
      icon: GitBranch,
      title: t("builders.useCaseAggregatorsTitle"),
      body: t("builders.useCaseAggregatorsBody"),
    },
    {
      icon: Terminal,
      title: t("builders.useCaseDappsTitle"),
      body: t("builders.useCaseDappsBody"),
    },
    {
      icon: Zap,
      title: t("builders.useCaseBotsTitle"),
      body: t("builders.useCaseBotsBody"),
    },
  ];

  return (
    <div className="max-w-4xl mx-auto space-y-16">
      {/* Hero */}
      <section aria-labelledby="builders-hero" className="space-y-3">
        <Badge variant="secondary" className="text-xs">
          {t("nav.builders")}
        </Badge>
        <h1 id="builders-hero" className="text-3xl sm:text-4xl font-bold tracking-tight">
          {t("builders.title")}
        </h1>
        <p className="text-lg text-muted-foreground leading-relaxed max-w-2xl">
          {t("builders.subtitle")}
        </p>
      </section>

      {/* Noir lane */}
      <section aria-labelledby="builders-noir" className="space-y-6">
        <div className="flex items-center gap-3">
          <div className="flex h-9 w-9 items-center justify-center rounded-lg bg-primary/10">
            <FileCode className="h-5 w-5 text-primary" aria-hidden="true" />
          </div>
          <div>
            <h2 id="builders-noir" className="text-xl font-semibold">
              {t("builders.noirTitle")}
            </h2>
          </div>
        </div>
        <p className="text-muted-foreground leading-relaxed max-w-2xl">
          {t("builders.noirIntro")}
        </p>
        <div className="grid gap-4 lg:grid-cols-2">
          <CodeBlock label={t("builders.noirDepLabel")} code={NARGO_TOML} />
          <CodeBlock label={t("builders.noirUseLabel")} code={NOIR_USAGE} />
        </div>
        <div className="grid gap-5 sm:grid-cols-3 pt-2">
          <Bullet
            icon={Boxes}
            title={t("builders.noirBullet1Title")}
            body={t("builders.noirBullet1Body")}
          />
          <Bullet
            icon={ArrowRight}
            title={t("builders.noirBullet2Title")}
            body={t("builders.noirBullet2Body")}
          />
          <Bullet
            icon={Zap}
            title={t("builders.noirBullet3Title")}
            body={t("builders.noirBullet3Body")}
          />
        </div>
      </section>

      {/* SDK lane */}
      <section aria-labelledby="builders-sdk" className="space-y-6">
        <div className="flex items-center gap-3">
          <div className="flex h-9 w-9 items-center justify-center rounded-lg bg-primary/10">
            <Package className="h-5 w-5 text-primary" aria-hidden="true" />
          </div>
          <div>
            <h2 id="builders-sdk" className="text-xl font-semibold">
              {t("builders.sdkTitle")}
            </h2>
          </div>
        </div>
        <p className="text-muted-foreground leading-relaxed max-w-2xl">
          {t("builders.sdkIntro")}
        </p>
        <div className="space-y-4">
          <CodeBlock label={t("builders.sdkInstallLabel")} code={SDK_INSTALL} />
          <CodeBlock label={t("builders.sdkUsageLabel")} code={SDK_USAGE} />
        </div>
        <div className="grid gap-5 sm:grid-cols-3 pt-2">
          <Bullet
            icon={Shield}
            title={t("builders.sdkBullet1Title")}
            body={t("builders.sdkBullet1Body")}
          />
          <Bullet
            icon={Code2}
            title={t("builders.sdkBullet2Title")}
            body={t("builders.sdkBullet2Body")}
          />
          <Bullet
            icon={Terminal}
            title={t("builders.sdkBullet3Title")}
            body={t("builders.sdkBullet3Body")}
          />
        </div>
      </section>

      {/* What you get */}
      <section aria-labelledby="builders-features" className="space-y-5">
        <h2 id="builders-features" className="text-xl font-semibold">
          {t("builders.whatYouGetTitle")}
        </h2>
        <ul className="grid gap-3 sm:grid-cols-2" role="list">
          {featureKeys.map((key) => (
            <li
              key={key}
              className="flex items-start gap-2.5 rounded-lg border border-border bg-card px-4 py-3"
            >
              <span
                className="mt-1.5 h-1.5 w-1.5 shrink-0 rounded-full bg-primary"
                aria-hidden="true"
              />
              <span className="text-sm text-muted-foreground leading-relaxed">
                {t(`builders.${key}`)}
              </span>
            </li>
          ))}
        </ul>
      </section>

      {/* Use cases */}
      <section aria-labelledby="builders-usecases" className="space-y-5">
        <h2 id="builders-usecases" className="text-xl font-semibold">
          {t("builders.useCasesTitle")}
        </h2>
        <div className="grid gap-4 sm:grid-cols-2">
          {useCases.map(({ icon: Icon, title, body }) => (
            <div
              key={title}
              className="rounded-xl border border-border bg-card p-5 space-y-3"
            >
              <div className="flex h-9 w-9 items-center justify-center rounded-lg bg-secondary">
                <Icon className="h-4 w-4 text-primary" aria-hidden="true" />
              </div>
              <h3 className="text-sm font-semibold">{title}</h3>
              <p className="text-sm text-muted-foreground leading-relaxed">
                {body}
              </p>
            </div>
          ))}
        </div>
      </section>

      {/* CTA */}
      <section
        aria-labelledby="builders-cta"
        className="rounded-2xl border border-border bg-card p-8 sm:p-10 text-center space-y-5"
      >
        <h2 id="builders-cta" className="text-2xl font-bold">
          {t("builders.ctaTitle")}
        </h2>
        <p className="text-muted-foreground max-w-xl mx-auto">
          {t("builders.ctaBody")}
        </p>
        <div className="flex flex-col sm:flex-row gap-3 justify-center">
          <Button asChild>
            <a
              href="https://github.com/SigalSwap"
              target="_blank"
              rel="noopener noreferrer"
            >
              {t("builders.ctaGithub")}
              <ExternalLink className="h-3.5 w-3.5 ml-1.5" aria-hidden="true" />
            </a>
          </Button>
          <Button asChild variant="outline">
            <a
              href="https://github.com/SigalSwap"
              target="_blank"
              rel="noopener noreferrer"
            >
              {t("builders.ctaSdkDocs")}
              <ExternalLink className="h-3.5 w-3.5 ml-1.5" aria-hidden="true" />
            </a>
          </Button>
        </div>
      </section>
    </div>
  );
}
