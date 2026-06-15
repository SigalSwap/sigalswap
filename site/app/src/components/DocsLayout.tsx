// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { NavLink } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { cn } from "@/lib/utils";

const DOCS_NAV = [
  { key: "docs.overview", href: "/docs/overview" },
  { key: "docs.howItWorks", href: "/docs/how-it-works" },
  { key: "docs.gettingStarted", href: "/docs/getting-started" },
  { key: "docs.swapping", href: "/docs/swapping" },
  { key: "docs.liquidity", href: "/docs/liquidity" },
  { key: "docs.feesDoc", href: "/docs/fees" },
  { key: "docs.faq", href: "/docs/faq" },
] as const;

export function DocsLayout({ children }: { children: React.ReactNode }) {
  const { t } = useTranslation();

  return (
    <div className="flex gap-10">
      {/* Sidebar */}
      <nav
        className="hidden w-48 shrink-0 md:block"
        aria-label={t("docs.sidebar")}
      >
        <div className="sticky top-24 space-y-1">
          {DOCS_NAV.map((item) => (
            <NavLink
              key={item.href}
              to={item.href}
              className={({ isActive }) =>
                cn(
                  "block rounded-md px-3 py-2 text-sm transition-colors",
                  isActive
                    ? "bg-secondary text-foreground font-medium"
                    : "text-muted-foreground hover:text-foreground hover:bg-secondary/50",
                )
              }
            >
              {t(item.key)}
            </NavLink>
          ))}
        </div>
      </nav>

      {/* Content */}
      <article className="min-w-0 flex-1 max-w-2xl space-y-6 text-base leading-relaxed text-muted-foreground [&_h1]:text-2xl [&_h1]:font-bold [&_h1]:text-foreground [&_h1]:mb-2 [&_h2]:text-lg [&_h2]:font-semibold [&_h2]:text-foreground [&_h2]:mt-8 [&_h2]:mb-3 [&_h3]:text-base [&_h3]:font-medium [&_h3]:text-foreground [&_h3]:mt-6 [&_h3]:mb-2 [&_strong]:text-foreground [&_ul]:list-disc [&_ul]:pl-5 [&_ul]:space-y-1 [&_ol]:list-decimal [&_ol]:pl-5 [&_ol]:space-y-2">
        {children}
      </article>
    </div>
  );
}
