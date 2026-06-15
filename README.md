# SigalSwap

A privacy-preserving Automated Market Maker (AMM) for [Aztec](https://aztec.network/) L2. Based on the constant-product algorithms described in the [Uniswap V2 whitepaper](https://uniswap.org/whitepaper.pdf), reimplemented in [Noir](https://noir-lang.org/) with privacy as a first-class feature.

The name derives from Sigalion, an epithet of Harpocrates -- the Greco-Roman god of silence and confidentiality.

> **Status: in development.** Contracts and SDK are written, tested, and open source; mainnet deployment is pending audit and funding. Nothing here is live yet -- this repo is the design and reference implementation, not a deployed protocol.

## What makes it different

On Ethereum, every swap ties a specific wallet address to a specific trade -- your entire trading history becomes searchable forever. On Aztec, SigalSwap severs that link: your identity isn't tied to your swaps, and your LP positions stay private, while pool reserves remain transparent for price discovery.

| Data | Visibility | Why |
|------|-----------|-----|
| Reserves | Public | Price discovery and K invariant verification |
| Total LP supply | Public | Mint/burn calculations |
| Swap caller identity | **Private** | No wallet-to-trade linkage |
| Swap amounts | Public per-tx | Inherent to a public-reserves AMM (derivable from reserve deltas). Unlinkability from caller identity is the privacy guarantee. |
| LP positions | **Private** | Hide who provides liquidity and how much |

## Why it matters

### What identity privacy gives you

SigalSwap's core property is that **your wallet identity is never linked on-chain to the trades you make.** Per-swap amounts and pool reserves remain public (necessary for price discovery in a public-reserves AMM), but the wallet-to-trade link is severed. This breaks a specific class of attacks and surveillance patterns that depend on tracking wallets over time:

**No wallet tracking.** On Ethereum, anyone can follow a wallet across protocols and time. Block explorers, on-chain analytics services (Arkham, Nansen, Chainalysis), and competitor traders all build profiles by linking trades to wallet addresses. On SigalSwap, no observer can link a swap to your wallet, so there is no SigalSwap activity in your wallet's public profile.

**No wallet-targeted attacks.** Some MEV strategies on Ethereum aren't generic -- they target specific known wallets (whale-hunting, copy-trading, dev-wallet sniping). Those patterns rely on identifying the wallet first, then attacking. With wallet identity hidden, attackers can't pre-select targets by who you are; they can only react to swap economics in real time, like every other participant.

**No future-leak surface.** If your wallet is ever linked to your identity later -- through a phishing site, a CEX deposit, an unrelated mistake -- your past public-DEX trades are immediately deanonymized. With SigalSwap, that linkage doesn't exist on-chain. Trades you make today don't become future evidence if your wallet is later identified.

### What identity privacy does NOT do

Identity privacy does **not** hide per-swap amounts or reserve updates. Public-reserves AMM design requires those to be on-chain in cleartext. Sandwich and frontrunning attacks based on amount visibility are mechanically possible -- bounded by user slippage tolerance, and constrained on Aztec today by the absence of an MEV-bot economy (no MEV-Boost / builder-searcher pipeline exists on Aztec). See [`docs/mev-considerations.md`](docs/mev-considerations.md) for the full threat analysis.

### What Aztec gives us

These properties SigalSwap inherits from Aztec rather than implements itself. They constrain MEV opportunistically rather than structurally:

| Property | What it means |
|---|---|
| **Private execution** | Wallet identity and authwit consumption are hidden inside ZK proofs |
| **Random sequencer selection** | Fernet protocol selects each slot's block proposer via VRF over L1 RANDAO |
| **Decentralized sequencer set** | ~3,400+ validators across 5+ continents on Ignition mainnet, no single party controls ordering |
| **Committee attestation** | Blocks require 2/3+1 supermajority signatures |
| **No MEV-Boost / builder-searcher pipeline** | Aztec rejected enshrined MEV markets (the B52 proposal); no infrastructure for organized MEV extraction exists today |

These are real benefits but they're Aztec's, not SigalSwap's -- a hypothetical second AMM on Aztec inherits the same.

### Privacy for liquidity providers

This is a SigalSwap-specific property, not an Aztec inheritance. Large LPs on public chains advertise their positions to the world: competitors see your strategy, adversaries target your positions, anyone can profile your wallet's full DeFi history. SigalSwap stores LP positions as private notes -- nobody sees which positions are yours, how much you've deposited, or what your share is.

### Composability

SigalSwap is private by default, public on request. The protocol supports flash swaps, multi-hop routing, TWAP oracles, and public-direct entry points that arbitrage bots, lending protocols, and other contracts can call without going through the privacy buffer. Other protocols can import SigalSwap as a Noir library and call it directly -- same integration patterns developers already know.

## Architecture

```
                         Users / dApps
                              |
                     @sigalswap/sdk (TypeScript)
                              |
                   +----------+----------+
                   |                     |
             SigalSwapRouter       SigalSwapFactory
             (periphery)          (governance, registry)
                   |                     |
              SigalSwapPair ---- registered & verified
                (core)
                   |
            Token0    Token1    LiquidityToken
```

**Core (Pair)** -- Immutable contract that holds funds. Implements constant-product swap math, TWAP oracle, flash swaps, and the protocol fee mechanism. One pair per token-pair-fee-tier combination.

**Factory** -- Pair registry with governance. Manages fee tiers, protocol fee settings, and emergency pause. All admin actions beyond pause/unpause require a 48-hour timelock.

**Router (Periphery)** -- Stateless, upgradeable entry point. Provides deadline enforcement, multi-hop routing (up to 3 hops), and the optimistic callback pattern for secure token settlement.

**SDK** -- TypeScript client library (`@sigalswap/sdk`) for dApp integration. Wraps contract interactions, handles authwit creation, and provides query helpers.

## Features

| Feature | Status |
|---------|--------|
| Constant-product AMM (x * y = k) | Complete |
| Identity-private swaps (exact input and exact output) | Complete |
| Private LP positions (add/remove liquidity) | Complete |
| Public swap and liquidity (router-mediated) | Complete |
| Protocol fee (additive markup on LP fee) | Complete |
| Flash swaps (atomic with synchronous callback) | Complete |
| Multi-hop routing (up to 3 hops) | Complete |
| TWAP oracle (UQ112x112 price accumulators) | Complete |
| Fee-on-transfer token support | Complete |
| Emergency pause (withdrawals always allowed) | Complete |
| 48-hour timelocked governance | Complete |
| Interface fee (SDK-controlled, for frontends) | Complete |
| TypeScript SDK with full API coverage | Complete |

**Not applicable on Aztec**: WETH/ETH handling, EIP-2612 Permit

**Deferred potential features**: Hooks, flash accounting, enhanced oracles, singleton architecture

## Fee model

SigalSwap uses an **additive proportional protocol fee** -- the protocol fee is added on top of the LP fee, not carved out of it. LPs always get 100% of their fee tier.

| Tier | LP gets | Protocol gets (at 20%) | Trader pays |
|------|---------|------------------------|-------------|
| 0.05% | 0.05% | 0.01% | 0.06% |
| 0.25% | 0.25% | 0.05% | 0.30% |
| 1.00% | 1.00% | 0.20% | 1.20% |

Default fee tiers: 5 bps (0.05%), 25 bps (0.25%), 100 bps (1.00%). Admin can add/remove tiers via timelocked governance.

## Project structure

```
SigalSwap/
+-- protocol/
|   +-- core/           # SigalSwapPair contract (Noir)
|   +-- factory/        # SigalSwapFactory contract (Noir)
|   +-- periphery/      # SigalSwapRouter contract (Noir)
+-- packages/
|   +-- sdk/            # @sigalswap/sdk (TypeScript)
+-- site/
|   +-- app/            # Web frontend (full dApp)
|   +-- prelaunch/      # Pre-launch site
+-- docs/               # Documentation site
```

## Documentation

| Document | Description |
|----------|-------------|
| [protocol/core/README.md](protocol/core/README.md) | Pair contract: functions, storage, fee model, TWAP, authwits |
| [protocol/factory/README.md](protocol/factory/README.md) | Factory contract: pair registration, governance, fee tiers |
| [protocol/periphery/README.md](protocol/periphery/README.md) | Router contract: multi-hop, deadlines, callback pattern |
| [packages/sdk/README.md](packages/sdk/README.md) | SDK: installation, quick start, full API reference |

## Integration

### As a Noir dependency

Other Aztec contracts can import SigalSwap directly:

```toml
[dependencies]
sigalswap_core = { git = "https://github.com/user/SigalSwap", tag = "v1.0.0", directory = "protocol/core" }
```

```noir
use dep::sigalswap_core::SigalSwapPair;

SigalSwapPair::at(pair_address).swap_exact_in_public(
    token_in, token_out, amount_in, min_out,
    recipient, callback_contract, callback_selector
).call(&mut context);
```

### As a TypeScript SDK

```bash
npm install @sigalswap/sdk
```

```typescript
import { SigalSwapClient } from '@sigalswap/sdk';

const client = await SigalSwapClient.create({
  wallet,
  senderAddress: wallet.getAddress(),
  factoryAddress,
  routerAddress,
});

// Query reserves
const pair = client.pair(pairAddress);
const { reserve0, reserve1 } = await pair.getReserves();

// Swap with deadline protection
const deadline = Math.floor(Date.now() / 1000) + 3600;
await client.router().swapSingleExactIn({
  pair: pairAddress,
  tokenIn: tokenA,
  tokenOut: tokenB,
  amountIn: 1000n,
  amountOutMin: 900n,
  deadline,
});
```

## Building

**Prerequisites**: [Nargo](https://noir-lang.org/docs/getting_started/installation/) (Noir compiler, 1.0.0-beta.21 — shipped with Aztec v4.3.0), [Node.js](https://nodejs.org/) (v18+)

```bash
# Compile contracts (test-contracts then app contracts; lp-token first because core derives from it)
cd protocol/test-contracts/flash-borrower && aztec compile
cd protocol/test-contracts/self-address-test && aztec compile
cd protocol/test-contracts/mock-factory && aztec compile
cd protocol/test-contracts/mock-pair-v2 && aztec compile
cd protocol/test-contracts/abusive-pair && aztec compile
cd protocol/test-contracts/hostile-token && aztec compile
cd protocol/lp-token && aztec compile
cd protocol/core && aztec compile
cd protocol/factory && aztec compile
cd protocol/periphery && aztec compile

# Stage external artifacts into each package's target/ (Token, cross-package deps)
bash tools/stage-test-artifacts.sh

# Build SDK
cd packages/sdk && npm install && npm run build
```

## Testing

```bash
# Contract tests (TXE is embedded by `aztec test`; --test-threads 1 is set internally)
# Each production crate holds inline unit tests; the sibling *-tests crates hold
# the TXE integration suites.
export TXE_PORT=8180
cd protocol/lp-token && aztec test
cd protocol/core && aztec test
cd protocol/factory && aztec test
cd protocol/periphery && aztec test
cd protocol/core-tests && aztec test
cd protocol/factory-tests && aztec test
cd protocol/periphery-tests && aztec test

# SDK unit + property tests (vitest)
cd packages/sdk && npm test

# SDK E2E tests against a Docker-isolated sandbox (avoids native TXE resource
# leakage — see tools/sandbox/README.md)
./tools/sandbox/up.sh
cd packages/sdk && npm run test:e2e
./tools/sandbox/down.sh

# Noir fuzz harnesses (run against Docker TXE workers — see tools/txe/README.md)
./tools/txe/up.sh
cd protocol/core-tests && nargo fuzz --oracle-resolver http://127.0.0.1:8181
./tools/txe/down.sh

# Bytecode budget check (fails if any contract's public_dispatch exceeds 2500 fields)
bash tools/bytecode-budget.sh
```

1,088 tests pass across all layers: 526 TXE (301 core + 133 factory + 63 periphery + 29 lp-token), 452 SDK unit/property, 94 E2E, 16 Noir fuzz harnesses.

## Target platform

- **Aztec**: v4.3.0 (aztec-packages)
- **Noir**: >=1.0.0-beta.21 (aztec-nr compiler)
- **Network**: Aztec L2 (Ignition mainnet live as of November 2025; SigalSwap deployment pending audit)

## License

See individual package directories for license information.
