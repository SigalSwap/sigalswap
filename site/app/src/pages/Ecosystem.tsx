// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { useTranslation } from "react-i18next";
import { ExternalLink, Wallet, ArrowLeftRight, Search, Radio, AlertTriangle } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";

function ExtLink({ href, children }: { href: string; children: React.ReactNode }) {
  return (
    <a
      href={href}
      target="_blank"
      rel="noopener noreferrer"
      className="inline-flex items-center gap-1 text-primary hover:underline"
    >
      {children}
      <ExternalLink className="h-3 w-3" aria-hidden="true" />
    </a>
  );
}

function Card({ icon: Icon, title, description, badge, action, href }: {
  icon: React.ElementType;
  title: string;
  description: string;
  badge?: string;
  action?: string;
  href?: string;
}) {
  return (
    <div className="rounded-xl border border-border bg-card p-5 space-y-3">
      <div className="flex items-start justify-between">
        <div className="flex items-center gap-3">
          <div className="flex h-9 w-9 items-center justify-center rounded-lg bg-secondary">
            <Icon className="h-4 w-4 text-primary" aria-hidden="true" />
          </div>
          <div>
            <h3 className="text-sm font-medium">{title}</h3>
            {badge && <Badge variant="secondary" className="text-xs mt-0.5">{badge}</Badge>}
          </div>
        </div>
        {action && href && (
          <Button asChild variant="outline" size="sm">
            <a href={href} target="_blank" rel="noopener noreferrer">
              {action}
              <ExternalLink className="h-3 w-3 ml-1" aria-hidden="true" />
            </a>
          </Button>
        )}
      </div>
      <p className="text-sm text-muted-foreground">{description}</p>
    </div>
  );
}

export function Ecosystem() {
  const { t } = useTranslation();

  return (
    <div className="max-w-3xl mx-auto space-y-10">
      <div>
        <h1 className="text-2xl font-bold">{t("ecosystem.title")}</h1>
        <p className="mt-2 text-muted-foreground">{t("ecosystem.subtitle")}</p>
      </div>

      {/* Wallets */}
      <section aria-labelledby="wallets-heading" className="space-y-4">
        <h2 id="wallets-heading" className="text-lg font-semibold">{t("ecosystem.wallets")}</h2>
        <p className="text-sm text-muted-foreground">{t("ecosystem.walletsIntro")}</p>
        <div className="grid gap-4 sm:grid-cols-2">
          <Card
            icon={Wallet}
            title={t("ecosystem.azguardName")}
            description={t("ecosystem.azguardDesc")}
            badge="Chrome"
            action={t("ecosystem.installWallet")}
            href="https://chromewebstore.google.com/detail/azguard-wallet/pliilpflcmabdiapdeihifihkbdfnbmn"
          />
          <Card
            icon={Wallet}
            title={t("ecosystem.obsidionName")}
            description={t("ecosystem.obsidionDesc")}
            badge="Chrome"
            action={t("ecosystem.installWallet")}
            href="https://app.obsidion.xyz/"
          />
        </div>
      </section>

      {/* Bridging */}
      <section aria-labelledby="bridging-heading" className="space-y-4">
        <h2 id="bridging-heading" className="text-lg font-semibold">{t("ecosystem.bridging")}</h2>
        <div className="rounded-xl border border-border bg-card p-5 space-y-3">
          <div className="flex items-center gap-3">
            <div className="flex h-9 w-9 items-center justify-center rounded-lg bg-secondary">
              <ArrowLeftRight className="h-4 w-4 text-primary" aria-hidden="true" />
            </div>
            <h3 className="text-sm font-medium">Ethereum → Aztec</h3>
          </div>
          <p className="text-sm text-muted-foreground">{t("ecosystem.bridgingIntro")}</p>
          <p className="text-sm text-muted-foreground"><strong className="text-foreground">{t("ecosystem.bridgingNoDelay")}</strong></p>
          <p className="text-sm text-muted-foreground">{t("ecosystem.bridgingPartners")}</p>
          <p className="text-xs text-muted-foreground italic">{t("ecosystem.bridgingCaveat")}</p>
        </div>
      </section>

      {/* Block explorers */}
      <section aria-labelledby="explorers-heading" className="space-y-4">
        <h2 id="explorers-heading" className="text-lg font-semibold">{t("ecosystem.explorers")}</h2>
        <p className="text-sm text-muted-foreground">{t("ecosystem.explorersIntro")}</p>
        <div className="grid gap-4 sm:grid-cols-2">
          <Card
            icon={Search}
            title={t("ecosystem.aztecscanName")}
            description={t("ecosystem.aztecscanDesc")}
            action="Open"
            href="https://aztecscan.xyz/"
          />
          <Card
            icon={Search}
            title={t("ecosystem.officialExplorerName")}
            description={t("ecosystem.officialExplorerDesc")}
            action="Open"
            href="https://explorer.aztec.network/"
          />
        </div>
      </section>

      {/* Network info */}
      <section aria-labelledby="network-heading" className="space-y-4">
        <h2 id="network-heading" className="text-lg font-semibold">{t("ecosystem.networkInfo")}</h2>
        <div className="rounded-xl border border-border bg-card p-5 space-y-3">
          <div className="flex items-center gap-3">
            <div className="flex h-9 w-9 items-center justify-center rounded-lg bg-secondary">
              <Radio className="h-4 w-4 text-primary" aria-hidden="true" />
            </div>
            <div>
              <h3 className="text-sm font-medium">{t("ecosystem.networkName")}</h3>
              <Badge variant="secondary" className="text-xs mt-0.5">{t("ecosystem.networkStatus")}</Badge>
            </div>
          </div>
          <div className="flex items-start gap-2 rounded-lg bg-destructive/10 p-3 text-sm">
            <AlertTriangle className="h-4 w-4 text-destructive shrink-0 mt-0.5" aria-hidden="true" />
            <p className="text-destructive">{t("ecosystem.networkNote")}</p>
          </div>
        </div>
      </section>
    </div>
  );
}
