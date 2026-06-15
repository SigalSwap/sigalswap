# SigalSwap MEV considerations: sandwich, front-running, and what protects users

SigalSwap is a public-reserves constant-product AMM. Swap amounts and reserve updates are public per-tx by design (see `CLAUDE.md` design-decisions table: amounts cannot be hidden on a public-reserves AMM without re-architecting). This document is the honest, audit-grade account of how that design interacts with MEV — sandwich attacks, front-running, back-running — and what protects users against each.

This doc is the source of truth for any SigalSwap marketing or integrator copy that touches "MEV protection." Architecture facts are sourced from Aztec's official material (sequencer design doc, Fernet announcement, Ignition launch blog, `docs.aztec.network`). Marketing copy must trace each claim back to a fact in this doc.

## Summary for integrators

If you read nothing else:

- **SigalSwap's privacy guarantee is identity-private, not amount-private.** A swap publishes its amounts and tokens in public events. The trader's wallet is hidden. See `docs/privacy-model.md` for the full privacy model.
- **Sandwich attacks are not structurally impossible at the contract layer.** Given public reserves and public amounts, contract-level prevention isn't achievable; the defenses live elsewhere (Aztec sequencer model, user-side slippage, identity privacy reducing targeted-victim risk).
- **The contract enforces `amount_out_min` / `amount_in_max` as the user-side floor/ceiling.** Whatever tolerance the user accepts is the maximum a sandwich can extract.
- **Use the slippage helpers.** `minimumAmountOut`, `maximumAmountIn`, `liquidityAmountMins` in `packages/sdk/src/slippage.ts` convert a percentage tolerance to the bigint floor/ceiling the contract expects. Passing `0` is permitted (for bots and contract integrators) but is a footgun for end-user wallets.
- **The Aztec mempool orders pending txs by priority fee, descending.** Verified in source 2026-05-28 (`p2p/src/mem_pools/tx_pool_v2/tx_pool_indices.ts:75-92`, `tx_pool/priority.ts:17-20`, `tx_pool_v2_impl.ts:694-698`). This is a deterministic positioning mechanism: a sandwich attacker sets `frontrun_fee > victim_fee > backrun_fee` and the sort yields the sandwich order — **no MEV-Boost, no bundle market, no builder-searcher pipeline required.** Searcher tooling for Aztec doesn't exist yet, but that's "no actors, not no mechanism," and the situation will erode as the ecosystem matures.

## Threat model

The adversary in this analysis can:

- **Observe public chain state**: reserves, swap events, sync events, factory events, all in cleartext after inclusion.
- **Submit transactions**: can submit competing trades on the same pair in the same block window.
- **Pay top-of-block priority**: bid for inclusion priority via standard fee mechanisms.
- **Watch the mempool** (verified worst case): Aztec uses a P2P transaction mempool; pending public-call data propagates to all nodes before inclusion, not just the sequencer. See "Aztec architecture today" below.
- **Run sandwich logic**: place a buy in the same direction as the victim, let the victim's swap execute at a worse price, then sell to capture the price impact.

The adversary cannot:

- See the trader's wallet address on a private-entry swap (verified — see `docs/privacy-model.md`).
- Decrypt private logs without the user's `ivsk`.
- Force a victim's `amount_out_min` floor to be violated without the contract reverting the victim's tx (verified — `protocol/periphery/src/main.nr:594`).
- Sandwich a trade whose `amount_out_min` is set tighter than the sandwich's worst-case price impact.

## What's publicly visible during a swap

For a router-mediated swap (the typical path for an end user via the SDK), the public surface is:

**Public call arguments** (visible to every node running the P2P mempool, not sequencer-only):

- Router's public continuation invokes `pair.swap_exact_in_public(token_in, token_out, amount_in, 0, recipient = router_addr, callback_contract = router_addr, callback_selector)`. All cleartext. The pair-level `amount_out_min` argument is a literal `0` — the user's post-fee floor is enforced at the router continuation (`protocol/periphery/src/main.nr:594`), not at the pair. The `recipient` is the router address, not the end user — that's the identity-privacy buffer (see `docs/privacy-model.md` §"Router-mediated flow").

**Public events** (visible to anyone after inclusion):

- `SwapPublicEvent { sender: router_addr, token_in, token_out, amount_in, amount_out, recipient: router_addr }` — all cleartext, but with no end-user address.
- `SyncEvent { reserve0, reserve1 }` — updated reserves.

**What an observer cannot see:**

- The end user's wallet address (encrypted in the router's mirror event; never appears in public events).
- The user's LP positions or trade history at the wallet level.

**What an observer can see and sandwich:**

- The amounts and direction of any pending swap once it's in mempool / sequencer view.
- The user's accepted slippage floor (`amount_out_min`) — it's a public-call argument.

This is the central architectural fact: **a sandwich attacker doesn't need to know who the trader is to size a sandwich**. They need to know the trade direction, size, and slippage tolerance — all of which are in the public call.

## Sandwich economics

For a constant-product AMM, the maximum a sandwich attacker can extract from a victim of size `Δx` against pool reserves `(x, y)`, with fee `f` and slippage tolerance `s`, is bounded by:

- The price impact of `Δx` alone (the natural slippage the victim would pay even in isolation).
- The portion of that impact the attacker can capture, capped by the victim's `amount_out_min` floor.

The classic result: profitability of sandwiching a victim trade rises with `(Δx / x)` and with the victim's tolerance `s`. Below a roughly `Δx ≈ 0.5–1%` ratio of the pool, sandwiches barely cover transaction costs even on L1. SigalSwap pays the same physics — there's no AMM-architecture reason to expect different economics here.

What changes the calculus on Aztec specifically:

- **Per-tx amount visibility is identical to L1.** The attacker sees the public call.
- **The mempool is fee-ordered** (verified in source — see "Aztec architecture today" below). This is the same positioning mechanism Ethereum L1 used pre-Flashbots in the 2019-2020 "priority gas auction" era. An attacker doesn't need to *be* the proposer to sandwich — they ride through any honest fee-ordering proposer by outbidding around the victim. Fernet's random leader selection does NOT defend against this vector (it only stops attackers who'd need to *be* the producer for multi-block planning).
- **Low throughput (~1 TPS, ~6s blocks) makes positioning easier, not harder** — fewer competing txs between the sandwich legs.
- **MEV searcher tooling doesn't exist for Aztec yet.** That's the only real (eroding) current mitigant. It's "no actors yet," not "no mechanism."

## What protects users today

Three layers, in increasing strength:

### 1. User-side slippage tolerance (contract-enforced)

On a router-mediated swap the router enforces the user's post-fee floor: the router continuation asserts `final_amount >= amount_out_min` (`protocol/periphery/src/main.nr:594` multi-hop, `:1022` single-hop). The pair-level `amount_out_min` argument is a literal `0` on this path, so the pair's own check is trivially satisfied and the router is the real enforcer. On the pair-direct path the pair asserts `amount_out >= amount_out_min` itself, and for exact-output swaps asserts `amount_in <= amount_in_max`. Whatever tolerance the user passes is the **maximum sandwich profit** possible — a sandwich that would push the output below the floor causes the victim's tx to revert, and the attacker eats their own front-run.

The SDK exposes `minimumAmountOut` and `maximumAmountIn` (see `packages/sdk/src/slippage.ts`) so integrators don't compute the math inline. Default recommendations:

| Pool depth (TVL) | Recommended tolerance | Reason |
|---|---|---|
| Stable pair, deep ($1M+) | 10 bps (0.10%) | Tight price; expected impact low |
| Major-pair, deep ($100k–$1M) | 25–50 bps | Standard wallet default |
| Mid pool ($10k–$100k) | 50–100 bps | Moderate impact + small sandwich envelope |
| Thin pool (<$10k) | 100–300 bps | Substantial impact; pool may be hostile |
| Volatile / small-cap | 200–500 bps | High volatility within block windows |

These are integrator-facing defaults, not contract-enforced minimums. The contract accepts `0` (zero protection); the SDK and wallet are responsible for picking a sensible value.

### 2. Identity privacy (contract-verified)

SigalSwap hides *who* is trading. This doesn't prevent sandwich attacks based on *amount*, but it does eliminate one class of MEV: **targeted-victim sandwiching**. An attacker on L1 can pattern-match a whale's wallet and pre-target them. On SigalSwap, the wallet isn't visible, so a sandwich attacker has to decide whether to attack based purely on the trade's economics, not on the trader's identity. See `docs/privacy-model.md` for the full identity-privacy verification.

This is a meaningful but partial defense: random-victim sandwiches based on amount alone still work.

### 3. Aztec architecture (inherited — narrower than once-implied)

Aztec's Ignition mainnet does NOT have a private/encrypted mempool — pending public-call args are visible to all nodes via P2P propagation. The mempool is fee-ordered (verified). The MEV resistance SigalSwap inherits from Aztec is narrower than the initial framing suggested:

- **Random leader election (Fernet)** — verified TRUE. This stops an attacker who'd need to *be* the proposer for multi-block planning. It does NOT stop fee-bid sandwiching, where the attacker rides through any honest fee-ordering proposer by outbidding around the victim.
- **Decentralized sequencer set (~3,400+ on Ignition)** — verified TRUE. Prevents single-party capture of ordering. Does not prevent fee-bid positioning.
- **No MEV-Boost / Flashbots / builder-searcher pipeline today** — verified TRUE. Aztec rejected the B52 design (which would have enshrined MEV) in favor of Fernet. But a fee-ordered public mempool *is* a positioning mechanism on its own; no bundle market is needed.

Net: the Aztec primitives prevent some attack classes (whole-block coordination, single-party ordering capture) but do NOT close the mempool-fee-bidding sandwich vector. The next section enumerates the verified facts.

## Aztec architecture today (Ignition mainnet, verified May 2026)

The architectural facts below were verified 2026-05-25 against Aztec official sources. See memory `project_aztec_v4_3_ignition_architecture` for the full source map; quoted Aztec material is from the sequencer design doc, the Fernet announcement, the Ignition launch blog, and `docs.aztec.network`.

**Verified facts:**

- **Decentralized sequencer set on Ignition mainnet (live since November 2025).** Target ~4,000 validators; currently ~3,400+ active across ~185 operators on 5 continents.
- **Fernet leader-selection protocol.** Each round (~12-36s), every sequencer computes a VRF score from `H(sequencer_private_key, L1_RANDAO, block_number)`. Highest score proposes. Committee rotates every 32 blocks (~38.4 min per epoch) via Fisher-Yates shuffle seeded by L1 RANDAO. No single party controls ordering across slots.
- **P2P transaction mempool, fee-ordered, not encrypted.** "Private proofs and public transaction requests both added to local mempool"; "full nodes use the P2P network to propagate transactions, making them accessible to Sequencer Nodes." Pending public-call args are visible to all nodes, not sequencer-only.
- **Pending txs are sorted by priority fee, descending** — verified in source 2026-05-28:
  - `p2p/src/mem_pools/tx_pool_v2/tx_pool_indices.ts:75-92` — `iteratePendingByPriority('desc')` sorts pending txs by fee, highest first, txHash tiebreaker.
  - `p2p/src/mem_pools/tx_pool/priority.ts:17-20` — priority = `min(maxFeesPerGas.feePerL2Gas, maxPriorityFeesPerGas.feePerL2Gas)`. Higher fee = earlier inclusion.
  - `p2p/src/mem_pools/tx_pool_v2/tx_pool_v2_impl.ts:694-698` — block builder pulls via `getEligiblePendingTxHashes()` = `iterateEligiblePendingByPriority('desc', ...)`, gated only by a maturation filter `receivedAt <= now - minTxPoolAgeMs` (default ~2s — removes the sub-second latency race; makes the fee auction cleaner, not safer).
  - **This is the load-bearing fact for sandwich exposure on SigalSwap.** A fee-ordered public mempool IS a positioning mechanism — the pre-Flashbots "priority gas auction" model.
- **Aztec's official MEV stance** (sequencer design doc, quoted): *"For the public domain, MEV is extracted by the sequencer responsible for the current slot. In the private domain, there is no direct MEV extraction."*
- **No MEV-Boost / Flashbots / builder-searcher pipeline exists on Aztec today.** Aztec deliberately chose Fernet (random leader election) over B52 (an alternative that would have enshrined MEV auctions). But absence of bundle-market infrastructure does **not** close the sandwich vector — the fee-ordered mempool does the positioning on its own.
- **Still UNVERIFIED:** whether the fee-sort is **protocol-enforced** (committee rejects a block violating the fee order) or just honest-software default. If enforced, a malicious proposer is boxed into the fee order (proposer-MEV reduces to external fee-bidding). If not, the proposer can reorder freely on top of the fee-bid baseline. Either way external fee-bidding is open; this question only affects how much *additional* MEV proposers can extract.
- **Block time ~6s, throughput ~1 TPS** on Ignition mainnet. Low throughput makes positioning *easier* (fewer competing txs between sandwich legs), not harder.

**What this means for SigalSwap:**

- **Sandwich attacks are mechanically OPEN today.** The fee-ordered P2P mempool means a sandwich attacker can outbid around any pending swap and the deterministic sort yields the sandwich order. No infrastructure (MEV-Boost, builder, searcher relay) is required. Fernet's random leader selection does NOT defend against this — the attacker rides through any honest fee-ordering proposer.
- **The only current friction is operational, not architectural.** Searcher tooling for Aztec hasn't been built yet. This is an erosion timer, not a guarantee. When someone builds Aztec-side sandwich tooling, the vector activates immediately.
- **SigalSwap's identity privacy still works** as a narrow defense: wallet-targeted sandwiches (whale-hunting, dev-wallet-sniping) don't work because the wallet isn't visible. Generic amount-based sandwiches still work.
- **The TWAP-anchored execution lever survives** (see the v2 options below). A short-window TWAP price band, baked into the pair, would revert any swap whose execution price deviates beyond a band of recent average prices — which is exactly what a fee-bid frontrun does within a single block. Moving the TWAP itself still requires sustained cross-block control, which Fernet's random rotation continues to deny.

**v5 release (July 2026)** addresses a critical proving-system vulnerability discovered 2026-03-17. There's no public statement that v5 adds protocol-level MEV protections (e.g., encrypted mempool, batched ordering). Treat MEV-architecture changes in v5+ as roadmap-unknown until announced.

## Comparison to L1 MEV landscape

| Vector | L1 Uniswap V2 | SigalSwap on Aztec Ignition |
|---|---|---|
| Mempool visibility of pending swap | Fully public | Fully public (P2P; pending public-call args propagate to all nodes) |
| Mempool ordering primitive | Fee-priority gas auction (pre-Flashbots) plus MEV-Boost private orderflow | Fee-priority sort, no Flashbots equivalent yet (verified in source) |
| MEV-Boost / private orderflow | Mature (Flashbots, MEV Blocker, CoW Swap) | Absent on Aztec today — but **not required** to sandwich; fee-ordering provides positioning on its own |
| Searcher/builder pipeline | Mature multi-billion-$ industry | Absent on Aztec today (erosion timer; no architectural barrier) |
| Leader selection | PoS validator, MEV-Boost-extended | Fernet random VRF per epoch (~38.4 min), ~3,400+ validators. Stops multi-block planning; does NOT stop fee-bid sandwiches that ride through any honest proposer. |
| Wallet-targeted sandwich (whale-hunting) | Possible (wallets are public) | Blocked by SigalSwap identity privacy |
| Amount-based sandwich (random victim) | Possible | Possible (fee-bid auction in the public mempool); bounded by user slippage; *not* meaningfully reduced by absence of bundle-market infra |
| Sequencer-level MEV (proposer reorder) | Bounded by validator/builder competition (and MEV-Boost auction) | Acknowledged-extractable by Aztec ("MEV is extracted by the sequencer responsible for the current slot, public domain"); if fee-ordering is protocol-enforced, bounded to honor the fee sort; if not, full discretion within slot |
| User-side slippage protection | Standard (V2 SDK ships `minimumAmountOut`) | Standard (SigalSwap SDK ships equivalent helpers) |

The honest summary: **SigalSwap's mempool / sequencer surface is structurally similar to L1's pre-Flashbots era — fee auction in a public mempool, sandwich-positioning works without a bundle market.** The Aztec primitives prevent some attack classes (whole-block coordination, single-party capture) but do not close the fee-bid sandwich vector. Identity privacy on SigalSwap blocks one class of L1-style attacks (targeted whale-hunting); it doesn't bound generic amount-based sandwiches. The two genuine current frictions on Aztec are (a) no searcher tooling has been built yet (eroding) and (b) low throughput / lower extractable value per attack at current TVL (also eroding).

## What SigalSwap could add in a future version

The current SigalSwap design intentionally tracks Uniswap V2 closely — same constant-product math, same mint/burn semantics, same public-reserves architecture. If sandwich-resistance becomes a SigalSwap-owned property rather than an Aztec-inherited one, several architectural additions are available for v1.1+:

- **TWAP-anchored execution with a deviation band.** The pair maintains a short-window TWAP (already does, for the oracle). A swap reverts if its execution price deviates beyond a configurable band of recent average prices. A fee-bid frontrun moves spot within a single block — a tight band catches that within the same block, reverts the victim, and strands the attacker's frontrun in the pool. Moving the TWAP itself requires sustained cross-block control, which Fernet's random leader rotation continues to deny. **This is the lever that survives the May 28 fee-ordering finding** and the strongest candidate for a SigalSwap-owned defense that doesn't require Aztec to ship anything. Single-tx UX. Trade-off: legitimate swaps during volatile periods get reverted more aggressively; the band has to be tuned per pair.
- **Commit-reveal swaps.** User commits to a swap hash in tx N, reveals and executes in tx N+1. Adds one block of latency plus capital lockup in escrow during the reveal window. UX cost was deemed unacceptable in the 2026-05-27 review; included here for completeness.
- **Batched router / clearing-price settlement.** Multiple swaps in a batch settle at a single clearing price (CoW-Swap-style). No ordering within a batch, so no sandwich. Requires solver / matching infrastructure and is essentially a different DEX architecture.
- **Threshold-encrypted swap intents — only works as a protocol-enshrined primitive.** Users encrypt swap intent to a committee that decrypts after ordering is committed. *App-level committee built on top of SigalSwap does not deliver sandwich resistance on Aztec*, because the committee's execution transaction still flows through the Aztec sequencer's fee-ordered mempool with amounts in cleartext — the sandwich vector relocates to the execution step. The only version that works is an **enshrined encrypted mempool at the Aztec protocol layer**, which is not on Aztec's published roadmap as of May 2026. We have an open question with the Aztec team about whether they're considering this; awaiting clarifying response (see Open questions below).
- **Time-weighted average execution (TWAMM).** Long-running orders that execute against a moving price, making per-tx sandwich infeasible. Distinct from the TWAP-band option above; TWAMM splits one order over time, whereas the band reverts single-tx deviation.

Each of these is a substantial design + audit project, not a flag flip. None are in scope for v1. They're enumerated here so the v1-vs-future marketing positioning is honest about what we *could* do versus what we *currently* do.

## Recommendations for integrators

**For wallets and UIs:**
- Always use `minimumAmountOut(quoted, slippageBps)` or `maximumAmountIn(quoted, slippageBps)` from the SDK rather than passing raw bigints.
- Default to 50 bps (0.50%) for typical pairs; surface a "slippage tolerance" UI control.
- Refuse to submit a tx with `amountOutMin = 0` unless the user has explicitly chosen "no protection" with a warning.
- Re-quote within a few blocks of submission; if the quote drifts more than the tolerance allows, re-prompt the user.

**For arb bots and contract integrators:**
- `amountOutMin = 0` is intentional and supported. You're expected to handle slippage upstream.
- Use the pair-direct entries (`swap_exact_in_public`, etc.) rather than the router if you need callback-pattern atomicity.

**For end users (when SigalSwap surfaces a UI):**
- Trust the wallet's default tolerance unless you have reason to override it.
- Beware of "zero slippage" / "infinity slippage" toggles in any wallet UI — both are degenerate cases that disable protection.

## Open questions for the Aztec team consultation

Foundational architecture questions (mempool model, sequencer selection, ordering rules, official MEV stance, fee-priority sort) were resolved through public-source research (2026-05-25) and direct source verification (2026-05-28). What remains for the consultation:

1. **Is the fee-priority sort protocol-enforced or honest-software default?** Verified in the p2p mempool source that pending txs are sorted by `min(maxFeesPerGas, maxPriorityFeesPerGas).feePerL2Gas`, descending. Open question: does the consensus / block-validation path reject a block whose ordering violates the fee sort, or is honoring the sort just a convention that honest sequencers follow? If enforced, a malicious proposer is boxed in (proposer-MEV ≈ external fee-bidding). If not, proposer can reorder freely on top of the fee-bid baseline. Either way the external fee-bid vector is open. To answer this: look at the consensus / block-validation code, not the mempool.
2. **Encrypted mempool / threshold-decrypt-after-ordering — is this on Aztec's roadmap?** Sent to Aztec team 2026-05-25; received a clarifying response 2026-05-28 (Josh: "you'd need to know who to encrypt to"). Refocused follow-up sent 2026-05-29 distinguishing permanent amount privacy (impossible, agreed) from sandwich resistance via reveal-timing (what we actually need); explained that app-level committee doesn't work because execution still flows through Aztec's sequencer with cleartext amounts; asked whether protocol-level enshrinement is being considered. Awaiting response.
3. **v5 roadmap** (July 2026 release): does v5 add any protocol-level MEV protections beyond the proving-system vulnerability fix?
4. **AMM-specific recommendations**: are there design patterns Aztec recommends for AMMs given the public-domain MEV-extractable property — specifically anything supporting the TWAP-anchored-execution-band approach?
5. **Cross-chain MEV vectors**: does the L1↔L2 bridge introduce any MEV vectors a public-reserves AMM should account for?
6. **Sequencer slashing**: under what conditions can a sequencer be slashed for MEV extraction? Is there an enforced fairness threshold today, or is it operator-discretion?

## References

- Identity privacy verification: `docs/privacy-model.md`
- TWAP manipulation cost model (assumes honest sequencer): `docs/twap-security.md`
- Router slippage enforcement: `protocol/periphery/src/main.nr:594` (`assert(final_amount >= amount_out_min, "INSUFFICIENT_OUTPUT_AMOUNT")`)
- Pair public-call argument shape: `protocol/core/src/main.nr` (search for `swap_exact_in_public`)
- SDK slippage helpers: `packages/sdk/src/slippage.ts`
