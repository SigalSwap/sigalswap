// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

import {
  createContext,
  useContext,
  useState,
  useCallback,
  useEffect,
  type ReactNode,
} from "react";
import {
  discoverWallets,
  type AztecWalletProvider,
} from "@/lib/wallet";
import { config } from "@/lib/config";

// Lazy-load the Token contract artifact (needed for wallet PXE to decode private notes)
let tokenArtifactCache: unknown | null = null;
async function getTokenArtifact(): Promise<unknown> {
  if (!tokenArtifactCache) {
    const res = await fetch("/artifacts/token-contract.json");
    tokenArtifactCache = await res.json();
  }
  return tokenArtifactCache;
}

const CHAIN_IDS: Record<string, string> = {
  local: "aztec:0",
  testnet: "aztec:1674512022",
  production: "aztec:1674512022",
};

export interface WalletState {
  /** All discovered wallets */
  availableWallets: AztecWalletProvider[];
  /** The connected wallet provider */
  activeWallet: AztecWalletProvider | null;
  /** Connected account address */
  address: string | null;
  /** Connected wallet name */
  walletName: string | null;
  /** Connection in progress */
  connecting: boolean;
  /** Last error */
  error: string | null;
  /** Connect to a wallet */
  connect: (wallet?: AztecWalletProvider) => Promise<void>;
  /** Disconnect */
  disconnect: () => void;
  /** Whether connected */
  connected: boolean;
}

const WalletContext = createContext<WalletState | null>(null);

export function WalletProvider({ children }: { children: ReactNode }) {
  const [availableWallets, setAvailableWallets] = useState<AztecWalletProvider[]>([]);
  const [activeWallet, setActiveWallet] = useState<AztecWalletProvider | null>(null);
  const [address, setAddress] = useState<string | null>(null);
  const [walletName, setWalletName] = useState<string | null>(null);
  const [connecting, setConnecting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    discoverWallets().then(setAvailableWallets);
  }, []);

  const connect = useCallback(async (wallet?: AztecWalletProvider) => {
    console.log("[SigalSwap] connect() called, wallet:", wallet?.info?.name ?? "default");
    setConnecting(true);
    setError(null);

    try {
      const target = wallet ?? availableWallets[0];
      if (!target) {
        throw new Error("NO_WALLET");
      }

      const chainId = CHAIN_IDS[config.environment] ?? CHAIN_IDS.local;
      const dappMetadata = {
        name: "SigalSwap",
        description: "Privacy-preserving AMM on Aztec",
        logo: `${window.location.origin}/favicon.svg`,
        url: window.location.origin,
      };

      console.log("[SigalSwap] calling target.connect...");
      const accounts = await target.connect(chainId, dappMetadata);
      console.log("[SigalSwap] accounts returned:", accounts);
      if (!accounts.length) {
        throw new Error("No accounts returned by wallet.");
      }

      const account = accounts[0].startsWith("aztec:")
        ? accounts[0]
        : `${chainId}:${accounts[0]}`;

      // Fetch the Token artifact so the wallet PXE can decode private notes
      console.log("[SigalSwap] Fetching Token artifact...");
      const tokenArtifact = await getTokenArtifact();

      // Token addresses need the artifact for private balance queries
      const tokenAddresses = new Set(
        config.deployedPairs.flatMap((p) => [
          p.token0Address,
          p.token1Address,
          p.lpTokenAddress,
        ]).filter(Boolean),
      );

      // Batch 1 (critical): register token contracts with the artifact
      const contractOps: any[] = [];
      for (const addr of tokenAddresses) {
        contractOps.push({ kind: "register_contract", chain: chainId, address: addr, artifact: tokenArtifact });
      }
      const deployerAddr = import.meta.env.VITE_DEPLOYER_ADDRESS;
      if (deployerAddr) {
        contractOps.push({ kind: "register_sender", chain: chainId, address: deployerAddr });
      }

      if (contractOps.length > 0) {
        console.log("[SigalSwap] Registering", contractOps.length, "contracts...");
        try {
          const results = await target.execute(contractOps);
          const failed = results.filter((r) => r.error);
          if (failed.length > 0) {
            console.warn("[SigalSwap] Some contract registrations failed:", failed.map((r) => r.error?.message));
          } else {
            console.log("[SigalSwap] Contract registration complete");
          }
        } catch (e: any) {
          console.warn("[SigalSwap] Contract registration failed (non-fatal):", e?.message);
        }
      }

      // Batch 2 (best-effort): register tokens for wallet display
      const tokenOps: any[] = [];
      for (const pair of config.deployedPairs) {
        for (const tokenAddr of [pair.token0Address, pair.token1Address]) {
          if (tokenAddr) {
            tokenOps.push({ kind: "register_token", account, address: tokenAddr });
          }
        }
      }

      if (tokenOps.length > 0) {
        try {
          const results = await target.execute(tokenOps);
          const failed = results.filter((r) => r.error);
          if (failed.length > 0) {
            console.warn("[SigalSwap] Token registration failed (non-fatal):", failed.map((r) => r.error?.message));
          }
        } catch (e: any) {
          console.warn("[SigalSwap] Token registration failed (non-fatal):", e?.message);
        }
      }

      setActiveWallet(target);
      setWalletName(target.info.name);
      setAddress(accounts[0]);

      // Subscribe to changes via the common interface
      target.onAccountsChanged((newAccounts) => {
        if (newAccounts.length === 0) {
          setActiveWallet(null);
          setWalletName(null);
          setAddress(null);
        } else {
          setAddress(newAccounts[0]);
        }
      });

      target.onDisconnected(() => {
        setActiveWallet(null);
        setWalletName(null);
        setAddress(null);
      });
    } catch (e) {
      const msg = e instanceof Error ? e.message : "Failed to connect wallet";
      setError(msg);
      if (msg !== "NO_WALLET") {
        console.error("Wallet connection failed:", e);
      }
    } finally {
      setConnecting(false);
    }
  }, [availableWallets]);

  const disconnect = useCallback(async () => {
    if (activeWallet) {
      try { await activeWallet.disconnect(); } catch { /* best effort */ }
    }
    setActiveWallet(null);
    setWalletName(null);
    setAddress(null);
    setError(null);
  }, [activeWallet]);

  const state: WalletState = {
    availableWallets,
    activeWallet,
    address,
    walletName,
    connecting,
    error,
    connect,
    disconnect,
    connected: activeWallet !== null && address !== null,
  };

  return (
    <WalletContext.Provider value={state}>
      {children}
    </WalletContext.Provider>
  );
}

export function useWallet(): WalletState {
  const ctx = useContext(WalletContext);
  if (!ctx) throw new Error("useWallet must be used within WalletProvider");
  return ctx;
}
