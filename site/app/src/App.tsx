// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { lazy, Suspense, useEffect } from "react";
import { Loader2 } from "lucide-react";
import { BrowserRouter, Routes, Route, Navigate, useLocation } from "react-router-dom";
import { TooltipProvider } from "@/components/ui/tooltip";
import { Toaster } from "@/components/ui/sonner";
import { WalletProvider } from "@/hooks/useWallet";
import { Layout } from "@/components/Layout";

// Lazy-loaded pages — each becomes its own chunk
const Home = lazy(() => import("@/pages/Home").then((m) => ({ default: m.Home })));
const Swap = lazy(() => import("@/pages/Swap").then((m) => ({ default: m.Swap })));
const Pools = lazy(() => import("@/pages/Pools").then((m) => ({ default: m.Pools })));
const PoolDetail = lazy(() => import("@/pages/PoolDetail").then((m) => ({ default: m.PoolDetail })));
const AddLiquidity = lazy(() => import("@/pages/AddLiquidity").then((m) => ({ default: m.AddLiquidity })));
const RemoveLiquidity = lazy(() => import("@/pages/RemoveLiquidity").then((m) => ({ default: m.RemoveLiquidity })));
const Portfolio = lazy(() => import("@/pages/Portfolio").then((m) => ({ default: m.Portfolio })));
const DocsOverview = lazy(() => import("@/pages/docs/Overview").then((m) => ({ default: m.DocsOverview })));
const DocsHowItWorks = lazy(() => import("@/pages/docs/HowItWorks").then((m) => ({ default: m.DocsHowItWorks })));
const DocsGettingStarted = lazy(() => import("@/pages/docs/GettingStarted").then((m) => ({ default: m.DocsGettingStarted })));
const DocsSwapping = lazy(() => import("@/pages/docs/Swapping").then((m) => ({ default: m.DocsSwapping })));
const DocsLiquidity = lazy(() => import("@/pages/docs/Liquidity").then((m) => ({ default: m.DocsLiquidity })));
const DocsFeesDoc = lazy(() => import("@/pages/docs/FeesDoc").then((m) => ({ default: m.DocsFeesDoc })));
const DocsFAQ = lazy(() => import("@/pages/docs/FAQ").then((m) => ({ default: m.DocsFAQ })));
const Fees = lazy(() => import("@/pages/Fees").then((m) => ({ default: m.Fees })));
const Ecosystem = lazy(() => import("@/pages/Ecosystem").then((m) => ({ default: m.Ecosystem })));
const Security = lazy(() => import("@/pages/Security").then((m) => ({ default: m.Security })));
const About = lazy(() => import("@/pages/About").then((m) => ({ default: m.About })));
const Terms = lazy(() => import("@/pages/Terms").then((m) => ({ default: m.Terms })));
const Privacy = lazy(() => import("@/pages/Privacy").then((m) => ({ default: m.Privacy })));
const NotFound = lazy(() => import("@/pages/NotFound").then((m) => ({ default: m.NotFound })));

function ScrollToTop() {
  const { pathname } = useLocation();
  useEffect(() => { window.scrollTo(0, 0); }, [pathname]);
  return null;
}

export function App() {
  return (
    <WalletProvider>
    <TooltipProvider>
    <BrowserRouter>
      <ScrollToTop />
      <Suspense fallback={<div className="flex min-h-[50vh] items-center justify-center"><Loader2 className="h-6 w-6 animate-spin text-muted-foreground" /></div>}>
      <Routes>
        <Route element={<Layout />}>
          <Route path="/" element={<Home />} />
          <Route path="/swap" element={<Swap />} />
          <Route path="/pools" element={<Pools />} />
          <Route path="/pools/:pair" element={<PoolDetail />} />
          <Route path="/pools/:pair/add" element={<AddLiquidity />} />
          <Route path="/pools/:pair/remove" element={<RemoveLiquidity />} />
          <Route path="/portfolio" element={<Portfolio />} />
          <Route path="/docs" element={<Navigate to="/docs/overview" replace />} />
          <Route path="/docs/overview" element={<DocsOverview />} />
          <Route path="/docs/how-it-works" element={<DocsHowItWorks />} />
          <Route path="/docs/getting-started" element={<DocsGettingStarted />} />
          <Route path="/docs/swapping" element={<DocsSwapping />} />
          <Route path="/docs/liquidity" element={<DocsLiquidity />} />
          <Route path="/docs/fees" element={<DocsFeesDoc />} />
          <Route path="/docs/faq" element={<DocsFAQ />} />
          <Route path="/fees" element={<Fees />} />
          <Route path="/ecosystem" element={<Ecosystem />} />
          <Route path="/security" element={<Security />} />
          <Route path="/about" element={<About />} />
          <Route path="/terms" element={<Terms />} />
          <Route path="/privacy" element={<Privacy />} />
          <Route path="*" element={<NotFound />} />
        </Route>
      </Routes>
      </Suspense>
    </BrowserRouter>
    </TooltipProvider>
    <Toaster theme="dark" position="bottom-right" />
    </WalletProvider>
  );
}
