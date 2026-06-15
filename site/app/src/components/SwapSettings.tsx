// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { useTranslation } from "react-i18next";
import { Settings } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from "@/components/ui/popover";
import { cn } from "@/lib/utils";

const SLIPPAGE_PRESETS = ["0.1", "0.5", "1.0"];

interface SwapSettingsProps {
  slippage: string;
  onSlippageChange: (value: string) => void;
  deadline: string;
  onDeadlineChange: (value: string) => void;
}

export function SwapSettings({
  slippage,
  onSlippageChange,
  deadline,
  onDeadlineChange,
}: SwapSettingsProps) {
  const { t } = useTranslation();
  const isCustom = !SLIPPAGE_PRESETS.includes(slippage);

  return (
    <Popover>
      <PopoverTrigger asChild>
        <Button
          variant="ghost"
          size="icon"
          aria-label={t("swap.settings")}
        >
          <Settings className="h-4 w-4 text-muted-foreground" aria-hidden="true" />
        </Button>
      </PopoverTrigger>
      <PopoverContent className="w-80 bg-card" align="end">
        <div className="space-y-4">
          <h3 className="text-sm font-medium">{t("swap.settings")}</h3>

          {/* Slippage tolerance */}
          <fieldset>
            <legend className="text-xs text-muted-foreground mb-2">
              {t("swap.slippageTolerance")}
            </legend>
            <div className="flex items-center gap-2">
              {SLIPPAGE_PRESETS.map((preset) => (
                <Button
                  key={preset}
                  variant={slippage === preset ? "default" : "secondary"}
                  size="sm"
                  onClick={() => onSlippageChange(preset)}
                  className="flex-1"
                >
                  {preset}%
                </Button>
              ))}
              <div className="relative flex-[1.5]">
                <Input
                  type="number"
                  step="0.1"
                  min="0.01"
                  max="50"
                  placeholder={t("swap.custom")}
                  value={isCustom ? slippage : ""}
                  onChange={(e) => onSlippageChange(e.target.value)}
                  className={cn(
                    "h-8 pr-6 text-sm bg-background",
                    isCustom && "border-primary",
                  )}
                  aria-label={`${t("swap.slippageTolerance")} ${t("swap.custom")}`}
                />
                <span className="absolute right-2 top-1/2 -translate-y-1/2 text-xs text-muted-foreground">
                  %
                </span>
              </div>
            </div>
          </fieldset>

          {/* Transaction deadline */}
          <fieldset>
            <legend className="text-xs text-muted-foreground mb-2">
              {t("swap.transactionDeadline")}
            </legend>
            <div className="flex items-center gap-2">
              <Input
                type="number"
                min="1"
                max="60"
                value={deadline}
                onChange={(e) => onDeadlineChange(e.target.value)}
                className="h-8 w-20 text-sm bg-background"
                aria-label={t("swap.transactionDeadline")}
              />
              <span className="text-xs text-muted-foreground">
                {t("swap.minutes")}
              </span>
            </div>
          </fieldset>
        </div>
      </PopoverContent>
    </Popover>
  );
}
