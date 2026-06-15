// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { useState } from "react";
import { Link, NavLink, Outlet, useLocation } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { Menu } from "lucide-react";
import { Logo } from "@/components/Logo";
import { Button } from "@/components/ui/button";
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
  SheetTrigger,
} from "@/components/ui/sheet";
import { Separator } from "@/components/ui/separator";
import { cn } from "@/lib/utils";

function NavItem({
  href,
  children,
  onClick,
}: {
  href: string;
  children: React.ReactNode;
  onClick?: () => void;
}) {
  return (
    <NavLink
      to={href}
      onClick={onClick}
      className={({ isActive }) =>
        cn(
          "text-sm transition-colors",
          isActive
            ? "text-foreground font-medium"
            : "text-muted-foreground hover:text-foreground",
        )
      }
    >
      {children}
    </NavLink>
  );
}

function Header() {
  const { t } = useTranslation();
  const [mobileOpen, setMobileOpen] = useState(false);

  const mainNav = [
    { label: t("nav.docs"), href: "/docs" },
    { label: t("nav.builders"), href: "/builders" },
    { label: t("nav.security"), href: "/security" },
    { label: t("nav.about"), href: "/about" },
  ];

  return (
    <header className="sticky top-0 z-50 border-b border-border bg-background/80 backdrop-blur-sm">
      <a
        href="#main-content"
        className="sr-only focus:not-sr-only focus:absolute focus:left-4 focus:top-4 focus:z-50 focus:rounded-md focus:bg-primary focus:px-4 focus:py-2 focus:text-primary-foreground"
      >
        {t("common.skipToContent")}
      </a>
      <div className="mx-auto flex h-16 max-w-7xl items-center justify-between px-6">
        <Link to="/" className="flex items-center gap-2" aria-label={t("nav.homeLink", { app: t("common.appName") })}>
          <Logo size={32} />
          <span className="text-xl font-semibold tracking-tight">
            {t("common.appName")}
          </span>
        </Link>

        <nav className="hidden items-center gap-6 md:flex" aria-label={t("nav.mainNavLabel")}>
          {mainNav.map((item) => (
            <NavItem key={item.href} href={item.href}>
              {item.label}
            </NavItem>
          ))}
        </nav>

        <Sheet open={mobileOpen} onOpenChange={setMobileOpen}>
          <SheetTrigger asChild className="md:hidden">
            <Button variant="ghost" size="icon" aria-label={t("nav.openMenu")}>
              <Menu className="h-5 w-5" aria-hidden="true" />
            </Button>
          </SheetTrigger>
          <SheetContent side="right" className="w-72 bg-background">
            <SheetHeader>
              <SheetTitle className="flex items-center gap-2">
                <Logo size={20} />
                {t("common.appName")}
              </SheetTitle>
            </SheetHeader>
            <nav className="mt-6 flex flex-col gap-4" aria-label={t("nav.mobileNavLabel")}>
              {mainNav.map((item) => (
                <NavItem
                  key={item.href}
                  href={item.href}
                  onClick={() => setMobileOpen(false)}
                >
                  {item.label}
                </NavItem>
              ))}
            </nav>
          </SheetContent>
        </Sheet>
      </div>
    </header>
  );
}

function Footer() {
  const { t } = useTranslation();

  const footerLinks = {
    [t("footer.resources")]: [
      { label: t("nav.docs"), href: "/docs" },
      { label: t("nav.builders"), href: "/builders" },
      { label: t("nav.security"), href: "/security" },
      { label: t("nav.about"), href: "/about" },
    ],
    [t("footer.community")]: [
      { label: t("footer.twitter"), href: "https://x.com/SigalSwap", external: true, icon: "x" },
      { label: t("footer.github"), href: "https://github.com/SigalSwap", external: true, icon: "github" },
    ],
  };

  return (
    <footer className="border-t border-border bg-background" role="contentinfo">
      <div className="mx-auto max-w-7xl px-6 py-12">
        <nav className="grid grid-cols-2 gap-8" aria-label={t("nav.footerNavLabel")}>
          {Object.entries(footerLinks).map(([category, links]) => (
            <div key={category}>
              <h3 className="text-sm font-medium text-foreground">
                {category}
              </h3>
              <ul className="mt-3 space-y-2" role="list">
                {links.map((link) => {
                  const icon = "icon" in link ? (link as { icon?: string }).icon : undefined;
                  const content = (
                    <span className="inline-flex items-center gap-1.5">
                      {icon === "x" && (
                        <svg className="h-3.5 w-3.5" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
                          <path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z" />
                        </svg>
                      )}
                      {icon === "github" && (
                        <svg className="h-3.5 w-3.5" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
                          <path d="M12 2C6.477 2 2 6.484 2 12.017c0 4.425 2.865 8.18 6.839 9.504.5.092.682-.217.682-.483 0-.237-.008-.868-.013-1.703-2.782.605-3.369-1.343-3.369-1.343-.454-1.158-1.11-1.466-1.11-1.466-.908-.62.069-.608.069-.608 1.003.07 1.531 1.032 1.531 1.032.892 1.53 2.341 1.088 2.91.832.092-.647.35-1.088.636-1.338-2.22-.253-4.555-1.113-4.555-4.951 0-1.093.39-1.988 1.029-2.688-.103-.253-.446-1.272.098-2.65 0 0 .84-.27 2.75 1.026A9.564 9.564 0 0 1 12 6.844a9.59 9.59 0 0 1 2.504.337c1.909-1.296 2.747-1.027 2.747-1.027.546 1.379.202 2.398.1 2.651.64.7 1.028 1.595 1.028 2.688 0 3.848-2.339 4.695-4.566 4.943.359.309.678.92.678 1.855 0 1.338-.012 2.419-.012 2.747 0 .268.18.58.688.482A10.02 10.02 0 0 0 22 12.017C22 6.484 17.522 2 12 2z" />
                        </svg>
                      )}
                      {link.label}
                    </span>
                  );
                  return (
                  <li key={link.label}>
                    {"external" in link && link.external ? (
                      <a
                        href={link.href}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="text-sm text-muted-foreground hover:text-foreground transition-colors"
                      >
                        {content}
                      </a>
                    ) : (
                      <Link
                        to={link.href}
                        className="text-sm text-muted-foreground hover:text-foreground transition-colors"
                      >
                        {content}
                      </Link>
                    )}
                  </li>
                  );
                })}
              </ul>
            </div>
          ))}
        </nav>

        <Separator className="my-8" />
        <div className="flex flex-col items-center justify-between gap-4 sm:flex-row">
          <div className="flex items-center gap-2">
            <Logo size={16} />
            <span className="text-sm text-muted-foreground">
              {t("footer.tagline")}
            </span>
          </div>
          <span className="text-xs text-muted-foreground">
            &copy; {new Date().getFullYear()} {t("common.appName")} LLC
          </span>
        </div>
      </div>
    </footer>
  );
}

export function Layout() {
  const location = useLocation();
  const isHome = location.pathname === "/";

  return (
    <div className="flex min-h-screen flex-col">
      <Header />
      <main
        id="main-content"
        className={cn("flex-1", !isHome && "mx-auto w-full max-w-7xl px-6 py-8")}
      >
        <Outlet />
      </main>
      <Footer />
    </div>
  );
}
