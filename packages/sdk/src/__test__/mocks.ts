import { vi } from 'vitest';
import type { AztecAddress } from '@aztec/aztec.js/addresses';
import type { Wallet } from '@aztec/aztec.js/wallet';
import { ADDR_A, ADDR_B, ADDR_LP_TOKEN, ADDR_FACTORY } from './addresses.js';

/** Mock a ContractFunctionInteraction with chainable .with() and .send(). */
export function mockInteraction(simulateResult?: any) {
  const interaction: any = {
    simulate: vi.fn().mockResolvedValue({ result: simulateResult }),
    getFunctionCall: vi.fn().mockResolvedValue({ selector: '0x00' }),
    with: vi.fn().mockImplementation(function (this: any) { return this; }),
    send: vi.fn().mockResolvedValue({ receipt: {} }),
  };
  return interaction;
}

/** Mock a Wallet that manages the given address. */
export function mockWallet(managedAddress: AztecAddress): Wallet {
  return {
    getAccounts: vi.fn().mockResolvedValue([
      { item: managedAddress, alias: 'test' },
    ]),
    createAuthWit: vi.fn().mockResolvedValue({ inner: '0x00' }),
    // Stub remaining Wallet methods as no-ops
    getPrivateEvents: vi.fn(),
    getChainInfo: vi.fn(),
    getContractMetadata: vi.fn(),
    getContractClassMetadata: vi.fn(),
    registerSender: vi.fn(),
    getAddressBook: vi.fn(),
    registerContract: vi.fn(),
    simulateTx: vi.fn(),
    executeUtility: vi.fn(),
    profileTx: vi.fn(),
    sendTx: vi.fn(),
    requestCapabilities: vi.fn(),
    batch: vi.fn(),
  } as unknown as Wallet;
}

/** Default pair config result: struct with named fields (matches real PXE return) */
export const DEFAULT_PAIR_CONFIG = {
  token0: ADDR_A,
  token1: ADDR_B,
  factory: ADDR_FACTORY,
  fee_tier_bps: 25n,
  version: 1n,
  lp_token: ADDR_LP_TOKEN,
};

/** Create a mock pair contract with configurable get_config result. */
export function mockPairContract(address: AztecAddress, configResult = DEFAULT_PAIR_CONFIG) {
  const methods: Record<string, any> = {};

  // Sensible per-method defaults so helpers that compose multiple reads
  // (e.g. getMyPositionValue -> previewProtocolFeeMint) don't trip
  // undefined-tuple destructuring in tests that don't override them.
  // `get_pair_state` defaults to "fee inactive" so previewProtocolFeeMint
  // short-circuits to 0n in test setups that don't care about fees.
  const queryDefaults: Record<string, any> = {
    get_config: configResult,
    get_reserves: [0n, 0n, 0n],
    get_reserves_last: [0n, 0n],
    get_pair_state: [0n, 0n, 0n, false, 0n, false],
    get_cumulative_prices: [0n, 0n, 0n, 0n, 0n],
    get_spot_prices: [0n, 0n, 0n, 0n],
    is_paused_view: false,
    get_fee_to: ADDR_FACTORY,
    get_version: 1n,
    quote_amount_out: 0n,
    quote_amount_in: 0n,
    get_position_value: [0n, 0n],
  };
  for (const [name, defaultResult] of Object.entries(queryDefaults)) {
    methods[name] = vi.fn().mockReturnValue(mockInteraction(defaultResult));
  }
  // `get_lp_token` is still exposed by the pair (used by the factory's
  // register_pair LP-deployment check). PairConfig also carries lp_token so
  // the SDK and router can fetch it in the same merkle proof.
  methods['get_lp_token'] = vi.fn().mockReturnValue(mockInteraction(ADDR_LP_TOKEN));

  // Transaction methods
  for (const name of [
    'swap_exact_in', 'swap_exact_out',
    'swap_exact_in_public', 'swap_exact_out_public', 'flash_swap',
    'add_liquidity', 'remove_liquidity', 'skim', 'sync',
  ]) {
    methods[name] = vi.fn().mockReturnValue(mockInteraction());
  }

  return { address, methods };
}

/** Create a mock router contract. */
export function mockRouterContract(address: AztecAddress) {
  const methods: Record<string, any> = {};
  for (const name of [
    'swap_exact_in', 'swap_exact_out',
    'swap_exact_in_multi_hop', 'swap_exact_out_multi_hop',
    'add_liquidity', 'remove_liquidity', 'get_factory', 'skim_to',
  ]) {
    methods[name] = vi.fn().mockReturnValue(mockInteraction());
  }
  return { address, methods };
}

/** Create a mock factory contract. */
export function mockFactoryContract(address: AztecAddress) {
  const methods: Record<string, any> = {};
  for (const name of [
    'get_pair', 'get_pair_versioned', 'get_latest_version',
    'get_pair_count', 'get_pair_at',
    'get_indexed_base_count', 'get_active_pair_count', 'get_latest_pair_at_index',
    'get_pair_class_version',
    'is_fee_tier_allowed',
    'get_admin', 'get_fee_to', 'get_protocol_fee_config', 'is_registration_paused',
    'get_timelock', 'get_timelock_params',
  ]) {
    methods[name] = vi.fn().mockReturnValue(mockInteraction());
  }
  return { address, methods };
}

/** Create a mock token contract whose transfer methods return mock interactions. */
export function mockTokenContract() {
  return {
    methods: {
      transfer_to_public: vi.fn().mockReturnValue(mockInteraction()),
      transfer_to_public_and_prepare_private_balance_increase: vi.fn().mockReturnValue(mockInteraction()),
      // Default to 0n so getMyPositionValue's balance reads don't trip
      // undefined-result destructuring; tests that exercise the donation
      // path override this per-call.
      balance_of_public: vi.fn().mockReturnValue(mockInteraction(0n)),
    },
  };
}

/** Future deadline (1 hour from now). */
export function futureDeadline(): number {
  return Math.floor(Date.now() / 1000) + 3600;
}
