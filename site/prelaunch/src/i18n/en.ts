// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 SigalSwap LLC

const en = {
  common: {
    appName: "SigalSwap",
    public: "Public",
    private: "Private",
    skipToContent: "Skip to main content",
    close: "Close",
  },

  nav: {
    docs: "Docs",
    builders: "Builders",
    security: "Security",
    about: "About",
    openMenu: "Open menu",
    homeLink: "{{app}} home",
    mainNavLabel: "Main navigation",
    mobileNavLabel: "Mobile navigation",
    footerNavLabel: "Footer navigation",
  },

  footer: {
    resources: "Resources",
    community: "Community",
    twitter: "X / Twitter",
    github: "GitHub",
    tagline: "SigalSwap — named for Sigalion, the god of silence",
  },

  home: {
    heroTitle: "Trade privately.",
    heroSubtitle:
      "A privacy-preserving AMM on Aztec. Your wallet, your positions, and your trading history stay yours. Silence is sovereignty.",
    // Value props
    whySigalSwap: "What SigalSwap gives you",
    propSandwichTitle: "Your wallet stays yours",
    propSandwichBody: "Swap without publishing your wallet address. Block explorers and on-chain analytics tools can't link a SigalSwap trade back to the wallet that made it.",
    propFrontrunTitle: "Your trading history is yours alone",
    propFrontrunBody: "Every operation emits a private event readable only by you. No public chronicle of every swap you've ever made.",
    propLPTitle: "Private LP positions",
    propLPBody: "Your liquidity is stored as private notes. No one sees which positions are yours, how much you've deposited, or what your share is.",
    propComposableTitle: "Built to compose",
    propComposableBody: "Flash swaps, multi-hop routing, TWAP oracle, public-direct entries for arb bots and contracts. Private by default, public on request.",
    // Public vs private
    publicVsPrivate: "What's public, what's private",
    publicLabel: "Public",
    privateLabel: "Private",
    publicReserves: "Pool reserves and per-swap amounts",
    publicSupply: "Total LP supply",
    publicFees: "Fee tiers and parameters",
    privateSwaps: "Your wallet identity",
    privatePositions: "Your LP positions",
    privateHistory: "Your trading history",
    // How privacy works
    howItWorks: "How privacy works",
    step1Title: "Private execution",
    step1Body: "Your transaction is computed locally on your device. The network sees a proof — not your wallet address, not the path your funds took to get there.",
    step2Title: "Public settlement",
    step2Body: "The trade settles on Aztec like any AMM. Reserves update and amounts appear in events. Your wallet identity does not.",
    step3Title: "Privacy by default",
    step3Body: "No special routes, no opt-in. Use the SDK or call the contracts directly — every user-facing entry point is identity-private.",
    // Learn more
    learnMoreBody: "Read the design, the privacy model, and how SigalSwap fits into the Aztec ecosystem.",
    learnMoreLink: "Read the docs",
    // Bottom CTA (pre-launch)
    ctaTitle: "In development. Open source.",
    ctaBody: "Source code on GitHub. Follow along, or get in touch about integrations and partnerships.",
    ctaButton: "Read the docs",
  },

  docs: {
    title: "Documentation",
    sidebar: "Documentation navigation",
    overview: "Overview",
    howItWorks: "How it works",
    liquidity: "Liquidity",
    feesDoc: "Fees",
    faq: "FAQ",
    // Overview
    overviewTitle: "What is SigalSwap?",
    overviewIntro: "SigalSwap is a privacy-preserving automated market maker (AMM) being built for Aztec, a privacy-focused Layer 2 on Ethereum. The protocol is in development; the source code is open and the design is documented below. On Ethereum, every swap publicly ties a specific wallet to a specific trade — your trading history becomes a permanent, searchable record. SigalSwap severs the wallet-to-trade link: your identity isn't tied to your swaps, and your LP positions stay private, while pool reserves and per-swap amounts remain transparent for price discovery.",
    overviewProtection: "What identity privacy gives you",
    overviewProtectionIntro: "SigalSwap's core property is that your wallet identity is never linked on-chain to the trades you make. This breaks a specific class of attacks and surveillance patterns that depend on tracking wallets over time.",
    overviewSandwich: "No wallet tracking",
    overviewSandwichBody: "On Ethereum, anyone can follow a wallet across protocols and time. Block explorers, on-chain analytics services (Arkham, Nansen, Chainalysis), and competitor traders all build profiles by linking trades to wallet addresses. On SigalSwap, no observer can link a swap to your wallet, so there is no SigalSwap activity in your wallet's public profile.",
    overviewFrontrun: "No wallet-targeted attacks",
    overviewFrontrunBody: "Some MEV strategies on Ethereum aren't generic — they target specific known wallets (whale-hunting, copy-trading, dev-wallet sniping). Those patterns rely on identifying the wallet first, then attacking. With wallet identity hidden, attackers can't pre-select targets by who you are; they can only react to swap economics in real time, like every other participant.",
    overviewJIT: "No future-leak surface",
    overviewJITBody: "If your wallet is ever linked to your identity later — through a phishing site, a CEX deposit, an unrelated mistake — your past public-DEX trades are immediately deanonymized. With SigalSwap, that linkage doesn't exist on-chain. Trades you make today don't become future evidence if your wallet is later identified.",
    overviewLevelField: "What identity privacy does NOT do: it does not hide per-swap amounts or reserve updates. Public-reserves AMM design requires those to be on-chain in cleartext. Sandwich and frontrunning attacks based on amount visibility are mechanically possible — bounded by user slippage tolerance. The Aztec mempool is fee-ordered, so fee-bid sandwich positioning works today without a Flashbots-style bundle market; Aztec-side searcher tooling just hasn't been built yet, which is an eroding operational friction, not a structural defense. See the MEV considerations doc for the full analysis.",
    overviewLPPrivacy: "Privacy for liquidity providers",
    overviewLPPrivacyBody: "Large LPs on public chains advertise their positions to the world. Competitors can see your strategy, adversaries can target your positions, and anyone can profile your wallet's full DeFi history. SigalSwap stores LP positions as private notes — nobody knows which positions are yours or how much you hold.",
    overviewComposability: "Composability",
    overviewComposabilityBody: "SigalSwap is private by default, public on request. The protocol supports flash swaps, multi-hop routing, TWAP oracles, and public-direct entry points that arbitrage bots, lending protocols, and other contracts can call without going through the privacy buffer. Other protocols can import SigalSwap as a Noir library and call it directly — same integration patterns developers already know.",
    overviewDefense: "What Aztec gives us",
    overviewDefensePrivate: "Private execution — wallet identity and authwit consumption are hidden inside ZK proofs",
    overviewDefenseSequencer: "Random sequencer selection — Fernet protocol uses VRF over L1 RANDAO per slot",
    overviewDefenseDecentralized: "Decentralized sequencer set — ~3,400+ validators on Ignition mainnet, no single party controls ordering",
    overviewDefenseAttestation: "Committee attestation — blocks require two-thirds-plus-one supermajority signatures",
    overviewDefenseNoMEV: "No MEV-Boost / builder-searcher pipeline on Aztec today — but the fee-ordered public mempool already enables fee-bid sandwich positioning without one, so this is not by itself a structural defense",
    overviewDefenseFooter: "These are properties SigalSwap inherits from Aztec, not implemented by it. They block some attack classes (multi-block MEV planning, single-party ordering capture) but do not close the fee-bid sandwich vector — Aztec's mempool is fee-ordered, so amount-based sandwich attacks remain mechanically possible whenever Aztec-side searcher tooling materializes.",
    overviewHow: "How it's built",
    overviewHowBody: "SigalSwap implements the constant-product AMM algorithm (x × y = k) in Noir, the programming language for Aztec contracts. Private entry points run inside the user's PXE; public continuations update reserves on-chain. The math is the same well-understood model used by Uniswap V2; the privacy is in the execution model.",
    // How it works
    howItWorksTitle: "How SigalSwap works",
    howPublicVsPrivate: "What's public, what's private",
    howPublicReserves: "Pool reserves — needed for price discovery and the constant product invariant",
    howPublicSupply: "Total LP token supply — needed for mint/burn calculations",
    howPublicFees: "Fee tiers and protocol parameters",
    howPrivateSwaps: "Your wallet identity — no observer can link a trade to your address",
    howPrivateLP: "LP positions — your liquidity contribution is a private note",
    howPrivateHistory: "Your trading history — no wallet tracking or activity profiling",
    howAMMTitle: "The constant product AMM",
    howAMMBody: "SigalSwap uses the constant product formula, x × y = k. Every pool holds reserves of two tokens. When you swap, you add one token and remove the other, keeping the product of reserves constant (minus fees). The price you get depends on the ratio of reserves — larger trades relative to pool size move the price more.",
    howPrivacyTitle: "The privacy model",
    howPrivacyBody: "Aztec uses a UTXO-based note system similar to Zcash. When you provide liquidity, you receive private LP notes that only you can decrypt. When you swap, your wallet identity stays hidden inside a zero-knowledge proof — the contract verifies your call without learning who you are. The swap amounts themselves settle against the pool's public reserves and are visible on-chain; a public-reserves AMM requires this. What stays private is the link between you and the trade, not the trade's size. Nullifiers prevent double-spending without exposing which notes were consumed.",
    // Liquidity
    liquidityTitle: "Providing liquidity",
    liquidityIntro: "Liquidity providers deposit token pairs into pools and earn fees from every swap.",
    liquidityHow: "How it works",
    liquidityHowBody: "When you add liquidity, you deposit both tokens in a pool at the current price ratio. In return, you receive LP tokens representing your share of the pool. As traders swap, they pay fees that accumulate in the pool, increasing the value of your LP tokens over time.",
    liquidityAdd: "Adding liquidity",
    liquidityAddBody: "Adding liquidity deposits both tokens at the pool's current ratio. The pair contract reads the actual balance delta from the deposits, returns LP tokens for the matched portion, and refunds any excess on the over-deposited side. The protocol enforces caller-supplied minimums on both legs so the deposit fails cleanly if the ratio has moved beyond the caller's tolerance.",
    liquidityRemove: "Removing liquidity",
    liquidityRemoveBody: "Removing liquidity burns LP tokens and returns the corresponding share of both reserves. The contract enforces caller-supplied minimums on each token so the burn fails cleanly if the share has shifted beyond the caller's tolerance.",
    liquidityIL: "Impermanent loss",
    liquidityILBody: "If the relative price of the two tokens changes after you deposit, you may end up with less value than if you had simply held the tokens. This is called impermanent loss. It's \"impermanent\" because if the price returns to the original ratio, the loss disappears. Fee earnings can offset impermanent loss, but it's important to understand the risk before providing liquidity.",
    liquidityPrivacy: "LP position privacy",
    liquidityPrivacyBody: "Your LP tokens are stored as private notes on Aztec. No one else can see how much liquidity you've provided, which pools you're in, or what fees you've earned. Only you can view and manage your positions.",
    // Fees doc
    feesDocTitle: "Understanding fees",
    feesDocIntro: "SigalSwap uses a transparent, additive fee model. Here's how it works.",
    feesDocLP: "LP fee",
    feesDocLPBody: "The LP fee is paid by the trader on every swap and goes entirely to the liquidity providers in that pool. The rate depends on the pool's fee tier — lower tiers for stable pairs, higher tiers for volatile pairs.",
    feesDocProtocol: "Protocol fee",
    feesDocProtocolBody: "The protocol fee is a percentage markup on top of the LP fee. It goes to the SigalSwap treasury to fund development and operations. When active, it's added on top of the LP fee — it never reduces what LPs earn.",
    feesDocUI: "UI fee",
    feesDocUIBody: "The UI fee is charged by this frontend interface. It's separate from the on-chain fees. Alternative frontends or direct contract interaction may have different UI fees.",
    feesDocExample: "Example",
    feesDocExampleBody: "In a pool with a 0.25% LP fee tier and 20% protocol markup, a trader swapping 1 ETH pays 0.25% to LPs (0.0025 ETH) plus 0.05% to the protocol (0.0005 ETH), for a total of 0.30%.",
    // FAQ
    faqTitle: "Frequently asked questions",
    faqSafe: "What's the current state of SigalSwap?",
    faqSafeBody: "SigalSwap is in development and not yet deployed to mainnet. The smart contracts are written, tested (1,000+ tests across contracts and SDK), and the source is open. Formal audit and mainnet launch are pending. See the <security>Security</security> page for the full state.",
    faqDifferent: "How is SigalSwap different from a public AMM?",
    faqDifferentBody: "SigalSwap uses the same well-established constant-product AMM math, but runs on Aztec's privacy-preserving execution model. Your wallet identity is not linked on-chain to your trades, and your LP positions are private notes only you can see. Per-swap amounts and pool reserves remain public (as in any public-reserves AMM); the privacy property is about who is trading, not what.",
    faqFrontRunning: "Can I be front-run or sandwiched on SigalSwap?",
    faqFrontRunningBody: "Honest answer: yes, at the amount-visibility layer. Aztec exposes a P2P transaction mempool where pending public-call arguments (including swap amounts) are visible, and the mempool is fee-ordered — which means a sandwich attacker can outbid around your swap without needing any Flashbots-style infrastructure. The only current friction is operational: Aztec-side searcher tooling hasn't been built yet. That will change. Your slippage tolerance is the real bound on sandwich extraction. Identity privacy does block one narrow class — wallet-targeted attacks — because attackers can't pre-select you by wallet history. See the MEV considerations doc for the full analysis.",
    faqAztecDown: "What happens if Aztec goes down?",
    faqAztecDownBody: "SigalSwap runs on the Aztec L2 network. If Aztec experiences downtime, swaps and liquidity operations would be unavailable until the network recovers. Funds remain in the smart contracts and become accessible again when the network is operational.",
    faqTokens: "Which tokens are supported?",
    faqTokensBody: "Any Aztec-compatible token can be paired through SigalSwap. The pair contract assumes standard Aztec Token interface behavior; tokens with custom transfer logic (rebasing, fee-on-transfer beyond a simple deduction, hostile balance reporting) may not be safe to trade through the router. See the token-compatibility doc for the full assumption surface.",
    faqCost: "How will fees work?",
    faqCostBody: "Pools have configurable fee tiers (typically 0.05%, 0.25%, 1.00%) paid to liquidity providers. A protocol fee is added on top (not carved out of the LP fee). Aztec network gas fees apply to every transaction.",
  },

  builders: {
    title: "Build on SigalSwap",
    subtitle:
      "Two ways to integrate. One is a Noir dependency for atomic, on-chain composition. The other is a TypeScript SDK for everything off-chain.",

    // Noir lane
    noirTitle: "From your Noir contract",
    noirIntro:
      "SigalSwap ships as a Noir library. Add it to your Nargo.toml and call the pair contract directly from your own code — same module, same types, atomic in a single transaction.",
    noirDepLabel: "Nargo.toml",
    noirUseLabel: "your_contract.nr",
    noirBullet1Title: "Atomic composition",
    noirBullet1Body:
      "Settle a swap in the same transaction as your own contract logic. Build vaults, aggregators, liquidation engines, or flash-loan strategies without external coordination.",
    noirBullet2Title: "Optimistic callback pattern",
    noirBullet2Body:
      "The pair's public swap entry transfers tokens out first, then calls back into your contract to collect the input — an optimistic settlement model that keeps your contract non-custodial.",
    noirBullet3Title: "Flash swaps included",
    noirBullet3Body:
      "Borrow either side of a pair, run arbitrary callback logic, and repay (or revert) atomically. Capital-free arbitrage, self-liquidation, and collateral swaps are all single-tx operations.",

    // SDK lane
    sdkTitle: "From your TypeScript app",
    sdkIntro:
      "The @sigalswap/sdk package wraps the full protocol surface. Build frontends, indexers, bots, or wallet integrations against a typed API instead of raw contract calls.",
    sdkInstallLabel: "Install",
    sdkUsageLabel: "Quick start",
    sdkBullet1Title: "Verified pair resolution",
    sdkBullet1Body:
      "client.pair(address) cross-checks every pair against the factory before any tx is built. Impersonation and unregistered pairs are rejected up front, not at settlement.",
    sdkBullet2Title: "Typed errors, typed events",
    sdkBullet2Body:
      "Every contract revert surfaces as a SigalSwapContractRevertError with a parsed revertReason. Public and private events come with TypeScript types for all 39 emitters across pair, router, factory, and LP token.",
    sdkBullet3Title: "Wallet history without joins",
    sdkBullet3Body:
      "client.getSwapHistory() and getLiquidityHistory() decrypt the sender's private events across pair-direct and router-mediated paths and return a single unified, sorted list.",

    // What you get
    whatYouGetTitle: "What you build against",
    whatYouGet1: "Constant-product AMM with multiple fee tiers and an additive protocol fee",
    whatYouGet2: "Single-hop and multi-hop routing up to 3 hops, exact-in and exact-out",
    whatYouGet3: "Flash swaps with synchronous callback",
    whatYouGet4: "TWAP oracle for time-weighted average prices",
    whatYouGet5: "Fee-on-transfer token support (pair-direct)",
    whatYouGet6: "skim() / sync() recovery primitives",
    whatYouGet7: "Deadline + slippage enforcement on every router entry",
    whatYouGet8: "39 indexed events for analytics, dashboards, and wallet history",

    // Use cases
    useCasesTitle: "What people build with it",
    useCaseVaultsTitle: "Vaults and yield strategies",
    useCaseVaultsBody:
      "Deposit, swap into the strategy asset, and mint position tokens in one atomic call. Users never expose intermediate balances.",
    useCaseAggregatorsTitle: "Aggregators and routers",
    useCaseAggregatorsBody:
      "Route through SigalSwap as the private leg of a multi-protocol swap. Quote off-chain via the SDK, settle on-chain via the router or pair.",
    useCaseDappsTitle: "Frontends and wallets",
    useCaseDappsBody:
      "Embed swap and LP flows in your own UI with the SDK's authwit handling and deadline guards built in.",
    useCaseBotsTitle: "Bots and indexers",
    useCaseBotsBody:
      "Index public reserve and swap events for analytics. Run skim-based arbitrage. Use flash swaps for capital-efficient strategies.",

    // Footer
    ctaTitle: "Ready to integrate?",
    ctaBody:
      "Find the full API reference, event catalog, and architecture notes on GitHub.",
    ctaGithub: "GitHub",
    ctaSdkDocs: "SDK docs",
  },

  security: {
    title: "Security",
    subtitle: "An honest accounting of where things stand.",
    auditStatus: "Audit status",
    auditBody: "SigalSwap smart contracts have not been formally audited. The protocol is new and should be considered experimental. We plan to pursue a formal audit before mainnet launch.",
    contractRisks: "Smart contract risks",
    contractRisksIntro: "As with any DeFi protocol:",
    contractRisk1: "Smart contract bugs could result in loss of funds",
    contractRisk2: "The constant product AMM math is well-understood, but the Noir/Aztec implementation is new",
    contractRisk3: "Interactions between private state and public state introduce novel edge cases",
    contractRisk4: "Oracle manipulation and flash loan attacks remain theoretical risks",
    recommendation: "Our recommendation",
    recommendationBody: "Do not deposit more than you can afford to lose. Start small. The protocol is functional and tested (1,000+ tests across contracts and SDK), but \"tested\" is not \"audited\" and \"audited\" is not \"risk-free.\"",
    disclosure: "Responsible disclosure",
    disclosureBody: "If you discover a vulnerability in SigalSwap, please report it privately. Do not open a public GitHub issue for security vulnerabilities.",
    disclosureEmail: "Email: contact@sigalswap.com",
    disclosureResponse: "We aim to acknowledge reports within 48 hours and provide a substantive response within 7 days.",
    sourceCode: "Source code",
    sourceCodeBody: "SigalSwap is open source. The protocol contracts, SDK, tests, and documentation are on <github>GitHub</github>.",
  },

  about: {
    title: "The Name",
    subtitle: "Why SigalSwap?",
    loreOrigin:
      "Sigal takes its name from <name>Sigalion</name> (Σιγαλίων), an epithet of Harpocrates — the Greco-Roman god of silence, secrets, and confidentiality. Adapted from the Egyptian child-god Horus, Harpocrates became one of antiquity's most recognizable figures: a youth with finger pressed to lips, the universal gesture for silence.",
    loreHistory:
      "Throughout the ancient Mediterranean world, small terracotta statues of Harpocrates stood in household shrines and temple doorways. His image appeared wherever discretion mattered — a quiet guardian ensuring that what was spoken in confidence remained protected. The Romans painted roses on meeting room ceilings as a nod to his symbolism, giving us the phrase <phrase>sub rosa</phrase>: \"under the rose,\" meaning held in confidence.",
    loreMeaning:
      "Sigalion wasn't a god of deception or hiding wrongdoing. He was the protector of sacred knowledge, the keeper of mystery rites, the guardian of reputations. Silence, in this tradition, wasn't absence — it was <sovereignty>sovereignty over one's own information</sovereignty>.",
    loreToday:
      "SigalSwap carries this tradition forward. On a public blockchain, every transaction speaks loudly to anyone watching. Sigal restores your finger to your lips. Your swaps exist, they settle, they're valid — they simply don't announce themselves to the world.",
  },

  notFound: {
    title: "Page not found",
    body: "This page doesn't exist. It may have been moved or you may have mistyped the URL.",
    goHome: "Go home",
  },
} as const;

export default en;
