// SPDX-License-Identifier: MIT
// Copyright (c) 2026 SigalSwap LLC

import type { AztecAddress } from '@aztec/aztec.js/addresses';
import type { Wallet } from '@aztec/aztec.js/wallet';
import { Fr } from '@aztec/aztec.js/fields';

import type { TxSendResultMined } from '@aztec/aztec.js/contracts';
import { FunctionSelector } from '@aztec/aztec.js/abi';
import { SigalSwapPairContract } from './artifacts/SigalSwapPair.js';
import { SigalSwapLPTokenContract } from './artifacts/SigalSwapLPToken.js';
import { TokenContract } from './artifacts/Token.js';
import type { SigalSwapConfig } from './config/index.js';
import { SigalSwapValidationError, wrapContractRevert } from './errors.js';
import { computeProtocolFeeMint } from './protocol-fee.js';

/** Reserves and timestamp from get_reserves(). */
export interface Reserves {
  reserve0: bigint;
  reserve1: bigint;
  blockTimestampLast: bigint;
}

/** Pair state from get_pair_state(). */
export interface PairState {
  reserve0: bigint;
  reserve1: bigint;
  blockTimestampLast: bigint;
  isPaused: boolean;
  protocolFeePercent: number;
  protocolFeeActive: boolean;
}

/** Cumulative TWAP prices from get_cumulative_prices(). */
/** UQ112x112 fixed-point scale (2^112). Matches `Q112` in `protocol/core/src/math/fixed_point.nr`. */
const TWAP_Q112 = 1n << 112n;
/** BN254 scalar field modulus; the TWAP integer accumulator is a `Field` and wraps here. */
const TWAP_FIELD_MODULUS =
  21888242871839275222246405745257275088548364400416034343698204186575808495617n;

export interface CumulativePrices {
  price0CumulInt: bigint;
  price0CumulFrac: bigint;
  price1CumulInt: bigint;
  price1CumulFrac: bigint;
  blockTimestampLast: bigint;
}

/** Time-weighted average price between two cumulative-price samples. */
export interface TwapResult {
  /** Seconds between the two samples. */
  secondsElapsed: bigint;
  /**
   * Mean price0 (reserve1/reserve0) over the window, in UQ112x112 fixed-point
   * (i.e. multiplied by 2^112). Full precision -- divide by 2^112 for the ratio.
   */
  price0Scaled: bigint;
  /** Mean price1 (reserve0/reserve1) over the window, UQ112x112-scaled. */
  price1Scaled: bigint;
  /** `price0Scaled / 2^112` floored: the plain price0 ratio (loses sub-unit precision). */
  price0: bigint;
  /** `price1Scaled / 2^112` floored: the plain price1 ratio. */
  price1: bigint;
}

/** Spot prices as reserve ratios from get_spot_prices(). */
export interface SpotPrices {
  price0Num: bigint;
  price0Den: bigint;
  price1Num: bigint;
  price1Den: bigint;
}

/** LP position value from get_position_value(). */
export interface PositionValue {
  amount0: bigint;
  amount1: bigint;
}

/** Pair configuration from get_config(). */
export interface PairConfig {
  token0: AztecAddress;
  token1: AztecAddress;
  /**
   * The pair's LP Token address. Derived inside the pair's constructor from
   * the pair's own address using a hardcoded `LP_TOKEN_CLASS_ID`, so the LP
   * token is cryptographically bound to the pair and not supplied as a
   * user-facing parameter. Available as the `lp_token` view on the pair.
   */
  lpToken: AztecAddress;
  factory: AztecAddress;
  feeTierBps: bigint;
  /**
   * Pair bytecode version. Baked in at compile time via the `VERSION` global
   * in core/src/main.nr; the factory cross-checks this against its
   * admin-declared `pair_class_version` at registration time.
   */
  version: bigint;
}

/**
 * High-level wrapper around a SigalSwapPair contract.
 *
 * Provides clean async methods for swaps, liquidity, and queries.
 * Creates authorization witnesses (authwits) automatically for all
 * transaction methods.
 *
 * **Note**: Pair-level transaction methods have no deadline enforcement.
 * For deadline-protected swaps and liquidity operations, use `SigalSwapRouter`.
 * Check `getPairState().isPaused` before submitting transactions to avoid
 * wasting gas on a paused pair.
 *
 * @internal Construct via `SigalSwapClient.pair()` rather than directly.
 */
export class SigalSwapPair {
  private cachedConfig: PairConfig | null = null;

  /** @internal */
  constructor(
    private readonly contract: SigalSwapPairContract,
    private readonly wallet: Wallet,
    private readonly senderAddress: AztecAddress,
    private readonly config: SigalSwapConfig,
  ) {}

  /** The pair contract's address. */
  get address(): AztecAddress {
    return this.contract.address;
  }

  // ================================================================
  // Queries (no transaction, no gas)
  // ================================================================

  /**
   * Get current reserves and last update timestamp.
   *
   * Returns the pair's stored reserves snapshot, not its actual token
   * balances -- the two diverge between liquidity events when donations
   * or fee-on-transfer residual sit in the pair's public balance. See the
   * "Reserves vs balances" note in the README. Use the swap-formula
   * helpers (`quoteAmountOut`, `quoteAmountIn`) for slippage-safe quotes
   * and `Token.balance_of_public(pair)` directly when you need the
   * current balance.
   */
  async getReserves(): Promise<Reserves> {
    const { result } = await this.contract.methods.get_reserves().simulate({ from: this.senderAddress });
    return {
      reserve0: result[0],
      reserve1: result[1],
      blockTimestampLast: result[2],
    };
  }

  /**
   * Get the cached reserves snapshot used as the protocol-fee K-growth
   * baseline. Returns `(reserve0Last, reserve1Last)` -- the reserves at
   * the last liquidity event (mint, burn) or the last protocol-fee
   * percent change. Combined with `getReserves`, `getLpTotalSupply`, and
   * the active fee percent, callers can preview the protocol-fee mint
   * the next liquidity event would trigger via `previewProtocolFeeMint`
   * or `computeProtocolFeeMint`. Returns `(0, 0)` when the protocol fee
   * was off at the last liquidity event.
   */
  async getReservesLast(): Promise<{ reserve0Last: bigint; reserve1Last: bigint }> {
    const { result } = await this.contract.methods.get_reserves_last().simulate({ from: this.senderAddress });
    return { reserve0Last: result[0], reserve1Last: result[1] };
  }

  /**
   * Whether the pair is currently paused. Direct single-bool read of the
   * pause bit in `packed_flags`; cheaper than `getPairState` when only the
   * pause status is needed (e.g., wallet UIs gating "swap" / "add liquidity"
   * buttons on the pause flag).
   */
  async isPaused(): Promise<boolean> {
    const { result } = await this.contract.methods.is_paused_view().simulate({ from: this.senderAddress });
    return result;
  }

  /**
   * Get the pair-side `fee_to` recipient (the address that receives this
   * pair's protocol-fee LP mint on the next liquidity event). Updated by
   * the factory's `sync_protocol_fee` and may lag the factory's current
   * `fee_to` between a global change and the next per-pair sync. Indexers
   * showing "who currently receives protocol fees on this specific pair"
   * should query here rather than the factory's getter.
   */
  async getFeeTo(): Promise<AztecAddress> {
    const { result } = await this.contract.methods.get_fee_to().simulate({ from: this.senderAddress });
    return result;
  }

  /** Get full pair state including fee configuration. */
  async getPairState(): Promise<PairState> {
    const { result } = await this.contract.methods.get_pair_state().simulate({ from: this.senderAddress });
    return {
      reserve0: result[0],
      reserve1: result[1],
      blockTimestampLast: result[2],
      isPaused: result[3],
      protocolFeePercent: Number(result[4]),
      protocolFeeActive: result[5],
    };
  }

  /** Get pair configuration (token addresses, factory, fee tier, derived LP token). Cached after first call. */
  async getConfig(): Promise<PairConfig> {
    if (!this.cachedConfig) {
      const { result } = await this.contract.methods.get_config().simulate({ from: this.senderAddress });
      this.cachedConfig = {
        token0: result.token0,
        token1: result.token1,
        lpToken: result.lp_token,
        factory: result.factory,
        feeTierBps: result.fee_tier_bps,
        version: result.version,
      };
    }
    return this.cachedConfig;
  }

  /**
   * Get the pair's compile-time bytecode version. Cheaper than getConfig()
   * when only the version is needed.
   */
  async getVersion(): Promise<number> {
    const { result } = await this.contract.methods.get_version().simulate({ from: this.senderAddress });
    return Number(result);
  }

  /**
   * Quote output amount for a given input.
   *
   * Computes against stored reserves (the AMM formula). Returns the
   * conservative floor of what an actual swap delivers -- the contract's
   * settlement absorbs any pre-existing donation in `tokenIn` as
   * additional input, which can only increase the actual output above
   * this quote, never decrease it. Suitable for slippage protection
   * (`amountOutMin` in `swapExactIn`).
   */
  async quoteAmountOut(amountIn: bigint, tokenIn: AztecAddress): Promise<bigint> {
    const { result } = await this.contract.methods
      .quote_amount_out(amountIn, tokenIn)
      .simulate({ from: this.senderAddress });
    return result;
  }

  /**
   * Quote required input for a desired output.
   *
   * Reserve-based, like {@link quoteAmountOut}. Returns the conservative
   * upper-bound input the user might need under no-donation conditions.
   * The actual swap may consume *less* input if there are donations in
   * `tokenIn` that get absorbed; the user's `amountInMax` cap stays
   * authoritative either way.
   */
  async quoteAmountIn(amountOut: bigint, tokenOut: AztecAddress): Promise<bigint> {
    const { result } = await this.contract.methods
      .quote_amount_in(amountOut, tokenOut)
      .simulate({ from: this.senderAddress });
    return result;
  }

  /** Get cumulative TWAP prices. */
  async getCumulativePrices(): Promise<CumulativePrices> {
    const { result } = await this.contract.methods.get_cumulative_prices().simulate({ from: this.senderAddress });
    return {
      price0CumulInt: result[0],
      price0CumulFrac: result[1],
      price1CumulInt: result[2],
      price1CumulFrac: result[3],
      blockTimestampLast: result[4],
    };
  }

  /**
   * Compute the time-weighted average price between two `getCumulativePrices`
   * samples, for both directions.
   *
   * Each accumulator is a UQ112x112 split value: the true cumulative is
   * `integer + fraction / 2^112`. This helper reconstructs the full scaled
   * value (`integer * 2^112 + fraction`) for each sample BEFORE differencing.
   * Differencing the integer alone -- a tempting shortcut -- yields TWAP = 0
   * for any pair whose price ratio is below 1 in that direction (every
   * decimal-mismatched pair, e.g. ETH/USDC): there the integer accumulator is
   * permanently 0 and the entire price signal lives in the fraction. Always
   * read the `*Scaled` fields when you need sub-unit precision; the plain
   * `price0` / `price1` floor away everything below 1.
   *
   * `later` must be the chronologically later sample (strictly greater
   * `blockTimestampLast`).
   *
   * @throws {SigalSwapValidationError} if `later` is not after `earlier`.
   */
  static twapBetween(earlier: CumulativePrices, later: CumulativePrices): TwapResult {
    const secondsElapsed = later.blockTimestampLast - earlier.blockTimestampLast;
    if (secondsElapsed <= 0n) {
      throw new SigalSwapValidationError(
        'twapBetween: `later` must have a strictly greater blockTimestampLast than `earlier`',
      );
    }
    const price0Scaled = SigalSwapPair.#twapOneSide(
      earlier.price0CumulInt, earlier.price0CumulFrac,
      later.price0CumulInt, later.price0CumulFrac,
      secondsElapsed,
    );
    const price1Scaled = SigalSwapPair.#twapOneSide(
      earlier.price1CumulInt, earlier.price1CumulFrac,
      later.price1CumulInt, later.price1CumulFrac,
      secondsElapsed,
    );
    return {
      secondsElapsed,
      price0Scaled,
      price1Scaled,
      price0: price0Scaled / TWAP_Q112,
      price1: price1Scaled / TWAP_Q112,
    };
  }

  static #twapOneSide(
    intA: bigint, fracA: bigint, intB: bigint, fracB: bigint, dt: bigint,
  ): bigint {
    const scaledA = intA * TWAP_Q112 + fracA;
    const scaledB = intB * TWAP_Q112 + fracB;
    // The integer accumulator wraps modularly at the BN254 field order. For any
    // realistic window the delta is positive and tiny relative to the modulus;
    // the `+ wrap` guard corrects the (astronomically rare) field wrap.
    let delta = scaledB - scaledA;
    if (delta < 0n) delta += TWAP_FIELD_MODULUS * TWAP_Q112;
    return delta / dt;
  }

  /**
   * Get spot prices as reserve ratios.
   *
   * "Spot price" in AMM convention is the marginal exchange rate at the
   * current reserves: `price0 = reserve1 / reserve0`. The reserve ratio
   * is the right basis here -- balance-based "spot price" is not a
   * meaningful AMM concept since donations don't shift the marginal
   * trade rate.
   */
  async getSpotPrices(): Promise<SpotPrices> {
    const { result } = await this.contract.methods.get_spot_prices().simulate({ from: this.senderAddress });
    return {
      price0Num: result[0],
      price0Den: result[1],
      price1Num: result[2],
      price1Den: result[3],
    };
  }

  /**
   * Calculate what an LP position is worth at the given inputs.
   *
   * Reserve-based formula primitive: `(lp * reserve0 / totalSupply,
   * lp * reserve1 / totalSupply)`. Pass arbitrary `(lpAmount,
   * totalSupply)` for hypothetical queries (e.g. "what would 100 LP at
   * supply 10000 be worth"). For the contract-equivalent answer to
   * "what will I receive on burn right now" -- which uses balances and
   * folds in pending protocol-fee dilution -- use {@link getMyPositionValue}.
   */
  async getPositionValue(
    lpAmount: bigint,
    totalSupply: bigint,
  ): Promise<PositionValue> {
    const { result } = await this.contract.methods
      .get_position_value(lpAmount, totalSupply)
      .simulate({ from: this.senderAddress });
    return { amount0: result[0], amount1: result[1] };
  }

  /**
   * Get the LP balance for `owner` (defaults to the SDK's senderAddress) in
   * both private and public stores. Most LP positions are private (the
   * privacy-preserving design routes through partial notes); a non-zero
   * `public` balance indicates LP that was moved to the public mutable
   * map -- typically Router-transient during a router-mediated mint.
   * Queries both stores in parallel.
   *
   * **Cross-owner caveat**: when `owner !== senderAddress`, the `private`
   * field is always `0n` -- the wallet's PXE can only decrypt notes
   * addressed to keys it manages, so a foreign owner's private balance is
   * unreadable by design. The `public` field is correct for any address.
   * Callers building "X owns this much LP" displays for arbitrary users
   * should treat `private` as "unknown, not zero" when `owner` differs
   * from the SDK sender.
   */
  async getLpBalance(owner?: AztecAddress): Promise<{ private: bigint; public: bigint }> {
    const target = owner ?? this.senderAddress;
    const lpToken = await this.getLpTokenWrapper();
    const [{ result: priv }, { result: pub }] = await Promise.all([
      lpToken.methods.balance_of_private(target).simulate({ from: this.senderAddress }),
      lpToken.methods.balance_of_public(target).simulate({ from: this.senderAddress }),
    ]);
    return { private: priv, public: pub };
  }

  /** Get the LP Token's total supply. */
  async getLpTotalSupply(): Promise<bigint> {
    const lpToken = await this.getLpTokenWrapper();
    const { result } = await lpToken.methods.total_supply().simulate({ from: this.senderAddress });
    return result;
  }

  /**
   * Compute the underlying-token value of the SDK sender's LP position --
   * "what is my LP worth in token0/token1 if I burn it right now?"
   *
   * Contract-equivalent answer: reads pair token balances (matching the
   * burn-side `get_amounts_on_remove` formula which divides against
   * balances, not stored reserves -- donations and any fee-on-transfer
   * residual at the pair are part of the LP claim) AND folds in the
   * pending protocol-fee mint (which dilutes total_supply at burn time,
   * before the proportional division).
   *
   * For arbitrary `(lpAmount, totalSupply)` inputs against stored
   * reserves, use the lower-level {@link getPositionValue} primitive.
   * That helper is the reserve-based formula and is appropriate for
   * "what would N LP at supply S be worth" hypothetical queries; this
   * helper is the "what will I actually receive on burn" answer.
   */
  async getMyPositionValue(): Promise<PositionValue> {
    // Pre-cache config so subsequent parallel reads don't race on the
    // first getConfig() call (the cache is populated after the await).
    const { token0, token1 } = await this.getConfig();

    const tokenA = TokenContract.at(token0, this.wallet);
    const tokenB = TokenContract.at(token1, this.wallet);

    const [balance, totalSupply, pendingFee, balance0Res, balance1Res] = await Promise.all([
      this.getLpBalance(),
      this.getLpTotalSupply(),
      this.previewProtocolFeeMint(),
      tokenA.methods.balance_of_public(this.contract.address).simulate({ from: this.senderAddress }),
      tokenB.methods.balance_of_public(this.contract.address).simulate({ from: this.senderAddress }),
    ]);

    const lpAmount = balance.private + balance.public;
    if (lpAmount === 0n) return { amount0: 0n, amount1: 0n };

    const effectiveSupply = totalSupply + pendingFee;
    if (effectiveSupply === 0n) return { amount0: 0n, amount1: 0n };

    const balance0: bigint = balance0Res.result;
    const balance1: bigint = balance1Res.result;

    return {
      amount0: (lpAmount * balance0) / effectiveSupply,
      amount1: (lpAmount * balance1) / effectiveSupply,
    };
  }

  /**
   * Preview the LP-token amount that would be minted to `feeTo` on the
   * next liquidity event (mint or burn) on this pair. The protocol fee
   * accrues as K growth between liquidity events and is realized as a
   * one-shot LP mint at the next event; this helper returns that pending
   * amount without firing a tx.
   *
   * Reads `getPairState` (current reserves + active percent + fee on/off
   * flag), `getReservesLast` (K-growth baseline), and `getLpTotalSupply`
   * in parallel, then runs the same `compute_mint_fee` formula the
   * contract uses on-chain. Returns `0n` when the protocol fee is
   * disabled on this pair, when no K growth has occurred since the
   * baseline, or when the baseline is unset (fee was off at the last
   * liquidity event). For callers that already have these inputs from a
   * batched read or event replay, prefer the pure
   * `computeProtocolFeeMint` -- this method is just the convenience
   * wrapper.
   */
  async previewProtocolFeeMint(): Promise<bigint> {
    const [state, last, totalSupply] = await Promise.all([
      this.getPairState(),
      this.getReservesLast(),
      this.getLpTotalSupply(),
    ]);
    if (!state.protocolFeeActive) return 0n;
    return computeProtocolFeeMint(
      state.reserve0,
      state.reserve1,
      last.reserve0Last,
      last.reserve1Last,
      totalSupply,
      state.protocolFeePercent,
    );
  }

  // ================================================================
  // Transactions (require wallet, consume gas)
  //
  // These call the pair contract directly and have NO deadline
  // enforcement. For deadline-protected operations, use SigalSwapRouter.
  // ================================================================

  /**
   * Swap exact input tokens for maximum output.
   *
   * **Warning**: No deadline protection. Prefer `SigalSwapRouter.swapSingleExactIn()`
   * for deadline-enforced swaps.
   */
  async swapExactIn(opts: {
    tokenIn: AztecAddress;
    tokenOut: AztecAddress;
    amountIn: bigint;
    amountOutMin: bigint;
  }): Promise<TxSendResultMined> {
    if (opts.amountIn <= 0n) throw new SigalSwapValidationError('amountIn must be positive');
    if (opts.amountOutMin < 0n) throw new SigalSwapValidationError('amountOutMin cannot be negative');
    if (opts.tokenIn.equals(opts.tokenOut)) throw new SigalSwapValidationError('tokenIn and tokenOut must differ');
    await this.assertTokensMatchPair(opts.tokenIn, opts.tokenOut);

    const nonce = Fr.random();

    // Authorize pair to transfer tokenIn from user
    const authWit = await this.createTransferAuthwit(
      opts.tokenIn, 'transfer_to_public', opts.amountIn, nonce,
    );

    return wrapContractRevert(
      'pair.swap_exact_in',
      () => this.contract.methods
        .swap_exact_in(
          opts.tokenIn,
          opts.tokenOut,
          opts.amountIn,
          opts.amountOutMin,
          nonce,
        )
        .with({ authWitnesses: [authWit] })
        .send({ from: this.senderAddress }) as unknown as Promise<TxSendResultMined>,
    );
  }

  /**
   * Swap tokens for exact output amount.
   *
   * **Warning**: No deadline protection. Prefer `SigalSwapRouter.swapSingleExactOut()`
   * for deadline-enforced swaps.
   */
  async swapExactOut(opts: {
    tokenIn: AztecAddress;
    tokenOut: AztecAddress;
    amountOut: bigint;
    amountInMax: bigint;
  }): Promise<TxSendResultMined> {
    if (opts.amountOut <= 0n) throw new SigalSwapValidationError('amountOut must be positive');
    if (opts.amountInMax <= 0n) throw new SigalSwapValidationError('amountInMax must be positive');
    if (opts.tokenIn.equals(opts.tokenOut)) throw new SigalSwapValidationError('tokenIn and tokenOut must differ');
    await this.assertTokensMatchPair(opts.tokenIn, opts.tokenOut);

    const nonce = Fr.random();

    // Authorize pair to transfer up to amountInMax of tokenIn from user
    const authWit = await this.createTransferAuthwit(
      opts.tokenIn, 'transfer_to_public_and_prepare_private_balance_increase', opts.amountInMax, nonce,
    );

    return wrapContractRevert(
      'pair.swap_exact_out',
      () => this.contract.methods
        .swap_exact_out(
          opts.tokenIn,
          opts.tokenOut,
          opts.amountOut,
          opts.amountInMax,
          nonce,
        )
        .with({ authWitnesses: [authWit] })
        .send({ from: this.senderAddress }) as unknown as Promise<TxSendResultMined>,
    );
  }

  /**
   * Add liquidity to the pair.
   *
   * Automatically queries pair config to determine token addresses for authwits.
   *
   * **Warning**: No deadline protection. Prefer `SigalSwapRouter.addLiquidity()`
   * for deadline-enforced liquidity additions.
   */
  async addLiquidity(opts: {
    amount0Max: bigint;
    amount1Max: bigint;
    amount0Min: bigint;
    amount1Min: bigint;
  }): Promise<TxSendResultMined> {
    if (opts.amount0Max <= 0n) throw new SigalSwapValidationError('amount0Max must be positive');
    if (opts.amount1Max <= 0n) throw new SigalSwapValidationError('amount1Max must be positive');
    if (opts.amount0Min < 0n) throw new SigalSwapValidationError('amount0Min cannot be negative');
    if (opts.amount1Min < 0n) throw new SigalSwapValidationError('amount1Min cannot be negative');
    if (opts.amount0Min > opts.amount0Max) throw new SigalSwapValidationError('amount0Min must be <= amount0Max');
    if (opts.amount1Min > opts.amount1Max) throw new SigalSwapValidationError('amount1Min must be <= amount1Max');

    const { token0, token1 } = await this.getConfig();
    if (token0.equals(token1)) throw new SigalSwapValidationError('Pair has identical token0 and token1 — invalid pair');

    const nonce = Fr.random();

    // Authorize pair to transfer both tokens from user
    const [authWit0, authWit1] = await Promise.all([
      this.createTransferAuthwit(
        token0, 'transfer_to_public_and_prepare_private_balance_increase', opts.amount0Max, nonce,
      ),
      this.createTransferAuthwit(
        token1, 'transfer_to_public_and_prepare_private_balance_increase', opts.amount1Max, nonce,
      ),
    ]);

    return wrapContractRevert(
      'pair.add_liquidity',
      () => this.contract.methods
        .add_liquidity(
          opts.amount0Max,
          opts.amount1Max,
          opts.amount0Min,
          opts.amount1Min,
          nonce,
        )
        .with({ authWitnesses: [authWit0, authWit1] })
        .send({ from: this.senderAddress }) as unknown as Promise<TxSendResultMined>,
    );
  }

  /**
   * Remove liquidity from the pair.
   *
   * Automatically queries pair config to determine LP token address for authwit.
   *
   * **Warning**: No deadline protection. Prefer `SigalSwapRouter.removeLiquidity()`
   * for deadline-enforced liquidity removals.
   *
   * **Note-fragmentation cap.** Removal debits the LP via the LP token's
   * `transfer_to_public`, which consumes at most 16 private notes in a single
   * call (the framework `try_sub` cap). Each `addLiquidity` mints exactly one
   * LP note, so a position built from more than ~16 separate adds whose 16
   * largest notes do not sum to `liquidity` will revert with "Balance too low"
   * despite the holder owning the balance. This is recoverable: remove in
   * chunks (each <= the sum of the 16 largest notes) or first consolidate by
   * self-transferring the full balance (the LP token's `transfer` path recurses
   * up to ~58 notes and collapses them into one change note). A future SDK
   * release may auto-consolidate when the note count is high.
   */
  async removeLiquidity(opts: {
    liquidity: bigint;
    amount0Min: bigint;
    amount1Min: bigint;
  }): Promise<TxSendResultMined> {
    if (opts.liquidity <= 0n) throw new SigalSwapValidationError('liquidity must be positive');
    if (opts.amount0Min < 0n) throw new SigalSwapValidationError('amount0Min cannot be negative');
    if (opts.amount1Min < 0n) throw new SigalSwapValidationError('amount1Min cannot be negative');

    const nonce = Fr.random();
    const { lpToken } = await this.getConfig();

    // Authorize pair to transfer LP tokens from user
    const authWit = await this.createTransferAuthwit(
      lpToken, 'transfer_to_public', opts.liquidity, nonce,
    );

    return wrapContractRevert(
      'pair.remove_liquidity',
      () => this.contract.methods
        .remove_liquidity(opts.liquidity, opts.amount0Min, opts.amount1Min, nonce)
        .with({ authWitnesses: [authWit] })
        .send({ from: this.senderAddress }) as unknown as Promise<TxSendResultMined>,
    );
  }

  /**
   * Skim excess tokens to a recipient's private balance.
   *
   * This is a private function -- the recipient address is not revealed on-chain.
   */
  async skim(to: AztecAddress): Promise<TxSendResultMined> {
    if (to.isZero()) throw new SigalSwapValidationError('skim recipient cannot be zero');
    return wrapContractRevert(
      'pair.skim',
      () => this.contract.methods
        .skim(to)
        .send({ from: this.senderAddress }) as unknown as Promise<TxSendResultMined>,
    );
  }

  /** Sync reserves to match actual token balances. This is a public function. */
  async sync(): Promise<TxSendResultMined> {
    return wrapContractRevert(
      'pair.sync',
      () => this.contract.methods
        .sync()
        .send({ from: this.senderAddress }) as unknown as Promise<TxSendResultMined>,
    );
  }

  // ================================================================
  // V3-style callback swaps (public). Caller's `callbackContract` must
  // implement `(pair_address, token_in, amount_in)` and transfer
  // `amount_in` of `token_in` to `pair_address` before returning. Used by
  // arbitrage bots, zaps, and hook contracts that compose with the pair.
  //
  // The pair's own swap functions enforce the V3 contract; the SDK just
  // packages the call. There is NO authwit creation here -- the callback
  // contract is responsible for sourcing the input.
  // ================================================================

  /**
   * Public exact-input swap with V3-style callback payment. The pair sends
   * `amount_out` of `tokenOut` to `recipient`, then synchronously calls
   * `callbackContract.<callbackSelector>(pair_address, tokenIn, amountIn)`.
   * The callback must transfer at least `amountIn` of `tokenIn` to the
   * pair before returning, or the swap reverts `INSUFFICIENT_PAYMENT`.
   * Defense-in-depth K-invariant check happens before reserves write.
   */
  async swapExactInPublic(opts: {
    tokenIn: AztecAddress;
    tokenOut: AztecAddress;
    amountIn: bigint;
    amountOutMin: bigint;
    recipient: AztecAddress;
    callbackContract: AztecAddress;
    callbackSelector: FunctionSelector;
  }): Promise<TxSendResultMined> {
    if (opts.amountIn <= 0n) throw new SigalSwapValidationError('amountIn must be positive');
    if (opts.amountOutMin < 0n) throw new SigalSwapValidationError('amountOutMin cannot be negative');
    if (opts.tokenIn.equals(opts.tokenOut)) throw new SigalSwapValidationError('tokenIn and tokenOut must differ');
    await this.assertTokensMatchPair(opts.tokenIn, opts.tokenOut);
    await this.assertCallbackTargetValid(opts.recipient, 'recipient');
    await this.assertCallbackTargetValid(opts.callbackContract, 'callbackContract');

    return wrapContractRevert(
      'pair.swap_exact_in_public',
      () => this.contract.methods
        .swap_exact_in_public(
          opts.tokenIn, opts.tokenOut,
          opts.amountIn, opts.amountOutMin,
          opts.recipient,
          opts.callbackContract, opts.callbackSelector,
        )
        .send({ from: this.senderAddress }) as unknown as Promise<TxSendResultMined>,
    );
  }

  /**
   * Public exact-output swap with V3-style callback payment. The pair
   * sends exactly `amountOut` of `tokenOut` to `recipient` (computed via
   * the formula `get_amount_in`), then calls the callback for payment.
   * Reverts `EXCESSIVE_INPUT_AMOUNT` if the formula-derived input exceeds
   * `amountInMax`, and `INSUFFICIENT_PAYMENT` if the callback shortfalls.
   */
  async swapExactOutPublic(opts: {
    tokenIn: AztecAddress;
    tokenOut: AztecAddress;
    amountOut: bigint;
    amountInMax: bigint;
    recipient: AztecAddress;
    callbackContract: AztecAddress;
    callbackSelector: FunctionSelector;
  }): Promise<TxSendResultMined> {
    if (opts.amountOut <= 0n) throw new SigalSwapValidationError('amountOut must be positive');
    if (opts.amountInMax <= 0n) throw new SigalSwapValidationError('amountInMax must be positive');
    if (opts.tokenIn.equals(opts.tokenOut)) throw new SigalSwapValidationError('tokenIn and tokenOut must differ');
    await this.assertTokensMatchPair(opts.tokenIn, opts.tokenOut);
    await this.assertCallbackTargetValid(opts.recipient, 'recipient');
    await this.assertCallbackTargetValid(opts.callbackContract, 'callbackContract');

    return wrapContractRevert(
      'pair.swap_exact_out_public',
      () => this.contract.methods
        .swap_exact_out_public(
          opts.tokenIn, opts.tokenOut,
          opts.amountOut, opts.amountInMax,
          opts.recipient,
          opts.callbackContract, opts.callbackSelector,
        )
        .send({ from: this.senderAddress }) as unknown as Promise<TxSendResultMined>,
    );
  }

  /**
   * Flash swap: borrow tokens optimistically, run a callback, repay. The
   * pair sends `amount0Out` + `amount1Out` to `borrower`, then invokes
   * `borrower.<callbackSelector>(...)`. The callback must transfer enough
   * of the borrowed tokens back to the pair to cover the loan plus the
   * fee implied by the K invariant -- failing that, the call reverts
   * `INSUFFICIENT_REPAYMENT`. `data: Field` is forwarded to the callback
   * for caller-defined context (e.g., a job ID, an arbitrage path
   * encoding, or a packed param). Exactly one of `amount0Out`/`amount1Out`
   * may be zero; both being non-zero is supported (dual-token loans).
   */
  async flashSwap(opts: {
    amount0Out: bigint;
    amount1Out: bigint;
    borrower: AztecAddress;
    callbackSelector: FunctionSelector;
    data: Fr;
  }): Promise<TxSendResultMined> {
    if (opts.amount0Out < 0n) throw new SigalSwapValidationError('amount0Out cannot be negative');
    if (opts.amount1Out < 0n) throw new SigalSwapValidationError('amount1Out cannot be negative');
    if (opts.amount0Out === 0n && opts.amount1Out === 0n) {
      throw new SigalSwapValidationError('at least one of amount0Out / amount1Out must be positive');
    }
    await this.assertCallbackTargetValid(opts.borrower, 'borrower');

    return wrapContractRevert(
      'pair.flash_swap',
      () => this.contract.methods
        .flash_swap(
          opts.amount0Out, opts.amount1Out,
          opts.borrower,
          opts.callbackSelector,
          opts.data,
        )
        .send({ from: this.senderAddress }) as unknown as Promise<TxSendResultMined>,
    );
  }

  // ================================================================
  // Internal helpers
  // ================================================================

  /**
   * Assert that `(tokenIn, tokenOut)` matches the pair's `(token0, token1)`
   * in either order. Boundary fail-fast against the contract's
   * `TOKEN_IN_IS_INVALID` / `TOKEN_OUT_IS_INVALID` reverts -- a
   * mis-supplied token argument burns proving cycles before discovering
   * the mismatch deep in public continuation. Uses the cached pair config
   * so the cost is amortized to one read per wrapper lifetime.
   */
  private async assertTokensMatchPair(
    tokenIn: AztecAddress,
    tokenOut: AztecAddress,
  ): Promise<void> {
    const { token0, token1 } = await this.getConfig();
    const matchesForward = token0.equals(tokenIn) && token1.equals(tokenOut);
    const matchesReverse = token0.equals(tokenOut) && token1.equals(tokenIn);
    if (!matchesForward && !matchesReverse) {
      throw new SigalSwapValidationError(
        `pair tokens (token0=${token0.toString()}, token1=${token1.toString()}) ` +
          `do not match the supplied (tokenIn=${tokenIn.toString()}, ` +
          `tokenOut=${tokenOut.toString()})`,
      );
    }
  }

  /**
   * Assert that `target` is not on the contract's V3-callback / flash-swap
   * / public-swap-recipient blocklist (zero, self, token0, token1,
   * lp_token, factory). Mirrors the six `INVALID_CALLBACK_TARGET` /
   * `INVALID_BORROWER` / `INVALID_RECIPIENT` asserts on
   * `swap_exact_{in,out}_public` and `flash_swap`; the three blocklists
   * are identical sets, so one helper covers all three roles. Uses the
   * cached pair config; `role` is the user-facing label for clear error
   * messages.
   */
  private async assertCallbackTargetValid(
    target: AztecAddress,
    role: 'callbackContract' | 'borrower' | 'recipient',
  ): Promise<void> {
    if (target.isZero()) {
      throw new SigalSwapValidationError(`${role} cannot be zero`);
    }
    if (target.equals(this.contract.address)) {
      throw new SigalSwapValidationError(`${role} cannot be the pair itself`);
    }
    const { token0, token1, lpToken, factory } = await this.getConfig();
    if (target.equals(token0) || target.equals(token1)) {
      throw new SigalSwapValidationError(`${role} cannot be a pair token`);
    }
    if (target.equals(lpToken)) {
      throw new SigalSwapValidationError(`${role} cannot be the LP Token`);
    }
    if (target.equals(factory)) {
      throw new SigalSwapValidationError(`${role} cannot be the factory`);
    }
  }

  /** Cached LP Token wrapper for balance / supply queries. */
  private cachedLpToken: SigalSwapLPTokenContract | null = null;

  /**
   * Lazily resolve the pair's LP Token address (via `get_lp_token` cached
   * in `getConfig`) and instantiate the LP Token contract wrapper. Cached
   * to avoid re-instantiation on each balance/supply query.
   */
  private async getLpTokenWrapper(): Promise<SigalSwapLPTokenContract> {
    if (!this.cachedLpToken) {
      const { lpToken } = await this.getConfig();
      this.cachedLpToken = SigalSwapLPTokenContract.at(lpToken, this.wallet);
    }
    return this.cachedLpToken;
  }

  /**
   * Create an authwit authorizing the pair contract to call a token transfer
   * method on behalf of the user.
   */
  private async createTransferAuthwit(
    tokenAddress: AztecAddress,
    method: 'transfer_to_public' | 'transfer_to_public_and_prepare_private_balance_increase',
    amount: bigint,
    nonce: Fr,
  ) {
    const token = TokenContract.at(tokenAddress, this.wallet);
    const action = token.methods[method](
      this.senderAddress, this.contract.address, amount, nonce,
    );
    const call = await action.getFunctionCall();
    return this.wallet.createAuthWit(this.senderAddress, {
      caller: this.contract.address,
      call,
    });
  }
}
