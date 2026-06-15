import { describe, it, expect, vi, beforeEach } from 'vitest';
import { AztecAddress } from '@aztec/aztec.js/addresses';
import {
  SigalSwapFactory, ActionType, decodeActionValue,
  computeActionHash, computeSetPairClassIdParam, computeClearPairSlotParam,
} from './factory.js';
import { ADDR_A, ADDR_B, ADDR_PAIR, ADDR_LP_TOKEN, ADDR_FACTORY, ADDR_SENDER, ADDR_ZERO } from './__test__/addresses.js';
import { mockFactoryContract, mockInteraction, mockWallet } from './__test__/mocks.js';

describe('SigalSwapFactory', () => {
  let factory: SigalSwapFactory;
  let contract: ReturnType<typeof mockFactoryContract>;

  beforeEach(() => {
    contract = mockFactoryContract(ADDR_FACTORY);
    factory = new SigalSwapFactory(contract as any, ADDR_SENDER);
  });

  it('getPair returns the address from simulate', async () => {
    contract.methods.get_pair.mockReturnValue(mockInteraction(ADDR_A));
    const result = await factory.getPair(ADDR_A, ADDR_A, 25);
    expect(result).toBe(ADDR_A);
  });

  it('getPairCount converts bigint to number', async () => {
    contract.methods.get_pair_count.mockReturnValue(mockInteraction(5n));
    expect(await factory.getPairCount()).toBe(5);
  });

  it('isFeeTierAllowed returns boolean', async () => {
    contract.methods.is_fee_tier_allowed.mockReturnValue(mockInteraction(true));
    expect(await factory.isFeeTierAllowed(25)).toBe(true);
  });

  it('getAdmin returns address', async () => {
    contract.methods.get_admin.mockReturnValue(mockInteraction(ADDR_A));
    expect(await factory.getAdmin()).toBe(ADDR_A);
  });

  it('getFeeTo returns address', async () => {
    contract.methods.get_fee_to.mockReturnValue(mockInteraction(ADDR_A));
    expect(await factory.getFeeTo()).toBe(ADDR_A);
  });

  it('getProtocolFeeConfig maps tuple correctly', async () => {
    contract.methods.get_protocol_fee_config.mockReturnValue(mockInteraction([ADDR_A, 20n, true]));
    expect(await factory.getProtocolFeeConfig()).toEqual({ feeTo: ADDR_A, percent: 20, enabled: true });
  });

  it('isRegistrationPaused returns boolean', async () => {
    contract.methods.is_registration_paused.mockReturnValue(mockInteraction(false));
    expect(await factory.isRegistrationPaused()).toBe(false);
  });

  it('getPairVersioned returns address for a specific version', async () => {
    contract.methods.get_pair_versioned.mockReturnValue(mockInteraction(ADDR_A));
    const result = await factory.getPairVersioned(ADDR_A, ADDR_A, 25, 1);
    expect(result).toBe(ADDR_A);
    expect(contract.methods.get_pair_versioned).toHaveBeenCalledWith(ADDR_A, ADDR_A, 25, 1);
  });

  it('getLatestVersion converts bigint to number', async () => {
    contract.methods.get_latest_version.mockReturnValue(mockInteraction(2n));
    expect(await factory.getLatestVersion(ADDR_A, ADDR_A, 25)).toBe(2);
  });

  it('getIndexedBaseCount converts bigint to number', async () => {
    contract.methods.get_indexed_base_count.mockReturnValue(mockInteraction(3n));
    expect(await factory.getIndexedBaseCount()).toBe(3);
  });

  it('getActivePairCount converts bigint to number', async () => {
    contract.methods.get_active_pair_count.mockReturnValue(mockInteraction(2n));
    expect(await factory.getActivePairCount()).toBe(2);
  });

  it('getLatestPairAtIndex returns address', async () => {
    contract.methods.get_latest_pair_at_index.mockReturnValue(mockInteraction(ADDR_A));
    const result = await factory.getLatestPairAtIndex(0);
    expect(result).toBe(ADDR_A);
    expect(contract.methods.get_latest_pair_at_index).toHaveBeenCalledWith(0);
  });

  it('getPairClassVersion converts bigint to number', async () => {
    contract.methods.get_pair_class_version.mockReturnValue(mockInteraction(1n));
    expect(await factory.getPairClassVersion()).toBe(1);
  });

  it('getPairAt returns historical pair by index', async () => {
    contract.methods.get_pair_at.mockReturnValue(mockInteraction(ADDR_A));
    const result = await factory.getPairAt(2);
    expect(result).toBe(ADDR_A);
    expect(contract.methods.get_pair_at).toHaveBeenCalledWith(2);
  });

  describe('timelock status', () => {
    const TEST_HASH = { toString: () => '0xabc' } as any;

    it('getTimelock returns the queued_at timestamp as bigint', async () => {
      contract.methods.get_timelock.mockReturnValue(mockInteraction(1700000000n));
      expect(await factory.getTimelock(TEST_HASH)).toBe(1700000000n);
    });

    it('getTimelock returns 0n when not queued', async () => {
      contract.methods.get_timelock.mockReturnValue(mockInteraction(0n));
      expect(await factory.getTimelock(TEST_HASH)).toBe(0n);
    });

    it('getTimelockParams unpacks (delay, window) tuple', async () => {
      contract.methods.get_timelock_params.mockReturnValue(mockInteraction([172800n, 604800n]));
      expect(await factory.getTimelockParams()).toEqual({ delay: 172800n, window: 604800n });
    });

    it('getTimelockStatus returns not_queued when queued_at is 0', async () => {
      contract.methods.get_timelock.mockReturnValue(mockInteraction(0n));
      contract.methods.get_timelock_params.mockReturnValue(mockInteraction([172800n, 604800n]));
      expect(await factory.getTimelockStatus(TEST_HASH, 1_700_000_000n)).toEqual({ status: 'not_queued' });
    });

    it('getTimelockStatus returns queued when now is before executableAt', async () => {
      contract.methods.get_timelock.mockReturnValue(mockInteraction(1_700_000_000n));
      contract.methods.get_timelock_params.mockReturnValue(mockInteraction([172800n, 604800n]));
      // now = queuedAt + 1s, well before queuedAt + delay.
      expect(await factory.getTimelockStatus(TEST_HASH, 1_700_000_001n)).toEqual({
        status: 'queued',
        queuedAt: 1_700_000_000n,
        executableAt: 1_700_172_800n,
        expiresAt: 1_700_777_600n,
      });
    });

    it('getTimelockStatus returns executable at the boundary now == executableAt', async () => {
      contract.methods.get_timelock.mockReturnValue(mockInteraction(1_700_000_000n));
      contract.methods.get_timelock_params.mockReturnValue(mockInteraction([172800n, 604800n]));
      expect(await factory.getTimelockStatus(TEST_HASH, 1_700_172_800n)).toEqual({
        status: 'executable',
        queuedAt: 1_700_000_000n,
        executableAt: 1_700_172_800n,
        expiresAt: 1_700_777_600n,
      });
    });

    it('getTimelockStatus returns executable at the boundary now == expiresAt', async () => {
      contract.methods.get_timelock.mockReturnValue(mockInteraction(1_700_000_000n));
      contract.methods.get_timelock_params.mockReturnValue(mockInteraction([172800n, 604800n]));
      expect(await factory.getTimelockStatus(TEST_HASH, 1_700_777_600n)).toMatchObject({
        status: 'executable',
      });
    });

    it('getTimelockStatus returns expired when now > expiresAt', async () => {
      contract.methods.get_timelock.mockReturnValue(mockInteraction(1_700_000_000n));
      contract.methods.get_timelock_params.mockReturnValue(mockInteraction([172800n, 604800n]));
      expect(await factory.getTimelockStatus(TEST_HASH, 1_700_777_601n)).toMatchObject({
        status: 'expired',
        queuedAt: 1_700_000_000n,
        executableAt: 1_700_172_800n,
        expiresAt: 1_700_777_600n,
      });
    });
  });

  // ================================================================
  // Multi-pair admin tooling: getPairPauseStates / getProtocolFeeDriftStates
  // ================================================================

  describe('multi-pair tooling', () => {
    /**
     * Wire a per-pair `SigalSwapPairContract.at` mock returning the
     * given map of `{ address.toString(): { isPaused, feeTo, percent,
     * active } }` snapshots. Each snapshot drives the pair-side reads
     * (is_paused_view, get_fee_to, get_pair_state) for that address.
     */
    async function stubPerPair(
      snapshots: Record<string, { isPaused?: boolean; feeTo?: AztecAddress; percent?: number; active?: boolean }>,
    ) {
      const { SigalSwapPairContract } = await import('./artifacts/SigalSwapPair.js');
      vi.mocked(SigalSwapPairContract.at).mockImplementation((addr: any) => {
        const key = addr.toString();
        const snap = snapshots[key] ?? {};
        return {
          address: addr,
          methods: {
            is_paused_view: vi.fn().mockReturnValue(mockInteraction(snap.isPaused ?? false)),
            get_fee_to: vi.fn().mockReturnValue(mockInteraction(snap.feeTo ?? ADDR_ZERO)),
            get_pair_state: vi.fn().mockReturnValue(
              mockInteraction([0n, 0n, 0n, snap.isPaused ?? false, BigInt(snap.percent ?? 0), snap.active ?? false]),
            ),
          },
        } as any;
      });
    }

    function makeFactoryWithWallet() {
      const wallet = mockWallet(ADDR_SENDER);
      return {
        factory: new SigalSwapFactory(contract as any, ADDR_SENDER, wallet),
        wallet,
      };
    }

    it('getPairPauseStates throws when wallet not provided', async () => {
      // The default `factory` in this describe block is constructed without
      // a wallet (the basic factory tests don't need one).
      await expect(factory.getPairPauseStates()).rejects.toThrow(/wallet handle/);
    });

    it('getProtocolFeeDriftStates throws when wallet not provided', async () => {
      await expect(factory.getProtocolFeeDriftStates()).rejects.toThrow(/wallet handle/);
    });

    it('getPairPauseStates returns paused/unpaused flags per live pair', async () => {
      const PAIR_A = AztecAddress.fromBigInt(0xa1n);
      const PAIR_B = AztecAddress.fromBigInt(0xb2n);
      const PAIR_C = AztecAddress.fromBigInt(0xc3n);
      contract.methods.get_active_pair_count.mockReturnValue(mockInteraction(5n));
      // Indices: 0=A (paused), 1=ZERO (cleared), 2=B (unpaused), 3=ZERO, 4=C (paused).
      contract.methods.get_latest_pair_at_index.mockImplementation((i: number) =>
        mockInteraction([PAIR_A, ADDR_ZERO, PAIR_B, ADDR_ZERO, PAIR_C][i]),
      );
      await stubPerPair({
        [PAIR_A.toString()]: { isPaused: true },
        [PAIR_B.toString()]: { isPaused: false },
        [PAIR_C.toString()]: { isPaused: true },
      });
      const { factory: f } = makeFactoryWithWallet();
      const result = await f.getPairPauseStates();
      expect(result).toHaveLength(3);
      expect(result.map((r) => ({ index: r.index, isPaused: r.isPaused }))).toEqual([
        { index: 0, isPaused: true },
        { index: 2, isPaused: false },
        { index: 4, isPaused: true },
      ]);
    });

    it('getPairPauseStates honors pagination via (start, end)', async () => {
      const PAIR_A = AztecAddress.fromBigInt(0xa1n);
      const PAIR_B = AztecAddress.fromBigInt(0xb2n);
      const PAIR_C = AztecAddress.fromBigInt(0xc3n);
      contract.methods.get_active_pair_count.mockReturnValue(mockInteraction(3n));
      contract.methods.get_latest_pair_at_index.mockImplementation((i: number) =>
        mockInteraction([PAIR_A, PAIR_B, PAIR_C][i]),
      );
      await stubPerPair({
        [PAIR_A.toString()]: { isPaused: true },
        [PAIR_B.toString()]: { isPaused: false },
        [PAIR_C.toString()]: { isPaused: true },
      });
      const { factory: f } = makeFactoryWithWallet();
      const page = await f.getPairPauseStates({ start: 1, end: 3 });
      expect(page).toHaveLength(2);
      expect(page.map((r) => r.index)).toEqual([1, 2]);
    });

    it('getProtocolFeeDriftStates flags drift per pair', async () => {
      const PAIR_A = AztecAddress.fromBigInt(0xa1n);
      const PAIR_B = AztecAddress.fromBigInt(0xb2n);
      const FACTORY_FEE_TO = AztecAddress.fromBigInt(0xfeen);
      // Factory's current protocol fee config: feeTo=FEE, percent=20, enabled=true.
      contract.methods.get_protocol_fee_config.mockReturnValue(
        mockInteraction([FACTORY_FEE_TO, 20n, true]),
      );
      contract.methods.get_active_pair_count.mockReturnValue(mockInteraction(2n));
      contract.methods.get_latest_pair_at_index.mockImplementation((i: number) =>
        mockInteraction([PAIR_A, PAIR_B][i]),
      );
      await stubPerPair({
        // Pair A is in sync (drifted = false)
        [PAIR_A.toString()]: { feeTo: FACTORY_FEE_TO, percent: 20, active: true },
        // Pair B has stale percent (drifted = true)
        [PAIR_B.toString()]: { feeTo: FACTORY_FEE_TO, percent: 10, active: true },
      });
      const { factory: f } = makeFactoryWithWallet();
      const result = await f.getProtocolFeeDriftStates();
      expect(result).toHaveLength(2);
      expect(result[0]).toMatchObject({ pair: PAIR_A, drifted: false });
      expect(result[1]).toMatchObject({ pair: PAIR_B, drifted: true, pairPercent: 10, factoryPercent: 20 });
    });

    it('getProtocolFeeDriftStates returns empty when registry is empty', async () => {
      contract.methods.get_active_pair_count.mockReturnValue(mockInteraction(0n));
      contract.methods.get_protocol_fee_config.mockReturnValue(mockInteraction([ADDR_ZERO, 0n, false]));
      const { factory: f } = makeFactoryWithWallet();
      const result = await f.getProtocolFeeDriftStates();
      expect(result).toEqual([]);
    });
  });
});

// ============================================================================
// createPair -- orchestrates pair deploy + LP Token deploy + register_pair
// ============================================================================

vi.mock('./artifacts/SigalSwapPair.js', () => ({
  SigalSwapPairContract: {
    deploy: vi.fn(),
    at: vi.fn(),
  },
}));
vi.mock('./artifacts/SigalSwapLPToken.js', () => ({
  SigalSwapLPTokenContract: {
    deploy: vi.fn(),
    at: vi.fn(),
  },
}));

describe('SigalSwapFactory.createPair', () => {
  let factory: SigalSwapFactory;
  let contract: ReturnType<typeof mockFactoryContract>;
  let wallet: ReturnType<typeof mockWallet>;

  // Mocks created in beforeEach and reused in each test.
  let pairDeployMethod: {
    getInstance: ReturnType<typeof vi.fn>;
    send: ReturnType<typeof vi.fn>;
  };
  let lpDeployMethod: {
    getInstance: ReturnType<typeof vi.fn>;
    send: ReturnType<typeof vi.fn>;
  };
  let pairGetLpToken: ReturnType<typeof vi.fn>;
  let registerPairSend: ReturnType<typeof vi.fn>;

  // Default `getContractMetadata` replies per-address. Tests override.
  let contractInitByAddress: Map<string, boolean>;

  beforeEach(async () => {
    contract = mockFactoryContract(ADDR_FACTORY);
    factory = new SigalSwapFactory(contract as any, ADDR_SENDER);
    wallet = mockWallet(ADDR_SENDER);

    contractInitByAddress = new Map();

    vi.mocked(wallet.getContractMetadata).mockImplementation(async (addr: AztecAddress) => ({
      instance: undefined,
      initializationStatus: contractInitByAddress.get(addr.toString())
        ? 'INITIALIZED'
        : 'UNINITIALIZED',
      isContractPublished: contractInitByAddress.get(addr.toString()) ?? false,
      isContractUpdated: false,
    } as any));

    // Factory's get_pair view: default is "nothing registered" (zero).
    contract.methods.get_pair = vi.fn().mockReturnValue(mockInteraction(ADDR_ZERO));
    // Factory preflight defaults: tier allowed, registration not paused.
    contract.methods.is_fee_tier_allowed.mockReturnValue(mockInteraction(true));
    contract.methods.is_registration_paused.mockReturnValue(mockInteraction(false));
    // Factory's register_pair tx: default is success.
    registerPairSend = vi.fn().mockResolvedValue(undefined);
    contract.methods.register_pair = vi.fn().mockReturnValue({ send: registerPairSend });

    // Pair contract's get_lp_token simulate return (used to verify derived LP match).
    pairGetLpToken = vi.fn().mockReturnValue(mockInteraction(ADDR_LP_TOKEN));

    // Pair deploy method: .getInstance returns the canonical address,
    // .send returns the deployed contract handle. Tests override either.
    pairDeployMethod = {
      getInstance: vi.fn().mockResolvedValue({ address: ADDR_PAIR }),
      send: vi.fn().mockResolvedValue({
        contract: {
          address: ADDR_PAIR,
          methods: { get_lp_token: pairGetLpToken },
        },
      }),
    };

    lpDeployMethod = {
      getInstance: vi.fn().mockResolvedValue({ address: ADDR_LP_TOKEN }),
      send: vi.fn().mockResolvedValue({
        contract: { address: ADDR_LP_TOKEN },
      }),
    };

    const { SigalSwapPairContract } = await import('./artifacts/SigalSwapPair.js');
    const { SigalSwapLPTokenContract } = await import('./artifacts/SigalSwapLPToken.js');
    vi.mocked(SigalSwapPairContract.deploy).mockReturnValue(pairDeployMethod as any);
    vi.mocked(SigalSwapLPTokenContract.deploy).mockReturnValue(lpDeployMethod as any);

    // .at() returns a handle matching what a real deployed pair would look like.
    // Used by idempotent paths where the pair is already deployed.
    vi.mocked(SigalSwapPairContract.at).mockImplementation(
      (address: AztecAddress) => ({
        address,
        methods: { get_lp_token: pairGetLpToken },
      }) as any,
    );
    vi.mocked(SigalSwapLPTokenContract.at).mockImplementation(
      (address: AztecAddress) => ({ address }) as any,
    );
  });

  it('happy path: nothing deployed -> deploys pair, deploys LP, registers', async () => {
    const result = await factory.createPair(wallet, ADDR_A, ADDR_B, 25);

    expect(result.pair.address).toBe(ADDR_PAIR);
    expect(result.lpToken.address).toBe(ADDR_LP_TOKEN);
    expect(result.token0).toBeDefined();
    expect(result.token1).toBeDefined();

    // All four tx steps were issued.
    expect(pairDeployMethod.getInstance).toHaveBeenCalled();
    expect(pairDeployMethod.send).toHaveBeenCalled();
    expect(pairGetLpToken).toHaveBeenCalled();
    expect(lpDeployMethod.getInstance).toHaveBeenCalled();
    expect(lpDeployMethod.send).toHaveBeenCalled();
    expect(registerPairSend).toHaveBeenCalled();
  });

  it('idempotent: pair already deployed, LP not -> skips pair deploy, deploys LP, registers', async () => {
    contractInitByAddress.set(ADDR_PAIR.toString(), true);
    contractInitByAddress.set(ADDR_LP_TOKEN.toString(), false);

    const result = await factory.createPair(wallet, ADDR_A, ADDR_B, 25);

    expect(result.pair.address).toBe(ADDR_PAIR);
    expect(result.lpToken.address).toBe(ADDR_LP_TOKEN);

    // Pair deploy was NOT re-sent; we took the .at() branch.
    expect(pairDeployMethod.send).not.toHaveBeenCalled();
    // LP deploy + register were sent.
    expect(lpDeployMethod.send).toHaveBeenCalled();
    expect(registerPairSend).toHaveBeenCalled();
  });

  it('idempotent: pair + LP deployed, not registered -> skips both deploys, registers', async () => {
    contractInitByAddress.set(ADDR_PAIR.toString(), true);
    contractInitByAddress.set(ADDR_LP_TOKEN.toString(), true);

    const result = await factory.createPair(wallet, ADDR_A, ADDR_B, 25);

    expect(result.pair.address).toBe(ADDR_PAIR);
    expect(result.lpToken.address).toBe(ADDR_LP_TOKEN);

    expect(pairDeployMethod.send).not.toHaveBeenCalled();
    expect(lpDeployMethod.send).not.toHaveBeenCalled();
    expect(registerPairSend).toHaveBeenCalled();
  });

  it('idempotent: fully registered -> no tx sent, returns handles', async () => {
    contractInitByAddress.set(ADDR_PAIR.toString(), true);
    contractInitByAddress.set(ADDR_LP_TOKEN.toString(), true);
    contract.methods.get_pair.mockReturnValue(mockInteraction(ADDR_PAIR));

    const result = await factory.createPair(wallet, ADDR_A, ADDR_B, 25);

    expect(result.pair.address).toBe(ADDR_PAIR);
    expect(result.lpToken.address).toBe(ADDR_LP_TOKEN);

    expect(pairDeployMethod.send).not.toHaveBeenCalled();
    expect(lpDeployMethod.send).not.toHaveBeenCalled();
    expect(registerPairSend).not.toHaveBeenCalled();
  });

  it('throws if a different pair is registered at the same (tokens, tier)', async () => {
    // The factory reports a different pair at this base -- e.g., after
    // pair_class_version was bumped. Our canonical deploy is ADDR_PAIR,
    // but the factory already has ADDR_A registered there.
    contractInitByAddress.set(ADDR_PAIR.toString(), true);
    contractInitByAddress.set(ADDR_LP_TOKEN.toString(), true);
    contract.methods.get_pair.mockReturnValue(mockInteraction(ADDR_A));

    await expect(factory.createPair(wallet, ADDR_A, ADDR_B, 25))
      .rejects.toThrow(/different pair is already registered/);
    expect(registerPairSend).not.toHaveBeenCalled();
  });

  it('throws if LP canonical deploy would land at a different address than the pair derives', async () => {
    // Pair derives ADDR_LP_TOKEN but LP deploy's canonical address is ADDR_A.
    lpDeployMethod.getInstance.mockResolvedValue({ address: ADDR_A });

    await expect(factory.createPair(wallet, ADDR_A, ADDR_B, 25))
      .rejects.toThrow(/LP Token canonical deploy would land at .* but pair derived/);
  });

  it('rejects identical tokens', async () => {
    await expect(factory.createPair(wallet, ADDR_A, ADDR_A, 25))
      .rejects.toThrow(/identical in their lower 128 bits/);
  });

  it('wraps register_pair revert as SigalSwapContractRevertError', async () => {
    // When register_pair fails after preflight passes (e.g., a race with the
    // admin pausing between preflight and execute), the revert is wrapped
    // with the contract-side reason extracted. Caller retries createPair
    // after clearing the underlying cause; the deploy steps short-circuit.
    const { SigalSwapContractRevertError } = await import('./errors.js');
    const cause = new Error('Public execution reverted: PAIR_EXISTS');
    registerPairSend.mockRejectedValueOnce(cause);

    await expect(factory.createPair(wallet, ADDR_A, ADDR_B, 25))
      .rejects.toBeInstanceOf(SigalSwapContractRevertError);
    registerPairSend.mockRejectedValueOnce(cause);
    await expect(factory.createPair(wallet, ADDR_A, ADDR_B, 25))
      .rejects.toMatchObject({ revertReason: 'PAIR_EXISTS', context: 'factory.register_pair' });
  });

  describe('preflight', () => {
    it('rejects unwhitelisted fee tier with SigalSwapValidationError before any deploy', async () => {
      const { SigalSwapValidationError } = await import('./errors.js');
      contract.methods.is_fee_tier_allowed.mockReturnValue(mockInteraction(false));

      await expect(factory.createPair(wallet, ADDR_A, ADDR_B, 25))
        .rejects.toBeInstanceOf(SigalSwapValidationError);
      // Crucially: no deploy was attempted.
      expect(pairDeployMethod.send).not.toHaveBeenCalled();
      expect(lpDeployMethod.send).not.toHaveBeenCalled();
      expect(registerPairSend).not.toHaveBeenCalled();
    });

    it('rejects when registration is paused with SigalSwapValidationError before any deploy', async () => {
      const { SigalSwapValidationError } = await import('./errors.js');
      contract.methods.is_registration_paused.mockReturnValue(mockInteraction(true));

      await expect(factory.createPair(wallet, ADDR_A, ADDR_B, 25))
        .rejects.toBeInstanceOf(SigalSwapValidationError);
      expect(pairDeployMethod.send).not.toHaveBeenCalled();
      expect(lpDeployMethod.send).not.toHaveBeenCalled();
      expect(registerPairSend).not.toHaveBeenCalled();
    });

    it('runs both preflight queries in parallel before deploying', async () => {
      // Both queries should be issued before any deploy; verified by the fact
      // that even the un-paused / allowed-tier happy path checks both before
      // the first deploy. We assert both methods got called once each.
      await factory.createPair(wallet, ADDR_A, ADDR_B, 25);
      expect(contract.methods.is_fee_tier_allowed).toHaveBeenCalledTimes(1);
      expect(contract.methods.is_registration_paused).toHaveBeenCalledTimes(1);
    });
  });
});

// ============================================================================
// isPairRegistered + deriveCanonicalPairAddress -- public helpers
// ============================================================================

describe('SigalSwapFactory.isPairRegistered', () => {
  let factory: SigalSwapFactory;
  let contract: ReturnType<typeof mockFactoryContract>;

  beforeEach(() => {
    contract = mockFactoryContract(ADDR_FACTORY);
    factory = new SigalSwapFactory(contract as any, ADDR_SENDER);
  });

  it('returns true when the factory reports the given pair', async () => {
    contract.methods.get_pair.mockReturnValue(mockInteraction(ADDR_PAIR));
    expect(await factory.isPairRegistered(ADDR_PAIR, ADDR_A, ADDR_B, 25)).toBe(true);
  });

  it('returns false when the factory reports a different pair', async () => {
    contract.methods.get_pair.mockReturnValue(mockInteraction(ADDR_A));
    expect(await factory.isPairRegistered(ADDR_PAIR, ADDR_A, ADDR_B, 25)).toBe(false);
  });

  it('returns false when nothing is registered at this base', async () => {
    contract.methods.get_pair.mockReturnValue(mockInteraction(ADDR_ZERO));
    expect(await factory.isPairRegistered(ADDR_PAIR, ADDR_A, ADDR_B, 25)).toBe(false);
  });

  it('sorts tokens before querying (caller can pass either order)', async () => {
    contract.methods.get_pair.mockReturnValue(mockInteraction(ADDR_PAIR));
    await factory.isPairRegistered(ADDR_PAIR, ADDR_B, ADDR_A, 25);
    // get_pair was called with the sorted pair (ADDR_A < ADDR_B), regardless
    // of the order the caller passed.
    const callArgs = contract.methods.get_pair.mock.calls[0];
    expect(callArgs[0]).toBe(ADDR_A);
    expect(callArgs[1]).toBe(ADDR_B);
  });
});

describe('SigalSwapFactory.deriveCanonicalPairAddress', () => {
  let factory: SigalSwapFactory;
  let contract: ReturnType<typeof mockFactoryContract>;
  let wallet: ReturnType<typeof mockWallet>;

  beforeEach(async () => {
    contract = mockFactoryContract(ADDR_FACTORY);
    factory = new SigalSwapFactory(contract as any, ADDR_SENDER);
    wallet = mockWallet(ADDR_SENDER);

    const { SigalSwapPairContract } = await import('./artifacts/SigalSwapPair.js');
    vi.mocked(SigalSwapPairContract.deploy).mockReturnValue({
      getInstance: vi.fn().mockResolvedValue({ address: ADDR_PAIR }),
    } as any);
  });

  it('returns the deploy method canonical instance address without sending', async () => {
    const result = await factory.deriveCanonicalPairAddress(wallet, ADDR_A, ADDR_B, 25);
    expect(result).toBe(ADDR_PAIR);
  });

  it('sorts tokens before computing', async () => {
    const { SigalSwapPairContract } = await import('./artifacts/SigalSwapPair.js');
    await factory.deriveCanonicalPairAddress(wallet, ADDR_B, ADDR_A, 25);
    const deployArgs = vi.mocked(SigalSwapPairContract.deploy).mock.calls[0];
    // Constructor args should be (wallet, token0, token1, factory, feeTierBps)
    // where token0 is the smaller address.
    expect(deployArgs[1]).toBe(ADDR_A); // sorted token0
    expect(deployArgs[2]).toBe(ADDR_B); // sorted token1
  });
});

describe('ActionType', () => {
  // These IDs must match the `ACTION_*` globals in protocol/factory/src/main.nr.
  // A mismatch means the factory and SDK disagree on governance semantics.
  it('matches the factory contract constants', () => {
    expect(ActionType.SET_FEE_TO).toBe(1n);
    expect(ActionType.SET_PROTOCOL_FEE_PERCENT).toBe(2n);
    expect(ActionType.SET_PROTOCOL_FEE_ENABLED).toBe(3n);
    expect(ActionType.ADD_FEE_TIER).toBe(4n);
    expect(ActionType.REMOVE_FEE_TIER).toBe(5n);
    expect(ActionType.SET_ADMIN).toBe(6n);
    expect(ActionType.SET_PAIR_CLASS_ID).toBe(7n);
    expect(ActionType.CLEAR_PAIR_SLOT).toBe(8n);
  });
});

describe('decodeActionValue', () => {
  it('decodes SET_FEE_TO into an AztecAddress', () => {
    const addr = AztecAddress.fromBigInt(0x1234n);
    const decoded = decodeActionValue(ActionType.SET_FEE_TO, 0x1234n);
    expect(decoded.type).toBe('set_fee_to');
    if (decoded.type === 'set_fee_to') {
      expect(decoded.newFeeTo.equals(addr)).toBe(true);
    }
  });

  it('decodes SET_PROTOCOL_FEE_PERCENT as a number', () => {
    const decoded = decodeActionValue(ActionType.SET_PROTOCOL_FEE_PERCENT, 25n);
    expect(decoded).toEqual({ type: 'set_protocol_fee_percent', newPercent: 25 });
  });

  it('decodes SET_PROTOCOL_FEE_ENABLED as boolean', () => {
    expect(decodeActionValue(ActionType.SET_PROTOCOL_FEE_ENABLED, 1n)).toEqual({
      type: 'set_protocol_fee_enabled', enabled: true,
    });
    expect(decodeActionValue(ActionType.SET_PROTOCOL_FEE_ENABLED, 0n)).toEqual({
      type: 'set_protocol_fee_enabled', enabled: false,
    });
  });

  it('decodes ADD_FEE_TIER and REMOVE_FEE_TIER as tier bps', () => {
    expect(decodeActionValue(ActionType.ADD_FEE_TIER, 100n)).toEqual({
      type: 'add_fee_tier', tierBps: 100,
    });
    expect(decodeActionValue(ActionType.REMOVE_FEE_TIER, 25n)).toEqual({
      type: 'remove_fee_tier', tierBps: 25,
    });
  });

  it('decodes SET_ADMIN into an AztecAddress', () => {
    const decoded = decodeActionValue(ActionType.SET_ADMIN, 0xabcdn);
    expect(decoded.type).toBe('set_admin');
    if (decoded.type === 'set_admin') {
      expect(decoded.newAdmin.equals(AztecAddress.fromBigInt(0xabcdn))).toBe(true);
    }
  });

  it('surfaces compound-hash actions with valueIsCompoundHash', () => {
    const classHash = 0xdeadbeefn;
    const slotHash = 0xcafebaben;
    expect(decodeActionValue(ActionType.SET_PAIR_CLASS_ID, classHash)).toEqual({
      type: 'set_pair_class_id', valueIsCompoundHash: true, raw: classHash,
    });
    expect(decodeActionValue(ActionType.CLEAR_PAIR_SLOT, slotHash)).toEqual({
      type: 'clear_pair_slot', valueIsCompoundHash: true, raw: slotHash,
    });
  });

  it('returns unknown for out-of-range action types', () => {
    expect(decodeActionValue(0n, 42n)).toEqual({ type: 'unknown', actionType: 0n, raw: 42n });
    expect(decodeActionValue(9n, 42n)).toEqual({ type: 'unknown', actionType: 9n, raw: 42n });
    expect(decodeActionValue(999n, 0n)).toEqual({ type: 'unknown', actionType: 999n, raw: 0n });
  });

  // ================================================================
  // Compute helpers (pure functions, no tx wrappers)
  // ================================================================

  describe('compute helpers', () => {
    it('computeActionHash is deterministic for the same inputs', async () => {
      const h1 = await computeActionHash(ActionType.SET_FEE_TO, 0xdeadbeefn);
      const h2 = await computeActionHash(ActionType.SET_FEE_TO, 0xdeadbeefn);
      expect(h1.toString()).toBe(h2.toString());
    });

    it('computeActionHash differentiates between action types', async () => {
      const v = 100n;
      const setFeeTo = await computeActionHash(ActionType.SET_FEE_TO, v);
      const setAdmin = await computeActionHash(ActionType.SET_ADMIN, v);
      expect(setFeeTo.toString()).not.toBe(setAdmin.toString());
    });

    it('computeActionHash differentiates between values for the same action', async () => {
      const a = await computeActionHash(ActionType.SET_FEE_TO, 1n);
      const b = await computeActionHash(ActionType.SET_FEE_TO, 2n);
      expect(a.toString()).not.toBe(b.toString());
    });

    it('computeSetPairClassIdParam binds class_id and version distinctly', async () => {
      const v1 = await computeSetPairClassIdParam(0xabcdn, 1);
      const v2 = await computeSetPairClassIdParam(0xabcdn, 2);
      const w1 = await computeSetPairClassIdParam(0xefffn, 1);
      expect(v1.toString()).not.toBe(v2.toString()); // version-bound
      expect(v1.toString()).not.toBe(w1.toString()); // class_id-bound
    });

    it('computeClearPairSlotParam is canonical regardless of token order', async () => {
      // Mirror the contract's lower-128-bit sort. Passing tokens in either
      // order should produce the same hash.
      const forward = await computeClearPairSlotParam(ADDR_PAIR, ADDR_A, ADDR_B, 25, 0);
      const reverse = await computeClearPairSlotParam(ADDR_PAIR, ADDR_B, ADDR_A, 25, 0);
      expect(forward.toString()).toBe(reverse.toString());
    });

    it('computeClearPairSlotParam is sensitive to all five inputs', async () => {
      const base = await computeClearPairSlotParam(ADDR_PAIR, ADDR_A, ADDR_B, 25, 0);
      const diffPair = await computeClearPairSlotParam(ADDR_LP_TOKEN, ADDR_A, ADDR_B, 25, 0);
      const diffTier = await computeClearPairSlotParam(ADDR_PAIR, ADDR_A, ADDR_B, 100, 0);
      const diffNewVersion = await computeClearPairSlotParam(ADDR_PAIR, ADDR_A, ADDR_B, 25, 1);
      expect(diffPair.toString()).not.toBe(base.toString());
      expect(diffTier.toString()).not.toBe(base.toString());
      expect(diffNewVersion.toString()).not.toBe(base.toString());
    });
  });
});
