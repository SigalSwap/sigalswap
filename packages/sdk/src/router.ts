// SPDX-License-Identifier: MIT
// Copyright (c) 2026 SigalSwap LLC

import { AztecAddress } from '@aztec/aztec.js/addresses';
import { Fr } from '@aztec/aztec.js/fields';
import type { Wallet } from '@aztec/aztec.js/wallet';

import type { TxSendResultMined } from '@aztec/aztec.js/contracts';
import { SigalSwapPairContract } from './artifacts/SigalSwapPair.js';
import { SigalSwapRouterContract } from './artifacts/SigalSwapRouter.js';
import type { SigalSwapFactoryContract } from './artifacts/SigalSwapFactory.js';
import { TokenContract } from './artifacts/Token.js';
import type { SigalSwapConfig } from './config/index.js';
import { MAX_INTERFACE_FEE_BIPS } from './constants.js';
import { SigalSwapConfigurationError, SigalSwapValidationError, wrapContractRevert } from './errors.js';
import { checkPairRegistration } from './pair-verification.js';

/**
 * Maximum number of hops in a multi-hop swap.
 * Must match the contract's `MAX_HOPS` in periphery/src/libraries/mod.nr.
 */
export const MAX_HOPS = 3;

/**
 * High-level wrapper around the SigalSwapRouter contract.
 *
 * Provides single-hop and multi-hop swap routing with deadline enforcement
 * and automatic interface fee injection. Creates authorization witnesses
 * (authwits) automatically for all transaction methods. Token addresses
 * for liquidity operations are auto-fetched from the pair contract to
 * prevent ordering mistakes.
 *
 * **Path restrictions**: `swapExactOut` rejects paths where the final
 * token appears earlier in the path (cyclic or hub-routing shapes).
 * `swapExactIn` supports cyclic paths (triangular arbitrage).
 *
 * **Note**: Deadline validation is best-effort on the client side. The
 * authoritative deadline check happens on-chain in the contract. The SDK's
 * past-deadline check uses wall-clock (`Date.now() / 1000`); the contract's
 * `EXPIRED` assert uses the L2 block timestamp, which can lag wall-clock
 * by seconds depending on inclusion latency. A deadline that passes SDK
 * validation could still revert on-chain. Pick deadlines at least 30 seconds
 * in the future for typical L2 inclusion latency; tighter bounds risk
 * spurious `EXPIRED` reverts even on well-formed txs.
 *
 * @internal Construct via `SigalSwapClient.router()` rather than directly.
 */
export class SigalSwapRouter {
  /**
   * Parsed `feeRecipient` from the SDK config, resolved once at construction.
   * `AztecAddress.fromString` runs a regex + hex-validation pass; caching
   * here avoids re-parsing on every swap. Falls back to the zero address
   * when the config carries no `feeRecipient` (the contract reads "no
   * interface fee" semantics from a zero recipient).
   */
  private readonly feeRecipient: AztecAddress;

  /**
   * Per-pair verification cache. A pair address makes it into this set
   * after `assertPairVerified` confirms the factory has it registered at
   * its self-reported version. Subsequent calls on the same pair are
   * cache hits and skip the round-trip. Keyed by `address.toString()`
   * since `AztecAddress` is reference-typed and `Set<AztecAddress>` would
   * not dedupe equal-but-distinct instances.
   */
  private readonly pairVerifiedCache: Set<string> = new Set();

  /** @internal */
  constructor(
    private readonly contract: SigalSwapRouterContract,
    private readonly wallet: Wallet,
    private readonly senderAddress: AztecAddress,
    private readonly config: SigalSwapConfig,
    /**
     * Factory contract handle, optional at construction but required by
     * every fund-moving entry. Methods that take a `pair` argument call
     * `assertPairVerified` before authwit construction; that check throws
     * a clear configuration error when the factory was not wired in.
     */
    private readonly factoryContract: SigalSwapFactoryContract | null = null,
  ) {
    this.feeRecipient = config.feeRecipient
      ? AztecAddress.fromString(config.feeRecipient)
      : AztecAddress.zero();

    // The router's swap entries assert `fee_recipient != self.address`
    // (FEE_RECIPIENT_IS_ROUTER). A misconfigured frontend that aliases
    // feeRecipient to the router would otherwise build every swap, sign
    // an authwit, pay proving cost, and only discover the issue at the
    // contract revert. Surface it at construction instead. Zero is the
    // "no fee" sentinel and never equals a deployed router.
    if (this.feeRecipient.equals(this.contract.address)) {
      throw new SigalSwapConfigurationError(
        `feeRecipient (${this.feeRecipient.toString()}) cannot equal the ` +
        `router address. Pick a separate address for the interface fee.`,
      );
    }
  }

  // ================================================================
  // Single-hop swaps (deadline-protected)
  //
  // Single-hop dispatches to the router's `swap_exact_in` / `swap_exact_out`
  // private entries. The ROUTER is the caller that pulls tokens from the
  // user (via `transfer_to_public(sender, router, amount, nonce)`), routes
  // through the pair, and refunds any change. Authwits authorize the
  // ROUTER address. Honors the SDK's configured interface fee identically
  // to multi-hop -- no asymmetry between the two paths since the router
  // consolidation.
  // ================================================================

  /**
   * Single-hop swap with exact input amount and deadline protection.
   *
   * Honors the SDK's configured interface fee. `amountOutMin` is the user's
   * POST-FEE minimum received; the contract deducts the fee from the pair's
   * output before enforcing it.
   *
   * @param opts.pair - The pair contract address
   * @param opts.tokenIn - Input token address
   * @param opts.tokenOut - Output token address
   * @param opts.amountIn - Exact input amount
   * @param opts.amountOutMin - Minimum acceptable post-fee output
   * @param opts.deadline - Unix timestamp deadline (seconds)
   */
  async swapSingleExactIn(opts: {
    pair: AztecAddress;
    tokenIn: AztecAddress;
    tokenOut: AztecAddress;
    amountIn: bigint;
    amountOutMin: bigint;
    deadline: number;
  }): Promise<TxSendResultMined> {
    if (opts.pair.isZero()) throw new SigalSwapValidationError('pair address cannot be zero');
    if (opts.amountIn <= 0n) throw new SigalSwapValidationError('amountIn must be positive');
    if (opts.amountOutMin < 0n) throw new SigalSwapValidationError('amountOutMin cannot be negative');
    if (opts.tokenIn.equals(opts.tokenOut)) throw new SigalSwapValidationError('tokenIn and tokenOut must differ');
    this.validateDeadline(opts.deadline);
    await this.assertPairVerified(opts.pair);
    await this.assertSingleHopConsistency(opts.pair, opts.tokenIn, opts.tokenOut);

    const nonce = Fr.random();
    const { feeRecipient, feeBips, amountOutMin } = this.computeFeeParams(opts.amountOutMin);

    const authWit = await this.createTransferAuthwit(
      opts.tokenIn, 'transfer_to_public', opts.amountIn, nonce, this.contract.address,
    );

    return wrapContractRevert(
      'router.swap_exact_in',
      () => this.contract.methods
        .swap_exact_in(
          opts.pair,
          opts.tokenIn,
          opts.tokenOut,
          opts.amountIn,
          amountOutMin,
          opts.deadline,
          nonce,
          feeRecipient,
          feeBips,
        )
        .with({ authWitnesses: [authWit] })
        .send({ from: this.senderAddress }) as unknown as Promise<TxSendResultMined>,
    );
  }

  /**
   * Single-hop swap for exact output amount with deadline protection.
   *
   * Honors the SDK's configured interface fee. The router grosses up the
   * pair-level target on-chain so the user receives at least `amountOut`
   * after fee deduction.
   *
   * @param opts.pair - The pair contract address
   * @param opts.tokenIn - Input token address
   * @param opts.tokenOut - Output token address
   * @param opts.amountOut - Minimum post-fee amount the user will receive
   * @param opts.amountInMax - Maximum input amount willing to spend
   * @param opts.deadline - Unix timestamp deadline (seconds)
   */
  async swapSingleExactOut(opts: {
    pair: AztecAddress;
    tokenIn: AztecAddress;
    tokenOut: AztecAddress;
    amountOut: bigint;
    amountInMax: bigint;
    deadline: number;
  }): Promise<TxSendResultMined> {
    if (opts.pair.isZero()) throw new SigalSwapValidationError('pair address cannot be zero');
    if (opts.amountOut <= 0n) throw new SigalSwapValidationError('amountOut must be positive');
    if (opts.amountInMax <= 0n) throw new SigalSwapValidationError('amountInMax must be positive');
    if (opts.tokenIn.equals(opts.tokenOut)) throw new SigalSwapValidationError('tokenIn and tokenOut must differ');
    this.validateDeadline(opts.deadline);
    await this.assertPairVerified(opts.pair);
    await this.assertSingleHopConsistency(opts.pair, opts.tokenIn, opts.tokenOut);

    const nonce = Fr.random();
    const { feeRecipient, feeBips } = this.computeFeeParams(opts.amountOut);

    const authWit = await this.createTransferAuthwit(
      opts.tokenIn,
      'transfer_to_public_and_prepare_private_balance_increase',
      opts.amountInMax,
      nonce,
      this.contract.address,
    );

    return wrapContractRevert(
      'router.swap_exact_out',
      () => this.contract.methods
        .swap_exact_out(
          opts.pair,
          opts.tokenIn,
          opts.tokenOut,
          opts.amountOut,
          opts.amountInMax,
          opts.deadline,
          nonce,
          feeRecipient,
          feeBips,
        )
        .with({ authWitnesses: [authWit] })
        .send({ from: this.senderAddress }) as unknown as Promise<TxSendResultMined>,
    );
  }

  // ================================================================
  // Multi-hop swaps (deadline-protected, with interface fee)
  // ================================================================

  /**
   * Execute a multi-hop swap with exact input amount.
   *
   * The SDK injects the configured interface fee. The contract enforces
   * `amount_out_min` AFTER fee deduction, so amountOutMin is the user's actual
   * post-fee floor -- no inflation tricks required.
   *
   * @param opts.path - Token addresses in order [tokenIn, ..., tokenOut]
   * @param opts.pairs - Pair addresses for each hop
   * @param opts.amountIn - Exact input amount
   * @param opts.amountOutMin - Minimum acceptable output after fee (slippage protection)
   * @param opts.deadline - Unix timestamp deadline (seconds)
   */
  async swapExactIn(opts: {
    path: AztecAddress[];
    pairs: AztecAddress[];
    amountIn: bigint;
    amountOutMin: bigint;
    deadline: number;
  }): Promise<TxSendResultMined> {
    if (opts.path.length < 2) throw new SigalSwapValidationError('Path must have at least 2 tokens');
    if (opts.path.length > MAX_HOPS + 1) throw new SigalSwapValidationError(`Path too long (max ${MAX_HOPS + 1} tokens)`);
    if (opts.pairs.length !== opts.path.length - 1) throw new SigalSwapValidationError('Pairs array must be one shorter than path');
    if (opts.amountIn <= 0n) throw new SigalSwapValidationError('amountIn must be positive');
    if (opts.amountOutMin < 0n) throw new SigalSwapValidationError('amountOutMin cannot be negative');
    this.validateDeadline(opts.deadline);
    this.validatePathAdjacency(opts.path);
    await Promise.all(opts.pairs.map((p) => this.assertPairVerified(p)));
    await this.validatePathPairConsistency(opts.path, opts.pairs);

    const pathPadded = this.padArray(opts.path, MAX_HOPS + 1);
    const pairsPadded = this.padArray(opts.pairs, MAX_HOPS);
    const nonce = Fr.random();

    const { feeRecipient, feeBips, amountOutMin } = this.computeFeeParams(opts.amountOutMin);

    // For multi-hop, the ROUTER itself transfers input tokens (not the pair)
    const authWit = await this.createTransferAuthwit(
      opts.path[0], 'transfer_to_public', opts.amountIn, nonce, this.contract.address,
    );

    return wrapContractRevert(
      'router.swap_exact_in_multi_hop',
      () => this.contract.methods
        .swap_exact_in_multi_hop(
          pathPadded,
          pairsPadded,
          opts.path.length,
          opts.amountIn,
          amountOutMin,
          opts.deadline,
          nonce,
          feeRecipient,
          feeBips,
        )
        .with({ authWitnesses: [authWit] })
        .send({ from: this.senderAddress }) as unknown as Promise<TxSendResultMined>,
    );
  }

  /**
   * Execute a multi-hop swap for an exact output amount.
   *
   * The SDK injects the configured interface fee. The contract derives
   * per-hop input ceilings on-chain by walking backward from the user's
   * target output via `pair.quote_amount_in_public`, and enforces
   * `amount_in_max` on the first hop's required input. `amountOut` is
   * the user's POST-FEE desired output; the contract grosses up for
   * the fee on-chain, so the SDK passes `amountOut` unchanged.
   *
   * The final token must be distinct from every other token in the path
   * (no cycle back to the initial, no hub-routing through an
   * intermediate). The contract also enforces this as
   * `FINAL_TOKEN_REPEATED`; cyclic paths are supported only by
   * `swapExactIn`.
   *
   * @param opts.path - Token addresses in order [tokenIn, ..., tokenOut]
   * @param opts.pairs - Pair addresses for each hop
   * @param opts.amountOut - Exact post-fee output amount to receive
   * @param opts.amountInMax - Maximum input ceiling (slippage protection)
   * @param opts.deadline - Unix timestamp deadline (seconds)
   */
  async swapExactOut(opts: {
    path: AztecAddress[];
    pairs: AztecAddress[];
    amountOut: bigint;
    amountInMax: bigint;
    deadline: number;
  }): Promise<TxSendResultMined> {
    if (opts.path.length < 2) throw new SigalSwapValidationError('Path must have at least 2 tokens');
    if (opts.path.length > MAX_HOPS + 1) throw new SigalSwapValidationError(`Path too long (max ${MAX_HOPS + 1} tokens)`);
    if (opts.pairs.length !== opts.path.length - 1) throw new SigalSwapValidationError('Pairs array must be one shorter than path');
    if (opts.amountOut <= 0n) throw new SigalSwapValidationError('amountOut must be positive');
    if (opts.amountInMax <= 0n) throw new SigalSwapValidationError('amountInMax must be positive');
    this.validateDeadline(opts.deadline);
    this.validatePathAdjacency(opts.path);
    this.validatePathFinalUnique(opts.path);
    await Promise.all(opts.pairs.map((p) => this.assertPairVerified(p)));
    await this.validatePathPairConsistency(opts.path, opts.pairs);

    const pathPadded = this.padArray(opts.path, MAX_HOPS + 1);
    const pairsPadded = this.padArray(opts.pairs, MAX_HOPS);
    const nonce = Fr.random();

    const { feeRecipient, feeBips } = this.computeFeeParams(opts.amountOut);

    // For multi-hop exact-out, the router transfers amount_in_max of
    // path[0] into its own public balance and prepares a change note
    // for the unused remainder. Authwit target is token_in; caller is
    // the router.
    const authWit = await this.createTransferAuthwit(
      opts.path[0],
      'transfer_to_public_and_prepare_private_balance_increase',
      opts.amountInMax,
      nonce,
      this.contract.address,
    );

    return wrapContractRevert(
      'router.swap_exact_out_multi_hop',
      () => this.contract.methods
        .swap_exact_out_multi_hop(
          pathPadded,
          pairsPadded,
          opts.path.length,
          opts.amountOut,
          opts.amountInMax,
          opts.deadline,
          nonce,
          feeRecipient,
          feeBips,
        )
        .with({ authWitnesses: [authWit] })
        .send({ from: this.senderAddress }) as unknown as Promise<TxSendResultMined>,
    );
  }

  // ================================================================
  // Liquidity (deadline-protected)
  //
  // For liquidity operations, the router delegates to the pair.
  // The PAIR is the caller that transfers tokens.
  // ================================================================

  /**
   * Add liquidity with deadline protection.
   *
   * Automatically queries the pair contract to determine token addresses
   * for authwit creation, ensuring correct token ordering.
   *
   * @param opts.pair - The pair contract address
   * @param opts.amount0Max - Maximum amount of token0 to deposit
   * @param opts.amount1Max - Maximum amount of token1 to deposit
   * @param opts.amount0Min - Minimum amount of token0 to deposit (slippage)
   * @param opts.amount1Min - Minimum amount of token1 to deposit (slippage)
   * @param opts.deadline - Unix timestamp deadline (seconds)
   */
  async addLiquidity(opts: {
    pair: AztecAddress;
    amount0Max: bigint;
    amount1Max: bigint;
    amount0Min: bigint;
    amount1Min: bigint;
    deadline: number;
  }): Promise<TxSendResultMined> {
    if (opts.pair.isZero()) throw new SigalSwapValidationError('pair address cannot be zero');
    if (opts.amount0Max <= 0n) throw new SigalSwapValidationError('amount0Max must be positive');
    if (opts.amount1Max <= 0n) throw new SigalSwapValidationError('amount1Max must be positive');
    if (opts.amount0Min < 0n) throw new SigalSwapValidationError('amount0Min cannot be negative');
    if (opts.amount1Min < 0n) throw new SigalSwapValidationError('amount1Min cannot be negative');
    if (opts.amount0Min > opts.amount0Max) throw new SigalSwapValidationError('amount0Min must be <= amount0Max');
    if (opts.amount1Min > opts.amount1Max) throw new SigalSwapValidationError('amount1Min must be <= amount1Max');
    this.validateDeadline(opts.deadline);
    await this.assertPairVerified(opts.pair);

    const { token0, token1, lpToken } = await this.fetchPairConfig(opts.pair);
    const nonce = Fr.random();

    // Router pulls user's amount_max into its own public balance (V2-router pattern).
    // The router computes the optimal pair-ratio match in its public continuation
    // and refunds the unused remainder to the user via partial notes.
    const [authWit0, authWit1] = await Promise.all([
      this.createTransferAuthwit(
        token0, 'transfer_to_public_and_prepare_private_balance_increase',
        opts.amount0Max, nonce, this.contract.address,
      ),
      this.createTransferAuthwit(
        token1, 'transfer_to_public_and_prepare_private_balance_increase',
        opts.amount1Max, nonce, this.contract.address,
      ),
    ]);

    return wrapContractRevert(
      'router.add_liquidity',
      () => this.contract.methods
        .add_liquidity(
          opts.pair,
          token0,
          token1,
          lpToken,
          opts.amount0Max,
          opts.amount1Max,
          opts.amount0Min,
          opts.amount1Min,
          opts.deadline,
          nonce,
        )
        .with({ authWitnesses: [authWit0, authWit1] })
        .send({ from: this.senderAddress }) as unknown as Promise<TxSendResultMined>,
    );
  }

  /**
   * Remove liquidity with deadline protection.
   *
   * Automatically queries the pair contract to determine the LP token
   * address for authwit creation.
   *
   * @param opts.pair - The pair contract address
   * @param opts.liquidity - Amount of LP tokens to burn
   * @param opts.amount0Min - Minimum token0 to receive
   * @param opts.amount1Min - Minimum token1 to receive
   * @param opts.deadline - Unix timestamp deadline (seconds)
   */
  async removeLiquidity(opts: {
    pair: AztecAddress;
    liquidity: bigint;
    amount0Min: bigint;
    amount1Min: bigint;
    deadline: number;
  }): Promise<TxSendResultMined> {
    if (opts.pair.isZero()) throw new SigalSwapValidationError('pair address cannot be zero');
    if (opts.liquidity <= 0n) throw new SigalSwapValidationError('liquidity must be positive');
    if (opts.amount0Min < 0n) throw new SigalSwapValidationError('amount0Min cannot be negative');
    if (opts.amount1Min < 0n) throw new SigalSwapValidationError('amount1Min cannot be negative');
    this.validateDeadline(opts.deadline);
    await this.assertPairVerified(opts.pair);

    const { token0, token1, lpToken } = await this.fetchPairConfig(opts.pair);
    const nonce = Fr.random();

    // Router transfers LP tokens to pair (user authorizes router as caller)
    const authWit = await this.createTransferAuthwit(
      lpToken, 'transfer_to_public', opts.liquidity, nonce, this.contract.address, opts.pair,
    );

    return wrapContractRevert(
      'router.remove_liquidity',
      () => this.contract.methods
        .remove_liquidity(
          opts.pair,
          token0,
          token1,
          lpToken,
          opts.liquidity,
          opts.amount0Min,
          opts.amount1Min,
          opts.deadline,
          nonce,
        )
        .with({ authWitnesses: [authWit] })
        .send({ from: this.senderAddress }) as unknown as Promise<TxSendResultMined>,
    );
  }

  // ================================================================
  // Views
  // ================================================================

  /**
   * Get the factory address this router is bound to. Useful when an
   * integrator instantiates `SigalSwapClient` with only a router address
   * and wants to discover the factory to look up pairs without hardcoding
   * a separate config field.
   */
  async getFactory(): Promise<AztecAddress> {
    const { result } = await this.contract.methods
      .get_factory()
      .simulate({ from: this.senderAddress });
    return result;
  }

  /**
   * Quote the final output of a multi-hop exact-input swap without executing
   * it. One simulate call walks the entire path on-chain (router utility ->
   * each pair's `quote_amount_out` utility), so the SDK doesn't have to chain
   * N per-pair simulate calls.
   *
   * Does not subtract the router's interface fee; callers that apply a fee
   * should subtract `result * feeBips / 10_000` to mirror the on-chain
   * `_deduct_interface_fee` behavior.
   *
   * Throws on PATH_TOO_SHORT, PATH_TOO_LONG (router-side validator) or any
   * per-hop pair revert (TOKEN_IN_IS_INVALID, INSUFFICIENT_LIQUIDITY, etc.).
   */
  async quoteExactInMultiHop(
    path: AztecAddress[],
    pairs: AztecAddress[],
    amountIn: bigint,
  ): Promise<bigint> {
    if (path.length < 2) throw new SigalSwapValidationError('Path too short (need >= 2 tokens)');
    if (path.length > MAX_HOPS + 1) throw new SigalSwapValidationError(`Path too long (max ${MAX_HOPS + 1} tokens)`);
    if (pairs.length !== path.length - 1) {
      throw new SigalSwapValidationError(`pairs.length must equal path.length - 1`);
    }
    const paddedPath = this.padArray(path, MAX_HOPS + 1);
    const paddedPairs = this.padArray(pairs, MAX_HOPS);
    const { result } = await this.contract.methods
      .quote_exact_in_multi_hop(paddedPath, paddedPairs, path.length, amountIn)
      .simulate({ from: this.senderAddress });
    return result as bigint;
  }

  /**
   * Quote the input amount required to produce a target output through a
   * multi-hop exact-output swap. Walks the path backwards (router utility ->
   * each pair's `quote_amount_in` utility) in a single simulate call.
   *
   * Does not account for the interface fee; if the eventual swap applies one,
   * scale the returned amount up by `10_000 / (10_000 - feeBips)` before
   * granting the authwit.
   */
  async quoteExactOutMultiHop(
    path: AztecAddress[],
    pairs: AztecAddress[],
    amountOut: bigint,
  ): Promise<bigint> {
    if (path.length < 2) throw new SigalSwapValidationError('Path too short (need >= 2 tokens)');
    if (path.length > MAX_HOPS + 1) throw new SigalSwapValidationError(`Path too long (max ${MAX_HOPS + 1} tokens)`);
    if (pairs.length !== path.length - 1) {
      throw new SigalSwapValidationError(`pairs.length must equal path.length - 1`);
    }
    const paddedPath = this.padArray(path, MAX_HOPS + 1);
    const paddedPairs = this.padArray(pairs, MAX_HOPS);
    const { result } = await this.contract.methods
      .quote_exact_out_multi_hop(paddedPath, paddedPairs, path.length, amountOut)
      .simulate({ from: this.senderAddress });
    return result as bigint;
  }

  // ================================================================
  // Stuck-balance recovery
  // ================================================================

  /**
   * Sweep the router's full public balance of `token` to `recipient`.
   *
   * The router is designed to hold zero token balances between transactions,
   * but two situations can leave dust at its address:
   *   1. Cyclic exact-in paths (e.g. `[A, B, A]`) preserve any pre-existing
   *      router balance of `A`, since per-hop accounting only touches deltas.
   *   2. Anyone can `transfer_in_public(_, router, amount, 0)` directly --
   *      tokens land at the router with no owner record.
   *
   * `skim_to` is the recovery escape hatch. Permissionless on purpose:
   *   - Donations are a known footgun (sending to a contract with no withdraw
   *     method); permissionless skim lets any party reclaim dust before
   *     someone else does.
   *   - The contract enforces `hop_active == false`, so this can't extract
   *     tokens that the router currently holds for an in-flight swap.
   *
   * Reverts with:
   *   - `SigalSwapValidationError` if `recipient` is the zero address (would
   *     permanently lock the swept tokens).
   *   - `SigalSwapContractRevertError` for `HOP_ACTIVE` (mid-swap; should be
   *     unreachable in practice, since multi-hop is atomic) or `NO_BALANCE`
   *     (router holds no balance of `token` -- pre-check via Token contract).
   */
  async skimTo(token: AztecAddress, recipient: AztecAddress): Promise<TxSendResultMined> {
    if (recipient.isZero()) {
      throw new SigalSwapValidationError('skimTo: recipient cannot be the zero address');
    }
    // Pre-flight the on-chain `NO_BALANCE` revert with a public balance
    // read. A scrubber iterating skim across many tokens otherwise pays
    // a wasted proving cycle for every token at which the router holds
    // zero. The contract's NO_BALANCE assert stays as defense-in-depth.
    const { result: routerBalance } = await TokenContract.at(token, this.wallet)
      .methods
      .balance_of_public(this.contract.address)
      .simulate({ from: this.senderAddress });
    if ((routerBalance as bigint) === 0n) {
      throw new SigalSwapValidationError(
        `skimTo: router holds no balance of token ${token.toString()}`,
      );
    }
    return wrapContractRevert(
      'router.skim_to',
      () => this.contract.methods
        .skim_to(token, recipient)
        .send({ from: this.senderAddress }) as unknown as Promise<TxSendResultMined>,
    );
  }

  // ================================================================
  // Internal helpers
  // ================================================================

  /** Cache of pair configs keyed by address string. */
  private pairConfigCache = new Map<string, { token0: AztecAddress; token1: AztecAddress; lpToken: AztecAddress }>();

  /**
   * Fetch a pair's token configuration. Cached per pair address.
   * This ensures correct token ordering for authwit creation. The LP
   * Token address is included in `PairConfig` (derived in the pair's
   * constructor and embedded at construction), so a single `get_config`
   * read covers all three fields.
   */
  /**
   * Cross-check a user-supplied pair address against the factory before
   * any fund movement. Caches successful verifications per address so a
   * caller making repeated swaps on the same pair pays the round-trip
   * only on the first call.
   *
   * Without this check, a pair address sourced from outside the factory
   * could point at a malicious contract that conforms to the
   * `SigalSwapPair` ABI and lies about its config consistently. The
   * router's existing consistency helpers (`assertSingleHopConsistency`,
   * `validatePathPairConsistency`) read the pair's self-report and pass
   * against a lying pair; this method closes the circle by asking the
   * factory whether THAT version of the pair is registered at THAT slot.
   *
   * The factory is required: an integrator who constructs `SigalSwapClient`
   * without a `factoryAddress` cannot use any router fund-moving entry.
   * The error message names the configuration knob to set.
   *
   * @throws if factory is not configured
   * @throws if the pair is not registered at its self-reported version
   */
  private async assertPairVerified(pair: AztecAddress): Promise<void> {
    const key = pair.toString();
    if (this.pairVerifiedCache.has(key)) return;
    if (!this.factoryContract) {
      throw new SigalSwapValidationError(
        `cannot verify pair ${key}: factory address not configured on the ` +
        `SigalSwapClient. Pass \`factoryAddress\` to \`SigalSwapClient.create\` ` +
        `to enable router transactions.`,
      );
    }
    const pairContract = SigalSwapPairContract.at(pair, this.wallet);
    const result = await checkPairRegistration(
      pair, pairContract, this.factoryContract, this.senderAddress,
    );
    if (!result.verified) {
      throw new SigalSwapValidationError(
        `pair ${key} is not a registered SigalSwap pair. ` +
        (result.reason
          ? `Verification failed while reading config or factory registry: ${result.reason}`
          : `The factory has ${result.registeredAt.toString()} registered at the ` +
            `pair's self-reported (tokens, feeTier, version) slot. This may ` +
            `indicate a phishing pair impersonating SigalSwap.`),
      );
    }
    this.pairVerifiedCache.add(key);
    // Reuse the config this check already read so the subsequent consistency
    // check (`assertSingleHopConsistency` / `validatePathPairConsistency` via
    // `fetchPairConfig`) is a cache hit rather than a second `get_config`
    // round-trip on the first action against a pair.
    if (result.config && !this.pairConfigCache.has(key)) {
      this.pairConfigCache.set(key, result.config);
    }
  }

  private async fetchPairConfig(pairAddress: AztecAddress): Promise<{
    token0: AztecAddress;
    token1: AztecAddress;
    lpToken: AztecAddress;
  }> {
    const key = pairAddress.toString();
    if (!this.pairConfigCache.has(key)) {
      const pairContract = SigalSwapPairContract.at(pairAddress, this.wallet);
      const { result: config } = await pairContract.methods
        .get_config()
        .simulate({ from: this.senderAddress });
      this.pairConfigCache.set(key, {
        token0: config.token0,
        token1: config.token1,
        lpToken: config.lp_token,
      });
    }
    return this.pairConfigCache.get(key)!;
  }

  /**
   * Resolve fee parameters for a multi-hop swap.
   *
   * The contract enforces `amount_out_min` AFTER the interface fee is deducted,
   * so the user's requested minimum passes through directly -- no SDK-side
   * inflation is needed or correct.
   *
   * The router caps fee_bips at 500 (5%); the SDK mirrors that cap to give
   * integrators a clear client-side error before a transaction is built.
   */
  private computeFeeParams(userAmountOutMin: bigint): {
    feeRecipient: AztecAddress;
    feeBips: number;
    amountOutMin: bigint;
  } {
    const feeBips = this.config.feeBips ?? 0;
    if (feeBips > MAX_INTERFACE_FEE_BIPS) {
      throw new SigalSwapValidationError(`feeBips must be <= ${MAX_INTERFACE_FEE_BIPS} (5% cap)`);
    }
    return { feeRecipient: this.feeRecipient, feeBips, amountOutMin: userAmountOutMin };
  }

  /**
   * Create an authwit authorizing a caller contract to call a token transfer
   * method on behalf of the user.
   *
   * @param tokenAddress - The token contract
   * @param method - The transfer method name
   * @param amount - Amount to transfer
   * @param nonce - Authwit nonce
   * @param caller - Who calls the token (for authwit authorization)
   * @param to - Destination of the transfer (defaults to caller)
   */
  private async createTransferAuthwit(
    tokenAddress: AztecAddress,
    method: 'transfer_to_public' | 'transfer_to_public_and_prepare_private_balance_increase',
    amount: bigint,
    nonce: Fr,
    caller: AztecAddress,
    to?: AztecAddress,
  ) {
    const token = TokenContract.at(tokenAddress, this.wallet);
    const action = token.methods[method](
      this.senderAddress, to ?? caller, amount, nonce,
    );
    const call = await action.getFunctionCall();
    return this.wallet.createAuthWit(this.senderAddress, { caller, call });
  }

  /**
   * Validate that a deadline is a positive future timestamp.
   *
   * SDK-side rejection uses wall-clock (`Date.now() / 1000`); the contract's
   * authoritative `EXPIRED` assert uses the L2 block timestamp. The two can
   * disagree by seconds during normal operation, so a deadline that's
   * "in the future" by wall-clock can still trip `EXPIRED` on inclusion.
   * Callers should pick deadlines >= 30 seconds in the future to leave room
   * for inclusion latency; this helper does not enforce a minimum buffer.
   */
  private validateDeadline(deadline: number): void {
    if (!Number.isInteger(deadline) || deadline <= 0) {
      throw new SigalSwapValidationError('deadline must be a positive integer');
    }
    if (deadline < Math.floor(Date.now() / 1000)) {
      throw new SigalSwapValidationError('deadline is in the past');
    }
  }

  /**
   * Assert no two adjacent tokens in the path are the same. Adjacent
   * duplicates would revert at the pair level (pair asserts `token_in !=
   * token_out`); this is a fast client-side fail. Applies to both swap
   * directions.
   */
  private validatePathAdjacency(path: AztecAddress[]): void {
    for (let i = 0; i < path.length - 1; i++) {
      if (path[i].equals(path[i + 1])) {
        throw new SigalSwapValidationError(`Adjacent tokens in path must differ (duplicate at index ${i})`);
      }
    }
  }

  /**
   * Assert the final token in the path does not appear earlier. Required
   * for exact-output multi-hop: the router's per-token change-refund and
   * intermediate-dust-refund loops would consume the final-output balance
   * if the final token coincided with the initial or an intermediate.
   * The contract enforces the same invariant with `FINAL_TOKEN_REPEATED`.
   *
   * NOT required for exact-input — in that direction the final token is
   * measured cleanly and cycles are supported (e.g., triangular arbitrage
   * via `[A, B, C, A]`).
   */
  private validatePathFinalUnique(path: AztecAddress[]): void {
    const final_idx = path.length - 1;
    const final_token = path[final_idx];
    for (let i = 0; i < final_idx; i++) {
      if (path[i].equals(final_token)) {
        throw new SigalSwapValidationError(
          `Final token cannot appear earlier in path for exact-output (repeated at index ${i}); use swapExactIn for cyclic paths`,
        );
      }
    }
  }

  /**
   * Single-hop variant of {@link validatePathPairConsistency}. Asserts the
   * supplied `pair` carries `(tokenIn, tokenOut)` in either order. Same
   * fail-fast purpose -- without it the contract reverts deep at
   * `TOKEN_IN_IS_INVALID` after the authwit has been built and the user
   * has paid the proving cost.
   */
  private async assertSingleHopConsistency(
    pair: AztecAddress,
    tokenIn: AztecAddress,
    tokenOut: AztecAddress,
  ): Promise<void> {
    const cfg = await this.fetchPairConfig(pair);
    const matchesForward = cfg.token0.equals(tokenIn) && cfg.token1.equals(tokenOut);
    const matchesReverse = cfg.token0.equals(tokenOut) && cfg.token1.equals(tokenIn);
    if (!matchesForward && !matchesReverse) {
      throw new SigalSwapValidationError(
        `pair ${pair.toString()} does not contain ` +
          `tokenIn=${tokenIn.toString()} and tokenOut=${tokenOut.toString()} ` +
          `(pair has token0=${cfg.token0.toString()}, token1=${cfg.token1.toString()})`,
      );
    }
  }

  /**
   * For each hop, assert that the supplied `pairs[i]` is a pair whose
   * `(token0, token1)` matches `{path[i], path[i+1]}` in either order.
   * Without this, a shuffled `pairs` array burns gas to a contract-side
   * `TOKEN_IN_IS_INVALID` revert deep in execution after authwits are
   * already consumed. Runs the lookups in parallel and reuses the cache
   * populated by `fetchPairConfig`.
   */
  private async validatePathPairConsistency(
    path: AztecAddress[],
    pairs: AztecAddress[],
  ): Promise<void> {
    const configs = await Promise.all(pairs.map((p) => this.fetchPairConfig(p)));
    for (let i = 0; i < pairs.length; i++) {
      const cfg = configs[i];
      const expected0 = path[i];
      const expected1 = path[i + 1];
      const matchesForward =
        cfg.token0.equals(expected0) && cfg.token1.equals(expected1);
      const matchesReverse =
        cfg.token0.equals(expected1) && cfg.token1.equals(expected0);
      if (!matchesForward && !matchesReverse) {
        throw new SigalSwapValidationError(
          `pair at hop ${i} (${pairs[i].toString()}) does not contain ` +
            `path[${i}]=${expected0.toString()} and path[${i + 1}]=${expected1.toString()} ` +
            `(pair has token0=${cfg.token0.toString()}, token1=${cfg.token1.toString()})`,
        );
      }
    }
  }

  /** Pad an address array to a fixed length with AztecAddress.zero(). */
  private padArray(arr: AztecAddress[], targetLength: number): AztecAddress[] {
    if (arr.length > targetLength) {
      throw new SigalSwapValidationError(`Array length ${arr.length} exceeds target ${targetLength}`);
    }
    const padded = [...arr];
    while (padded.length < targetLength) {
      padded.push(AztecAddress.zero());
    }
    return padded;
  }
}
