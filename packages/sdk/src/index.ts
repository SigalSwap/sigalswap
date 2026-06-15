// SPDX-License-Identifier: MIT
// Copyright (c) 2026 SigalSwap LLC

/**
 * @sigalswap/sdk - TypeScript SDK for SigalSwap
 *
 * Privacy-preserving AMM on Aztec L2.
 *
 * @example
 * ```typescript
 * import { SigalSwapClient } from '@sigalswap/sdk';
 *
 * const client = await SigalSwapClient.create({
 *   wallet: myWallet,
 *   senderAddress: myWallet.getAddress(),
 *   factoryAddress: deployedFactoryAddress,
 *   routerAddress: deployedRouterAddress,
 * });
 *
 * // Query a pair (the wrapper is verified against the factory at construction)
 * const pair = await client.pair(pairAddress);
 * const reserves = await pair.getReserves();
 * const quote = await pair.quoteAmountOut(1000n, tokenIn);
 *
 * // Swap through the router (multi-hop with deadline + interface fee)
 * await client.router().swapExactIn({
 *   path: [tokenA, tokenB],
 *   pairs: [pairAB],
 *   amountIn: 1000n,
 *   amountOutMin: 900n,
 *   deadline: Math.floor(Date.now() / 1000) + 3600,
 * });
 * ```
 */

// Side-effect import: warns on artifact / SDK aztec-version mismatch at module load.
import './version-check.js';

// Contract-side constants mirrored for SDK consumers (see constants.ts for source links)
export {
  MINIMUM_LIQUIDITY,
  TIMELOCK_DELAY_SECONDS,
  TIMELOCK_WINDOW_SECONDS,
  MAX_INTERFACE_FEE_BIPS,
  LP_TOKEN_SALT,
  LP_TOKEN_CLASS_ID,
} from './constants.js';

// Typed error hierarchy. Integrators `instanceof SigalSwapError` to filter
// SDK-side failures, then narrow to the specific subclass for category-based
// handling (validation vs. config vs. deployment vs. contract revert).
export {
  SigalSwapError,
  SigalSwapValidationError,
  SigalSwapConfigurationError,
  SigalSwapDeploymentError,
  SigalSwapContractRevertError,
  wrapContractRevert,
} from './errors.js';

// High-level SDK classes
export { SigalSwapClient } from './client.js';
export type { SwapHistoryEntry, LiquidityHistoryEntry } from './client.js';
export { SigalSwapPair } from './pair.js';
export { SigalSwapRouter, MAX_HOPS } from './router.js';
export { computeProtocolFeeMint } from './protocol-fee.js';
export { minimumAmountOut, maximumAmountIn, liquidityAmountMins } from './slippage.js';
export {
  SigalSwapFactory, CANONICAL_DEPLOY_SALT, ActionType, decodeActionValue,
  computeActionHash, computeSetPairClassIdParam, computeClearPairSlotParam,
  sortTokensByField,
} from './factory.js';
export type { ActionTypeId, DecodedAction, TimelockStatus } from './factory.js';

// Types
export type {
  Reserves,
  PairState,
  PairConfig,
  CumulativePrices,
  SpotPrices,
  PositionValue,
  TwapResult,
} from './pair.js';

// Configuration
export {
  LOCAL_CONFIG,
  TESTNET_CONFIG,
  PRODUCTION_CONFIG,
  validateConfig,
} from './config/index.js';
export type { SigalSwapConfig, Environment } from './config/index.js';

// Transaction result type (re-exported so consumers don't need @aztec/aztec.js internals)
export type { TxSendResultMined } from '@aztec/aztec.js/contracts';

// Events
export { SigalSwapEvents } from './events.js';
export type {
  SwapEventData,
  SwapPublicEventData,
  MintEventData,
  MintPublicEventData,
  BurnEventData,
  BurnPublicEventData,
  SyncEventData,
  FlashSwapEventData,
  ProtocolFeeMintedEventData,
  PrivateSwapExactInEventData,
  PrivateSwapExactOutEventData,
  PrivateMintEventData,
  PrivateBurnEventData,
  RouterSwapExactInEventData,
  RouterSwapExactOutEventData,
  RouterMintEventData,
  RouterBurnEventData,
  RouterSkimEventData,
  LPTransferEventData,
  PairCreatedEventData,
  PairSlotClearedEventData,
  RegistrationPausedEventData,
  RegistrationUnpausedEventData,
  FactoryPairPausedEventData,
  FactoryPairUnpausedEventData,
  ProtocolFeeSyncedEventData,
  PairPausedEventData,
  PairUnpausedEventData,
  ActionQueuedEventData,
  ActionExecutedEventData,
  ActionCancelledEventData,
  AdminChangedEventData,
  FeeToChangedEventData,
  FeeTierAddedEventData,
  ProtocolFeePercentChangedEventData,
  ProtocolFeeEnabledChangedEventData,
  ProtocolFeeConfigChangedEventData,
  FeeTierRemovedEventData,
  PairClassIdChangedEventData,
} from './events.js';

// Re-export generated contract artifacts for advanced usage. Test-fixture
// contracts (FlashBorrower, AbusivePair, MockPairV2) are intentionally NOT
// re-exported here -- their wrappers and artifacts live in src/ for
// internal E2E test use but are excluded from the published bundle via
// tsconfig + build-script filters.
export { SigalSwapPairContract, SigalSwapPairContractArtifact } from './artifacts/SigalSwapPair.js';
export { SigalSwapFactoryContract, SigalSwapFactoryContractArtifact } from './artifacts/SigalSwapFactory.js';
export { SigalSwapRouterContract, SigalSwapRouterContractArtifact } from './artifacts/SigalSwapRouter.js';
export { SigalSwapLPTokenContract, SigalSwapLPTokenContractArtifact } from './artifacts/SigalSwapLPToken.js';
export { TokenContract, TokenContractArtifact, type Transfer as TokenTransfer } from './artifacts/Token.js';
