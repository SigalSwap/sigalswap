// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import { useState } from "react";
import { useTranslation } from "react-i18next";
import { Search, Coins } from "lucide-react";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { type Token } from "@/lib/utils";
import { config } from "@/lib/config";

/** Derive available tokens from deployed pairs config. */
function getDeployedTokens(): Token[] {
  const seen = new Set<string>();
  const tokens: Token[] = [];
  for (const pair of config.deployedPairs) {
    if (!seen.has(pair.token0Address)) {
      seen.add(pair.token0Address);
      tokens.push({ symbol: pair.token0Symbol, name: pair.token0Symbol, decimals: 18, address: pair.token0Address });
    }
    if (!seen.has(pair.token1Address)) {
      seen.add(pair.token1Address);
      tokens.push({ symbol: pair.token1Symbol, name: pair.token1Symbol, decimals: 18, address: pair.token1Address });
    }
  }
  return tokens;
}

const TOKENS = getDeployedTokens();

interface TokenSelectorProps {
  selected: Token | null;
  onSelect: (token: Token) => void;
  disabledSymbol?: string;
  trigger: React.ReactNode;
}

export function TokenSelector({
  selected,
  onSelect,
  disabledSymbol,
  trigger,
}: TokenSelectorProps) {
  const { t } = useTranslation();
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");

  const filtered = TOKENS.filter(
    (token) =>
      token.symbol.toLowerCase().includes(query.toLowerCase()) ||
      token.name.toLowerCase().includes(query.toLowerCase()),
  );

  function handleSelect(token: Token) {
    onSelect(token);
    setOpen(false);
    setQuery("");
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>{trigger}</DialogTrigger>
      <DialogContent className="sm:max-w-md bg-card">
        <DialogHeader>
          <DialogTitle>{t("swap.selectToken")}</DialogTitle>
        </DialogHeader>

        {/* Search */}
        <div className="relative">
          <Search
            className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground"
            aria-hidden="true"
          />
          <Input
            placeholder={t("swap.searchTokens")}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            className="pl-10 bg-background"
            aria-label={t("swap.searchTokens")}
          />
        </div>

        {/* Token list */}
        <ul className="max-h-72 overflow-y-auto space-y-1" role="listbox" aria-label={t("swap.selectToken")}>
          {filtered.length === 0 ? (
            <li className="py-6 text-center text-sm text-muted-foreground" role="option" aria-selected={false}>
              {t("swap.noTokensFound")}
            </li>
          ) : (
            filtered.map((token) => {
              const isDisabled = token.symbol === disabledSymbol;
              const isSelected = token.symbol === selected?.symbol;
              return (
                <li key={token.symbol}>
                  <button
                    role="option"
                    aria-selected={isSelected}
                    disabled={isDisabled}
                    onClick={() => handleSelect(token)}
                    className="flex w-full items-center gap-3 rounded-lg px-3 py-3 text-left transition-colors hover:bg-secondary disabled:opacity-40 disabled:cursor-not-allowed focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
                  >
                    {/* Token icon placeholder */}
                    <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-secondary">
                      <Coins className="h-4 w-4 text-muted-foreground" aria-hidden="true" />
                    </div>
                    <div className="flex-1 min-w-0">
                      <div className="text-sm font-medium">{token.symbol}</div>
                      <div className="text-xs text-muted-foreground truncate">
                        {token.name}
                      </div>
                    </div>
                    <div className="text-sm text-muted-foreground font-mono">
                      —
                    </div>
                  </button>
                </li>
              );
            })
          )}
        </ul>
      </DialogContent>
    </Dialog>
  );
}
