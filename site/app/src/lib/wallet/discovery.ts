// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

/**
 * Wallet discovery — finds all available Aztec wallets.
 *
 * Discovery order:
 *   1. AZIP-6963 event-based discovery (the emerging standard)
 *   2. Specific wallet detection (Azguard injected provider, etc.)
 *
 * When AZIP-6963 is widely adopted, step 2 becomes unnecessary.
 * For now, most wallets still use injected providers.
 */

import type { AztecWalletProvider, WalletInfo } from "@/lib/wallet/types";
import { AzguardAdapter } from "@/lib/wallet/azguard-adapter";

// --- AZIP-6963 event-based discovery ---

const AZIP_REQUEST = "azip6963:requestProviders";
const AZIP_ANNOUNCE = "azip6963:announceProvider";

/**
 * Generic adapter for wallets discovered via AZIP-6963.
 * These wallets already speak the standard protocol.
 */
class Azip6963Adapter implements AztecWalletProvider {
  info: WalletInfo;
  private provider: any;
  private accounts: string[] = [];
  private _connected = false;
  private accountsHandlers: ((accounts: string[]) => void)[] = [];
  private disconnectHandlers: (() => void)[] = [];

  constructor(info: WalletInfo, provider: any) {
    this.info = info;
    this.provider = provider;
  }

  async connect(chainId: string): Promise<string[]> {
    const result = await this.provider.request({
      method: "aztec_requestAccounts",
      params: [chainId],
    });
    this.accounts = (result as string[]) ?? [];
    this._connected = this.accounts.length > 0;

    this.provider.on?.("accountsChanged", (newAccounts: string[]) => {
      this.accounts = newAccounts;
      this.accountsHandlers.forEach((h) => h(newAccounts));
      if (newAccounts.length === 0) {
        this._connected = false;
        this.disconnectHandlers.forEach((h) => h());
      }
    });

    return this.accounts;
  }

  async disconnect(): Promise<void> {
    this._connected = false;
    this.accounts = [];
  }

  isConnected(): boolean { return this._connected; }
  getAccounts(): string[] { return this.accounts; }

  async execute(operations: any[]): Promise<any[]> {
    // AZIP-6963 wallets may support batch execute or individual calls
    if (typeof this.provider.execute === "function") {
      return this.provider.execute(operations);
    }
    // Fallback: execute one at a time via request()
    const results = [];
    for (const op of operations) {
      try {
        const value = await this.provider.request({ method: op.kind, params: [op] });
        results.push({ value });
      } catch (e: any) {
        results.push({ error: { message: e.message ?? "Operation failed" } });
      }
    }
    return results;
  }

  onAccountsChanged(handler: (accounts: string[]) => void): void {
    this.accountsHandlers.push(handler);
  }

  onDisconnected(handler: () => void): void {
    this.disconnectHandlers.push(handler);
  }
}

// --- Main discovery function ---

export async function discoverWallets(): Promise<AztecWalletProvider[]> {
  const wallets: AztecWalletProvider[] = [];
  const seen = new Set<string>();

  function add(wallet: AztecWalletProvider) {
    if (!seen.has(wallet.info.uuid)) {
      seen.add(wallet.info.uuid);
      wallets.push(wallet);
    }
  }

  // 1. AZIP-6963 discovery
  const azipWallets = await discoverAzip6963(500);
  azipWallets.forEach(add);

  // 2. Specific wallet detection (fallback for wallets that don't support AZIP-6963 yet)
  const azguard = await AzguardAdapter.detect();
  if (azguard) add(azguard);

  return wallets;
}

function discoverAzip6963(timeoutMs: number): Promise<AztecWalletProvider[]> {
  return new Promise((resolve) => {
    const wallets: AztecWalletProvider[] = [];

    function onAnnounce(event: Event) {
      const detail = (event as CustomEvent).detail;
      if (detail?.info && detail?.provider) {
        wallets.push(new Azip6963Adapter(detail.info, detail.provider));
      }
    }

    window.addEventListener(AZIP_ANNOUNCE, onAnnounce);
    window.dispatchEvent(new CustomEvent(AZIP_REQUEST));

    setTimeout(() => {
      window.removeEventListener(AZIP_ANNOUNCE, onAnnounce);
      resolve(wallets);
    }, timeoutMs);
  });
}
