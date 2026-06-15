// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

/**
 * Azguard wallet adapter.
 * Normalizes Azguard's API into the common AztecWalletProvider interface.
 *
 * Azguard result format: { status: "ok", result: T } | { status: "failed", error: string } | { status: "skipped" }
 * Our OpResult format: { value?: T, error?: { message: string } }
 */

import type {
  AztecWalletProvider,
  DappMetadata,
  Operation,
  OpResult,
  WalletInfo,
} from "@/lib/wallet/types";

export class AzguardAdapter implements AztecWalletProvider {
  private client: any;
  public info: WalletInfo;

  constructor(client: any, info: WalletInfo) {
    this.client = client;
    this.info = info;
  }

  async connect(chainId: string, dappMetadata: DappMetadata): Promise<string[]> {
    const requiredPermissions = [
      {
        chains: [chainId],
        methods: [
          // Operations
          "send_transaction",
          "simulate_transaction",
          "simulate_views",
          "register_contract",
          "register_sender",
          "register_token",
          // Actions (used inside operations)
          "call",
          "add_private_authwit",
        ],
      },
    ];

    await this.client.connect(dappMetadata, requiredPermissions);
    return this.getAccounts();
  }

  async disconnect(): Promise<void> {
    await this.client.disconnect();
  }

  isConnected(): boolean {
    return this.client.connected;
  }

  getAccounts(): string[] {
    return this.client.accounts.map((a: any) => a.toString());
  }

  async execute(operations: Operation[]): Promise<OpResult[]> {
    let rawResults: any[];
    try {
      rawResults = await this.client.execute(operations);
    } catch (e: any) {
      console.error("[Azguard] execute threw:", e?.message);
      return operations.map(() => ({ error: { message: e?.message ?? "Wallet execution failed" } }));
    }

    if (!Array.isArray(rawResults)) {
      rawResults = [rawResults];
    }

    // Map Azguard's { status, result, error } to our { value, error } format
    return rawResults.map((r: any) => {
      if (r?.status === "ok") {
        return { value: r.result };
      }
      if (r?.status === "failed") {
        return { error: { message: r.error ?? "Operation failed" } };
      }
      if (r?.status === "skipped") {
        return { error: { message: "Operation skipped (previous operation in batch failed)" } };
      }
      // Fallback for unexpected format
      if (r?.error) {
        return { error: { message: r.error.message ?? r.error ?? "Operation failed" } };
      }
      return { value: r?.value ?? r?.result ?? r };
    });
  }

  onAccountsChanged(handler: (accounts: string[]) => void): void {
    this.client.onAccountsChanged?.addHandler((accounts: any[]) => {
      handler(accounts.map((a: any) => a.toString()));
    });
  }

  onDisconnected(handler: () => void): void {
    this.client.onDisconnected?.addHandler(handler);
  }

  /**
   * Detect and create an Azguard adapter if the wallet is installed.
   * Returns null if Azguard is not found.
   */
  static async detect(): Promise<AzguardAdapter | null> {
    try {
      const { AzguardClient } = await import("@azguardwallet/client");
      const installed = await AzguardClient.isAzguardInstalled(1000);
      if (!installed) return null;

      const client = await AzguardClient.create();
      const walletInfo = await client.getWalletInfo().catch(() => null);

      return new AzguardAdapter(client, {
        name: walletInfo?.name ?? "Azguard",
        icon: walletInfo?.logo ?? "",
        uuid: "azguard",
      });
    } catch {
      return null;
    }
  }
}
