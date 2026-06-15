# @sigalswap/sdk

TypeScript SDK for integrating with SigalSwap on Aztec L2.

## Installation

```bash
npm install @sigalswap/sdk
```

**Peer dependency**: `@aztec/aztec.js` >= 4.0.0 < 5.0.0

## Building from source

Published releases include the generated contract bindings, so consumers need
nothing beyond `npm install`. Building from a clean checkout is different — the
bindings under `src/artifacts/` are generated, not committed — so generate them
first:

```bash
# 1. Compile the Noir contracts (requires the Aztec toolchain)
for c in core factory periphery lp-token; do (cd ../../protocol/$c && aztec compile); done
# 2. Generate the SDK contract bindings, then build
npm run codegen
npm run build
```

## Quick start

```typescript
import { SigalSwapClient } from '@sigalswap/sdk';

// Create client
const client = await SigalSwapClient.create({
  wallet,
  senderAddress: wallet.getAddress(),
  factoryAddress,
  routerAddress,
});

// Resolve a verified pair wrapper. `client.pair()` cross-checks the
// supplied address against the factory and rejects an unregistered or
// impersonating pair before any tx is built. For tests/forks where the
// pair isn't registered, use `client.unsafePair(addr)`.
const pair = await client.pair(pairAddress);
const { reserve0, reserve1 } = await pair.getReserves();

// Get a swap quote
const amountOut = await pair.quoteAmountOut(1000n, tokenAAddress);

// Swap via router (with deadline protection)
const deadline = Math.floor(Date.now() / 1000) + 3600; // 1 hour
await client.router().swapSingleExactIn({
  pair: pairAddress,
  tokenIn: tokenAAddress,
  tokenOut: tokenBAddress,
  amountIn: 1000n,
  amountOutMin: 900n,
  deadline,
});
```

## API reference

### SigalSwapClient

Main entry point. Manages wallet configuration and provides access to Pair, Router, and Factory.

#### Creation

```typescript
static async create(opts: {
  config?: SigalSwapConfig;
  wallet: Wallet;
  senderAddress: AztecAddress;
  factoryAddress?: AztecAddress;
  routerAddress?: AztecAddress;
}): Promise<SigalSwapClient>
```

- Validates that `senderAddress` is managed by the provided wallet
- Freezes config to prevent mutation
- `factoryAddress` and `routerAddress` are optional but required for `factory()` and `router()` calls

#### Properties

- `config: Readonly<SigalSwapConfig>` -- Frozen configuration
- `wallet: Wallet` -- Aztec wallet for signing
- `senderAddress: AztecAddress` -- Transaction sender

#### Methods

| Method | Returns | Description |
|--------|---------|-------------|
| `pair(address)` | `Promise<SigalSwapPair>` | Get a pair wrapper, verified against the factory at construction. Throws `SigalSwapConfigurationError` if no `factoryAddress` was configured; throws `SigalSwapValidationError` if the pair isn't registered at its self-reported version. The returned wrapper is safe for any subsequent swap, liquidity, or query call. |
| `unsafePair(address)` | `SigalSwapPair` | Get a pair wrapper WITHOUT a factory cross-check. Use only for tests, sandbox/fork environments, or when the pair address came from a trusted source (the result of `factory.createPair` on a just-deployed pair). Production integrators should prefer `pair()`. |
| `factory()` | `SigalSwapFactory` | Get factory wrapper (throws if not configured) |
| `router()` | `SigalSwapRouter` | Get router wrapper (throws if not configured). The router enforces the same factory cross-check on every fund-moving entry; the verification is cached per pair so repeated swaps on the same pair pay the round-trip only on the first call. |
| `verifyPair(address)` | `Promise<boolean>` | True iff the pair is registered at its self-reported `(token0, token1, feeTierBps, version)`. Returns true for older registered versions; LPs holding pre-upgrade LP can still verify. Used by `pair()` internally; surfaced here for callers that want a boolean check without a wrapper. |
| `isLatestPair(address)` | `Promise<boolean>` | True iff the pair is the *latest* registered version at its `(token0, token1, feeTierBps)` base. Use for routing UIs; use `verifyPair` for general validation. |
| `getSwapHistory({ pairs?, pair?, fromBlock?, toBlock? })` | `Promise<SwapHistoryEntry[]>` | Decrypt the sender's private swap events from both pair-direct and router-mediated paths into a unified history. Pass `pairs: AztecAddress[]` to scope pair-direct queries; `pair` is shorthand for a single-element array. Omit both to auto-enumerate live pairs from the factory (requires `factoryAddress` configured). Sorted ascending by `(blockNumber, txHash, source, direction)`. |
| `getLiquidityHistory({ pairs?, pair?, fromBlock?, toBlock? })` | `Promise<LiquidityHistoryEntry[]>` | Decrypt the sender's private mint/burn events across pair-direct and router-mediated paths into a unified history. Same scoping rules as `getSwapHistory`; sorted by `(blockNumber, txHash, source, kind)`. |

> **Pair-direct decryption requires wallet registration.** A pair address only returns events the wallet's PXE can decrypt — pairs the wallet hasn't registered (via `wallet.registerContract` or sender registration) yield empty results from that pair. Auto-enumeration over the factory is therefore cheap-but-empty for unfamiliar pairs, not wrong.
>
> **Same-tx ordering caveat.** Aztec's `Wallet.getPrivateEvents` (v4.3.0) doesn't expose the PXE's internal `eventIndexInTx`, so events from different `(source, direction)` buckets in the same tx are tiebroken lexically by `(source, direction)` rather than emission order. This affects only wrapper contracts that alternate event types in one atomic tx; direct SDK use is unaffected.

---

### SigalSwapPair

Wraps a SigalSwapPair contract. Handles authwit creation automatically.

> **Note**: Pair-level transaction methods have NO deadline enforcement. Use `SigalSwapRouter` for deadline protection.

#### Query methods (no gas cost)

```typescript
await pair.getReserves()
// { reserve0: bigint, reserve1: bigint, blockTimestampLast: bigint }

await pair.getReservesLast()
// { reserve0Last: bigint, reserve1Last: bigint }
// The K-growth baseline used to compute the next protocol-fee mint.

await pair.isPaused()
// boolean -- single-bool read of the pair's pause flag

await pair.getFeeTo()
// AztecAddress -- the recipient of this pair's protocol-fee LP mints

await pair.getPairState()
// { reserve0, reserve1, blockTimestampLast, isPaused, protocolFeePercent, protocolFeeActive }

await pair.getConfig()
// { token0, token1, lpToken, factory, feeTierBps, version }  (cached after first call)
// `lpToken` is derived by the pair from its own address; not a user-facing
// constructor argument. See `factory.createPair()` for the deploy flow.

await pair.getVersion()
// number -- the pair bytecode's compile-time VERSION global

await pair.quoteAmountOut(amountIn: bigint, tokenIn: AztecAddress)
// bigint -- expected output

await pair.quoteAmountIn(amountOut: bigint, tokenOut: AztecAddress)
// bigint -- required input

await pair.getCumulativePrices()
// { price0CumulInt, price0CumulFrac, price1CumulInt, price1CumulFrac, blockTimestampLast }

// To turn two cumulative-price samples into a TWAP, use the static helper --
// do NOT difference the integer component alone. Each accumulator is a
// UQ112x112 split value (integer + fraction / 2^112); for decimal-mismatched
// pairs (e.g. ETH/USDC) one direction's integer accumulator is permanently 0
// and the whole signal lives in the fraction, so the integer-only delta reads
// TWAP = 0. `twapBetween` reconstructs `integer * 2^112 + fraction` per sample
// before differencing and handles the field-wrap edge.
const earlier = await pair.getCumulativePrices();
// ... wait some blocks ...
const later = await pair.getCumulativePrices();
const twap = SigalSwapPair.twapBetween(earlier, later);
// { secondsElapsed, price0Scaled, price1Scaled, price0, price1 }
// *Scaled fields are UQ112x112 (price * 2^112) and keep sub-unit precision;
// price0/price1 are the floored plain ratios (0 for sub-unit directions).

await pair.getSpotPrices()
// { price0Num, price0Den, price1Num, price1Den }

await pair.getPositionValue(lpAmount: bigint, totalSupply: bigint)
// { amount0: bigint, amount1: bigint } -- value of an arbitrary LP holding

await pair.getLpBalance(owner?: AztecAddress)
// { private: bigint, public: bigint } -- owner's LP balance in both stores

await pair.getLpTotalSupply()
// bigint -- LP Token total supply

await pair.getMyPositionValue()
// { amount0: bigint, amount1: bigint } -- value of the SDK sender's full LP

await pair.previewProtocolFeeMint()
// bigint -- LP that would be minted to feeTo on the next mint/burn
// Composes getPairState + getReservesLast + getLpTotalSupply and runs
// the same formula the contract uses on-chain.
```

> **On-chain quote variant.** The pair also exposes a constrained
> `quote_amount_in_public` view used by the router for exact-output
> multi-hop derivation. Off-chain TS callers get the same number from
> `quoteAmountIn` (cheaper) -- the constrained view is for Noir-side
> integrators that want to compose with the pair from another contract;
> reach for the contract artifact directly in that case.

> **Reserves vs balances.** `getReserves`, `quoteAmountOut`, `quoteAmountIn`,
> `getSpotPrices`, and `getPositionValue(lp, totalSupply)` all read the
> pair's *stored reserves*. The pair's actual token balances can exceed
> stored reserves between liquidity events -- through donations
> (`transfer_in_public(pair, ...)` from any address) or fee-on-transfer
> residual. The contract handles those two surfaces differently:
>
> - **Swap formula** is reserve-based on the input side too. The actual
>   swap settlement reads `balance_in - reserve_in` as the effective
>   input, so a pre-existing donation in `tokenIn` makes the user receive
>   *more* than the formula reserve-quote predicts. Reserve-based quotes
>   are therefore the **conservative floor**, which is what slippage
>   protection (`amountOutMin`) needs -- a tighter balance-aware quote
>   would be invalidated by any drift between quote and execution.
> - **Burn** uses *balances* (donations and dust accrue to LP claims).
>   `getMyPositionValue` is balance-aware as a result -- it is the
>   contract-equivalent answer to "what will I receive if I burn my LP
>   right now," and reads `Token.balance_of_public(pair)` for both
>   tokens plus the pending protocol-fee dilution before computing.
> - **`getPositionValue(lp, totalSupply)`** is the lower-level reserve-
>   based formula primitive; pass arbitrary inputs for hypothetical
>   queries. Use `getMyPositionValue` for the burn-equivalent answer.
>
> If you specifically want a balance-current quote (e.g. an arbitrage bot
> deciding whether to skim donations), call
> `Token.balance_of_public(pair.address)` directly on each token contract
> -- the values are public.

#### Transaction methods

```typescript
// Swap exact input
await pair.swapExactIn({
  tokenIn: AztecAddress,
  tokenOut: AztecAddress,
  amountIn: bigint,         // exact amount to swap
  amountOutMin: bigint,     // minimum acceptable output
})

// Swap exact output
await pair.swapExactOut({
  tokenIn: AztecAddress,
  tokenOut: AztecAddress,
  amountOut: bigint,        // exact amount to receive
  amountInMax: bigint,      // maximum input willing to spend
})

// Add liquidity
await pair.addLiquidity({
  amount0Max: bigint,
  amount1Max: bigint,
  amount0Min: bigint,       // slippage protection
  amount1Min: bigint,
})

// Remove liquidity
await pair.removeLiquidity({
  liquidity: bigint,        // LP tokens to burn
  amount0Min: bigint,       // minimum token0 to receive
  amount1Min: bigint,       // minimum token1 to receive
})

// V3-style callback swaps (public). The callback contract is responsible
// for transferring `amountIn` of `tokenIn` to the pair before returning.
// No authwit creation -- the callback sources the input itself.
await pair.swapExactInPublic({
  tokenIn, tokenOut,
  amountIn, amountOutMin,
  recipient,
  callbackContract,
  callbackSelector,
})

await pair.swapExactOutPublic({
  tokenIn, tokenOut,
  amountOut, amountInMax,
  recipient,
  callbackContract,
  callbackSelector,
})

// Flash swap: borrow optimistically, run callback, repay or revert.
await pair.flashSwap({
  amount0Out: bigint,        // borrow amount of token0 (0 to skip)
  amount1Out: bigint,        // borrow amount of token1 (0 to skip)
  borrower: AztecAddress,    // callback target
  callbackSelector: FunctionSelector,
  data: Fr,                   // forwarded to the callback
})

// Recovery
await pair.skim(to: AztecAddress)   // send excess tokens to recipient (private)
await pair.sync()                    // force reserves to match balances (public)
```

---

### SigalSwapRouter

Multi-hop swaps with deadline enforcement and automatic interface fee handling.

#### Picking a deadline

Every router entry takes a `deadline` (unix seconds). The contract's `EXPIRED` assert reads the L2 block timestamp, which can lag wall-clock by seconds during normal inclusion. The SDK rejects deadlines already past wall-clock at submission time, but doesn't enforce a forward buffer — that's the caller's responsibility.

Pick deadlines at least 30 seconds in the future for typical L2 inclusion latency. Tighter bounds are valid but risk `EXPIRED` reverts on otherwise-correct txs when the L2 timestamp catches up to the deadline before the tx lands. The SDK examples below use a 1-hour buffer for headroom; production frontends should choose a value matched to their UX (a swap quote that's hours-stale carries different MEV risk than a fresh one).

#### Single-hop swaps

```typescript
const deadline = Math.floor(Date.now() / 1000) + 3600;

// Exact input
await router.swapSingleExactIn({
  pair: AztecAddress,
  tokenIn: AztecAddress,
  tokenOut: AztecAddress,
  amountIn: bigint,
  amountOutMin: bigint,
  deadline: number,         // unix timestamp
})

// Exact output
await router.swapSingleExactOut({
  pair: AztecAddress,
  tokenIn: AztecAddress,
  tokenOut: AztecAddress,
  amountOut: bigint,
  amountInMax: bigint,
  deadline: number,
})
```

#### Multi-hop swaps

```typescript
// A -> B -> C swap
await router.swapExactIn({
  path: [tokenA, tokenB, tokenC],     // token addresses in order
  pairs: [pairAB, pairBC],            // pair for each hop
  amountIn: 1000n,
  amountOutMin: 900n,
  deadline,
})

// A -> B -> C with exact output (final token must not appear earlier in path)
await router.swapExactOut({
  path: [tokenA, tokenB, tokenC],
  pairs: [pairAB, pairBC],
  amountOut: 100n,
  amountInMax: 200n,
  deadline,
})
```

- Maximum 3 hops (4 tokens in path, `MAX_HOPS = 3` constant)
- `swapExactIn` accepts cyclic paths (e.g. `[A, B, A]` for triangular arbitrage); `swapExactOut` rejects them.
- If `config.feeBips > 0` and `config.feeRecipient` is set, the interface fee is automatically injected. The contract enforces `amount_out_min` AFTER deducting the fee, so `amountOutMin` is the user's post-fee floor — no SDK-side inflation needed.

#### Liquidity (with deadline)

```typescript
await router.addLiquidity({
  pair: AztecAddress,
  amount0Max: bigint,
  amount1Max: bigint,
  amount0Min: bigint,
  amount1Min: bigint,
  deadline: number,
})

await router.removeLiquidity({
  pair: AztecAddress,
  liquidity: bigint,
  amount0Min: bigint,
  amount1Min: bigint,
  deadline: number,
})
```

Token addresses are fetched automatically from the pair's config (cached).

#### Views and recovery

```typescript
await router.getFactory()
// AztecAddress -- the factory the router was constructed against. Useful
// when only a router address is wired up and the integrator wants to
// discover the factory without a separate config field.

await router.quoteExactInMultiHop(
  path: AztecAddress[],
  pairs: AztecAddress[],
  amountIn: bigint,
)
// bigint -- expected amount of path[path.length - 1] for a swap of amountIn
// units of path[0]. Walks the entire path in one simulate call (router
// utility -> each pair's quote_amount_out utility, v4.3 cross-contract
// utility calls). Replaces the older pattern of orchestrating N per-pair
// quote calls from TypeScript. Does NOT subtract the router's interface
// fee; subtract `result * feeBips / 10_000` manually if the eventual swap
// applies one.

await router.quoteExactOutMultiHop(
  path: AztecAddress[],
  pairs: AztecAddress[],
  amountOut: bigint,
)
// bigint -- input amount of path[0] required to produce amountOut units of
// path[path.length - 1]. Walks the path backwards (router utility -> each
// pair's quote_amount_in utility). If the eventual swap applies an interface
// fee, scale up by `10_000 / (10_000 - feeBips)` before granting the authwit.

await router.skimTo(token: AztecAddress, recipient: AztecAddress)
// Sweep the router's full public balance of `token` to `recipient`.
// Permissionless on purpose: cyclic exact-in paths preserve any
// pre-existing router balance of the looped token; anyone can
// transfer-in to the router with no owner record. The contract enforces
// `hop_active == false` so this can't extract tokens held mid-swap.
```

---

### SigalSwapFactory

Pair registry and protocol configuration queries.

```typescript
const factory = client.factory();

// Pair lookup
await factory.getPair(tokenA, tokenB, 25)             // AztecAddress (zero if not found)
await factory.getPairVersioned(tokenA, tokenB, 25, 1) // AztecAddress at a specific version
await factory.getLatestVersion(tokenA, tokenB, 25)    // number (0 if no version exists)
await factory.deriveCanonicalPairAddress(wallet, tokenA, tokenB, 25)
                                                       // AztecAddress (the canonical
                                                       // address a pair would deploy to)
await factory.isPairRegistered(pair, token0, token1, 25) // boolean

// Pair enumeration (full registry, including historical versions)
await factory.getPairCount()                  // number of distinct registrations
await factory.getPairAt(i)                    // pair at registration index i

// Pair enumeration (current, by-base)
await factory.getIndexedBaseCount()           // count of distinct (tokens, fee-tier) bases
await factory.getActivePairCount()            // count of bases with a live pair
await factory.getLatestPairAtIndex(i)         // latest pair for the i-th base

// Protocol config
await factory.getPairClassVersion()                // currently blessed pair bytecode version
await factory.isFeeTierAllowed(25)                 // boolean
await factory.getAdmin()                            // AztecAddress
await factory.getFeeTo()                            // AztecAddress
await factory.getProtocolFeeConfig()                // { feeTo, percent, enabled }
await factory.isRegistrationPaused()                // boolean (only gates register_pair, not trading)

// Timelock state for queued admin actions
await factory.getTimelock(actionHash)               // bigint -- queued_at, or 0n if not queued
await factory.getTimelockParams()                   // { delay, window } in seconds
await factory.getTimelockStatus(actionHash, now?)   // typed status: not_queued | queued | executable | expired

// Deploy + register a new pair in one call. Idempotent: if any step
// landed already, subsequent calls complete the remaining steps. Two
// preflight checks (`isFeeTierAllowed` and `isRegistrationPaused`) gate
// the deploy so an unwhitelisted tier surfaces as a typed error rather
// than wasting gas on a doomed register call.
const { pair, lpToken, token0, token1 } = await factory.createPair(
  wallet, tokenA, tokenB, 25 /* fee tier bps */,
);
```

Admin/governance operations are not wrapped by the SDK. Use contract artifacts directly for admin calls.

---

## Events

SigalSwap contracts emit 39 events across four contracts (16 Pair, 5 Router, 17 Factory, 1 LP Token). The SDK exports event metadata and TypeScript types for every event; access them via `SigalSwapEvents.{pair,router,factory,lpToken}`. Note the LP Token's `LPTransfer` is a *private* (encrypted) event, not public — see the visibility column.

### Querying public events

Public events (swap amounts, reserve updates, governance actions) are visible to anyone.

```typescript
import { getPublicEvents } from '@aztec/aztec.js/events';
import { SigalSwapEvents, type SwapEventData } from '@sigalswap/sdk';

// All swaps on a pair
const { events } = await getPublicEvents<SwapEventData>(
  node,
  SigalSwapEvents.pair.SwapEvent,
  { contractAddress: pairAddress, fromBlock: 1 },
);

// Reserve updates
const { events: syncs } = await getPublicEvents<SyncEventData>(
  node,
  SigalSwapEvents.pair.SyncEvent,
  { contractAddress: pairAddress, fromBlock: 1 },
);

// New pair registrations
const { events: pairs } = await getPublicEvents<PairCreatedEventData>(
  node,
  SigalSwapEvents.factory.PairCreatedEvent,
  { contractAddress: factoryAddress, fromBlock: 1 },
);
```

### Querying private events (wallet history)

Private events are encrypted to the sender. Only the sender's wallet can decrypt them.

Swap events are split by direction. Exact-in events carry the actual input (`amount_in`); exact-out events carry the user's upper bound (`amount_in_max`) and exact output (`amount_out`). For exact-out, the actual input consumed is recoverable via the refund partial note finalized in the same tx, or by reading the public `SwapEvent`.

```typescript
import {
  SigalSwapEvents,
  type PrivateSwapExactInEventData,
  type PrivateSwapExactOutEventData,
} from '@sigalswap/sdk';

// Pair-direct swaps
const pairExactIn = await wallet.getPrivateEvents<PrivateSwapExactInEventData>(
  SigalSwapEvents.pair.PrivateSwapExactInEvent,
  { contractAddress: pairAddress, scopes: [myAddress] },
);
const pairExactOut = await wallet.getPrivateEvents<PrivateSwapExactOutEventData>(
  SigalSwapEvents.pair.PrivateSwapExactOutEvent,
  { contractAddress: pairAddress, scopes: [myAddress] },
);

// Router-mediated swaps (most common path)
const routerExactIn = await wallet.getPrivateEvents<PrivateSwapExactInEventData>(
  SigalSwapEvents.router.RouterSwapExactInEvent,
  { contractAddress: routerAddress, scopes: [myAddress] },
);
const routerExactOut = await wallet.getPrivateEvents<PrivateSwapExactOutEventData>(
  SigalSwapEvents.router.RouterSwapExactOutEvent,
  { contractAddress: routerAddress, scopes: [myAddress] },
);
```

For a unified swap-or-liquidity history without manual stitching, use
`client.getSwapHistory()` and `client.getLiquidityHistory()`.

### Event reference

| Contract | Event | Visibility | Fields |
|----------|-------|-----------|--------|
| Pair | `SwapEvent` | Public | `token_in`, `token_out`, `amount_in`, `amount_out` |
| Pair | `SwapPublicEvent` | Public | `sender`, `token_in`, `token_out`, `amount_in`, `amount_out`, `recipient` |
| Pair | `MintEvent` | Public | `amount0`, `amount1`, `liquidity` |
| Pair | `MintPublicEvent` | Public | `sender`, `amount0`, `amount1`, `liquidity` |
| Pair | `BurnEvent` | Public | `amount0`, `amount1`, `liquidity` |
| Pair | `BurnPublicEvent` | Public | `sender`, `amount0`, `amount1`, `liquidity`, `recipient` |
| Pair | `SyncEvent` | Public | `reserve0`, `reserve1` |
| Pair | `FlashSwapEvent` | Public | `borrower`, `amount0_in`, `amount1_in`, `amount0_out`, `amount1_out` |
| Pair | `ProtocolFeeMintedEvent` | Public | `fee_to`, `amount` |
| Pair | `ProtocolFeeConfigChangedEvent` | Public | `fee_to`, `percent`, `active` |
| Pair | `PairPausedEvent` | Public | (none — pair address is the emitter) |
| Pair | `PairUnpausedEvent` | Public | (none — pair address is the emitter) |
| Pair | `PrivateSwapExactInEvent` | Private | `token_in`, `token_out`, `amount_in`, `amount_out_min` |
| Pair | `PrivateSwapExactOutEvent` | Private | `token_in`, `token_out`, `amount_in_max`, `amount_out` |
| Pair | `PrivateMintEvent` | Private | `token0`, `token1`, `amount0_max`, `amount1_max` |
| Pair | `PrivateBurnEvent` | Private | `token0`, `token1`, `liquidity` |
| Router | `RouterSwapExactInEvent` | Private | `token_in`, `token_out`, `amount_in`, `amount_out_min` |
| Router | `RouterSwapExactOutEvent` | Private | `token_in`, `token_out`, `amount_in_max`, `amount_out` |
| Router | `RouterMintEvent` | Private | `token0`, `token1`, `amount0_max`, `amount1_max` |
| Router | `RouterBurnEvent` | Private | `token0`, `token1`, `liquidity` |
| Router | `RouterSkimEvent` | Public | `token`, `recipient`, `amount` |
| Factory | `PairCreatedEvent` | Public | `token0`, `token1`, `pair`, `lp_token`, `fee_tier_bps`, `version`, `pair_count` |
| Factory | `PairSlotClearedEvent` | Public | `pair`, `token0`, `token1`, `fee_tier_bps`, `cleared_version`, `new_latest_version`, `new_latest_pair` |
| Factory | `RegistrationPausedEvent` | Public | (none) |
| Factory | `RegistrationUnpausedEvent` | Public | (none) |
| Factory | `PairPausedEvent` | Public | `pair` |
| Factory | `PairUnpausedEvent` | Public | `pair` |
| Factory | `ActionQueuedEvent` | Public | `action_type`, `value`, `execute_after` |
| Factory | `ActionExecutedEvent` | Public | `action_type`, `value` |
| Factory | `ActionCancelledEvent` | Public | `action_type`, `value` |
| Factory | `AdminChangedEvent` | Public | `new_admin` |
| Factory | `FeeToChangedEvent` | Public | `new_fee_to` |
| Factory | `FeeTierAddedEvent` | Public | `tier_bps` |
| Factory | `FeeTierRemovedEvent` | Public | `tier_bps` |
| Factory | `ProtocolFeePercentChangedEvent` | Public | `new_percent` |
| Factory | `ProtocolFeeEnabledChangedEvent` | Public | `enabled` |
| Factory | `ProtocolFeeSyncedEvent` | Public | `pair` |
| Factory | `PairClassIdChangedEvent` | Public | `class_id`, `version` |
| LP Token | `LPTransfer` | Private (encrypted to `to`) | `from`, `to`, `amount` |

Private events log the user's requested parameters (actual settlement amounts are determined in public). The wallet can reconcile actual amounts by checking token balance changes, by reading the refund partial-note value, or by joining against the public `SwapEvent`.

The LP Token's event is named `LPTransfer` rather than `Transfer` to avoid a selector collision with Aztec's standard Token `Transfer` event when both contracts are imported by the same consumer (the pair contract holds token0/token1 via the Aztec Token interface and also mints LP tokens via the LP Token). Following Aztec's reference Token, `LPTransfer` is emitted **only on the private holder-to-holder `transfer` path** (encrypted to `to`); it does **not** use a zero-address mint/burn convention. Mint and burn record balance changes through the note/`public_balances` state itself and emit no `LPTransfer`. Index LP supply changes via the pair's `MintEvent` / `BurnEvent` instead.

`ActionQueuedEvent` / `ActionExecutedEvent` / `ActionCancelledEvent` carry a numeric `action_type` plus a raw `value`. Use `decodeActionValue(actionType, value)` to interpret them as typed variants.

---

## Configuration

```typescript
interface SigalSwapConfig {
  nodeUrl: string;                    // Aztec node URL (required)
  environment: 'local' | 'testnet' | 'production';
  feeRecipient?: string;             // Interface fee recipient (Aztec address)
  feeBips?: number;                   // Interface fee in basis points [0, MAX_INTERFACE_FEE_BIPS] (5% cap)
}
```

### Presets

```typescript
import { LOCAL_CONFIG, TESTNET_CONFIG, PRODUCTION_CONFIG } from '@sigalswap/sdk';

// Local development
const client = await SigalSwapClient.create({
  config: LOCAL_CONFIG,  // nodeUrl: 'http://localhost:8080', feeBips: 0
  wallet,
  senderAddress: wallet.getAddress(),
});

// Custom config with interface fee
const client = await SigalSwapClient.create({
  config: {
    nodeUrl: 'https://aztec-testnet.example.com',
    environment: 'testnet',
    feeRecipient: '0x1234...',
    feeBips: 50,  // 0.50% interface fee
  },
  wallet,
  senderAddress: wallet.getAddress(),
  factoryAddress,
  routerAddress,
});
```

### Validation rules

- `nodeUrl` must not be empty
- `feeBips` must be an integer in `[0, MAX_INTERFACE_FEE_BIPS]` (the contract caps interface fees at 5%)
- `feeRecipient` is required if `feeBips > 0`
- `feeRecipient` must be a valid Aztec address

> **No-op combo.** `{ feeBips: 0, feeRecipient: <address> }` parses successfully (the address is validated as a well-formed Aztec address) but has no on-chain effect: the router contract short-circuits when `feeBips == 0` and never transfers to `feeRecipient`. Callers that intend to enable an interface fee must set `feeBips > 0`.

---

## Constants

The SDK mirrors a handful of contract-side constants for off-chain use. A drift canary in `constants.test.ts` greps the Noir source on every `npm test`, so a contract-side change without a matching SDK update fails the suite.

```typescript
import {
  MINIMUM_LIQUIDITY,         // bigint -- 10000n; locked LP on first mint
  TIMELOCK_DELAY_SECONDS,    // bigint -- 172800n (48h); queue -> executable
  TIMELOCK_WINDOW_SECONDS,   // bigint -- 604800n (7d);  executable lifetime
  MAX_INTERFACE_FEE_BIPS,    // number -- 500;            5% cap on interface fees
  LP_TOKEN_SALT,             // Fr     -- Fr(1);          canonical deploy salt for pair + LP Token
  LP_TOKEN_CLASS_ID,         // Fr     -- compile-time LP Token class id
  CANONICAL_DEPLOY_SALT,     // Fr     -- alias for LP_TOKEN_SALT
} from '@sigalswap/sdk';
```

`LP_TOKEN_SALT` and `CANONICAL_DEPLOY_SALT` point at the same Field; both names are exposed for clarity (one mirrors the contract global, the other emphasizes the deploy-time semantics). They are kept in lockstep via a single source-of-truth definition.

---

## Slippage protection

The router and pair entry points accept `amountOutMin`, `amountInMax`, and `amount{0,1}Min` as raw bigints. The contract enforces them after the swap or deposit math runs:

| Floor / ceiling | Meaning | Contract revert if violated |
|---|---|---|
| `amountOutMin` | minimum output the user will accept on a swap | `INSUFFICIENT_OUTPUT_AMOUNT` |
| `amountInMax` | maximum input the user will pay on an exact-output swap | `EXCESSIVE_INPUT_AMOUNT` |
| `amount{0,1}Min` | minimum deposit on each leg of `add_liquidity` (the pair refunds excess above the optimal-ratio deposit) | `INSUFFICIENT_*_AMOUNT` |

Passing `0` is a valid input that disables protection — intentional for arb bots and contract integrators that handle slippage upstream. For end-user wallets, `0` is a footgun: it accepts any output the contract delivers, including whatever a sandwich attack leaves behind.

The SDK exposes three pure helpers that turn a percentage tolerance into the bigint floor/ceiling. Use these instead of computing the math inline.

```typescript
import {
  minimumAmountOut,
  maximumAmountIn,
  liquidityAmountMins,
} from '@sigalswap/sdk';

// Exact-input swap: user is OK with up to 0.5% off the quoted output.
const quotedOut = await pair.quoteAmountOut(amountIn, tokenIn);
const amountOutMin = minimumAmountOut(quotedOut, 50);   // 50 bps = 0.50%
await router.swapSingleExactIn({ pair, tokenIn, tokenOut, amountIn, amountOutMin, deadline });

// Exact-output swap: user wants exactly amountOut, willing to spend up to 0.5% more than quoted.
const quotedIn = await pair.quoteAmountIn(amountOut, tokenOut);
const amountInMax = maximumAmountIn(quotedIn, 50);
await router.swapSingleExactOut({ pair, tokenIn, tokenOut, amountOut, amountInMax, deadline });

// Add liquidity: symmetric 0.5% tolerance on both legs.
const { amount0Min, amount1Min } = liquidityAmountMins(amount0Optimal, amount1Optimal, 50);
await router.addLiquidity({ pair, amount0Desired, amount1Desired, amount0Min, amount1Min, deadline });
```

Tolerance is always in basis points (1 bp = 0.01%). Typical values:

| Tolerance | Bps | Use case |
|---|---|---|
| 0.10% | `10` | Tight; safe only for stable-pair quotes with low expected impact |
| 0.50% | `50` | Typical wallet default |
| 1.00% | `100` | Loose; thin pools or volatile pairs |
| 3.00% | `300` | Very loose; small-cap tokens or worst-case sandwich envelope |

`minimumAmountOut` rounds DOWN and `maximumAmountIn` rounds UP — both match the Uniswap-V2 SDK convention and bias the slippage envelope toward "the trade goes through" rather than failing on a 1-wei rounding difference.

See `docs/mev-considerations.md` for the broader MEV / sandwich threat model and how slippage protection fits into it.

---

## Errors

SDK errors are typed. Catch `SigalSwapError` to filter SDK-side failures from unrelated Aztec / network errors, then narrow to the specific subclass for category-based handling without pattern-matching on message text.

```typescript
import {
  SigalSwapError,
  SigalSwapValidationError,    // bad input the SDK pre-flighted off-chain
  SigalSwapConfigurationError, // SDK wired up incorrectly (bad feeBips, missing feeRecipient, etc.)
  SigalSwapDeploymentError,    // createPair partial state -- carries pairAddress / lpTokenAddress
  SigalSwapContractRevertError,// contract reverted on-chain; revertReason extracted when present
  wrapContractRevert,          // helper to wrap a contract-call promise as the typed revert error
} from '@sigalswap/sdk';

try {
  await pair.swapExactIn({ tokenIn, tokenOut, amountIn, amountOutMin });
} catch (err) {
  if (err instanceof SigalSwapValidationError) {
    // Bad arguments. Recoverable by re-asking the user.
  } else if (err instanceof SigalSwapContractRevertError) {
    // On-chain revert. err.revertReason is the contract-side assertion
    // string when extractable (e.g. "INSUFFICIENT_OUTPUT_AMOUNT"), or
    // undefined for unstructured errors. err.context names the SDK
    // operation; err.cause carries the original Aztec error for
    // diagnostics.
    if (err.revertReason === 'INSUFFICIENT_OUTPUT_AMOUNT') { /* ... */ }
  }
}
```

All consumer-facing transaction methods on `SigalSwapPair`, `SigalSwapRouter`, and `SigalSwapFactory.createPair` wrap their on-chain reverts as `SigalSwapContractRevertError`. SDK-side validation throws `SigalSwapValidationError` synchronously before any tx is built.

### Common SDK validation messages

These are surfaced as `SigalSwapValidationError`:

#### Client creation
- `"nodeUrl is required"` -- empty nodeUrl in config
- `"senderAddress is not managed by this wallet"` -- wallet doesn't control the sender

#### Pair transactions
- `"amountIn must be positive"` -- zero or negative input
- `"tokenIn and tokenOut must differ"` -- same token for both sides
- `"amount0Min must be <= amount0Max"` -- invalid slippage bounds
- `"skim recipient cannot be zero"` -- zero recipient on `pair.skim`

#### Router transactions
- `"deadline must be a positive integer"` -- invalid deadline
- `"deadline is in the past"` -- expired deadline (best-effort client check; authoritative check on-chain)
- `"Path must have at least 2 tokens"` -- empty or single-token path
- `` `Path too long (max ${MAX_HOPS + 1} tokens)` `` -- too many hops
- `"Adjacent tokens in path must differ"` -- duplicate consecutive tokens
- `` `Final token cannot appear earlier in path for exact-output ...` `` -- cyclic / hub path on exact-out (use `swapExactIn` for cyclic shapes)
- `` `feeBips must be <= ${MAX_INTERFACE_FEE_BIPS} (5% cap)` ``

#### Configuration
- `` `Factory address not configured` `` -- called `factory()` without providing address
- `` `Router address not configured` `` -- called `router()` without providing address
- `` `feeBips must be an integer in [0, ${MAX_INTERFACE_FEE_BIPS}], got ...` ``
- `` `feeBips > 0 requires a feeRecipient address` ``

---

## Building

```bash
npm run build        # tsc + copy production JSON artifacts to dist/
npm run clean        # Remove dist/
npm run codegen      # Regenerate contract artifacts from Noir ABIs
```

## Testing

```bash
npm test             # tsc --noEmit + vitest unit tests (452 tests, ~1s)
npm run typecheck    # tsc --noEmit only
npm run test:watch   # vitest watch mode
npm run test:e2e     # E2E tests (94 tests, ~minutes, needs sandbox on :8080)
```

`npm test` runs `tsc --noEmit` before `vitest run` so type drift in the SDK surface fails the suite immediately rather than only at `npm run build` time.

For `npm run test:e2e`, bring up a Docker-isolated Aztec sandbox first to avoid native TXE resource leaks (see `tools/sandbox/README.md`):

```bash
./tools/sandbox/up.sh         # boots aztec:4.3.0 on localhost:8080 (~30-60s first run)
npm run test:e2e
./tools/sandbox/down.sh       # atomic teardown via docker rm -f
```
