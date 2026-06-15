// SPDX-License-Identifier: MIT
// Copyright (c) 2026 SigalSwap LLC

import { AztecAddress } from '@aztec/aztec.js/addresses';
import { ContractInitializationStatus, type Wallet } from '@aztec/aztec.js/wallet';
import { Fr } from '@aztec/foundation/curves/bn254';
import { poseidon2Hash } from '@aztec/foundation/crypto/poseidon';

import { SigalSwapFactoryContract } from './artifacts/SigalSwapFactory.js';
import { SigalSwapPairContract } from './artifacts/SigalSwapPair.js';
import { SigalSwapLPTokenContract } from './artifacts/SigalSwapLPToken.js';
import { LP_TOKEN_SALT } from './constants.js';
import {
  SigalSwapDeploymentError,
  SigalSwapValidationError,
  wrapContractRevert,
} from './errors.js';

/**
 * Canonical deploy salt used for both the pair and its LP Token. Must match
 * the pair's compile-time `LP_TOKEN_SALT` global and the factory's expected
 * `pair_salt` arg to `register_pair`. Any other value lands contracts at
 * different addresses than the derivation expects and registration fails.
 *
 * Same Field value as `LP_TOKEN_SALT`; both names point at the canonical
 * source of truth in `constants.ts` and stay in lockstep with the contract
 * via the drift canary in `constants.test.ts`.
 */
export const CANONICAL_DEPLOY_SALT: Fr = LP_TOKEN_SALT;

/**
 * High-level wrapper around the SigalSwapFactory contract.
 *
 * Provides pair lookups and protocol configuration queries.
 * Admin/governance operations are not wrapped -- use the contract artifacts directly.
 *
 * @internal Construct via `SigalSwapClient.factory()` rather than directly.
 */
export class SigalSwapFactory {
  /** @internal */
  constructor(
    private readonly contract: SigalSwapFactoryContract,
    private readonly senderAddress: AztecAddress,
    /**
     * Wallet handle, optional. Required only by the multi-pair tooling
     * helpers (`getPairPauseStates`, `getProtocolFeeDriftStates`) that
     * instantiate per-pair wrappers under the hood. Direct factory
     * lookups don't need it.
     */
    private readonly wallet?: Wallet,
  ) {}

  /**
   * Look up the *latest* pair address at a (tokens, fee-tier) base. Returns
   * the zero address if no pair is registered at this base or if the slot has
   * been cleared by governance.
   */
  async getPair(
    tokenA: AztecAddress,
    tokenB: AztecAddress,
    feeTierBps: number,
  ): Promise<AztecAddress> {
    const { result } = await this.contract.methods.get_pair(tokenA, tokenB, feeTierBps).simulate({ from: this.senderAddress });
    return result;
  }

  /**
   * Look up a pair address at a specific version of a (tokens, fee-tier)
   * base. Useful for resolving historical pairs; use `getPair` for routing.
   */
  async getPairVersioned(
    tokenA: AztecAddress,
    tokenB: AztecAddress,
    feeTierBps: number,
    version: number,
  ): Promise<AztecAddress> {
    const { result } = await this.contract.methods
      .get_pair_versioned(tokenA, tokenB, feeTierBps, version)
      .simulate({ from: this.senderAddress });
    return result;
  }

  /**
   * Get the current latest version at a (tokens, fee-tier) base. Returns 0
   * if no pair has been registered at the base, or if the base has been
   * cleared back to zero by governance.
   */
  async getLatestVersion(
    tokenA: AztecAddress,
    tokenB: AztecAddress,
    feeTierBps: number,
  ): Promise<number> {
    const { result } = await this.contract.methods
      .get_latest_version(tokenA, tokenB, feeTierBps)
      .simulate({ from: this.senderAddress });
    return Number(result);
  }

  /**
   * Total number of registered pairs including historical versions. Use
   * `getIndexedBaseCount` for distinct-base enumeration (or
   * `getActivePairCount` for the count of currently routable bases).
   */
  async getPairCount(): Promise<number> {
    const { result } = await this.contract.methods.get_pair_count().simulate({ from: this.senderAddress });
    return Number(result);
  }

  /**
   * Historical-order pair lookup: returns the pair registered at position `i`
   * in registration order (including version upgrades as distinct entries).
   * Cleared pairs retain their historical slot; use `getLatestPairAtIndex`
   * for the live set. Reverts if `i >= getPairCount()`.
   */
  async getPairAt(i: number): Promise<AztecAddress> {
    const { result } = await this.contract.methods
      .get_pair_at(i)
      .simulate({ from: this.senderAddress });
    return result;
  }

  /**
   * Number of distinct (tokens, fee-tier) bases that have ever had a pair
   * registered, also the upper bound for `getLatestPairAtIndex` iteration.
   * Monotonically increasing -- not decremented when a base is cleared (the
   * cleared slot stays indexed and `getLatestPairAtIndex` returns the zero
   * address there). Use `getActivePairCount` for the count of currently
   * routable bases.
   */
  async getIndexedBaseCount(): Promise<number> {
    const { result } = await this.contract.methods
      .get_indexed_base_count()
      .simulate({ from: this.senderAddress });
    return Number(result);
  }

  /**
   * Number of bases currently routable -- bases whose latest pair address is
   * non-zero. Differs from `getIndexedBaseCount` when one or more bases have
   * been fully cleared via `executeClearPairSlot`. Computed on-chain by
   * iterating indexed bases and counting non-zero entries; a single utility
   * call instead of an N-round-trip walk on the SDK side.
   */
  async getActivePairCount(): Promise<number> {
    const { result } = await this.contract.methods
      .get_active_pair_count()
      .simulate({ from: this.senderAddress });
    return Number(result);
  }

  /**
   * Get the latest pair address for the i-th distinct base. Returns the zero
   * address if that base was cleared by governance. Iterate over
   * `[0, getIndexedBaseCount())` to enumerate all bases (with possible gaps
   * from cleared ones).
   */
  async getLatestPairAtIndex(i: number): Promise<AztecAddress> {
    const { result } = await this.contract.methods
      .get_latest_pair_at_index(i)
      .simulate({ from: this.senderAddress });
    return result;
  }

  /**
   * Currently blessed pair class version. Pairs whose `get_version()` does
   * not match this value will fail registration with `VERSION_MISMATCH`.
   */
  async getPairClassVersion(): Promise<number> {
    const { result } = await this.contract.methods
      .get_pair_class_version()
      .simulate({ from: this.senderAddress });
    return Number(result);
  }

  /** Check if a fee tier is allowed. */
  async isFeeTierAllowed(tierBps: number): Promise<boolean> {
    const { result } = await this.contract.methods.is_fee_tier_allowed(tierBps).simulate({ from: this.senderAddress });
    return result;
  }

  /** Get the current admin address. */
  async getAdmin(): Promise<AztecAddress> {
    const { result } = await this.contract.methods.get_admin().simulate({ from: this.senderAddress });
    return result;
  }

  /** Get the protocol fee recipient address. */
  async getFeeTo(): Promise<AztecAddress> {
    const { result } = await this.contract.methods.get_fee_to().simulate({ from: this.senderAddress });
    return result;
  }

  /**
   * Get the complete protocol fee configuration -- recipient, percent, and
   * enabled flag in one call. The three fields are conceptually one unit
   * (who gets fees, how much, whether it's active); fetching them together
   * keeps the SDK's view of the config coherent.
   */
  async getProtocolFeeConfig(): Promise<{
    feeTo: AztecAddress;
    percent: number;
    enabled: boolean;
  }> {
    const { result } = await this.contract.methods.get_protocol_fee_config().simulate({ from: this.senderAddress });
    return {
      feeTo: result[0],
      percent: Number(result[1]),
      enabled: result[2],
    };
  }

  /**
   * Check whether new pair registrations are currently paused.
   *
   * NOTE: this flag only gates `register_pair`. Trading on already-registered
   * pairs is not affected. To freeze trading across the protocol, admin
   * tooling must iterate `pausePair` over the full registry.
   */
  async isRegistrationPaused(): Promise<boolean> {
    const { result } = await this.contract.methods.is_registration_paused().simulate({ from: this.senderAddress });
    return result;
  }

  // ================================================================
  // Multi-pair admin tooling
  //
  // Aggregated read-side queries ("how many pairs are paused?", "which
  // pairs have stale protocol-fee config?") aren't on-chain factory
  // utilities -- aztec-nr's `UtilityContext` doesn't expose a
  // cross-contract `.view()` method, only `raw_storage_read` against
  // arbitrary addresses, which would couple the factory's bytecode to
  // pair storage layouts. The off-chain pattern below avoids that
  // coupling at the cost of N+1 PXE round-trips per aggregate query
  // (parallelized via `Promise.all`).
  //
  // Both helpers iterate live (currently routable) pairs only --
  // superseded versions and cleared bases are skipped, since pause /
  // protocol-fee status on a non-routable pair has no operational
  // meaning. Callers that need pause states across historical pairs
  // should iterate `getPairAt(i)` over `[0, getPairCount())` directly.
  // ================================================================

  /**
   * Resolve the set of live pair addresses for a paginated range. Iterates
   * `getLatestPairAtIndex(i)` over `[start, end)` of `getActivePairCount`,
   * filters cleared (zero) entries, and returns `(pair, index)` pairs so
   * callers can correlate results back to the registry index.
   */
  private async resolveLivePairs(
    start: number,
    end: number,
  ): Promise<{ pair: AztecAddress; index: number }[]> {
    const indices = Array.from({ length: end - start }, (_, k) => start + k);
    const candidates = await Promise.all(
      indices.map((i) => this.getLatestPairAtIndex(i)),
    );
    return indices
      .map((index, k) => ({ index, pair: candidates[k] }))
      .filter((entry) => !entry.pair.isZero());
  }

  /**
   * For each live pair in the indexed range `[start, end)`, return its
   * current pause flag. `start` defaults to `0`; `end` defaults to
   * `getActivePairCount()`. Cleared bases (zero entries) are omitted
   * from the result.
   *
   * The `index` field is the original `getLatestPairAtIndex` slot --
   * useful for stable correlation when iterating in pages or comparing
   * snapshots over time.
   *
   * @throws if the wallet wasn't passed to the factory wrapper (the
   *   helper instantiates per-pair contract wrappers).
   */
  async getPairPauseStates(opts: {
    start?: number;
    end?: number;
  } = {}): Promise<{ pair: AztecAddress; index: number; isPaused: boolean }[]> {
    if (!this.wallet) {
      throw new SigalSwapValidationError(
        'getPairPauseStates: factory wrapper was constructed without a wallet handle. ' +
          'Use SigalSwapClient.factory() to get a wallet-aware factory.',
      );
    }
    const start = opts.start ?? 0;
    const end = opts.end ?? (await this.getActivePairCount());
    if (end <= start) return [];
    const live = await this.resolveLivePairs(start, end);
    const wallet = this.wallet;
    const senderAddress = this.senderAddress;
    const flags = await Promise.all(
      live.map(async ({ pair }) => {
        const contract = SigalSwapPairContract.at(pair, wallet);
        const { result } = await contract.methods
          .is_paused_view()
          .simulate({ from: senderAddress });
        return result as boolean;
      }),
    );
    return live.map((entry, i) => ({
      pair: entry.pair,
      index: entry.index,
      isPaused: flags[i],
    }));
  }

  /**
   * For each live pair in the indexed range `[start, end)`, return both
   * the factory's protocol-fee config and the pair-side cached config,
   * with a `drifted` flag set when any of `(fee_to, percent, active)`
   * differs. The factory's `sync_protocol_fee` push is per-pair and
   * fires only when an admin or anyone-permissionless caller invokes it,
   * so a pair's view of the protocol fee can lag the factory's between
   * pushes -- `drifted` surfaces those gaps for the admin tooling that
   * reconciles them.
   *
   * `index` correlates back to the `getLatestPairAtIndex` slot.
   *
   * @throws if the wallet wasn't passed to the factory wrapper.
   */
  async getProtocolFeeDriftStates(opts: {
    start?: number;
    end?: number;
  } = {}): Promise<{
    pair: AztecAddress;
    index: number;
    pairFeeTo: AztecAddress;
    pairPercent: number;
    pairActive: boolean;
    factoryFeeTo: AztecAddress;
    factoryPercent: number;
    factoryActive: boolean;
    drifted: boolean;
  }[]> {
    if (!this.wallet) {
      throw new SigalSwapValidationError(
        'getProtocolFeeDriftStates: factory wrapper was constructed without a wallet handle. ' +
          'Use SigalSwapClient.factory() to get a wallet-aware factory.',
      );
    }
    const start = opts.start ?? 0;
    const end = opts.end ?? (await this.getActivePairCount());
    if (end <= start) return [];
    const [live, factoryFee] = await Promise.all([
      this.resolveLivePairs(start, end),
      this.getProtocolFeeConfig(),
    ]);
    const wallet = this.wallet;
    const senderAddress = this.senderAddress;
    const perPair = await Promise.all(
      live.map(async ({ pair }) => {
        const contract = SigalSwapPairContract.at(pair, wallet);
        const [{ result: feeTo }, { result: state }] = await Promise.all([
          contract.methods.get_fee_to().simulate({ from: senderAddress }),
          contract.methods.get_pair_state().simulate({ from: senderAddress }),
        ]);
        // get_pair_state: [reserve0, reserve1, blockTimestampLast, isPaused, percent, active]
        return {
          feeTo: feeTo as AztecAddress,
          percent: Number(state[4]),
          active: state[5] as boolean,
        };
      }),
    );
    return live.map((entry, i) => {
      const p = perPair[i];
      const drifted =
        !p.feeTo.equals(factoryFee.feeTo) ||
        p.percent !== factoryFee.percent ||
        p.active !== factoryFee.enabled;
      return {
        pair: entry.pair,
        index: entry.index,
        pairFeeTo: p.feeTo,
        pairPercent: p.percent,
        pairActive: p.active,
        factoryFeeTo: factoryFee.feeTo,
        factoryPercent: factoryFee.percent,
        factoryActive: factoryFee.enabled,
        drifted,
      };
    });
  }

  /**
   * Get the `queued_at` timestamp for a timelocked action, or `0n` if not
   * queued (never queued, already executed, or cancelled).
   *
   * `actionHash` comes from `computeActionHash(actionType, value)`. To
   * convert to a typed status (queued / executable / expired), use
   * `getTimelockStatus` which combines this read with the protocol's
   * timelock params and a caller-provided `now`.
   */
  async getTimelock(actionHash: Fr): Promise<bigint> {
    const { result } = await this.contract.methods.get_timelock(actionHash).simulate({ from: this.senderAddress });
    return BigInt(result);
  }

  /**
   * Get the protocol's timelock parameters: `delay` (queue→executable) and
   * `window` (executable lifetime before re-queue is required), in seconds.
   * Both are compile-time globals on the factory. Querying them here keeps
   * off-chain code from hardcoding values that could drift if the contract
   * is redeployed with different parameters.
   */
  async getTimelockParams(): Promise<{ delay: bigint; window: bigint }> {
    const { result } = await this.contract.methods.get_timelock_params().simulate({ from: this.senderAddress });
    return {
      delay: BigInt(result[0]),
      window: BigInt(result[1]),
    };
  }

  /**
   * Resolve the typed lifecycle state of a timelocked action at time `now`
   * (defaulting to wall-clock seconds). One round-trip: queries `get_timelock`
   * + `get_timelock_params` in parallel and computes the rest off-chain.
   *
   * Returns one of:
   *   - `{ status: 'not_queued' }`            -- action has not been queued, or was already executed/cancelled.
   *   - `{ status: 'queued', queuedAt, executableAt, expiresAt }` -- in the delay window.
   *   - `{ status: 'executable', queuedAt, executableAt, expiresAt }` -- can be executed now.
   *   - `{ status: 'expired', queuedAt, executableAt, expiresAt }`    -- past the window, must re-queue.
   */
  async getTimelockStatus(
    actionHash: Fr,
    now: bigint = BigInt(Math.floor(Date.now() / 1000)),
  ): Promise<TimelockStatus> {
    const [queuedAt, params] = await Promise.all([
      this.getTimelock(actionHash),
      this.getTimelockParams(),
    ]);
    if (queuedAt === 0n) {
      return { status: 'not_queued' };
    }
    const executableAt = queuedAt + params.delay;
    const expiresAt = executableAt + params.window;
    let status: 'queued' | 'executable' | 'expired';
    if (now < executableAt) {
      status = 'queued';
    } else if (now <= expiresAt) {
      status = 'executable';
    } else {
      status = 'expired';
    }
    return { status, queuedAt, executableAt, expiresAt };
  }

  /**
   * Create a pair for `(token0, token1, feeTierBps)`. The flow has three
   * steps -- deploy the pair, deploy its LP Token at the pair's derived
   * address, and register with the factory -- each of which checks for
   * prior completion before acting, so this call is **idempotent**: if
   * some earlier call failed partway through, calling `createPair` again
   * with the same arguments completes the remaining steps and returns
   * the fully-wired handles.
   *
   * Caller is responsible for ensuring `tokenA != tokenB` and that both are
   * valid Token addresses. Two preflight checks (`isFeeTierAllowed` and
   * `isRegistrationPaused`) run automatically against the factory before any
   * deploy tx fires, so an unwhitelisted fee tier or a paused registration
   * surface as a `SigalSwapValidationError` *before* the user spends gas on
   * a pair + LP Token deploy that would only revert at register time.
   *
   * The deploy uses canonical inputs (salt=1, universal deploy, default
   * public keys) so the pair's address-match in `register_pair` succeeds.
   * Any deviation causes `register_pair` to revert with `PAIR_NOT_CANONICAL`.
   *
   * @throws {SigalSwapValidationError} if `feeTierBps` is not in the
   *   factory's whitelist or registration is currently paused.
   * @throws {SigalSwapDeploymentError} if an LP Token deploy would land at
   *   an address different from the one the pair derives internally (deploy
   *   inputs out of sync, usually a bug or version skew), or if a
   *   **different** pair is already registered at the canonical slot (the
   *   admin bumped `pair_class_version`; query the existing pair with
   *   `getPair`).
   * @throws {SigalSwapContractRevertError} if `register_pair` reverts.
   *   Clear the underlying cause and retry `createPair`; the deploy steps
   *   short-circuit on contracts already at their canonical addresses, so
   *   only the register step re-runs.
   */
  async createPair(
    wallet: Wallet,
    tokenA: AztecAddress,
    tokenB: AztecAddress,
    feeTierBps: number,
  ): Promise<{
    pair: SigalSwapPairContract;
    lpToken: SigalSwapLPTokenContract;
    token0: AztecAddress;
    token1: AztecAddress;
  }> {
    const [token0, token1] = sortTokensByField(tokenA, tokenB);

    // --- Step 0: preflight against factory state ---
    //
    // Both checks would otherwise surface as `register_pair` reverts AFTER
    // the pair + LP Token were already deployed -- user's gas wasted. The
    // preflight is two reads in parallel; trivial cost vs. the multi-tx
    // deploy flow it gates.
    const [tierAllowed, paused] = await Promise.all([
      this.contract.methods
        .is_fee_tier_allowed(feeTierBps)
        .simulate({ from: this.senderAddress }),
      this.contract.methods
        .is_registration_paused()
        .simulate({ from: this.senderAddress }),
    ]);
    if (!tierAllowed.result) {
      throw new SigalSwapValidationError(
        `createPair: feeTierBps ${feeTierBps} is not in the factory's whitelist. ` +
        `Call factory.isFeeTierAllowed(tier) to enumerate, or have the admin ` +
        `add the tier via queue_add_fee_tier first.`,
      );
    }
    if (paused.result) {
      throw new SigalSwapValidationError(
        `createPair: factory.registration_paused is true; new pair ` +
        `registrations are blocked. Wait for admin to unpause via ` +
        `unpause_registration.`,
      );
    }

    // --- Step 1: pair deploy (or fetch if already at canonical address) ---
    //
    // Build the deploy interaction to get the canonical address it would
    // land at, then check whether a contract is already there. If yes, an
    // earlier run of this function (or another caller using identical
    // inputs) already deployed -- contracts at a given Aztec address are
    // content-addressed, so "already deployed" implies "the same pair we
    // would have deployed."
    const pairDeployMethod = SigalSwapPairContract.deploy(
      wallet, token0, token1, this.contract.address, feeTierBps,
      { universalDeploy: true, salt: CANONICAL_DEPLOY_SALT },
    );
    const pairInstance = await pairDeployMethod.getInstance();
    const expectedPairAddress = pairInstance.address;

    let pair: SigalSwapPairContract;
    if (await isContractDeployed(wallet, expectedPairAddress)) {
      pair = SigalSwapPairContract.at(expectedPairAddress, wallet);
    } else {
      const { contract } = await pairDeployMethod.send({
        from: this.senderAddress,
      });
      pair = contract;
    }

    // --- Step 2: LP Token deploy (or fetch) ---
    //
    // The pair derives its LP Token address internally. Our canonical-
    // deploy inputs must land the LP Token at that same address, or the
    // factory's `LP_TOKEN_NOT_DEPLOYED` / `LP_TOKEN_WRONG_CLASS` check at
    // register time will revert. Verify the match before either branch.
    const { result: derivedLpAddress } = await pair.methods
      .get_lp_token()
      .simulate({ from: this.senderAddress });

    const lpDeployMethod = SigalSwapLPTokenContract.deploy(
      wallet, pair.address,
      { universalDeploy: true, salt: CANONICAL_DEPLOY_SALT },
    );
    const lpInstance = await lpDeployMethod.getInstance();

    if (!lpInstance.address.equals(derivedLpAddress)) {
      throw new SigalSwapDeploymentError(
        `LP Token canonical deploy would land at ${lpInstance.address} but ` +
        `pair derived ${derivedLpAddress}; canonical deploy inputs (salt, ` +
        `deployer, public keys) must match the pair's LP_TOKEN_SALT and ` +
        `PublicKeys::default().`,
        { pairAddress: pair.address, lpTokenAddress: lpInstance.address },
      );
    }

    let lpToken: SigalSwapLPTokenContract;
    if (await isContractDeployed(wallet, lpInstance.address)) {
      lpToken = SigalSwapLPTokenContract.at(lpInstance.address, wallet);
    } else {
      const { contract } = await lpDeployMethod.send({
        from: this.senderAddress,
      });
      lpToken = contract;
    }

    // --- Step 3: register (or skip if already registered) ---
    //
    // Query the factory's `get_pair` view to see what's registered at
    // `(token0, token1, feeTierBps)`. Three cases:
    //   - zero: not yet registered -> call register_pair.
    //   - pair.address: already registered -> skip.
    //   - other address: a different pair is registered here. This can
    //     happen if the admin bumped pair_class_version and our canonical
    //     class no longer matches. Surface explicitly; can't proceed.
    const { result: registeredAddress } = await this.contract.methods
      .get_pair(token0, token1, feeTierBps)
      .simulate({ from: this.senderAddress });
    const registered: AztecAddress = registeredAddress;

    if (registered.isZero()) {
      await wrapContractRevert(
        'factory.register_pair',
        () => this.contract.methods.register_pair(
          pair.address, token0, token1, feeTierBps, CANONICAL_DEPLOY_SALT,
        ).send({ from: this.senderAddress }) as unknown as Promise<unknown>,
      );
    } else if (!registered.equals(pair.address)) {
      throw new SigalSwapDeploymentError(
        `A different pair is already registered at (${token0}, ${token1}, ${feeTierBps}): ` +
        `factory reports ${registered}, but canonical deploy is ${pair.address}. ` +
        `This usually means the factory's pair_class_version was bumped; query the ` +
        `existing pair via getPair() rather than creating a new one.`,
        { pairAddress: pair.address, lpTokenAddress: lpInstance.address },
      );
    }
    // else: already registered to our pair -> skip, idempotent.

    return { pair, lpToken, token0, token1 };
  }

  /**
   * Compute the canonical address a pair would deploy to, without actually
   * deploying. Useful for indexers and UIs that want to check whether a
   * pair exists before prompting the user to create one.
   *
   * Callers can check whether the computed address is populated via the
   * wallet's `getContractMetadata(address)` -- `initializationStatus`
   * tells you whether the deploy has happened.
   */
  async deriveCanonicalPairAddress(
    wallet: Wallet,
    tokenA: AztecAddress,
    tokenB: AztecAddress,
    feeTierBps: number,
  ): Promise<AztecAddress> {
    const [token0, token1] = sortTokensByField(tokenA, tokenB);
    const instance = await SigalSwapPairContract.deploy(
      wallet, token0, token1, this.contract.address, feeTierBps,
      { universalDeploy: true, salt: CANONICAL_DEPLOY_SALT },
    ).getInstance();
    return instance.address;
  }

  /**
   * Returns true iff `pairAddress` is the current registered pair at the
   * factory for `(token0, token1, feeTierBps)`. Returns false if nothing is
   * registered there, or if some other address is registered (e.g., after
   * `pair_class_version` was bumped).
   */
  async isPairRegistered(
    pairAddress: AztecAddress,
    token0: AztecAddress,
    token1: AztecAddress,
    feeTierBps: number,
  ): Promise<boolean> {
    const [sorted0, sorted1] = sortTokensByField(token0, token1);
    const { result } = await this.contract.methods
      .get_pair(sorted0, sorted1, feeTierBps)
      .simulate({ from: this.senderAddress });
    return (result as AztecAddress).equals(pairAddress);
  }
}

/**
 * Sort two token addresses into the canonical `(token0, token1)` order the
 * pair contract expects (lower-128-bits comparison, matching Noir's
 * `token.to_field() as u128`). The factory rejects unsorted tokens during
 * `register_pair`; integrators constructing a pair manually (without
 * `createPair`) must apply this ordering themselves. Exported so callers
 * don't have to re-implement the lower-128-bits truncation -- a footgun
 * with full-Field address comparisons that look right but fail
 * registration.
 *
 * Throws {@link SigalSwapValidationError} when the two addresses' lower
 * 128 bits collide; the pair contract wouldn't accept that pair regardless.
 */
export function sortTokensByField(
  tokenA: AztecAddress,
  tokenB: AztecAddress,
): [AztecAddress, AztecAddress] {
  const aU128 = tokenA.toBigInt() & ((1n << 128n) - 1n);
  const bU128 = tokenB.toBigInt() & ((1n << 128n) - 1n);
  if (aU128 === bU128) {
    throw new SigalSwapValidationError(
      'sortTokensByField: token addresses are identical in their lower 128 bits',
    );
  }
  return aU128 < bU128 ? [tokenA, tokenB] : [tokenB, tokenA];
}

/**
 * Returns true iff the wallet's PXE reports a deployed + initialized
 * contract at `address`. For a never-deployed address this is false;
 * the wallet's `getContractMetadata` returns the "unknown" shape with
 * `initializationStatus === UNKNOWN` rather than throwing.
 */
async function isContractDeployed(
  wallet: Wallet,
  address: AztecAddress,
): Promise<boolean> {
  const meta = await wallet.getContractMetadata(address);
  return meta.initializationStatus === ContractInitializationStatus.INITIALIZED;
}

// ================================================================
// Timelock status types
// ================================================================

/**
 * Typed lifecycle state for a queued governance action.
 *
 * `queuedAt` / `executableAt` / `expiresAt` are wall-clock seconds. Computed
 * by {@link SigalSwapFactory.getTimelockStatus} from the on-chain
 * `queued_at` slot + the protocol's `(delay, window)` parameters.
 */
export type TimelockStatus =
  | { status: 'not_queued' }
  | {
      status: 'queued' | 'executable' | 'expired';
      queuedAt: bigint;
      executableAt: bigint;
      expiresAt: bigint;
    };

// ================================================================
// Governance action types and decoding
// ================================================================

/**
 * Timelock action-type identifiers used by the factory's governance queue.
 *
 * Each `queue_*` function on the factory writes to the timelock under a
 * `(action_type, value)` pair. `ActionQueuedEvent` and `ActionExecutedEvent`
 * both expose these two raw fields; consumers decode them using this enum +
 * {@link decodeActionValue}. The numeric IDs are contract constants (see
 * `ACTION_*` globals in `protocol/factory/src/main.nr`) — changing them is
 * a breaking governance change.
 *
 * The factory README's "Action type IDs" section is the authoritative
 * source for the semantics of each type's `value` field.
 */
export const ActionType = {
  SET_FEE_TO: 1n,
  SET_PROTOCOL_FEE_PERCENT: 2n,
  SET_PROTOCOL_FEE_ENABLED: 3n,
  ADD_FEE_TIER: 4n,
  REMOVE_FEE_TIER: 5n,
  SET_ADMIN: 6n,
  SET_PAIR_CLASS_ID: 7n,
  CLEAR_PAIR_SLOT: 8n,
} as const;

/** The numeric id of an action type (matches the factory's `ACTION_*` globals). */
export type ActionTypeId = typeof ActionType[keyof typeof ActionType];

// ================================================================
// Action-hash compute helpers
//
// Mirror the factory's pure `compute_action_hash` / `compute_*_param`
// helpers (see `protocol/factory/src/helpers.nr`). Indexers, explorers,
// and audit tools use these to correlate `ActionQueuedEvent` /
// `ActionExecutedEvent` / `ActionCancelledEvent` payloads back to the
// admin submissions that produced them. Pure functions -- no tx
// sending, no wallet required, safe to call anywhere.
//
// Tx-sending wrappers for queue / execute / cancel deliberately do NOT
// live in this SDK -- admin tooling is a separate package with
// different security assumptions (multisig signing, hardware wallets,
// infrequent invocation cadence). The compute helpers are public-SDK
// because non-admin observers (indexers, dashboards) need them to
// match events to submissions.
// ================================================================

/**
 * Compute the action hash that the factory uses as the storage key for a
 * timelocked action's queued-at timestamp. Matches the contract's
 * `compute_action_hash(action_type, param)` helper -- the param Field is
 * either the action's value directly (for SET_FEE_TO, SET_ADMIN, etc.)
 * or the result of `computeSetPairClassIdParam` / `computeClearPairSlotParam`
 * for the two compound-arg actions.
 *
 * Use this to find a queued action's timestamp without the SDK doing a
 * round-trip to the factory: keccak the params yourself, query the
 * `timelock` storage map at the resulting key.
 */
export async function computeActionHash(
  actionType: ActionTypeId,
  param: Fr | bigint,
): Promise<Fr> {
  const paramFr = param instanceof Fr ? param : new Fr(param);
  return poseidon2Hash([new Fr(actionType), paramFr]);
}

/**
 * Compute the `param` Field for a `set_pair_class_id` timelock action.
 * Matches the contract's `compute_class_id_version_param(class_id, version)`.
 * Distinct (class_id, version) combinations hash to distinct params so
 * two queued blessings with the same class_id but different versions
 * don't collide in the timelock map.
 */
export async function computeSetPairClassIdParam(
  classId: Fr | bigint,
  version: number,
): Promise<Fr> {
  const classIdFr = classId instanceof Fr ? classId : new Fr(classId);
  return poseidon2Hash([classIdFr, new Fr(BigInt(version))]);
}

/**
 * Compute the `param` Field for a `clear_pair_slot` timelock action.
 * Matches the contract's `compute_clear_slot_param(...)`. Sorts (token0,
 * token1) by their lower-128-bit field representation -- the factory
 * does the same so the param is canonical regardless of caller-supplied
 * token order.
 */
export async function computeClearPairSlotParam(
  pair: AztecAddress,
  token0: AztecAddress,
  token1: AztecAddress,
  feeTierBps: number,
  newLatestVersion: number,
): Promise<Fr> {
  const U128_MASK = (1n << 128n) - 1n;
  const t0Lower = token0.toBigInt() & U128_MASK;
  const t1Lower = token1.toBigInt() & U128_MASK;
  const [t0, t1] = t0Lower < t1Lower ? [token0, token1] : [token1, token0];
  return poseidon2Hash([
    new Fr(pair.toBigInt()),
    new Fr(t0.toBigInt()),
    new Fr(t1.toBigInt()),
    new Fr(BigInt(feeTierBps)),
    new Fr(BigInt(newLatestVersion)),
  ]);
}

/**
 * Structured decoding of an `ActionQueuedEvent` / `ActionExecutedEvent`.
 *
 * Each variant's `type` matches the `ActionType` entry by name. For the two
 * compound actions (`set_pair_class_id`, `clear_pair_slot`) the on-chain
 * `value` is a Poseidon2 hash of the original arguments and cannot be
 * inverted: the `raw` field is returned as-is, and callers that need the
 * pre-hash arguments must cross-reference their own submission record.
 *
 * The `unknown` variant is returned for any `action_type` outside 1..=8 so
 * consumers can fail gracefully if a future factory upgrade adds new types.
 */
export type DecodedAction =
  | { type: 'set_fee_to'; newFeeTo: AztecAddress }
  | { type: 'set_protocol_fee_percent'; newPercent: number }
  | { type: 'set_protocol_fee_enabled'; enabled: boolean }
  | { type: 'add_fee_tier'; tierBps: number }
  | { type: 'remove_fee_tier'; tierBps: number }
  | { type: 'set_admin'; newAdmin: AztecAddress }
  | { type: 'set_pair_class_id'; valueIsCompoundHash: true; raw: bigint }
  | { type: 'clear_pair_slot'; valueIsCompoundHash: true; raw: bigint }
  | { type: 'unknown'; actionType: bigint; raw: bigint };

/**
 * Decode an `ActionQueuedEvent` or `ActionExecutedEvent` payload into a
 * typed, self-describing variant.
 *
 * For simple actions (types 1, 2, 3, 4, 5, 6) the `value` is a direct
 * argument — address, percent, boolean flag, or tier in bps — and the
 * decoder returns it in its native form.
 *
 * For compound actions (types 7 and 8) `value` is a Poseidon2 hash of
 * multiple arguments. The original arguments are not recoverable from the
 * hash alone; callers wanting them must retain the submission record and
 * match by hash. The decoder surfaces this as `valueIsCompoundHash: true`
 * so consumers handle it explicitly.
 *
 * @example
 * ```typescript
 * import { ActionType, decodeActionValue } from '@sigalswap/sdk';
 *
 * // For every ActionQueuedEvent you receive:
 * const decoded = decodeActionValue(event.action_type, event.value);
 * switch (decoded.type) {
 *   case 'set_fee_to':
 *     console.log('new fee recipient:', decoded.newFeeTo.toString());
 *     break;
 *   case 'set_protocol_fee_percent':
 *     console.log('new percent:', decoded.newPercent);
 *     break;
 *   case 'set_pair_class_id':
 *     // Value is a hash. Cross-reference your own records of queued
 *     // (class_id, version) pairs using `decoded.raw` as the key.
 *     break;
 *   case 'unknown':
 *     console.warn('unknown action type', decoded.actionType);
 *     break;
 * }
 * ```
 */
export function decodeActionValue(actionType: bigint, value: bigint): DecodedAction {
  switch (actionType) {
    case ActionType.SET_FEE_TO:
      return { type: 'set_fee_to', newFeeTo: AztecAddress.fromBigInt(value) };
    case ActionType.SET_PROTOCOL_FEE_PERCENT:
      return { type: 'set_protocol_fee_percent', newPercent: Number(value) };
    case ActionType.SET_PROTOCOL_FEE_ENABLED:
      return { type: 'set_protocol_fee_enabled', enabled: value !== 0n };
    case ActionType.ADD_FEE_TIER:
      return { type: 'add_fee_tier', tierBps: Number(value) };
    case ActionType.REMOVE_FEE_TIER:
      return { type: 'remove_fee_tier', tierBps: Number(value) };
    case ActionType.SET_ADMIN:
      return { type: 'set_admin', newAdmin: AztecAddress.fromBigInt(value) };
    case ActionType.SET_PAIR_CLASS_ID:
      return { type: 'set_pair_class_id', valueIsCompoundHash: true, raw: value };
    case ActionType.CLEAR_PAIR_SLOT:
      return { type: 'clear_pair_slot', valueIsCompoundHash: true, raw: value };
    default:
      return { type: 'unknown', actionType, raw: value };
  }
}
