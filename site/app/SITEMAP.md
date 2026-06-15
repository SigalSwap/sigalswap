# SigalSwap Site Plan

## Sitemap

```
/                           Landing page — hero, value props, preview swap card
│
├── /swap                   Swap interface (the core product)
│
├── /pools                  Browse all liquidity pools
│   ├── /pools/:pair        Pool detail — stats, reserves, your position
│   ├── /pools/:pair/add    Add liquidity to a specific pool
│   └── /pools/:pair/remove Remove liquidity from a specific pool
│
├── /portfolio              Your LP positions and swap history (wallet required)
│
├── /docs                   Documentation hub
│   ├── /docs/overview      What is SigalSwap
│   ├── /docs/how-it-works  Privacy model, constant product AMM basics
│   ├── /docs/getting-started Wallet setup, connecting, funding
│   ├── /docs/swapping      How to make a swap
│   ├── /docs/liquidity     Providing and removing liquidity
│   ├── /docs/fees          Fee model and tiers explained
│   └── /docs/faq           Frequently asked questions
│
├── /fees                   Fee structure — LP, protocol, UI fees and current rates
├── /ecosystem              Compatible wallets, Aztec network info, block explorer
├── /security               Audit status, risk disclaimers, responsible disclosure
│
├── /about                  The name — Sigalion story, project ethos
├── /terms                  Terms of Service
└── /privacy                Privacy Policy
```

## Pages

### 1. Landing Page `/`
The front door. Communicates what SigalSwap is and why it matters.
- Hero: headline, tagline, primary CTA ("Launch App" → /swap)
- Value props: privacy, simplicity, Aztec-native (3 cards or columns)
- How it works: simple 3-step visual (connect → swap → done, privately)
- Preview swap card (already built in prototype)
- Social proof / stats section (TVL, volume — once live)
- Footer with nav links

### 2. Swap `/swap`
The main product page. Always accessible, wallet required to execute.
- Token input (pay): amount field, token selector, balance display
- Token output (receive): estimated output, token selector
- Swap direction toggle
- Price info: exchange rate, price impact, minimum received
- Fee breakdown: LP fee, protocol fee, total
- Slippage & deadline settings (gear icon → panel)
- Privacy indicators: shield icons on private fields
- Swap button (or "Connect Wallet" if not connected)
- Transaction status toast on submit

### 3. Pools `/pools`
Browse and manage liquidity positions.
- **Pool list** `/pools`: table/grid of all pairs — token pair, TVL, volume (24h), fee tier, your liquidity (if connected)
- **Pool detail** `/pools/:pair`: full stats for a pair — reserves, price, volume chart, fee earnings, your position breakdown
- **Add liquidity** `/pools/:pair/add`: two token inputs, price range display, share of pool estimate, add button
- **Remove liquidity** `/pools/:pair/remove`: LP amount slider/input, estimated token outputs, remove button

### 4. Portfolio `/portfolio`
Personal dashboard. Requires wallet connection.
- Your LP positions: list of pairs, your share, current value, fees earned
- Recent swaps: transaction history with amounts, timestamps, status
- Total value summary

### 5. Docs `/docs/*`
User-facing explanations. Written as normal website pages (not a docs engine).
Each page has a sidebar nav linking to all doc pages.

| Route | Content |
|-------|---------|
| `/docs/overview` | What is SigalSwap, why privacy matters, how it's different |
| `/docs/how-it-works` | Privacy model (private notes, nullifiers in plain english), constant product AMM, what's public vs private |
| `/docs/getting-started` | Install Aztec wallet, connect to SigalSwap, get testnet tokens |
| `/docs/swapping` | Step-by-step swap walkthrough, slippage, deadlines, what "private swap" means |
| `/docs/liquidity` | Why provide liquidity, how to add/remove, impermanent loss basics, fee earnings |
| `/docs/fees` | Fee tiers, LP fee vs protocol fee, how the additive model works |
| `/docs/faq` | Common questions: is it safe, what if Aztec goes down, how is this different from Uniswap, etc. |

### 6. Fees `/fees`
Transparent breakdown of every fee a user might encounter.
- LP fee: tier-based (0.05%, 0.25%, 1.00%) — goes entirely to liquidity providers
- Protocol fee: percentage markup on LP fee — goes to protocol treasury
- UI fee: whether the frontend charges anything (and if so, how much)
- Current state of each: which tiers are active, current protocol fee percentage
- Table showing what the trader actually pays at each tier
- Comparison to other DEXes for context
- Updated dynamically from on-chain state once SDK is wired up

### 7. Ecosystem `/ecosystem`
Everything a user needs to get connected and oriented.
- **Wallets**: compatible Aztec wallets with links, install instructions, brief descriptions
- **Network info**: Aztec L2 details — chain ID, RPC endpoints, block explorer links
- **Status**: current network health, whether the protocol is live/testnet
- **Resources**: links to Aztec docs, faucets for testnet tokens

### 8. Security `/security`
Honest accounting of the protocol's security posture.
- Audit status (audited / unaudited / in progress)
- What has been reviewed and by whom
- Known risks and limitations (alpha network, unaudited contracts, etc.)
- Responsible disclosure: how to report vulnerabilities, contact info
- Smart contract addresses (once deployed)
- Link to GitHub source code

### 9. About `/about`
The Sigalion story (content exists in Name.md). A standalone page with
the narrative, possibly with a subtle illustration or icon of Harpocrates.
This is a brand differentiator — most DEXes don't have a story like this.

### 10. Terms `/terms`
Render existing Terms of Service content (site/TERMS_OF_SERVICE.md) as a
styled page. Clean typography, readable layout.

### 11. Privacy `/privacy`
Render existing Privacy Policy content (site/PRIVACY_POLICY.md) as a
styled page. Especially important for a privacy-focused protocol.

## Shared Components

### Layout Shell
- **Header**: logo + name, main nav (Swap, Pools, Portfolio, Docs), wallet button
- **Footer**: nav links (About, Fees, Ecosystem, Security, Terms, Privacy), community links (Discord, X, GitHub), copyright, Sigalion tagline
- Persistent across all pages via React Router outlet

### Wallet Connection
- Connect button in header → modal with wallet options
- Connected state: truncated address, disconnect option
- Required-wallet gate for Portfolio and transaction execution

### Token Selector
- Modal triggered from swap/liquidity inputs
- Search by name or address
- Token list with icons, names, balances
- Warning for unverified tokens

### Transaction Notifications
- Toast/notification system for pending, confirmed, failed transactions
- Persistent across page navigation

### Settings Panel
- Slippage tolerance (0.1%, 0.5%, 1.0%, custom)
- Transaction deadline
- Accessible from swap and liquidity pages via gear icon

### Privacy Indicators
- Shield icon next to private fields (LP positions, wallet identity); amounts and reserves shown as public
- Lock icon on swap card
- "Private" badge where relevant
- Consistent visual language across all pages

## Build Order

| Phase | What | Why first |
|-------|------|-----------|
| 1 | Layout shell (header, footer, nav) | Foundation for every page |
| 2 | Swap page | Core product, highest user value |
| 3 | Pool pages (list, detail, add, remove) | Second-most important feature |
| 4 | Portfolio page | Completes the core app experience |
| 5 | Landing page polish | Refine hero, add value props, how-it-works |
| 6 | Fees, Ecosystem, Security pages | Transparency & trust pages |
| 7 | About page | Quick win — content already written |
| 8 | Docs pages | User-facing guides and explanations |
| 9 | Legal pages (Terms, Privacy) | Content exists, just needs rendering |

## Future Phases (blocked on external dependencies)

### Phase 10: Cross-Chain Swap (Integrated Bridge)

**Status**: Blocked — no canonical token portals exist for common tokens on Aztec yet.

**Goal**: Users with tokens on Ethereum L1 can swap directly into Aztec L2 tokens
without ever thinking about "bridging." The swap page handles everything seamlessly.

**Dependencies**:
- Third-party token portals deployed for common tokens (ETH, USDC, DAI, etc.)
  - Monitoring: Wormhole, TRAIN, Substance Labs, human.tech
  - SigalSwap will NOT deploy its own portals — we interact with existing ones only
- Published, stable contract addresses for those portals
- Aztec v5 (July 2026) — fixes critical proving system vulnerability

**What to build when unblocked**:
1. **Dual wallet connection** — L1 wallet (MetaMask/WalletConnect) + Aztec wallet side by side
2. **Token selector network badges** — "ETH on Ethereum" vs "ETH on Aztec", show L1 + L2 balances
3. **Cross-chain swap detection** — if input is L1 and output is L2, route through bridge automatically
4. **SDK bridge functions** — `depositToAztec()`, `bridgeAndSwap()` composing portal + swap
5. **Progress stepper UI** — "Locking on Ethereum..." → "Bridging to Aztec (~60s)..." → "Swapping..." → "Done"
6. **Price quoting** — include L1 gas + bridge latency + L2 swap fees in the breakdown
7. **Error handling** — L1 tx fails, bridge times out, L2 swap fails after bridge

**Design principle**: The user never sees a "bridge" page. They pick tokens, pick amounts,
and SigalSwap figures out the routing. Cross-chain is just another path, like multi-hop.

**What we can build now** (no dependencies):
- UI mockups / design for the cross-chain flow
- Dual wallet connection component
- Progress stepper component
- Network badge on token selector
