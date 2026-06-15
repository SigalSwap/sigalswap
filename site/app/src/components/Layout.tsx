// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { useState } from "react";
import { Link, NavLink, Outlet, useLocation } from "react-router-dom";
import { Trans, useTranslation } from "react-i18next";
import { Menu, Loader2, Wallet, Copy, LogOut } from "lucide-react";
import { toast } from "sonner";
import { Logo } from "@/components/Logo";
import { useWallet } from "@/hooks/useWallet";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
  SheetTrigger,
} from "@/components/ui/sheet";
import { Separator } from "@/components/ui/separator";
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from "@/components/ui/popover";
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

function WalletButton() {
  const { t } = useTranslation();

  // Wallet connection disabled until Azguard supports Aztec artifact
  // registration and the utilityFetchTaggedLogs oracle. Remove this early
  // return to re-enable wallet connectivity.
  return (
    <Button variant="outline" disabled title={t("common.walletComingSoon")}>
      <Wallet className="h-4 w-4 mr-1" aria-hidden="true" />
      {t("common.comingSoon")}
    </Button>
  );

  // --- Wallet connection logic (preserved for when blockers are resolved) ---

  const {
    connected,
    address,
    walletName,
    connecting,
    connect,
    disconnect,
    availableWallets,
  } = useWallet();
  const [pickerOpen, setPickerOpen] = useState(false);
  const [noWalletOpen, setNoWalletOpen] = useState(false);
  const [accountOpen, setAccountOpen] = useState(false);

  if (connecting) {
    return (
      <Button disabled>
        <Loader2 className="h-4 w-4 animate-spin" aria-hidden="true" />
        {t("common.loading")}
      </Button>
    );
  }

  if (connected && address) {
    const display = `${address!.slice(0, 6)}...${address!.slice(-4)}`;
    return (
      <Popover open={accountOpen} onOpenChange={setAccountOpen}>
        <PopoverTrigger asChild>
          <Button variant="outline">
            {display}
          </Button>
        </PopoverTrigger>
        <PopoverContent className="w-56 bg-card p-2" align="end">
          <div className="space-y-1">
            <div className="px-2 py-1.5">
              <p className="text-xs text-muted-foreground">{walletName}</p>
              <p className="text-xs font-mono text-muted-foreground truncate">{address}</p>
            </div>
            <Separator />
            <button
              onClick={() => {
                navigator.clipboard.writeText(address!);
                setAccountOpen(false);
                toast(t("common.copied"));
              }}
              className="flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-sm hover:bg-secondary transition-colors"
            >
              <Copy className="h-3.5 w-3.5 text-muted-foreground" aria-hidden="true" />
              {t("common.copyAddress")}
            </button>
            <button
              onClick={() => {
                setAccountOpen(false);
                disconnect();
              }}
              className="flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-sm text-destructive hover:bg-secondary transition-colors"
            >
              <LogOut className="h-3.5 w-3.5" aria-hidden="true" />
              {t("common.disconnect")}
            </button>
          </div>
        </PopoverContent>
      </Popover>
    );
  }

  // Multiple wallets → show picker dialog
  if (availableWallets.length > 1) {
    return (
      <Dialog open={pickerOpen} onOpenChange={setPickerOpen}>
        <DialogTrigger asChild>
          <Button>{t("common.connectWallet")}</Button>
        </DialogTrigger>
        <DialogContent className="sm:max-w-sm bg-card">
          <DialogHeader>
            <DialogTitle>{t("common.chooseWallet")}</DialogTitle>
          </DialogHeader>
          <div className="space-y-2">
            {availableWallets.map((w) => (
              <button
                key={w.info.uuid}
                onClick={async () => {
                  setPickerOpen(false);
                  await connect(w);
                }}
                className="flex w-full items-center gap-3 rounded-lg px-3 py-3 text-left transition-colors hover:bg-secondary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
              >
                {w.info.icon ? (
                  <img
                    src={w.info.icon}
                    alt=""
                    className="h-8 w-8 rounded-lg"
                    aria-hidden="true"
                  />
                ) : (
                  <div className="flex h-8 w-8 items-center justify-center rounded-lg bg-secondary">
                    <Wallet className="h-4 w-4 text-muted-foreground" aria-hidden="true" />
                  </div>
                )}
                <span className="text-sm font-medium">{w.info.name}</span>
              </button>
            ))}
          </div>
        </DialogContent>
      </Dialog>
    );
  }

  // No wallets → show install guidance dialog
  if (availableWallets.length === 0) {
    return (
      <Dialog open={noWalletOpen} onOpenChange={setNoWalletOpen}>
        <DialogTrigger asChild>
          <Button>{t("common.connectWallet")}</Button>
        </DialogTrigger>
        <DialogContent className="sm:max-w-sm bg-card">
          <DialogHeader>
            <DialogTitle>{t("common.noWalletFound")}</DialogTitle>
          </DialogHeader>
          <p className="text-sm text-muted-foreground">
            <Trans i18nKey="common.noWalletBody" components={{
              ecosystem: <Link to="/ecosystem" className="text-primary hover:underline" onClick={() => setNoWalletOpen(false)} />,
            }} />
          </p>
        </DialogContent>
      </Dialog>
    );
  }

  // One wallet → connect directly
  return <Button onClick={() => connect()}>{t("common.connectWallet")}</Button>;
}

function Header() {
  const { t } = useTranslation();
  const [mobileOpen, setMobileOpen] = useState(false);

  const mainNav = [
    { label: t("nav.swap"), href: "/swap" },
    { label: t("nav.pools"), href: "/pools" },
    { label: t("nav.portfolio"), href: "/portfolio" },
    { label: t("nav.docs"), href: "/docs" },
  ];

  const secondaryNav = [
    { label: t("nav.fees"), href: "/fees" },
    { label: t("nav.ecosystem"), href: "/ecosystem" },
    { label: t("nav.security"), href: "/security" },
    { label: t("nav.about"), href: "/about" },
  ];

  return (
    <header className="sticky top-0 z-50 border-b border-border bg-background/80 backdrop-blur-sm">
      <a
        href="#main-content"
        className="sr-only focus:not-sr-only focus:absolute focus:left-4 focus:top-4 focus:z-50 focus:rounded-md focus:bg-primary focus:px-4 focus:py-2 focus:text-primary-foreground"
      >
        Skip to main content
      </a>
      <div className="mx-auto flex h-16 max-w-7xl items-center justify-between px-6">
        {/* Logo */}
        <Link to="/" className="flex items-center gap-2" aria-label={`${t("common.appName")} home`}>
          <Logo size={32} />
          <span className="text-xl font-semibold tracking-tight">
            {t("common.appName")}
          </span>
        </Link>

        {/* Desktop nav */}
        <nav className="hidden items-center gap-6 md:flex" aria-label="Main navigation">
          {mainNav.map((item) => (
            <NavItem key={item.href} href={item.href}>
              {item.label}
            </NavItem>
          ))}
        </nav>

        {/* Desktop wallet button */}
        <div className="hidden md:block">
          <WalletButton />
        </div>

        {/* Mobile menu */}
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
            <nav className="mt-6 flex flex-col gap-4" aria-label="Mobile navigation">
              {mainNav.map((item) => (
                <NavItem
                  key={item.href}
                  href={item.href}
                  onClick={() => setMobileOpen(false)}
                >
                  {item.label}
                </NavItem>
              ))}
              <Separator className="my-2" />
              {secondaryNav.map((item) => (
                <NavItem
                  key={item.href}
                  href={item.href}
                  onClick={() => setMobileOpen(false)}
                >
                  {item.label}
                </NavItem>
              ))}
              <Separator className="my-2" />
              <div onClick={() => setMobileOpen(false)}>
                <WalletButton />
              </div>
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
    [t("footer.protocol")]: [
      { label: t("nav.swap"), href: "/swap" },
      { label: t("nav.pools"), href: "/pools" },
      { label: t("nav.portfolio"), href: "/portfolio" },
    ],
    [t("footer.resources")]: [
      { label: t("nav.docs"), href: "/docs" },
      { label: t("nav.fees"), href: "/fees" },
      { label: t("nav.ecosystem"), href: "/ecosystem" },
      { label: t("nav.security"), href: "/security" },
      { label: t("nav.about"), href: "/about" },
    ],
    [t("footer.community")]: [
      { label: t("footer.twitter"), href: "#", external: true, icon: "x" },
      { label: t("footer.github"), href: "https://github.com/SigalSwap", external: true, icon: "github" },
    ],
    [t("footer.legal")]: [
      { label: t("nav.terms"), href: "/terms" },
      { label: t("nav.privacy"), href: "/privacy" },
    ],
  };

  return (
    <footer className="border-t border-border bg-background" role="contentinfo">
      <div className="mx-auto max-w-7xl px-6 py-12">
        {/* Link columns */}
        <nav className="grid grid-cols-2 gap-8 sm:grid-cols-4" aria-label="Footer navigation">
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

        {/* Bottom bar */}
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
