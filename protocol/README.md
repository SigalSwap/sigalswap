# SigalSwap Protocol

Four Noir contracts that together implement a privacy-preserving constant-product AMM on Aztec L2. Inspired by the algorithms described in the Uniswap V2 whitepaper, reimplemented for Aztec's private execution environment.

## Contracts

```
protocol/
+-- core/           SigalSwapPair      Immutable. Holds funds, swap math, TWAP oracle.
+-- factory/        SigalSwapFactory   Governance. Pair registry, fee tiers, timelock.
+-- periphery/      SigalSwapRouter    Stateless. Multi-hop routing, deadlines, callbacks.
+-- lp-token/       SigalSwapLPToken   Private LP positions as UintNote UTXOs.
+-- test-contracts/ Test-only fixtures: flash-borrower, self-address-test,
|                   hostile-token, mock-factory, mock-pair-v2, abusive-pair.
```

### SigalSwapPair (core)

The AMM primitive. One instance per (token0, token1, fee_tier) combination. Holds both token balances and computes all swap/liquidity math. Maintains TWAP price accumulators in UQ112x112 fixed-point format.

Key properties:
- **Immutable** once deployed -- no admin functions, no upgrades
- **Private entry points** for swaps and liquidity (caller identity is unlinkable to the trade; per-tx amounts are public, like any public-reserves AMM)
- **Public entry points** for router-mediated operations and flash swaps
- **Balance-based accounting** handles fee-on-transfer tokens correctly
- **Emergency pause** blocks deposits/swaps but never blocks withdrawals

See [core/README.md](core/README.md) for full function reference and storage layout.

### SigalSwapFactory (factory)

Governance and registry. Manages the set of valid pairs, fee tier whitelist, and protocol fee configuration. All admin actions beyond emergency pause require a 48-hour timelock with a 7-day execution window.

Key properties:
- **Permissionless pair registration** with cryptographic bytecode + constructor verification
- **Timelocked governance** for fee changes, admin rotation, and class ID updates
- **Immediate pause** for emergency response (only admin action without delay)
- **Protocol fee propagation** pushes fee settings to individual pairs

See [factory/README.md](factory/README.md) for governance model and action types.

### SigalSwapRouter (periphery)

User-facing entry point. Stateless and upgradeable -- holds no funds between transactions. Provides deadline enforcement, multi-hop routing (up to 3 hops), and the optimistic callback pattern for secure token settlement.

Key properties:
- **Deadline enforcement** on every operation (prevents stale transaction execution)
- **Option A pattern** -- router transfers tokens, pair does math
- **Optimistic callback pattern** -- sends output first, then calls back for payment
- **Interface fee** -- optional frontend fee on multi-hop swaps (SDK-controlled)

See [periphery/README.md](periphery/README.md) for callback flow and multi-hop execution.

## Transaction flow

### Private swap (user calls Router)

```
User (private)
  |-- swap_exact_in(pair, tokenIn, tokenOut, amountIn, minOut, deadline, nonce)
  |   [private phase]
  |   1. Create authwit for token transfer
  |   2. Transfer tokenIn from user's private balance to Router's public balance
  |   3. Prepare partial note for tokenOut (user will receive privately)
  |   4. Enqueue public function
  |
  |   [public phase]
  |   5. Check deadline
  |   6. Set callback expectations in Router storage
  |   7. Call pair.swap_exact_in_public(tokenIn, tokenOut, amountIn, 0, router, router, callback)
  |      (router passes 0 as the pair-level min_out and enforces the user's post-fee minimum itself)
  |       a. Pair computes output
  |       b. Pair sends tokenOut to Router
  |       c. Pair calls router.swap_payment_callback(pair, tokenIn, amountIn)
  |       d. Router verifies params and transfers tokenIn to Pair
  |       e. Pair verifies payment, checks K invariant
  |   8. Router measures tokenOut balance delta
  |   9. Finalize partial note -- user receives tokenOut privately
```

### Private add liquidity (user calls Router)

```
User (private)
  |-- add_liquidity(pair, token0, token1, lp, amt0Max, amt1Max, amt0Min, amt1Min, deadline, nonce)
  |   [private phase]
  |   1. Transfer token0 and token1 from user to Router's public balance
  |   2. Prepare partial notes for refund0, refund1, and LP tokens
  |
  |   [public phase]
  |   3. Check deadline
  |   4. Router computes optimal pair-ratio amounts and pushes only those to the Pair,
  |      refunding the remainder from its own balance to the user
  |   5. Call pair.add_liquidity_public(router, amt0Min, amt1Min)
  |       a. Pair derives deposit amounts from its own balance delta
  |       b. Pair is V2-strict: it consumes the full balance delta, mints LP only for
  |          the pair-ratio-matched portion, and writes reserves to the full balances,
  |          so any off-ratio excess stays in reserves as a pro-rata gift to existing LPs
  |   6. Measure balance deltas for refunds and LP tokens
  |   7. Finalize partial notes -- user receives LP + refunds privately
```

## Building

Requires the Aztec toolchain pinned to aztec-packages v4.3.0 (nargo 1.0.0-beta.21). Contracts compile with `aztec compile`, which wraps nargo with the Aztec transpiler.

```bash
cd core && aztec compile
cd factory && aztec compile
cd periphery && aztec compile
cd lp-token && aztec compile
```

## Testing

```bash
export TXE_PORT=8180

cd lp-token  && aztec test     # 29 tests  (note auth, balances, partial-note paths, class-id probe)
cd core      && aztec test     # inline unit-test subset of 301 (lifecycle, fees, security, edge cases, fuzz, events)
cd factory   && aztec test     # inline unit-test subset of 133 (admin, governance, timelock, registry, upgrade paths)
cd periphery && aztec test     # inline unit-test subset of 63  (single/multi-hop, deadlines, interface fee, quote utilities)
```

The `cd <pkg> && aztec test` commands run only each package's inline pure unit
tests. The TXE integration tests live in the sibling `*-tests` crates
(`protocol/core-tests`, `protocol/factory-tests`, `protocol/periphery-tests`),
so those commands alone do not reproduce the full counts above. `lp-token` has
no sibling crate, so its 29 tests are complete in-crate.

Use `tools/txe/` (Docker TXE workers) for high-cycle workflows like fuzzing or
mutation testing — native TXE leaks resources that aren't released by `kill`.

## Aztec version

All four contracts target **aztec-packages v4.3.0** (aztec-nr, token contract,
uint-note). The migration from v4.1.2 absorbed the v4.2 log-tag /
init-nullifier / partial-note signature changes and adopted v4.3's typed
`Packable` storage wrappers and end-to-end cross-contract utility calls (used
by the router's multi-hop quote helpers). v4.3 stable closes the v4.1.x
`getSharedSecret` cross-contract-decryption gap (C-L6).
