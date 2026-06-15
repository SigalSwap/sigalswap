// SPDX-License-Identifier: MIT
// Copyright (c) 2026 SigalSwap LLC

/**
 * Event types and query helpers for SigalSwap.
 *
 * Public events are queryable by anyone via `getPublicEvents()`.
 * Private events are encrypted to the sender and queryable via the wallet's
 * `getPrivateEvents()` method.
 *
 * Each returned entry has shape `{ event: T, metadata: { ... } }` where
 * `event` is the decoded ABI struct and `metadata` carries tx/block context.
 * Access the decoded fields as `e.event.<field>`, not `e.data.<field>`.
 *
 * @example
 * ```typescript
 * import { getPublicEvents } from '@aztec/aztec.js/events';
 * import { SigalSwapEvents, type SwapEventData } from '@sigalswap/sdk';
 *
 * // Public swap events from a pair
 * const { events } = await getPublicEvents<SwapEventData>(
 *   node,
 *   SigalSwapEvents.pair.SwapEvent,
 *   { contractAddress: pairAddress, fromBlock: 1 },
 * );
 * for (const e of events) {
 *   console.log(e.event.amount_in, e.event.amount_out);
 * }
 *
 * // Private swap events from the user's wallet (query both directions)
 * const myExactInSwaps = await wallet.getPrivateEvents(
 *   SigalSwapEvents.pair.PrivateSwapExactInEvent,
 *   { contractAddress: pairAddress, scopes: [myAddress] },
 * );
 * const myExactOutSwaps = await wallet.getPrivateEvents(
 *   SigalSwapEvents.pair.PrivateSwapExactOutEvent,
 *   { contractAddress: pairAddress, scopes: [myAddress] },
 * );
 * ```
 */

import { AztecAddress } from '@aztec/aztec.js/addresses';

import { SigalSwapPairContract } from './artifacts/SigalSwapPair.js';
import { SigalSwapRouterContract } from './artifacts/SigalSwapRouter.js';
import { SigalSwapFactoryContract } from './artifacts/SigalSwapFactory.js';
import { SigalSwapLPTokenContract } from './artifacts/SigalSwapLPToken.js';

// Re-export event types from generated artifacts for consumer convenience
export type { SigalSwapPairContract } from './artifacts/SigalSwapPair.js';
export type { SigalSwapRouterContract } from './artifacts/SigalSwapRouter.js';
export type { SigalSwapFactoryContract } from './artifacts/SigalSwapFactory.js';
export type { SigalSwapLPTokenContract } from './artifacts/SigalSwapLPToken.js';

/**
 * Event metadata definitions for all SigalSwap contracts.
 *
 * Use these with `getPublicEvents()` (for public events) or
 * `wallet.getPrivateEvents()` (for private events).
 *
 * Each entry contains `eventSelector`, `abiType`, and `fieldNames`
 * as required by the Aztec event query APIs.
 */
export const SigalSwapEvents = {
  /** Pair contract events (16 total: 12 public + 4 private) */
  pair: SigalSwapPairContract.events,

  /** Router contract events (5 total: 4 private + 1 public) */
  router: SigalSwapRouterContract.events,

  /** Factory contract events (17 public) */
  factory: SigalSwapFactoryContract.events,

  /**
   * LP Token contract events (1 private).
   *
   * `LPTransfer` (`from`/`to`/`amount`) is a PRIVATE event: emitted only by the
   * private `transfer` entry and delivered ENCRYPTED to `to`. It is the
   * recipient's wallet-history attribution record (who sent them LP) and is NOT
   * readable by indexers; it does NOT use a zero-address mint/burn convention.
   * This mirrors the Aztec reference Token, which emits `Transfer` only on the
   * `transfer` path. LP supply and public-balance state are read from the pair's
   * Mint/Burn events and the `public_balances` map, not from LP-token events.
   *
   * The `LP` prefix (not `Transfer`) avoids an event-selector collision with
   * Aztec Token's `Transfer` when a consumer decodes both in one tx (the pair
   * holds token0/token1 via the Aztec Token interface).
   */
  lpToken: SigalSwapLPTokenContract.events,
} as const;

// ================================================================
// Decoded event types (for consumers who want typed results)
// ================================================================

// --- Pair public events ---

export interface SwapEventData {
  token_in: AztecAddress;
  token_out: AztecAddress;
  amount_in: bigint;
  amount_out: bigint;
}

export interface SwapPublicEventData {
  sender: AztecAddress;
  token_in: AztecAddress;
  token_out: AztecAddress;
  amount_in: bigint;
  amount_out: bigint;
  recipient: AztecAddress;
}

export interface MintEventData {
  amount0: bigint;
  amount1: bigint;
  liquidity: bigint;
}

export interface MintPublicEventData {
  sender: AztecAddress;
  amount0: bigint;
  amount1: bigint;
  liquidity: bigint;
}

export interface BurnEventData {
  amount0: bigint;
  amount1: bigint;
  liquidity: bigint;
}

export interface BurnPublicEventData {
  sender: AztecAddress;
  amount0: bigint;
  amount1: bigint;
  liquidity: bigint;
  recipient: AztecAddress;
}

export interface SyncEventData {
  reserve0: bigint;
  reserve1: bigint;
}

export interface FlashSwapEventData {
  borrower: AztecAddress;
  amount0_in: bigint;
  amount1_in: bigint;
  amount0_out: bigint;
  amount1_out: bigint;
}

/**
 * Emitted whenever the pair mints LP tokens to its `fee_to` recipient as
 * protocol-fee accrual on a liquidity-changing op. Sum across pairs to
 * compute protocol revenue without joining the LP Token's lower-level
 * mint logs. Only emitted when `protocol_fee_amount > 0` (i.e. fees are
 * active and there's been K growth since the last baseline).
 */
export interface ProtocolFeeMintedEventData {
  fee_to: AztecAddress;
  amount: bigint;
}

/**
 * Emitted from the pair's `set_protocol_fee` when at least one of
 * `(fee_to, percent, active)` actually changes. Repeated `sync_protocol_fee`
 * pushes that don't change state are silent. Lets indexers tracking pair
 * state see fee-config changes without cross-correlating against the
 * factory's governance events.
 */
export interface ProtocolFeeConfigChangedEventData {
  fee_to: AztecAddress;
  // u32 in the contract; the Aztec ABI decoder always returns bigint for
  // integer/Field fields. Do NOT widen back to `number`.
  percent: bigint;
  active: boolean;
}

/**
 * Emitted from the pair's `set_pause(true)` on inactive-to-paused
 * transitions. The pair address is the event's emitter (implicit), so no
 * payload is needed. Idempotent calls (set_pause(true) on an already-paused
 * pair) emit nothing. Mirror of the factory's
 * {@link FactoryPairPausedEventData}, which carries the pair address as a
 * field because the factory is the emitter.
 */
export interface PairPausedEventData {}

/**
 * Emitted from the pair's `set_pause(false)` on paused-to-inactive
 * transitions. Sibling of {@link PairPausedEventData}; same idempotent-skip
 * rule.
 */
export interface PairUnpausedEventData {}

// --- Pair/Router private events ---

/**
 * Exact-input swap event. `amount_in` is the actual input the pair consumes
 * (balance-based settlement accepts fee-on-transfer slippage but never
 * exceeds the declared value). Emitted from `swap_exact_in` on the pair and
 * `swap_exact_in` / `swap_exact_in_multi_hop` on the router.
 */
export interface PrivateSwapExactInEventData {
  token_in: AztecAddress;
  token_out: AztecAddress;
  amount_in: bigint;
  amount_out_min: bigint;
}

/**
 * Exact-output swap event. `amount_in_max` is the user's authorized upper
 * bound, not the actual input consumed. The pair computes the precise input
 * in public from current reserves; the difference (`amount_in_max - actual`)
 * is returned via the refund partial note delivered to the sender in the
 * same tx. To display actual spend, compute `amount_in_max - refund_note_value`
 * or read the public `SwapEvent` in the same tx. Emitted from `swap_exact_out`
 * on the pair and `swap_exact_out` / `swap_exact_out_multi_hop` on the router.
 */
export interface PrivateSwapExactOutEventData {
  token_in: AztecAddress;
  token_out: AztecAddress;
  amount_in_max: bigint;
  amount_out: bigint;
}

export interface PrivateMintEventData {
  token0: AztecAddress;
  token1: AztecAddress;
  amount0_max: bigint;
  amount1_max: bigint;
}

export interface PrivateBurnEventData {
  token0: AztecAddress;
  token1: AztecAddress;
  liquidity: bigint;
}

// Router private events mirror the pair's shapes
export type RouterSwapExactInEventData = PrivateSwapExactInEventData;
export type RouterSwapExactOutEventData = PrivateSwapExactOutEventData;
export type RouterMintEventData = PrivateMintEventData;
export type RouterBurnEventData = PrivateBurnEventData;

/**
 * Emitted when {@link SigalSwapRouter.skimTo} sweeps stuck token balance from
 * the router to a recipient. Indexers can use this to surface "router-side
 * dust recovery" activity distinct from the swap/liquidity event streams.
 */
export interface RouterSkimEventData {
  token: AztecAddress;
  recipient: AztecAddress;
  amount: bigint;
}

// --- LP Token events ---

/**
 * PRIVATE event: emitted only by the LP Token's private `transfer` entry and
 * delivered ENCRYPTED to `to`. It records, for the recipient's wallet, who
 * sent them LP (the received note already carries the amount). NOT readable by
 * indexers, and it does NOT use a zero-address mint/burn convention -- it fires
 * only on private holder-to-holder transfers, mirroring the Aztec reference
 * Token's `Transfer`-on-`transfer` design.
 */
export interface LPTransferEventData {
  from: AztecAddress;
  to: AztecAddress;
  amount: bigint;
}

// --- Factory events ---

export interface PairCreatedEventData {
  token0: AztecAddress;
  token1: AztecAddress;
  pair: AztecAddress;
  lp_token: AztecAddress;
  // u32 in the contract; the Aztec ABI decoder always returns bigint for
  // integer/Field fields. Do NOT widen back to `number`.
  fee_tier_bps: bigint;
  version: bigint;
  pair_count: bigint;
}

/**
 * Emitted when governance clears a pair slot via `execute_clear_pair_slot`.
 * The historical versioned `pairs` entry is zeroed and `latest_pair` either
 * rolls back to a prior registered version (`new_latest_pair = the rolled-
 * back-to address`) or is fully cleared (`new_latest_pair = AztecAddress.ZERO`,
 * `new_latest_version = 0n`).
 *
 * Plaintext `(token0, token1, fee_tier_bps)` lets indexers render "pool
 * retired" UX directly without joining against `PairCreatedEvent` to recover
 * the base identity from a hash. Indexers needing the legacy `base_key` can
 * recompute it via `poseidon2([token0, token1, fee_tier_bps])`.
 */
export interface PairSlotClearedEventData {
  pair: AztecAddress;
  token0: AztecAddress;
  token1: AztecAddress;
  // u32 in the contract; the Aztec ABI decoder always returns bigint for
  // integer/Field fields. Do NOT widen back to `number`.
  fee_tier_bps: bigint;
  cleared_version: bigint;
  new_latest_version: bigint;
  new_latest_pair: AztecAddress;
}

export interface RegistrationPausedEventData {}

export interface RegistrationUnpausedEventData {}

/**
 * Factory-side event: emitted when the admin calls `factory.pause_pair(pair)`.
 * The factory address is the emitter; the `pair` field identifies which pair
 * was paused. Distinct from the pair-emitted {@link PairPausedEventData},
 * which is fired by the pair itself on the same transition.
 */
export interface FactoryPairPausedEventData {
  pair: AztecAddress;
}

/**
 * Factory-side event: emitted when the admin calls `factory.unpause_pair(pair)`.
 * Sibling of {@link FactoryPairPausedEventData}.
 */
export interface FactoryPairUnpausedEventData {
  pair: AztecAddress;
}

/**
 * Factory-side event: emitted on every successful `sync_protocol_fee(pair)`
 * admin call, including no-op pushes against pairs whose protocol-fee config
 * already matches the factory's. Use this for the full admin-action audit
 * trail. The pair-side {@link ProtocolFeeConfigChangedEventData} fires only
 * on real state transitions, so an indexer wanting "did the pair's config
 * actually change" should consume that one instead.
 */
export interface ProtocolFeeSyncedEventData {
  pair: AztecAddress;
}

/**
 * Emitted when an admin calls a `queue_*` governance function on the
 * factory. `action_type` is one of the numeric IDs in `ActionType` (see
 * `factory.ts`); `value` is the action's raw parameter. For simple actions
 * the value is a direct argument (address, percent, tier bps, flag); for
 * `SET_PAIR_CLASS_ID` and `CLEAR_PAIR_SLOT` the value is a Poseidon2 hash
 * of multiple arguments. Use {@link decodeActionValue} from `@sigalswap/sdk`
 * to decode into a typed, self-describing variant.
 */
export interface ActionQueuedEventData {
  action_type: bigint;
  value: bigint;
  execute_after: bigint;
}

/**
 * Emitted when an admin calls the matching `execute_*` function after the
 * timelock delay. Fields mirror {@link ActionQueuedEventData}; use
 * `decodeActionValue` to interpret them.
 */
export interface ActionExecutedEventData {
  action_type: bigint;
  value: bigint;
}

/**
 * Emitted when an admin calls `cancel_action` on a queued governance
 * action before it is executed. Fields mirror {@link ActionQueuedEventData};
 * use `decodeActionValue` to interpret them. Indexers can pair each
 * `ActionQueuedEvent` with its subsequent `ActionExecutedEvent` or
 * `ActionCancelledEvent` by matching `(action_type, value)`.
 */
export interface ActionCancelledEventData {
  action_type: bigint;
  value: bigint;
}

export interface AdminChangedEventData {
  new_admin: AztecAddress;
}

export interface FeeToChangedEventData {
  new_fee_to: AztecAddress;
}

export interface FeeTierAddedEventData {
  // u32 in the contract; the Aztec ABI decoder always returns bigint for
  // integer/Field fields. Do NOT widen back to `number`.
  tier_bps: bigint;
}

export interface FeeTierRemovedEventData {
  // u32 in the contract; the Aztec ABI decoder always returns bigint for
  // integer/Field fields. Do NOT widen back to `number`.
  tier_bps: bigint;
}

/**
 * Emitted alongside `ActionExecutedEvent` when admin executes a
 * protocol-fee-percent change. Symmetric with the typed events for
 * `set_fee_to` / `set_admin` / fee-tier changes -- gives indexers using
 * typed-event streaming a uniform shape across all timelocked actions.
 */
export interface ProtocolFeePercentChangedEventData {
  // u32 in the contract; the Aztec ABI decoder always returns bigint for
  // integer/Field fields. Do NOT widen back to `number`.
  new_percent: bigint;
}

/**
 * Emitted alongside `ActionExecutedEvent` when admin executes a
 * protocol-fee-enabled change. Same symmetry argument as
 * `ProtocolFeePercentChangedEventData`.
 */
export interface ProtocolFeeEnabledChangedEventData {
  enabled: boolean;
}

/**
 * Emitted when the blessed pair bytecode class ID and/or version changes.
 * Fires from both branches of `set_pair_class_id` (first-call immediate and
 * subsequent timelocked). Indexers tracking which bytecode the factory will
 * accept for registration should key off this event.
 */
export interface PairClassIdChangedEventData {
  class_id: bigint;
  // u32 in the contract; the Aztec ABI decoder always returns bigint for
  // integer/Field fields. Do NOT widen back to `number`.
  version: bigint;
}
