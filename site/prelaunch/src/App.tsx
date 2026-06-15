// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { lazy, Suspense, useEffect } from "react";
import { Loader2 } from "lucide-react";
import { BrowserRouter, Routes, Route, Navigate, useLocation } from "react-router-dom";
import { TooltipProvider } from "@/components/ui/tooltip";
import { Layout } from "@/components/Layout";

const Home = lazy(() => import("@/pages/Home").then((m) => ({ default: m.Home })));
const DocsOverview = lazy(() => import("@/pages/docs/Overview").then((m) => ({ default: m.DocsOverview })));
const DocsHowItWorks = lazy(() => import("@/pages/docs/HowItWorks").then((m) => ({ default: m.DocsHowItWorks })));
const DocsLiquidity = lazy(() => import("@/pages/docs/Liquidity").then((m) => ({ default: m.DocsLiquidity })));
const DocsFeesDoc = lazy(() => import("@/pages/docs/FeesDoc").then((m) => ({ default: m.DocsFeesDoc })));
const DocsFAQ = lazy(() => import("@/pages/docs/FAQ").then((m) => ({ default: m.DocsFAQ })));
const Builders = lazy(() => import("@/pages/Builders").then((m) => ({ default: m.Builders })));
const Security = lazy(() => import("@/pages/Security").then((m) => ({ default: m.Security })));
const About = lazy(() => import("@/pages/About").then((m) => ({ default: m.About })));
const NotFound = lazy(() => import("@/pages/NotFound").then((m) => ({ default: m.NotFound })));

function ScrollToTop() {
  const { pathname } = useLocation();
  useEffect(() => { window.scrollTo(0, 0); }, [pathname]);
  return null;
}

export function App() {
  return (
    <TooltipProvider>
    <BrowserRouter>
      <ScrollToTop />
      <Suspense fallback={<div className="flex min-h-[50vh] items-center justify-center"><Loader2 className="h-6 w-6 animate-spin text-muted-foreground" /></div>}>
      <Routes>
        <Route element={<Layout />}>
          <Route path="/" element={<Home />} />
          <Route path="/docs" element={<Navigate to="/docs/overview" replace />} />
          <Route path="/docs/overview" element={<DocsOverview />} />
          <Route path="/docs/how-it-works" element={<DocsHowItWorks />} />
          <Route path="/docs/liquidity" element={<DocsLiquidity />} />
          <Route path="/docs/fees" element={<DocsFeesDoc />} />
          <Route path="/docs/faq" element={<DocsFAQ />} />
          <Route path="/builders" element={<Builders />} />
          <Route path="/security" element={<Security />} />
          <Route path="/about" element={<About />} />
          <Route path="*" element={<NotFound />} />
        </Route>
      </Routes>
      </Suspense>
    </BrowserRouter>
    </TooltipProvider>
  );
}
