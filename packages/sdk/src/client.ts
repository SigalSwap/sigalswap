// SPDX-License-Identifier: MIT
// Copyright (c) 2026 SigalSwap LLC

import type { AztecAddress } from '@aztec/aztec.js/addresses';
import type { Wallet } from '@aztec/aztec.js/wallet';
import type { BlockNumber } from '@aztec/foundation/branded-types';

import { SigalSwapPairContract } from './artifacts/SigalSwapPair.js';
import { SigalSwapFactoryContract } from './artifacts/SigalSwapFactory.js';
import { SigalSwapRouterContract } from './artifacts/SigalSwapRouter.js';
import { SigalSwapPair } from './pair.js';
import { SigalSwapRouter } from './router.js';
import { SigalSwapFactory } from './factory.js';
import { type SigalSwapConfig, LOCAL_CONFIG, validateConfig } from './config/index.js';
import { SigalSwapConfigurationError, SigalSwapValidationError } from './errors.js';
import { SigalSwapEvents } from './events.js';
import type {
  PrivateSwapExactInEventData,
  PrivateSwapExactOutEventData,
  PrivateMintEventData,
  PrivateBurnEventData,
} from './events.js';
import { checkPairRegistration } from './pair-verification.js';

/**
 * One swap from a user's history. The four `(source, direction)` pairs come
 * from the four event types the protocol emits for private swaps:
 *   - source='pair' direction='exactIn'  -> pair `swap_exact_in`
 *   - source='pair' direction='exactOut' -> pair `swap_exact_out`
 *   - source='router' direction='exactIn'  -> router `swap_exact_in*`
 *   - source='router' direction='exactOut' -> router `swap_exact_out*`
 *
 * The `data` shape is the same for both directions per source, with field
 * names accurate to direction (`amount_in` for exact-in, `amount_in_max`
 * for exact-out).
 */
export type SwapHistoryEntry =
  | { source: 'pair'; direction: 'exactIn'; data: PrivateSwapExactInEventData; blockNumber: number; txHash: string; }
  | { source: 'pair'; direction: 'exactOut'; data: PrivateSwapExactOutEventData; blockNumber: number; txHash: string; }
  | { source: 'router'; direction: 'exactIn'; data: PrivateSwapExactInEventData; blockNumber: number; txHash: string; }
  | { source: 'router'; direction: 'exactOut'; data: PrivateSwapExactOutEventData; blockNumber: number; txHash: string; };

/** One liquidity event (mint or burn) from a user's history. */
export type LiquidityHistoryEntry =
  | { source: 'pair'; kind: 'mint'; data: PrivateMintEventData; blockNumber: number; txHash: string; }
  | { source: 'pair'; kind: 'burn'; data: PrivateBurnEventData; blockNumber: number; txHash: string; }
  | { source: 'router'; kind: 'mint'; data: PrivateMintEventData; blockNumber: number; txHash: string; }
  | { source: 'router'; kind: 'burn'; data: PrivateBurnEventData; blockNumber: number; txHash: string; };

/**
 * Main entry point for the SigalSwap SDK.
 *
 * @example
 * ```typescript
 * const client = await SigalSwapClient.create({
 *   wallet: myWallet,
 *   senderAddress: myWallet.getAddress(),
 *   factoryAddress: deployedFactoryAddress,
 *   routerAddress: deployedRouterAddress,
 * });
 *
 * const pair = await client.pair(pairAddress);
 * const quote = await pair.quoteAmountOut(1000n, tokenIn);
 * ```
 */
export class SigalSwapClient {
  private constructor(
    public readonly config: Readonly<SigalSwapConfig>,
    public readonly wallet: Wallet,
    public readonly senderAddress: AztecAddress,
    private readonly factoryContract: SigalSwapFactoryContract | null,
    private readonly routerContract: SigalSwapRouterContract | null,
  ) {}

  /**
   * Create a new SigalSwapClient.
   *
   * @param opts.config - Network and fee configuration (defaults to LOCAL_CONFIG)
   * @param opts.wallet - Aztec wallet for signing transactions
   * @param opts.senderAddress - Address of the account sending transactions
   * @param opts.factoryAddress - Deployed factory contract address (optional)
   * @param opts.routerAddress - Deployed router contract address (optional)
   */
  static async create(opts: {
    config?: SigalSwapConfig;
    wallet: Wallet;
    senderAddress: AztecAddress;
    factoryAddress?: AztecAddress;
    routerAddress?: AztecAddress;
  }): Promise<SigalSwapClient> {
    const config = Object.freeze({ ...(opts.config ?? LOCAL_CONFIG) });
    validateConfig(config);

    // Verify senderAddress is managed by this wallet
    const accounts = await opts.wallet.getAccounts();
    const isKnown = accounts.some(a => a.item.equals(opts.senderAddress));
    if (!isKnown) {
      throw new SigalSwapValidationError(
        'SigalSwap: senderAddress is not managed by this wallet. '
        + 'Authwits would fail — the wallet must hold the signing key for senderAddress.',
      );
    }

    const factory = opts.factoryAddress
      ? SigalSwapFactoryContract.at(opts.factoryAddress, opts.wallet)
      : null;

    const router = opts.routerAddress
      ? SigalSwapRouterContract.at(opts.routerAddress, opts.wallet)
      : null;

    return new SigalSwapClient(config, opts.wallet, opts.senderAddress, factory, router);
  }

  /**
   * Verify that a pair address is registered in the factory at the SAME
   * bytecode version that the pair self-reports. This catches:
   *   - phishing pairs that mimic SigalSwapPair but aren't registered
   *   - mismatched-version impersonation (a v3 pair claiming to be the
   *     factory's v3 entry when in fact the factory has a v3 from a
   *     different deployer at that base)
   *
   * Returns `true` when the pair is the genuine entry at its self-reported
   * `(token0, token1, feeTierBps, version)` slot. Returns `true` for older
   * registered versions of a base whose latest has been upgraded -- those
   * are still legitimate pairs that LPs may need to interact with for
   * remove-liquidity flows. Use `isLatestPair` if you specifically want
   * "is this the live routing target" semantics.
   *
   * @returns true if the pair is registered at its self-reported version
   * @throws if factory is not configured
   */
  async verifyPair(pairAddress: AztecAddress): Promise<boolean> {
    if (!this.factoryContract) {
      throw new SigalSwapConfigurationError('Factory address not configured');
    }
    const pairContract = SigalSwapPairContract.at(pairAddress, this.wallet);
    const result = await checkPairRegistration(
      pairAddress, pairContract, this.factoryContract, this.senderAddress,
    );
    return result.verified;
  }

  /**
   * Check whether a pair is the *latest* version registered at its
   * `(token0, token1, feeTierBps)` base. Different from `verifyPair`,
   * which validates "is this pair genuinely registered at the version it
   * claims to be" -- `isLatestPair` returns false for older registered
   * versions whose base has been upgraded. Useful for routing UIs that
   * should send users to the live entry, not for verification gates that
   * need to allow legitimate older-version interactions (e.g.
   * remove-liquidity from a v1 LP after the base has been upgraded to v2).
   *
   * @returns true if the pair is the latest at its base
   * @throws if factory is not configured
   */
  async isLatestPair(pairAddress: AztecAddress): Promise<boolean> {
    const factory = this.factory();
    try {
      const config = await this.unsafePair(pairAddress).getConfig();
      const latest = await factory.getPair(
        config.token0, config.token1, Number(config.feeTierBps),
      );
      return latest.equals(pairAddress);
    } catch {
      return false;
    }
  }

  /**
   * Get a verified pair wrapper for the given pair address.
   *
   * Performs a factory cross-check before returning: reads the pair's
   * self-reported `(token0, token1, feeTierBps, version)` and asks the
   * factory whether THAT version of the pair is registered at THAT slot.
   * If the registered address doesn't equal the supplied address, throws
   * `SigalSwapValidationError`.
   *
   * Without this check, an integrator who sources a pair address from
   * outside the factory (an indexer's cached map, a UI URL parameter, a
   * user-provided "custom pool" input) might hand the SDK a malicious
   * contract that conforms to `SigalSwapPair`'s ABI and lies consistently.
   * A subsequent `swapExactIn` would sign an authwit naming the malicious
   * pair as `to` and hand it the user's tokens.
   *
   * For test/fork environments where the pair isn't (or can't be)
   * registered with a factory, use {@link unsafePair} instead.
   *
   * @throws if factory is not configured
   * @throws if the pair is not registered at its self-reported version
   */
  async pair(address: AztecAddress): Promise<SigalSwapPair> {
    if (!this.factoryContract) {
      throw new SigalSwapConfigurationError(
        'Factory address not configured. Pass `factoryAddress` to ' +
        '`SigalSwapClient.create` or use `unsafePair` if you have an ' +
        'out-of-band guarantee that the pair is genuine.',
      );
    }
    const pairContract = SigalSwapPairContract.at(address, this.wallet);
    const result = await checkPairRegistration(
      address, pairContract, this.factoryContract, this.senderAddress,
    );
    if (!result.verified) {
      throw new SigalSwapValidationError(
        `pair ${address.toString()} is not a registered SigalSwap pair. ` +
        (result.reason
          ? `Verification failed while reading config or factory registry: ${result.reason}`
          : `The factory has ${result.registeredAt.toString()} registered at the ` +
            `pair's self-reported (tokens, feeTier, version) slot. This may ` +
            `indicate a phishing pair impersonating SigalSwap.`) +
        ' Use `unsafePair` if you have an out-of-band guarantee.',
      );
    }
    return new SigalSwapPair(
      pairContract, this.wallet, this.senderAddress, this.config,
    );
  }

  /**
   * Construct a pair wrapper WITHOUT a factory cross-check.
   *
   * Skips the verification {@link pair} performs. Use only when:
   *   - testing against a sandbox or fork where the pair isn't registered
   *     in a factory
   *   - the pair address came from a trusted source (e.g. the result of
   *     `factory.createPair` on the just-deployed pair)
   *   - the SigalSwapClient was constructed without a `factoryAddress`
   *     and the integrator is interacting with a known-good pair
   *
   * Production integrators should prefer `pair()`.
   */
  unsafePair(address: AztecAddress): SigalSwapPair {
    return new SigalSwapPair(
      SigalSwapPairContract.at(address, this.wallet),
      this.wallet,
      this.senderAddress,
      this.config,
    );
  }

  /** Get the factory wrapper for pair lookups and protocol queries. */
  factory(): SigalSwapFactory {
    if (!this.factoryContract) {
      throw new SigalSwapConfigurationError('Factory address not configured');
    }
    return new SigalSwapFactory(this.factoryContract, this.senderAddress, this.wallet);
  }

  /** Get the router wrapper for multi-hop swaps with interface fee. */
  router(): SigalSwapRouter {
    if (!this.routerContract) {
      throw new SigalSwapConfigurationError('Router address not configured');
    }
    return new SigalSwapRouter(
      this.routerContract,
      this.wallet,
      this.senderAddress,
      this.config,
      this.factoryContract,
    );
  }

  /**
   * Fetch the user's private swap history -- merged across all four
   * `(source, direction)` event types the protocol emits. Without this
   * helper, an integrator would issue separate `getPrivateEvents` calls
   * per pair-and-event-type and re-implement the merge/sort/tag logic,
   * which is error-prone (forgetting one event type produces incomplete
   * history).
   *
   * **Pair scoping**: Aztec's `PrivateEventFilter` requires a single
   * `contractAddress` per query, so pair-side events have to be queried
   * pair-by-pair. Three input shapes:
   *   - `pairs: AztecAddress[]` -- explicit set; one query-pair fans out per
   *     address.
   *   - `pair: AztecAddress` -- shorthand for `pairs: [pair]`.
   *   - neither supplied -- if the factory is configured, auto-enumerate
   *     via {@link SigalSwapFactory.getActivePairCount} +
   *     {@link SigalSwapFactory.getLatestPairAtIndex} (skipping cleared
   *     bases). If the factory isn't configured, no pair-side events are
   *     queried and only the router-mediated history is returned.
   *
   * **Wallet-registration constraint**: a pair address only returns events
   * the wallet's PXE can decrypt -- pairs the wallet hasn't registered
   * (via `wallet.registerContract` or sender registration) yield empty
   * results. Auto-enumeration over an unfamiliar registry is therefore
   * cheap-but-empty rather than wrong. Integrators with users trading
   * pair-direct on specific pairs should register those pair addresses
   * with the wallet up-front.
   *
   * **Same-tx ordering caveat**: `Wallet.getPrivateEvents` doesn't expose
   * the PXE's internal `eventIndexInTx`. Within a single tx, events from
   * different `(source, direction)` buckets are tiebroken by lexical
   * `(source, direction)` rather than emission order. This affects only
   * wrapper contracts that alternate event types in one atomic tx; direct
   * SDK use is unaffected. See {@link compareSwapHistoryEntries}.
   *
   * @param opts.pairs - Pair addresses to scope pair-side events
   * @param opts.pair - Single-pair shorthand for `pairs: [pair]`
   * @param opts.fromBlock - First block to query (inclusive, default = 1)
   * @param opts.toBlock - Last block to query (exclusive, default = latest)
   * @returns Sorted by `(blockNumber, txHash, source, direction)`.
   */
  async getSwapHistory(opts: {
    pairs?: AztecAddress[];
    pair?: AztecAddress;
    fromBlock?: number;
    toBlock?: number;
  } = {}): Promise<SwapHistoryEntry[]> {
    if (!this.routerContract) {
      throw new SigalSwapConfigurationError('Router address not configured');
    }
    const baseFilter = this.buildBaseFilter(opts.fromBlock, opts.toBlock);
    const pairs = await this.resolvePairScope(opts.pairs, opts.pair);
    const routerFilter = { ...baseFilter, contractAddress: this.routerContract.address };

    const queries: Promise<SwapHistoryEntry[]>[] = [];
    for (const pair of pairs) {
      const pairFilter = { ...baseFilter, contractAddress: pair };
      queries.push(
        this.wallet.getPrivateEvents<PrivateSwapExactInEventData>(
          SigalSwapEvents.pair.PrivateSwapExactInEvent, pairFilter,
        ).then((evts) => evts.map((e) => ({
          source: 'pair' as const, direction: 'exactIn' as const,
          data: e.event,
          blockNumber: Number(e.metadata.l2BlockNumber),
          txHash: e.metadata.txHash.toString(),
        }))),
      );
      queries.push(
        this.wallet.getPrivateEvents<PrivateSwapExactOutEventData>(
          SigalSwapEvents.pair.PrivateSwapExactOutEvent, pairFilter,
        ).then((evts) => evts.map((e) => ({
          source: 'pair' as const, direction: 'exactOut' as const,
          data: e.event,
          blockNumber: Number(e.metadata.l2BlockNumber),
          txHash: e.metadata.txHash.toString(),
        }))),
      );
    }
    queries.push(
      this.wallet.getPrivateEvents<PrivateSwapExactInEventData>(
        SigalSwapEvents.router.RouterSwapExactInEvent, routerFilter,
      ).then((evts) => evts.map((e) => ({
        source: 'router' as const, direction: 'exactIn' as const,
        data: e.event,
        blockNumber: Number(e.metadata.l2BlockNumber),
        txHash: e.metadata.txHash.toString(),
      }))),
    );
    queries.push(
      this.wallet.getPrivateEvents<PrivateSwapExactOutEventData>(
        SigalSwapEvents.router.RouterSwapExactOutEvent, routerFilter,
      ).then((evts) => evts.map((e) => ({
        source: 'router' as const, direction: 'exactOut' as const,
        data: e.event,
        blockNumber: Number(e.metadata.l2BlockNumber),
        txHash: e.metadata.txHash.toString(),
      }))),
    );

    const merged = (await Promise.all(queries)).flat();
    merged.sort(compareSwapHistoryEntries);
    return merged;
  }

  /**
   * Fetch the user's private liquidity history (mint + burn) merged across
   * pair-direct and router-mediated paths. Same shape and pair-scoping
   * rules as {@link getSwapHistory} -- see that method's JSDoc for the full
   * rules around `pairs` / `pair` / auto-enumeration and the same-tx
   * ordering caveat. Tagged with `kind: 'mint' | 'burn'` instead of swap
   * directions.
   */
  async getLiquidityHistory(opts: {
    pairs?: AztecAddress[];
    pair?: AztecAddress;
    fromBlock?: number;
    toBlock?: number;
  } = {}): Promise<LiquidityHistoryEntry[]> {
    if (!this.routerContract) {
      throw new SigalSwapConfigurationError('Router address not configured');
    }
    const baseFilter = this.buildBaseFilter(opts.fromBlock, opts.toBlock);
    const pairs = await this.resolvePairScope(opts.pairs, opts.pair);
    const routerFilter = { ...baseFilter, contractAddress: this.routerContract.address };

    const queries: Promise<LiquidityHistoryEntry[]>[] = [];
    for (const pair of pairs) {
      const pairFilter = { ...baseFilter, contractAddress: pair };
      queries.push(
        this.wallet.getPrivateEvents<PrivateMintEventData>(
          SigalSwapEvents.pair.PrivateMintEvent, pairFilter,
        ).then((evts) => evts.map((e) => ({
          source: 'pair' as const, kind: 'mint' as const,
          data: e.event,
          blockNumber: Number(e.metadata.l2BlockNumber),
          txHash: e.metadata.txHash.toString(),
        }))),
      );
      queries.push(
        this.wallet.getPrivateEvents<PrivateBurnEventData>(
          SigalSwapEvents.pair.PrivateBurnEvent, pairFilter,
        ).then((evts) => evts.map((e) => ({
          source: 'pair' as const, kind: 'burn' as const,
          data: e.event,
          blockNumber: Number(e.metadata.l2BlockNumber),
          txHash: e.metadata.txHash.toString(),
        }))),
      );
    }
    queries.push(
      this.wallet.getPrivateEvents<PrivateMintEventData>(
        SigalSwapEvents.router.RouterMintEvent, routerFilter,
      ).then((evts) => evts.map((e) => ({
        source: 'router' as const, kind: 'mint' as const,
        data: e.event,
        blockNumber: Number(e.metadata.l2BlockNumber),
        txHash: e.metadata.txHash.toString(),
      }))),
    );
    queries.push(
      this.wallet.getPrivateEvents<PrivateBurnEventData>(
        SigalSwapEvents.router.RouterBurnEvent, routerFilter,
      ).then((evts) => evts.map((e) => ({
        source: 'router' as const, kind: 'burn' as const,
        data: e.event,
        blockNumber: Number(e.metadata.l2BlockNumber),
        txHash: e.metadata.txHash.toString(),
      }))),
    );

    const merged = (await Promise.all(queries)).flat();
    merged.sort(compareLiquidityHistoryEntries);
    return merged;
  }

  /** Build the shared block-range / scopes filter for both history methods. */
  private buildBaseFilter(fromBlock?: number, toBlock?: number) {
    return {
      scopes: [this.senderAddress],
      ...(fromBlock !== undefined ? { fromBlock: fromBlock as unknown as BlockNumber } : {}),
      ...(toBlock !== undefined ? { toBlock: toBlock as unknown as BlockNumber } : {}),
    };
  }

  /**
   * Resolve the set of pair addresses to query for pair-direct events.
   * Precedence: explicit `pairs` array > `pair` shorthand > factory
   * auto-enumeration (live pairs only) > empty (router-only history).
   */
  private async resolvePairScope(
    pairs: AztecAddress[] | undefined,
    pair: AztecAddress | undefined,
  ): Promise<AztecAddress[]> {
    if (pairs !== undefined) return pairs;
    if (pair !== undefined) return [pair];
    if (!this.factoryContract) return [];
    // Auto-enumerate live pairs via the factory. Cleared bases return zero
    // at their indexed slot; skip them. Parallelize the per-index reads.
    const factory = new SigalSwapFactory(this.factoryContract, this.senderAddress, this.wallet);
    const count = await factory.getActivePairCount();
    if (count === 0) return [];
    const indices = Array.from({ length: count }, (_, i) => i);
    const candidates = await Promise.all(indices.map((i) => factory.getLatestPairAtIndex(i)));
    return candidates.filter((p) => !p.isZero());
  }
}

/**
 * Stable, deterministic comparator for {@link SwapHistoryEntry}.
 *
 * Order keys, in priority:
 *   1. `blockNumber` ascending
 *   2. `txHash` ascending (lexical) -- groups same-block, different-tx events
 *   3. `source` ascending (lexical) -- separates pair-direct from router
 *   4. `direction` ascending (lexical) -- separates exactIn from exactOut
 *
 * Categories the comparator handles fully:
 *   - Cross-tx ordering (different `txHash`).
 *   - Same-tx, same-bucket events (multiple events of one type from one
 *     emitter in one tx -- e.g., a wrapper contract calling
 *     `pair.swap_exact_in` twice atomically). Within a single bucket the
 *     PXE returns events sorted by `(block, txIndexInBlock, eventIndexInTx)`;
 *     `Array.prototype.sort` is stable (ES2019+), so equal-key entries
 *     preserve their input order.
 *
 * Category the comparator does NOT resolve:
 *   - Same-tx, cross-bucket events (a wrapper contract alternating
 *     `swap_exact_in` and `swap_exact_out` in one atomic tx). The
 *     PXE-internal `eventIndexInTx` value would resolve this, but
 *     `Wallet.getPrivateEvents` strips it from the returned metadata in
 *     aztec.js v4.3.0 (verified 2026-05-23). Cross-
 *     bucket entries are deterministically tiebroken by `(source, direction)`
 *     lexical ordering, but that ordering does not necessarily match
 *     emission order. Track upstream:
 *     https://github.com/AztecProtocol/aztec-packages -- request that
 *     `txIndexInBlock` and `eventIndexInTx` be exposed via
 *     `PackedPrivateEvent` so consumers can sort across buckets correctly.
 */
function compareSwapHistoryEntries(a: SwapHistoryEntry, b: SwapHistoryEntry): number {
  if (a.blockNumber !== b.blockNumber) return a.blockNumber - b.blockNumber;
  if (a.txHash !== b.txHash) return a.txHash < b.txHash ? -1 : 1;
  if (a.source !== b.source) return a.source < b.source ? -1 : 1;
  if (a.direction !== b.direction) return a.direction < b.direction ? -1 : 1;
  return 0;
}

/** Liquidity-history sibling of {@link compareSwapHistoryEntries}; same caveats. */
function compareLiquidityHistoryEntries(a: LiquidityHistoryEntry, b: LiquidityHistoryEntry): number {
  if (a.blockNumber !== b.blockNumber) return a.blockNumber - b.blockNumber;
  if (a.txHash !== b.txHash) return a.txHash < b.txHash ? -1 : 1;
  if (a.source !== b.source) return a.source < b.source ? -1 : 1;
  if (a.kind !== b.kind) return a.kind < b.kind ? -1 : 1;
  return 0;
}
