import { describe, it, expect, vi, beforeEach } from 'vitest';
import { SigalSwapClient } from './client.js';
import { ADDR_SENDER, ADDR_A, ADDR_B, ADDR_C, ADDR_PAIR, ADDR_PAIR_BC, ADDR_FACTORY, ADDR_ROUTER, ADDR_LP_TOKEN, ADDR_ZERO } from './__test__/addresses.js';
import { DEFAULT_PAIR_CONFIG, mockWallet, mockInteraction } from './__test__/mocks.js';
import { AztecAddress } from '@aztec/aztec.js/addresses';

// Stub event metadata shapes -- matches what `aztec codegen` produces on
// the real artifact (`{ eventSelector, abiType, fieldNames }`). The history
// tests below route mocked private-event responses by `(contract,
// eventSelector)`; the mocks here just need each event metadata to have a
// stable `eventSelector.toString()`.
function evt(name: string) {
  return {
    eventSelector: { toString: () => `selector:${name}` },
    abiType: { kind: 'struct', fields: [] },
    fieldNames: [] as string[],
  };
}

vi.mock('./artifacts/SigalSwapPair.js', () => ({
  SigalSwapPairContract: {
    at: vi.fn().mockImplementation((address: any) => ({
      address,
      methods: {
        // Reuse the canonical PairConfig mock so a future field addition
        // (e.g., another address baked into PairConfig) flows through to
        // every test mock automatically.
        get_config: vi.fn().mockReturnValue(mockInteraction(DEFAULT_PAIR_CONFIG)),
        get_lp_token: vi.fn().mockReturnValue(mockInteraction(ADDR_LP_TOKEN)),
        get_version: vi.fn().mockReturnValue(mockInteraction(1n)),
      },
    })),
    events: {
      PrivateSwapExactInEvent: evt('PrivateSwapExactInEvent'),
      PrivateSwapExactOutEvent: evt('PrivateSwapExactOutEvent'),
      PrivateMintEvent: evt('PrivateMintEvent'),
      PrivateBurnEvent: evt('PrivateBurnEvent'),
    },
  },
}));
vi.mock('./artifacts/SigalSwapFactory.js', () => ({
  SigalSwapFactoryContract: {
    at: vi.fn().mockImplementation((address: any) => ({
      address,
      methods: {
        get_pair: vi.fn().mockReturnValue(mockInteraction(ADDR_PAIR)),
        get_pair_versioned: vi.fn().mockReturnValue(mockInteraction(ADDR_PAIR)),
        // Auto-enumeration defaults: zero pairs registered. Tests that
        // exercise the auto-enumerate path (history methods with no
        // `pairs`/`pair` arg) override these per-test.
        get_active_pair_count: vi.fn().mockReturnValue(mockInteraction(0n)),
        get_latest_pair_at_index: vi.fn().mockReturnValue(mockInteraction(ADDR_ZERO)),
      },
    })),
    events: {},
  },
}));
// LP Token artifact is loaded by events.ts (via SigalSwapEvents.lpToken).
// We don't exercise its surface here, but a stub keeps the import chain
// from loading the real artifact JSON during this test file.
vi.mock('./artifacts/SigalSwapLPToken.js', () => ({
  SigalSwapLPTokenContract: {
    at: vi.fn(),
    events: { LPTransfer: evt('LPTransfer') },
  },
}));
vi.mock('./artifacts/SigalSwapRouter.js', () => ({
  SigalSwapRouterContract: {
    at: vi.fn().mockImplementation((address: any) => ({ address, methods: {} })),
    events: {
      RouterSwapExactInEvent: evt('RouterSwapExactInEvent'),
      RouterSwapExactOutEvent: evt('RouterSwapExactOutEvent'),
      RouterMintEvent: evt('RouterMintEvent'),
      RouterBurnEvent: evt('RouterBurnEvent'),
      RouterSkimEvent: evt('RouterSkimEvent'),
    },
  },
}));

describe('SigalSwapClient', () => {
  let wallet: ReturnType<typeof mockWallet>;

  beforeEach(() => {
    wallet = mockWallet(ADDR_SENDER);
  });

  // ================================================================
  // create()
  // ================================================================

  describe('create()', () => {
    it('succeeds with valid opts', async () => {
      const client = await SigalSwapClient.create({
        wallet,
        senderAddress: ADDR_SENDER,
      });
      expect(client).toBeDefined();
      expect(client.senderAddress).toBe(ADDR_SENDER);
    });

    it('uses LOCAL_CONFIG when no config provided', async () => {
      const client = await SigalSwapClient.create({ wallet, senderAddress: ADDR_SENDER });
      expect(client.config.nodeUrl).toBe('http://localhost:8080');
    });

    it('freezes the config', async () => {
      const client = await SigalSwapClient.create({ wallet, senderAddress: ADDR_SENDER });
      expect(Object.isFrozen(client.config)).toBe(true);
    });

    it('throws when nodeUrl is empty', async () => {
      await expect(SigalSwapClient.create({
        wallet,
        senderAddress: ADDR_SENDER,
        config: { nodeUrl: '', environment: 'local' },
      })).rejects.toThrow('nodeUrl is required');
    });

    it('throws when senderAddress is not managed by wallet', async () => {
      vi.mocked(wallet.getAccounts).mockResolvedValueOnce([]);
      await expect(SigalSwapClient.create({
        wallet,
        senderAddress: ADDR_SENDER,
      })).rejects.toThrow('senderAddress is not managed by this wallet');
    });
  });

  // ================================================================
  // factory() / router() guards
  // ================================================================

  describe('factory()', () => {
    it('throws when factory not configured', async () => {
      const client = await SigalSwapClient.create({ wallet, senderAddress: ADDR_SENDER });
      expect(() => client.factory()).toThrow('Factory address not configured');
    });

    it('returns factory when configured', async () => {
      const client = await SigalSwapClient.create({
        wallet, senderAddress: ADDR_SENDER, factoryAddress: ADDR_FACTORY,
      });
      expect(client.factory()).toBeDefined();
    });
  });

  describe('router()', () => {
    it('throws when router not configured', async () => {
      const client = await SigalSwapClient.create({ wallet, senderAddress: ADDR_SENDER });
      expect(() => client.router()).toThrow('Router address not configured');
    });

    it('returns router when configured', async () => {
      const client = await SigalSwapClient.create({
        wallet, senderAddress: ADDR_SENDER, routerAddress: ADDR_ROUTER,
      });
      expect(client.router()).toBeDefined();
    });
  });

  // ================================================================
  // pair() / unsafePair()
  //
  // `pair()` is async and runs a factory cross-check before returning.
  // `unsafePair()` skips the check (sync, for tests/forks/known-good
  // addresses). Pairing them this way keeps the strong invariant ("if
  // you have a SigalSwapPair from `pair()`, it's verified") while
  // leaving an explicit escape hatch.
  // ================================================================

  describe('pair() / unsafePair()', () => {
    it('pair() throws SigalSwapConfigurationError when factory not configured', async () => {
      const { SigalSwapConfigurationError } = await import('./errors.js');
      const client = await SigalSwapClient.create({ wallet, senderAddress: ADDR_SENDER });
      await expect(client.pair(ADDR_PAIR)).rejects.toBeInstanceOf(SigalSwapConfigurationError);
    });

    it('pair() returns a verified wrapper when factory confirms registration', async () => {
      const client = await SigalSwapClient.create({
        wallet, senderAddress: ADDR_SENDER, factoryAddress: ADDR_FACTORY,
      });
      const wrapper = await client.pair(ADDR_PAIR);
      expect(wrapper).toBeDefined();
      expect(wrapper.address).toBe(ADDR_PAIR);
    });

    it('pair() throws SigalSwapValidationError when factory has a different address at the slot', async () => {
      const { SigalSwapFactoryContract } = await import('./artifacts/SigalSwapFactory.js');
      const { SigalSwapValidationError } = await import('./errors.js');
      vi.mocked(SigalSwapFactoryContract.at).mockReturnValueOnce({
        address: ADDR_FACTORY,
        methods: {
          get_pair_versioned: vi.fn().mockReturnValue(mockInteraction(ADDR_A)),
        },
      } as any);
      const client = await SigalSwapClient.create({
        wallet, senderAddress: ADDR_SENDER, factoryAddress: ADDR_FACTORY,
      });
      await expect(client.pair(ADDR_PAIR)).rejects.toBeInstanceOf(SigalSwapValidationError);
      await expect(client.pair(ADDR_PAIR)).rejects.toThrow(/not a registered SigalSwap pair|phishing/);
    });

    it('pair() surfaces the read failure when the pair contract reverts', async () => {
      const { SigalSwapPairContract } = await import('./artifacts/SigalSwapPair.js');
      const { SigalSwapValidationError } = await import('./errors.js');
      vi.mocked(SigalSwapPairContract.at).mockReturnValueOnce({
        address: ADDR_PAIR,
        methods: {
          get_config: vi.fn().mockReturnValue({
            simulate: vi.fn().mockRejectedValue(new Error('revert: pair self-destructed')),
          }),
        },
      } as any);
      const client = await SigalSwapClient.create({
        wallet, senderAddress: ADDR_SENDER, factoryAddress: ADDR_FACTORY,
      });
      await expect(client.pair(ADDR_PAIR)).rejects.toBeInstanceOf(SigalSwapValidationError);
    });

    it('unsafePair() returns a wrapper synchronously without any factory call', async () => {
      const { SigalSwapFactoryContract } = await import('./artifacts/SigalSwapFactory.js');
      const client = await SigalSwapClient.create({
        wallet, senderAddress: ADDR_SENDER, factoryAddress: ADDR_FACTORY,
      });
      const factoryAtCallsBefore = vi.mocked(SigalSwapFactoryContract.at).mock.calls.length;
      const wrapper = client.unsafePair(ADDR_PAIR);
      expect(wrapper).toBeDefined();
      expect(wrapper.address).toBe(ADDR_PAIR);
      // No factory contract instantiation happened on the unsafe path.
      expect(vi.mocked(SigalSwapFactoryContract.at).mock.calls.length).toBe(factoryAtCallsBefore);
    });

    it('unsafePair() works without a factory configured', async () => {
      const client = await SigalSwapClient.create({ wallet, senderAddress: ADDR_SENDER });
      // No factory; unsafePair must still return a wrapper.
      const wrapper = client.unsafePair(ADDR_PAIR);
      expect(wrapper.address).toBe(ADDR_PAIR);
    });
  });

  // ================================================================
  // verifyPair()
  // ================================================================

  describe('verifyPair()', () => {
    it('returns true when factory confirms pair address', async () => {
      const client = await SigalSwapClient.create({
        wallet, senderAddress: ADDR_SENDER, factoryAddress: ADDR_FACTORY,
      });
      const result = await client.verifyPair(ADDR_PAIR);
      expect(result).toBe(true);
    });

    it('returns false when factory returns a different address', async () => {
      const { SigalSwapFactoryContract } = await import('./artifacts/SigalSwapFactory.js');
      vi.mocked(SigalSwapFactoryContract.at).mockReturnValueOnce({
        address: ADDR_FACTORY,
        methods: {
          get_pair_versioned: vi.fn().mockReturnValue(mockInteraction(ADDR_A)), // different from ADDR_PAIR
        },
      } as any);

      const client = await SigalSwapClient.create({
        wallet, senderAddress: ADDR_SENDER, factoryAddress: ADDR_FACTORY,
      });
      const result = await client.verifyPair(ADDR_PAIR);
      expect(result).toBe(false);
    });

    it('returns true for an older registered version (verifies the version-specific slot)', async () => {
      // The pair self-reports v1; factory has BOTH v1 and v2 registered at
      // this base. verifyPair calls get_pair_versioned with the pair's
      // self-reported version, so it should return true even though
      // get_pair (latest) returns the v2 address. Without the version
      // awareness, an LP holding v1 would falsely fail verification.
      const { SigalSwapFactoryContract } = await import('./artifacts/SigalSwapFactory.js');
      vi.mocked(SigalSwapFactoryContract.at).mockReturnValueOnce({
        address: ADDR_FACTORY,
        methods: {
          get_pair: vi.fn().mockReturnValue(mockInteraction(ADDR_A)), // v2 latest -- different from input
          get_pair_versioned: vi.fn().mockReturnValue(mockInteraction(ADDR_PAIR)), // v1 slot matches input
        },
      } as any);

      const client = await SigalSwapClient.create({
        wallet, senderAddress: ADDR_SENDER, factoryAddress: ADDR_FACTORY,
      });
      expect(await client.verifyPair(ADDR_PAIR)).toBe(true);
      expect(await client.isLatestPair(ADDR_PAIR)).toBe(false); // not the latest
    });

    it('returns false when pair contract reverts', async () => {
      const { SigalSwapPairContract } = await import('./artifacts/SigalSwapPair.js');
      vi.mocked(SigalSwapPairContract.at).mockReturnValueOnce({
        address: ADDR_PAIR,
        methods: {
          get_config: vi.fn().mockReturnValue({
            simulate: vi.fn().mockRejectedValue(new Error('revert')),
          }),
        },
      } as any);

      const client = await SigalSwapClient.create({
        wallet, senderAddress: ADDR_SENDER, factoryAddress: ADDR_FACTORY,
      });
      const result = await client.verifyPair(ADDR_PAIR);
      expect(result).toBe(false);
    });
  });

  // ================================================================
  // getSwapHistory() / getLiquidityHistory()
  // ================================================================

  describe('history methods', () => {
    /**
     * Build a stub PrivateEvent record matching the
     * `Wallet.getPrivateEvents` return shape: `{ event, metadata: {
     *  l2BlockNumber, l2BlockHash, txHash } }`. Only the fields
     * `getSwapHistory`/`getLiquidityHistory` actually consume.
     */
    function makeEvent(blockNumber: number, txHash: string, eventBody: any = {}): any {
      return {
        event: eventBody,
        metadata: {
          l2BlockNumber: blockNumber,
          l2BlockHash: '0xblockhash',
          txHash: { toString: () => txHash },
        },
      };
    }

    /**
     * Wire the wallet mock so `getPrivateEvents` returns events keyed by
     * `(contractAddress, eventSelector)`. The callsite reaches the
     * callback with two args: `(eventDef, filter)` -- we route by the
     * filter's contractAddress and the eventDef.eventSelector toString.
     */
    function stubPrivateEvents(routeMap: Map<string, any[]>) {
      vi.mocked(wallet.getPrivateEvents).mockImplementation(
        async (eventDef: any, filter: any) => {
          const key = `${filter.contractAddress.toString()}|${eventDef.eventSelector?.toString?.() ?? eventDef.eventSelector}`;
          return routeMap.get(key) ?? [];
        },
      );
    }

    it('throws when router is not configured', async () => {
      const client = await SigalSwapClient.create({ wallet, senderAddress: ADDR_SENDER });
      await expect(client.getSwapHistory()).rejects.toThrow('Router address not configured');
      await expect(client.getLiquidityHistory()).rejects.toThrow('Router address not configured');
    });

    it('with no pairs and no factory returns router-only history', async () => {
      const { SigalSwapEvents } = await import('./events.js');
      stubPrivateEvents(new Map([
        [`${ADDR_ROUTER.toString()}|${SigalSwapEvents.router.RouterSwapExactInEvent.eventSelector.toString()}`,
          [makeEvent(5, '0xtx1', { token_in: ADDR_A, token_out: ADDR_B, amount_in: 100n, amount_out_min: 90n })]],
      ]));
      const client = await SigalSwapClient.create({
        wallet, senderAddress: ADDR_SENDER, routerAddress: ADDR_ROUTER,
      });
      const history = await client.getSwapHistory();
      expect(history).toHaveLength(1);
      expect(history[0]).toMatchObject({ source: 'router', direction: 'exactIn', blockNumber: 5 });
    });

    it('with explicit `pair` queries pair-side and router-side', async () => {
      const { SigalSwapEvents } = await import('./events.js');
      stubPrivateEvents(new Map([
        [`${ADDR_PAIR.toString()}|${SigalSwapEvents.pair.PrivateSwapExactInEvent.eventSelector.toString()}`,
          [makeEvent(1, '0xpa', { amount_in: 50n })]],
        [`${ADDR_ROUTER.toString()}|${SigalSwapEvents.router.RouterSwapExactInEvent.eventSelector.toString()}`,
          [makeEvent(2, '0xrt', { amount_in: 200n })]],
      ]));
      const client = await SigalSwapClient.create({
        wallet, senderAddress: ADDR_SENDER, routerAddress: ADDR_ROUTER,
      });
      const history = await client.getSwapHistory({ pair: ADDR_PAIR });
      expect(history).toHaveLength(2);
      expect(history[0]).toMatchObject({ source: 'pair', blockNumber: 1 });
      expect(history[1]).toMatchObject({ source: 'router', blockNumber: 2 });
    });

    it('with explicit `pairs` array fans out across multiple pairs', async () => {
      const { SigalSwapEvents } = await import('./events.js');
      stubPrivateEvents(new Map([
        [`${ADDR_PAIR.toString()}|${SigalSwapEvents.pair.PrivateSwapExactInEvent.eventSelector.toString()}`,
          [makeEvent(1, '0xa')]],
        [`${ADDR_PAIR_BC.toString()}|${SigalSwapEvents.pair.PrivateSwapExactInEvent.eventSelector.toString()}`,
          [makeEvent(2, '0xb')]],
      ]));
      const client = await SigalSwapClient.create({
        wallet, senderAddress: ADDR_SENDER, routerAddress: ADDR_ROUTER,
      });
      const history = await client.getSwapHistory({ pairs: [ADDR_PAIR, ADDR_PAIR_BC] });
      expect(history).toHaveLength(2);
      expect(history.map((e) => e.blockNumber)).toEqual([1, 2]);
    });

    it('auto-enumerates live pairs from factory when neither pairs nor pair supplied', async () => {
      const { SigalSwapFactoryContract } = await import('./artifacts/SigalSwapFactory.js');
      const { SigalSwapEvents } = await import('./events.js');
      // Three iterated indexed slots: 0 = ADDR_PAIR, 1 = ZERO (cleared base
      // -- skipped by resolvePairScope), 2 = ADDR_PAIR_BC. The count drives
      // iteration breadth; the zero filter then drops cleared slots.
      vi.mocked(SigalSwapFactoryContract.at).mockReturnValueOnce({
        address: ADDR_FACTORY,
        methods: {
          get_active_pair_count: vi.fn().mockReturnValue(mockInteraction(3n)),
          get_latest_pair_at_index: vi.fn().mockImplementation((i: number) =>
            mockInteraction([ADDR_PAIR, ADDR_ZERO, ADDR_PAIR_BC][i]),
          ),
        },
      } as any);
      stubPrivateEvents(new Map([
        [`${ADDR_PAIR.toString()}|${SigalSwapEvents.pair.PrivateSwapExactInEvent.eventSelector.toString()}`,
          [makeEvent(1, '0xpa')]],
        [`${ADDR_PAIR_BC.toString()}|${SigalSwapEvents.pair.PrivateSwapExactInEvent.eventSelector.toString()}`,
          [makeEvent(3, '0xpb')]],
      ]));
      const client = await SigalSwapClient.create({
        wallet, senderAddress: ADDR_SENDER,
        routerAddress: ADDR_ROUTER, factoryAddress: ADDR_FACTORY,
      });
      const history = await client.getSwapHistory();
      expect(history.map((e) => e.blockNumber).sort()).toEqual([1, 3]);
      // ZERO at index 1 should be filtered before the wallet query fires:
      // wallet.getPrivateEvents must NOT have been called with ADDR_ZERO.
      const calls = vi.mocked(wallet.getPrivateEvents).mock.calls;
      const queriedAddrs = calls.map((c: any) => c[1].contractAddress.toString());
      expect(queriedAddrs).not.toContain(ADDR_ZERO.toString());
    });

    it('skips pair-side queries when no factory and no pairs', async () => {
      const { SigalSwapEvents } = await import('./events.js');
      stubPrivateEvents(new Map([
        [`${ADDR_ROUTER.toString()}|${SigalSwapEvents.router.RouterSwapExactInEvent.eventSelector.toString()}`,
          [makeEvent(1, '0xa')]],
      ]));
      const client = await SigalSwapClient.create({
        wallet, senderAddress: ADDR_SENDER, routerAddress: ADDR_ROUTER,
      });
      const history = await client.getSwapHistory();
      expect(history).toHaveLength(1);
      // Verify wallet.getPrivateEvents was called only with router address
      const calls = vi.mocked(wallet.getPrivateEvents).mock.calls;
      const contractAddrs = calls.map((c: any) => c[1].contractAddress.toString());
      expect(contractAddrs.every((a) => a === ADDR_ROUTER.toString())).toBe(true);
    });

    it('sorts merged history by (blockNumber, txHash, source, direction)', async () => {
      const { SigalSwapEvents } = await import('./events.js');
      // Same block (5), same tx (0xabc), one pair-exactIn + one
      // router-exactIn. (source='pair') < (source='router') lexically, so
      // pair entry should come first.
      stubPrivateEvents(new Map([
        [`${ADDR_PAIR.toString()}|${SigalSwapEvents.pair.PrivateSwapExactInEvent.eventSelector.toString()}`,
          [makeEvent(5, '0xabc')]],
        [`${ADDR_ROUTER.toString()}|${SigalSwapEvents.router.RouterSwapExactInEvent.eventSelector.toString()}`,
          [makeEvent(5, '0xabc')]],
      ]));
      const client = await SigalSwapClient.create({
        wallet, senderAddress: ADDR_SENDER, routerAddress: ADDR_ROUTER,
      });
      const history = await client.getSwapHistory({ pair: ADDR_PAIR });
      expect(history.map((e) => e.source)).toEqual(['pair', 'router']);
    });

    it('preserves PXE order within a single bucket via stable sort', async () => {
      const { SigalSwapEvents } = await import('./events.js');
      // Three events from one pair-exactIn bucket, all same block, same tx
      // (e.g., a wrapper contract calling pair.swap_exact_in three times
      // atomically). The PXE returns them in (block, txIndexInBlock,
      // eventIndexInTx) order; the SDK's stable sort must preserve that
      // input order since (block, tx, source, direction) is identical.
      stubPrivateEvents(new Map([
        [`${ADDR_PAIR.toString()}|${SigalSwapEvents.pair.PrivateSwapExactInEvent.eventSelector.toString()}`,
          [
            makeEvent(7, '0xtx', { amount_in: 100n }),
            makeEvent(7, '0xtx', { amount_in: 200n }),
            makeEvent(7, '0xtx', { amount_in: 300n }),
          ]],
      ]));
      const client = await SigalSwapClient.create({
        wallet, senderAddress: ADDR_SENDER, routerAddress: ADDR_ROUTER,
      });
      const history = await client.getSwapHistory({ pair: ADDR_PAIR });
      expect(history).toHaveLength(3);
      expect(history.map((e) => (e.data as any).amount_in)).toEqual([100n, 200n, 300n]);
    });

    it('getLiquidityHistory follows the same scoping and sorting rules', async () => {
      const { SigalSwapEvents } = await import('./events.js');
      stubPrivateEvents(new Map([
        [`${ADDR_PAIR.toString()}|${SigalSwapEvents.pair.PrivateMintEvent.eventSelector.toString()}`,
          [makeEvent(2, '0xmint')]],
        [`${ADDR_PAIR.toString()}|${SigalSwapEvents.pair.PrivateBurnEvent.eventSelector.toString()}`,
          [makeEvent(3, '0xburn')]],
        [`${ADDR_ROUTER.toString()}|${SigalSwapEvents.router.RouterMintEvent.eventSelector.toString()}`,
          [makeEvent(1, '0xrmint')]],
      ]));
      const client = await SigalSwapClient.create({
        wallet, senderAddress: ADDR_SENDER, routerAddress: ADDR_ROUTER,
      });
      const history = await client.getLiquidityHistory({ pair: ADDR_PAIR });
      expect(history).toHaveLength(3);
      expect(history.map((e) => e.blockNumber)).toEqual([1, 2, 3]);
      expect(history.map((e) => e.kind)).toEqual(['mint', 'mint', 'burn']);
    });
  });
});
