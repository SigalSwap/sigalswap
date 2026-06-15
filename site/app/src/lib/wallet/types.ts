// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

/**
 * Common wallet interface for SigalSwap.
 *
 * Every wallet adapter (Azguard, Obsidion, future wallets) implements
 * this interface. The rest of the app talks to this — never to a
 * specific wallet SDK directly.
 */

// --- Operations (the common language) ---

export type Operation =
  | ExecuteUtilityOp
  | SendTransactionOp
  | SimulateTransactionOp
  | SimulateViewsOp
  | CreateAuthWitOp
  | RegisterContractOp
  | RegisterSenderOp
  | RegisterTokenOp
  | GetAccountsOp
  | GetPrivateEventsOp;

export interface ExecuteUtilityOp {
  kind: "execute_utility";
  account: string;
  contract: string;
  method: string;
  args: any[];
}

export interface SendTransactionOp {
  kind: "send_transaction";
  account: string;
  actions: any[];
  fee?: any;
}

export interface SimulateTransactionOp {
  kind: "simulate_transaction";
  account: string;
  actions: any[];
  fee?: any;
  simulatePublic?: boolean;
}

export interface CreateAuthWitOp {
  kind: "aztec_createAuthWit";
  account: string;
  messageHashOrIntent: any;
}

export interface RegisterContractOp {
  kind: "register_contract";
  chain: string;
  address: string;
  instance?: any;
  artifact?: any;
}

export interface GetAccountsOp {
  kind: "aztec_getAccounts";
  chain: string;
}

export interface SimulateViewsOp {
  kind: "simulate_views";
  account: string;
  calls: any[];
}

export interface RegisterSenderOp {
  kind: "register_sender";
  chain: string;
  address: string;
}

export interface RegisterTokenOp {
  kind: "register_token";
  account: string;
  address: string;
}

export interface GetPrivateEventsOp {
  kind: "aztec_getPrivateEvents";
  chain: string;
  eventMetadata: any;
  eventFilter: any;
}

// --- Result ---

export interface OpResult<T = any> {
  value?: T;
  error?: { message: string };
}

// --- Wallet info ---

export interface WalletInfo {
  name: string;
  icon: string;
  uuid: string;
}

// --- Common wallet interface ---

export interface AztecWalletProvider {
  /** Wallet metadata */
  info: WalletInfo;

  /** Connect and request account access */
  connect(chainId: string, dappMetadata: DappMetadata): Promise<string[]>;

  /** Disconnect */
  disconnect(): Promise<void>;

  /** Whether the wallet is connected */
  isConnected(): boolean;

  /** Get connected account addresses */
  getAccounts(): string[];

  /** Execute a batch of operations */
  execute(operations: Operation[]): Promise<OpResult[]>;

  /** Subscribe to account changes */
  onAccountsChanged(handler: (accounts: string[]) => void): void;

  /** Subscribe to disconnect */
  onDisconnected(handler: () => void): void;
}

export interface DappMetadata {
  name: string;
  description?: string;
  logo?: string;
  url?: string;
}
