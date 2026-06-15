// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { useTranslation } from "react-i18next";
import { SwapCard } from "@/components/SwapCard";

export function Swap() {
  const { t } = useTranslation();

  return (
    <div className="flex flex-col items-center py-8 sm:py-12">
      <h1 className="sr-only">{t("swap.title")}</h1>
      <SwapCard />
    </div>
  );
}
