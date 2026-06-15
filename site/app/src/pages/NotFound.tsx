// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { Link } from "react-router-dom";
import { useTranslation } from "react-i18next";
import { Button } from "@/components/ui/button";
import { Logo } from "@/components/Logo";

export function NotFound() {
  const { t } = useTranslation();

  return (
    <div className="flex flex-col items-center justify-center py-32 text-center px-6">
      <Logo size={72} className="mb-6" />
      <h1 className="text-lg font-medium mb-1">{t("notFound.title")}</h1>
      <p className="text-sm text-muted-foreground mb-8 max-w-md">
        {t("notFound.body")}
      </p>
      <Button asChild>
        <Link to="/">{t("notFound.goHome")}</Link>
      </Button>
    </div>
  );
}
