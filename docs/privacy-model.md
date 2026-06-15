# SigalSwap privacy model: what we promise, what we don't, and why

SigalSwap is a privacy-preserving constant-product AMM. The core privacy promise is that **a trader's address is not publicly linked to the trades they execute**. This document defines that promise precisely, enumerates the on-chain channels through which information about a trader could leak, and lists the things SigalSwap does *not* promise so integrators and end users can calibrate their own trust.

This is a self-contained read. Code references throughout point to the canonical implementation in `protocol/core/src/`, `protocol/factory/src/`, `protocol/lp-token/src/`, and `protocol/periphery/src/`.

## Summary for end users

If you read nothing else:

- **Use the private entry points** (`swap_exact_in`, `swap_exact_out`, `add_liquidity`, `remove_liquidity` on the pair, or any router function). Your address is cryptographically hidden in the public chain state.
- **Avoid the public-direct entry points** (`swap_exact_in_public`, `swap_exact_out_public`, `add_liquidity_public`, `remove_liquidity_public`) unless you *want* your address to be public. These are designed for arbitrage bots, MEV searchers, and other contracts; if you call them yourself, your address appears in cleartext in the public event.
- **Public information about every swap includes amounts and tokens.** The privacy guarantee is about *who* traded, not *what* was traded. Anyone watching the chain can see "a swap of 17.4 ETH for USDC happened on pair X." If your amounts are unique, you may be re-identifiable by amount alone.
- **Network-layer leaks are out of scope.** If your ISP, PXE provider, or RPC provider can see your tx submissions, they can correlate them to your wallet. Use a self-hosted PXE and a privacy-preserving transport (Tor/VPN) if this matters for your threat model.

## The privacy promise, stated formally

**Guarantee.** For any private-entry call by user U on a SigalSwap pair P, an observer with access only to the public chain state and public encrypted logs (i.e., no knowledge of any private key from U or any of U's counterparties) cannot determine that U is the caller, with security reducing to:

1. The Aztec `ONCHAIN_UNCONSTRAINED` encrypted-log delivery primitive's cryptographic guarantees (ECDH tag construction + envelope encryption), as documented by aztec-nr.
2. The non-leakage of U's incoming-viewing secret key (`ivsk`) and U's address-derivation keys.
3. The pair's bytecode containing no path that emits U's address as a public field in connection with the private-entry call.

The third clause is what this document verifies. Clauses (1) and (2) are framework guarantees inherited from Aztec; this document treats them as axioms and focuses on (3) and on the residual side channels that no contract-level design can close.

**Non-guarantees.** SigalSwap does NOT promise:

- That an observer cannot infer *what tokens* were swapped or *how much*. Amounts and token addresses are public, by construction (see "Design choice: public amounts" below).
- That an observer cannot fingerprint the *type* of operation (swap vs. mint vs. burn vs. multi-hop) from the on-chain tx shape.
- That an observer with network-layer access cannot correlate tx submission timing with the user's online activity.
- That an observer with access to U's PXE operator (if U doesn't self-host) cannot deanonymize U via their query patterns.
- That cross-protocol correlation (U is known to hold token X on protocol Y, U's wallet trades X on SigalSwap) doesn't narrow the candidate set for any given swap.

The remainder of this document explains what's behind each of these claims.

## Adversary model

The cost numbers and inference analyses below assume an attacker with the following capabilities:

- **Full public chain visibility.** The attacker reads every public state slot, every public event, every encrypted-log envelope (tag + ciphertext, but not plaintext), every nullifier, and every commitment ever published.
- **Historical chain access.** The attacker has unlimited time to scan history and run statistical analyses across multiple txs.
- **No keys.** The attacker does NOT have any user's `ivsk`, `nsk`, or address-derivation keys.
- **Public knowledge of token contracts.** The attacker knows which tokens exist at which addresses, which pairs are registered with the SigalSwap factory, and the published source of all SigalSwap contracts.
- **Pattern-of-life knowledge OPTIONAL.** A stronger attacker may have out-of-band information about a specific user U (online hours, holdings on other protocols, known wallet addresses on other chains). This is the "deanonymization-by-correlation" threat and is explicitly out-of-scope for the contract-level guarantee but addressed in worked examples.
- **Network observer OPTIONAL.** A still-stronger attacker may also see U's RPC traffic to a PXE / sequencer. Out-of-scope for contract-level guarantee.

What the attacker cannot do:
- Compromise Aztec's ECDH or envelope-encryption primitives.
- Force a user to reveal a private key.
- Compromise the bytecode of the deployed pair/factory/lp-token/router (assumed immutable post-deploy).

## The observable surface (what an observer actually sees)

To know what an observer can infer, we need to enumerate what they see. The following is comprehensive across all four SigalSwap contracts.

### Public state (permanently visible, read at any time)

The pair (`protocol/core/src/main.nr`):

| Slot | Type | Contents |
|---|---|---|
| `config` | PublicImmutable | `token0`, `token1`, `factory`, `fee_tier_bps`, `version`, `lp_token` |
| `lp_token` | PublicImmutable | LP-token contract address |
| `packed_reserves` | PublicMutable | current `reserve0`, `reserve1` |
| `block_timestamp_last` | PublicMutable | last TWAP update timestamp |
| `price0_cumul_int`, `price1_cumul_int`, `packed_twap_frac` | PublicMutable | TWAP accumulators |
| `packed_reserves_last` | PublicMutable | protocol-fee baseline reserves |
| `fee_to` | PublicMutable | protocol-fee recipient (admin-set) |
| `packed_flags` | PublicMutable | pause / lock / protocol-fee-active flags |

The factory (`protocol/factory/src/main.nr`): admin address, fee config, fee-tier whitelist, full pair registry (`pairs`, `pair_by_index`, `registered`, `latest_version`), timelock queue, pair-class-id.

The LP token (`protocol/lp-token/src/main.nr`): `pair` address (immutable), `total_supply`, `public_balances` map (for users with public LP balances), token metadata.

The router (`protocol/periphery/src/main.nr`): `factory` address (immutable), `hop_active`, `expected_callback_token`, `expected_callback_amount` (transient cross-call state).

**Privacy implication:** none of these contain a private user's address as a stored field. The only user-addressable slots are `fee_to` (admin), `admin` (admin), and `public_balances` (only populated for users who chose to use *public* LP balances).

### Public events (visible to everyone, cleartext)

Pair events (`protocol/core/src/main.nr:115-183`):

| Event | Fields | Emitted by |
|---|---|---|
| `SwapEvent` | `token_in`, `token_out`, `amount_in`, `amount_out` | private-entry swap settlement (no sender) |
| `MintEvent` | `amount0`, `amount1`, `liquidity` | private add-liquidity settlement (no sender) |
| `BurnEvent` | `amount0`, `amount1`, `liquidity` | private remove-liquidity settlement (no sender) |
| `SwapPublicEvent` | `sender`, `token_in`, `token_out`, `amount_in`, `amount_out`, `recipient` | public-direct swap (sender + recipient in cleartext) |
| `MintPublicEvent` | `sender`, `amount0`, `amount1`, `liquidity` | public-direct add (sender in cleartext) |
| `BurnPublicEvent` | `sender`, `amount0`, `amount1`, `liquidity`, `recipient` | public-direct remove (sender + recipient in cleartext) |
| `SyncEvent` | `reserve0`, `reserve1` | every reserves-touching call (no sender) |
| `ProtocolFeeMintedEvent` | `fee_to`, `amount` | when protocol fee is active and pool grew |
| `ProtocolFeeConfigChangedEvent` | `fee_to`, `percent`, `active` | factory-only `set_protocol_fee` call |
| `PairPausedEvent`, `PairUnpausedEvent` | (none) | factory-only state transition |
| `FlashSwapEvent` | `borrower`, `amount0_in`, `amount1_in`, `amount0_out`, `amount1_out` | flash swap (borrower in cleartext) |

Factory events (all public, all governance-related): `PairCreatedEvent`, `PairSlotClearedEvent`, pause/unpause events, timelock action events, admin/fee-to/tier change events, `PairClassIdChangedEvent`, `ProtocolFeeSyncedEvent`.

LP-token events: `LPTransfer` (`from`, `to`, `amount`) — emitted only by the *private* `transfer` entry and delivered as an **encrypted** log to `to` (`deliver_to(to, ONCHAIN_UNCONSTRAINED)`), not a public event; it carries the sender attribution a received note lacks, readable only by `to`. No other LP-token path emits anything: mint, burn, public transfers, and the ramps are recorded by the notes themselves (private) or the `public_balances` map (public), so an event would be redundant. This matches the Aztec reference Token, which likewise emits only on `transfer`. So no LP-token path publishes a private holder's address in cleartext; the one event that carries `from` is encrypted to the counterparty.

Router events: four of the five — `RouterSwapExactInEvent`, `RouterSwapExactOutEvent`, `RouterMintEvent`, `RouterBurnEvent` — are *private* (emitted from the router's private entries and delivered encrypted to the swapping user; none names the user in cleartext). The fifth, `RouterSkimEvent` (`token`, `recipient`, `amount`), is the exception: it is a **public cleartext** event, emitted with a bare `self.emit` from the `#[external("public")] skim_to` entry. That is by design — `skim_to` is a public, permissionless dust-recovery sweep (the caller designates `recipient`), not a private user swap, so there is no private caller identity to protect. No router event exposes a *private-path swapper's* address.

**Privacy implication:** the four events that *would* expose a private user's address are the four `*Public*` events from the pair, plus `FlashSwapEvent`. These are all on the public-direct path — opt-in for callers who want public settlement. Private-path users hit `SwapEvent`/`MintEvent`/`BurnEvent`/`SyncEvent`, none of which name a user.

### Encrypted logs (visible as opaque tag+ciphertext, decryptable only by recipient)

Pair private events: `PrivateSwapExactInEvent`, `PrivateSwapExactOutEvent`, `PrivateMintEvent`, `PrivateBurnEvent`. Each carries the user's swap *intent* (tokens, declared bounds) and is encrypted to the user themselves for wallet-history purposes.

Partial-note finalizations: per swap, 1-2 partial notes are finalized (output note + optional refund note for exact-out swaps). Each finalization writes a note commitment publicly; the commitment's plaintext (recipient, amount) is decryptable only by the recipient.

Router private events: `RouterSwapExactInEvent`, `RouterSwapExactOutEvent`, `RouterMintEvent`, `RouterBurnEvent`. Mirror events to the pair's, emitted by the router for users transacting through it, encrypted to the user. (`RouterSkimEvent` is NOT in this set — it is a public cleartext event from the permissionless `skim_to`, covered in the public-events section above.)

**Privacy implication:** each encrypted log adds one entry to the public log stream with an opaque tag. The *count* of encrypted logs in a tx is observable; the *content* is not (per Aztec's ECDH-tag guarantee, as long as keys aren't compromised).

### Nullifiers

Every spent note publishes a nullifier — a one-way commitment to the note's spending. SigalSwap nullifiers come from:
- LP token authwit consumption (`compute_authwit_nullifier(from, call_hash)` per call)
- Note spends (LP tokens, input tokens being routed in)

Each nullifier is a hash output that does not structurally reveal the user. Two nullifiers from the same user on different swaps are independent hash outputs — no structural linkage observable.

## Channel-by-channel analysis

For each plausible side channel, we ask: does this channel allow an observer to recover the user's identity, narrow the candidate set, or distinguish two different users' txs?

### Channel 1: encrypted-log tag derivation

**Mechanism.** Each encrypted log is prefixed with a tag derived (approximately) as:

```
tag = H( H( H( DH(sender_ivsk, recipient_ivpk), contract_address ), recipient_address ), index )
```

where `DH` is Diffie-Hellman between sender's incoming-viewing secret and recipient's incoming-viewing public key, and `index` increments per (sender, recipient, contract) tuple.

**Analysis.** For self-encrypted logs (the user encrypts to themselves — true for `PrivateSwap*Event` and partial-note finalizations destined to the trader):
- `DH(user_ivsk, user_ivpk)` is a constant K for that user's keys.
- `contract_address` is fixed per contract (pair or router).
- `recipient_address` is the user's own address (a constant from the user's perspective).
- Only `index` varies across the user's logs.

From an observer's perspective: the user emits a sequence of tags `H(K', i)`, `H(K', i+1)`, ... where `K' = H(H(K, contract_addr), user_addr)` is unknown. The observer sees opaque hash outputs. They cannot link two of the user's tags without knowing `K'`, and `K'` requires either the user's `ivsk` or knowledge of `K`.

**Verdict.** No leakage at the tag layer. Tags from the same user on different swaps are unlinkable to an observer.

**Caveat.** Tags from the same user *within a single tx* are not the leakage point — they're already co-located by being in the same tx, but tx-level co-location doesn't reveal the user (only that "some user did N logs in this tx"). The fact that the tags share an unknown `K'` is not externally observable.

### Channel 2: tx-shape fingerprinting

**Mechanism.** Different SigalSwap operations produce different counts of public events + encrypted logs. An observer can classify a tx by its shape.

**Analysis.** Approximate per-tx shapes (private path):

| Operation | Public events | Encrypted logs |
|---|---|---|
| Private `swap_exact_in` (single-hop) | 1 `SwapEvent` + 1 `SyncEvent` | pair-direct: 1 `PrivateSwapExactInEvent` + 1 output partial-note. Via router (mutually exclusive): 1 router mirror event + 1 output partial-note (the pair's private entry does not run, so no `PrivateSwapExactInEvent`) |
| Private `swap_exact_out` (single-hop) | 1 `SwapEvent` + 1 `SyncEvent` | pair-direct: 1 `PrivateSwapExactOutEvent` + 1 output partial-note + 1 refund partial-note. Via router (mutually exclusive): 1 router mirror event + output/refund partial-notes (the pair's private entry does not run, so no `PrivateSwapExactOutEvent`) |
| Private `add_liquidity` | 1 `MintEvent` + 1 `SyncEvent` + maybe 1 `ProtocolFeeMintedEvent` | 1 `PrivateMintEvent` + 2 token-refund partial-notes + 1 LP partial-note |
| Private `remove_liquidity` | 1 `BurnEvent` + 1 `SyncEvent` + maybe 1 `ProtocolFeeMintedEvent` | 1 `PrivateBurnEvent` + 2 output token partial-notes |
| Multi-hop swap (N hops, always router-mediated) | N `SwapPublicEvent` (sender = recipient = router) + N `SyncEvent` (one per pair) | 1 router event + a fixed partial-note count (exact-in: exactly 1 output partial-note regardless of N; exact-out: the full fixed placeholder set — output + change + MAX_HOPS-1 intermediates). The count is constant by design, not proportional to N |

The public-event column above reflects an op called **directly** on the pair's private entry (sender-less `SwapEvent` / `MintEvent` / `BurnEvent`). The same op routed through the **router** instead settles via the pair's public entry and emits the `*PublicEvent` variant with `sender = recipient = router` (`SwapPublicEvent`, `MintPublicEvent`, `BurnPublicEvent`) and no sender-less event -- so a router-mediated swap is publicly distinguishable from a direct-pair private swap, though neither names the user. Multi-hop is always router-mediated. Public-path operations also replace the encrypted logs with cleartext fields in `*PublicEvent`, so they're trivially distinguishable from private-path operations.

**Verdict.** A tx's *category* (swap vs. mint vs. burn vs. flash vs. multi-hop, and exact-in vs. exact-out) is observable. The *user* is not. An observer can say "a 3-hop swap happened" but cannot say "Alice did it." Mitigation: partial-note placeholders normalize note counts across single- vs. multi-hop within each category, reducing per-category sub-fingerprinting.

**Residual leakage.** Two users behaving identically (same operation category, same time of day, same volume tier) produce indistinguishable txs. Two users behaving very differently (Alice always does exact-out 4-hops at 3 AM UTC; Bob always does exact-in single-hops at 9 AM UTC) leave distinct *behavioral* fingerprints across many txs, even though each individual tx is anonymous. This is an inherent limitation of any public-blockchain privacy system and is addressed at the wallet/UX layer (mixers, stealth addresses, batched relayers), not the contract layer.

### Channel 3: reserve-delta and amount correlation

**Mechanism.** Every private swap emits a public `SwapEvent` containing `amount_in` and `amount_out` in cleartext. The reserves also change publicly by the same amounts (modulo donations and fee accrual). An observer reading just the reserve trajectory can recover every swap's amount even without parsing events.

**Analysis.** Amounts are public by design — this is documented in `CLAUDE.md` as a "Design Decision":

> Reserves: Public — Required for price discovery and K invariant.
> Swap amounts: Public per-tx — Inherent to public-reserves AMMs. Breaking the wallet-to-trade link (via private `msg_sender`) is the privacy guarantee SigalSwap provides; hiding amounts would require a structurally different architecture (private reserves, serial settlement).

So the question is not "can we hide amounts" (we can't, structurally) but "what does *amount-publicity* let an attacker do?"

**Inference scenarios:**

1. **Unique-amount fingerprinting.** If user U swaps an unusual amount (e.g., `17.482371 ETH` — a non-round value derived from some off-chain source), and that exact amount appears in a SwapEvent at time T, an attacker who later learns that U was online at time T narrows the candidate set to "users online at T who held exactly 17.482371 ETH before T." If U's wallet is known to hold ETH and is observed online at T, this is a strong fingerprint.

2. **Repeated-amount fingerprinting.** If U swaps the same amount many times (DCA, scheduled trades), an attacker sees a series of identical swaps at predictable intervals and can correlate to U's known activity pattern.

3. **Reserve-delta arithmetic.** The reserve change between two consecutive swap events is exactly `(amount_in, -amount_out)` for the swap that happened between them (plus donations, which are usually zero). The SwapEvent and the reserve trajectory are redundant signals — hiding one doesn't help if the other is published.

**Verdict.** **Amount publicity is the largest residual privacy gap, and it is structural.** The contract-level guarantee is "no address linkage at the cryptographic layer." The amount-correlation channel is real and the doc explicitly does not promise immunity to it.

**Mitigations (user-side, not contract-side):**
- Round amounts (swap 1.0 ETH, not 1.034829 ETH).
- Split large swaps across many smaller ones at varying times.
- Mix into traffic from other users (concentrated trading hours have larger anonymity sets).
- For privacy-critical applications, use stealth-address indirection so the wallet that *holds* the assets isn't the wallet that *signed* the swap.

### Channel 4: timing and submission patterns

**Mechanism.** An observer with mempool access (or sequencer-level access) sees tx submission timestamps. An observer with RPC access to a user's PXE sees the user's request times.

**Analysis.** Out of scope for the contract-level guarantee. Mitigations are user-side: self-hosted PXE, Tor or VPN for RPC traffic, mempool-private submission flows (if/when Aztec supports them).

**Verdict.** No contract-level remediation. The doc lists this as a residual side channel.

### Channel 5: PXE query patterns

**Mechanism.** A user's PXE polls nodes for encrypted logs matching the user's tag derivations. A PXE provider — or a network observer of PXE↔node RPC — can correlate "this PXE instance scanned for tags from contract C around block B" with "user U owns this PXE instance" to infer U's interest in contract C.

**Analysis.** Out of scope for the contract. Mitigations: self-host the PXE; use a privacy-preserving transport.

**Verdict.** No contract-level remediation. Doc flags it.

### Channel 6: authwit nullifier shape

**Mechanism.** When a private swap consumes an LP-token or input-token authwit, a nullifier is published: `H(from, call_hash)`.

**Analysis.** For two swaps by the same user with different amounts (or different tokens / nonces), the `call_hash` differs, so the two nullifiers are independent hash outputs. From an observer's perspective: pseudorandom, unrelated. No structural linkage.

For two swaps by the same user with the *same* amount/token/nonce — impossible by construction. Authwits are nonce-scoped and single-use; reusing a (from, nonce) pair on the same call hash would collide on the nullifier and fail. Different (from, nonce) → different nullifier. So even amount-identical swaps don't produce structurally-identical nullifiers.

**Verdict.** No leakage at the nullifier layer. Authwit consumption does not reveal the user across txs.

### Channel 7: partial-note finalization shape

**Mechanism.** Partial notes are created in private, finalized in public. The finalization step writes a note commitment publicly. The amount being finalized is supplied as a public function argument.

**Analysis.** The recipient address is encrypted in the partial note's plaintext (which only the recipient can decrypt). The amount at finalization is publicly visible — but this is the same information as the public `SwapEvent`/`MintEvent`/`BurnEvent` already publishes, so no new leakage.

Worth verifying: does the partial-note commitment's structure reveal anything? In aztec-nr, the commitment is `H(plaintext)` where plaintext includes (recipient, value, nullifier-seed, ...). Since the hash is one-way, the commitment doesn't reveal any of its inputs to an observer.

**Verdict.** No additional leakage beyond what amount-publicity already reveals.

### Channel 8: cross-contract reuse of shared secrets (closed in v4.2)

**Mechanism.** Aztec v4.1.x's `getSharedSecret` oracle returned the raw ECDH shared secret without app-siloing. A malicious contract the user interacted with could call the oracle for a SigalSwap-emitted log's ephemeral pubkey and derive the same shared secret, enabling cross-contract decryption inside the user's PXE.

**Analysis.** Framework-layer issue inherited from aztec-nr in v4.1.x. Aztec v4.2 app-silos oracle outputs, which closes the gap without any contract-level change.

**Verdict.** Closed by the v4.2 framework fix; SigalSwap runs on v4.3.0, so this channel is not present in the deployed code.

**Related v4 framework hardening.** Two additional privacy-relevant changes shipped in v4 and are inherited by SigalSwap without contract-level work: (a) domain-separated log tags, which strengthen the tag-derivation analysis in Channel 1 by ensuring tags from different contracts cannot collide even on the same (sender, recipient) pair; and (b) a corrected constrained/unconstrained encryption check, which closes a constrained-vs-unconstrained mismatch in the encrypted-log path. Both are framework primitives consumed via aztec-nr's `emit` macros.

### Channel 9: public-direct entry-point misuse

**Mechanism.** The pair exposes four public-direct entry points (`swap_exact_in_public`, `swap_exact_out_public`, `add_liquidity_public`, `remove_liquidity_public`) and `flash_swap`. These emit `*PublicEvent`s containing the caller's address in cleartext. A user who calls these directly (rather than via the router or via the pair's private entries) has their address published.

**Analysis.** The public-direct entries are intentional — they exist so that *other contracts* (arb bots, MEV searchers, synchronous-callback swap consumers, contracts integrating SigalSwap as building blocks) can transact against the pair in fully-public fashion when they want to.

The risk is that an end-user accidentally calls a public-direct entry thinking it's the private one. The SDK mitigates this by **naming**: on the `SigalSwapPair` wrapper the public-direct methods are explicitly suffixed `Public` (`swapExactInPublic`, `swapExactOutPublic`, `addLiquidityPublic`, `removeLiquidityPublic`), while the private entries carry no suffix -- so a public-direct call is visible at the call site. Separately, `Client.pair(addr)` runs an anti-phishing factory-registration check before returning the wrapper, whereas `Client.unsafePair(addr)` returns the same wrapper without that check (for callers with an out-of-band guarantee the pair is genuine). Both wrappers expose the same methods; the `Public` suffix -- not a separate object -- is the misuse guard.

**Verdict.** Privacy of router-mediated swaps verified: the router passes `self.address` (= router address) as the recipient to the pair's public-direct swap entry (`protocol/periphery/src/main.nr:129-133`), so the pair's `SwapPublicEvent` has `sender = router, recipient = router`. The end user's address never appears in the pair's public events; the pair delivers tokens to the router, and the router separately finalizes the partial note to the user (encrypted).

**Caveat.** A user calling `Client.unsafePair(...)` opts out of privacy. This is by design but bears repeating in user-facing docs and in the SDK README.

## Router-mediated flow: the privacy buffer

The router exists for multi-hop and composability reasons, but it also serves as a privacy buffer for users who don't want to interact with the pair's public-direct entries themselves but who *do* want to use the synchronous-callback (faster, atomic) swap path internally.

The flow for a user U swapping via the router:

1. U calls `router.swap_exact_in(...)` (private, hides U's address).
2. Router's private continuation transfers tokens from U to the router via the input token's private `transfer_to_public` (consumes U's authwit; emits encrypted log).
3. Router enqueues its public continuation `_swap_exact_in(...)`.
4. Public continuation calls `pair.swap_exact_in_public(token_in, token_out, amount_in, amount_out_min, recipient=router_addr, callback_contract=router_addr, callback_selector)`.
5. Pair emits `SwapPublicEvent { sender: router_addr, token_in, token_out, amount_in, amount_out, recipient: router_addr }` — note: router as both sender and recipient; U is not named.
6. Pair calls back to `router.swap_payment_callback(...)` to collect the input token.
7. Pair sends the output token to the router.
8. Router calls `token_out.finalize_transfer_to_private(amount, output_partial_note)` — finalizes the partial note for U (encrypted recipient, public amount).

**The observable signature:** one `SwapPublicEvent` with both sender and recipient = router address (the router settles via the pair's public entry, so there is no sender-less `SwapEvent` on this path), one `SyncEvent`, plus the encrypted logs from steps 2 and 8.

**The observer learns:** a swap of `amount_in` `token_in` → `amount_out` `token_out` happened, mediated by the router. They do not learn who U is.

**Multi-hop variation.** A multi-hop swap of N pairs produces N `SwapPublicEvent`s (all with sender=router, recipient=router) + N `SyncEvent`s, plus one router-level encrypted event and N-or-fewer partial-note finalizations. Same privacy property: router-as-buffer means the user never appears in the public events.

**Interface fee (frontend-attribution channel).** If the calling frontend sets an interface fee (bounded at 5%), the router makes one **additional public** `transfer_in_public(router -> fee_recipient, fee_amount)` of the output token (`protocol/periphery/src/main.nr:217-222`). This is observable and reveals *which integrator/frontend* mediated the swap (the `fee_recipient`), plus the fee magnitude -- it does **not** reveal U. It is an attribution signal about the frontend, not a deanonymization of the user; frontends that do not set a fee emit no such transfer.

## Worked examples

### Example 1 — Alice does a single private swap

Alice swaps 1.5 ETH for USDC via the SigalSwap router.

**What an observer sees:**
- One public `SwapPublicEvent { sender: router_addr, recipient: router_addr, token_in: ETH_addr, token_out: USDC_addr, amount_in: 1.5 ETH, amount_out: ~2700 USDC }` on the ETH/USDC pair. The router settles via the pair's public entry, so this is the only swap event -- there is no sender-less `SwapEvent` on the router path (see Channel 2).
- One public `SyncEvent` on the same pair with the new reserves.
- ~2-3 encrypted logs in the tx (the router's mirror event plus partial-note finalizations). On the router path the pair's private entry never runs, so there is no pair `PrivateSwapExactInEvent` in this tx.

**What an observer can infer:**
- A user swapped 1.5 ETH for USDC via the router. They do *not* know it was Alice.

**What an attacker with pattern-of-life knowledge about Alice could infer:**
- If Alice is the only known holder of exactly 1.5 ETH at the moment of the swap, and Alice was observed online at that moment, the attacker can narrow the candidate set. The amount-correlation channel is the gap, not the address-linkage channel.

### Example 2 — Bob does 50 private swaps with rounded amounts in a populated hour

Bob swaps 1 ETH for USDC, 50 times over an hour during peak SigalSwap trading.

**What an observer sees:**
- 50 `SwapEvent`s with `amount_in: 1.0 ETH` on the ETH/USDC pair, intermixed with other users' swaps of various amounts during the same hour.
- 50 `SyncEvent`s with monotonically (mostly) updating reserves.
- 50 sets of encrypted logs and partial-note finalizations.

**What an observer can infer:**
- 50 swaps of "1 ETH for ~1800 USDC each" happened during the hour. Many of them might be Bob, all of them might be Bob, or none of them might be Bob.
- Without out-of-band knowledge of Bob's identity, the observer cannot distinguish Bob's 50 swaps from any other user's similarly-sized swaps in the same hour.

**Privacy outcome:** Bob is anonymized by traffic. The combination of (a) rounded amount, (b) high-traffic hour, (c) common operation type maximizes Bob's anonymity set.

### Example 3 — Carol provides liquidity, holds for a week, withdraws

Carol does `add_liquidity` on day 0 with 10 ETH + 18,000 USDC; receives encrypted LP-token partial-note; waits 7 days; calls `remove_liquidity` on day 7.

**What an observer sees on day 0:**
- One `MintEvent { amount0: 10 ETH, amount1: 18,000 USDC, liquidity: ~13,416 LP }`.
- One `SyncEvent` reflecting the new reserves.
- One `ProtocolFeeMintedEvent` if applicable (small amount to the protocol's `fee_to` address).
- Encrypted partial-notes for Carol's LP receipt and any refunds.

**What an observer sees on day 7:**
- One `BurnEvent { amount0: 10.X ETH, amount1: 18,XXX USDC, liquidity: ~13,416 LP }` — amounts slightly higher than day 0 (the LP earned fees over the week).
- One `SyncEvent`.
- Encrypted partial-notes for Carol's redeemed tokens.

**What an observer can infer:**
- Two events on the ETH/USDC pair, 7 days apart, with matching `liquidity` values (the same ~13,416 LP). The mint and burn are *amount-linkable*: an observer can probabilistically pair them up.
- Carol is anonymized at the address layer (no cleartext `Carol` address ever appears), but her *position* is linkable across the week if her `liquidity` value is unique among all LPs of this pair during the window.

**Privacy outcome:** Address is hidden, but position tracking is possible. For thin pools with few LPs, this is a meaningful side channel; for crowded pools it is not. **Mitigation:** LPs concerned about position tracking can split their position into multiple smaller deposits with different fractional amounts, or use stealth addresses across multiple wallets.

## In-scope vs. out-of-scope responsibilities

| Concern | In scope (contract-level) | Out of scope (framework / user infrastructure) |
|---|---|---|
| Cryptographic encryption of private logs | Yes — uses Aztec `ONCHAIN_UNCONSTRAINED` correctly | — |
| Tag-derivation correctness | Yes — uses standard aztec-nr emit primitives | — |
| Routing of recipient through router buffer | Yes — verified in `protocol/periphery/src/main.nr` | — |
| Amount publicity | No — design choice; cannot hide amounts on public-reserves AMM | User-side: amount discipline, traffic mixing |
| Tx-shape fingerprinting | Partial — placeholder partial-notes normalize within-category counts | Architectural changes would require redesign (out of scope) |
| Network-layer correlation | No | User-side: Tor/VPN, self-hosted PXE |
| PXE query timing | No | User-side: self-hosted PXE |
| Cross-contract decryption (v4.1.2) | No | Aztec framework: closed in v4.2 |
| Position-tracking via mint/burn amount linkage | No — amount publicity is structural | User-side: split positions, stealth addresses |
| Pattern-of-life correlation | No | User-side: operational hygiene |

## What this analysis does NOT claim

- It does not claim formal cryptographic security beyond Aztec's primitives. We have not done a formal proof; we've reasoned through the channels using the documented behavior of aztec-nr.
- It does not claim immunity to side channels we did not enumerate. New side channels may exist that this document hasn't considered. A specialist privacy audit would catch additional channels.
- It does not claim that "private swap" means "untraceable swap." Amount-publicity is real. A determined attacker with pattern-of-life knowledge has a real attack surface.
- It does not claim immunity to framework-layer issues in older Aztec releases. The v4.1.x cross-contract shared-secret issue described in Channel 8 has been closed by the v4 framework (app-siloed oracle outputs), and SigalSwap runs on v4.3.0.

## How to verify the claims in this document

The contract-level claims (no public emission of private-caller address, router-as-buffer, tag derivation, nullifier shape) can be verified by reading:

- `protocol/core/src/main.nr` — pair contract. Search `emit` to find every public event emission point; verify that none of the private-path entries emit the user's address.
- `protocol/periphery/src/main.nr:115-138` (router's `_execute_one_hop_exact_in`) — verifies the router-buffer pattern: `recipient = self.address`, `callback_contract = self.address`.
- `protocol/lp-token/src/main.nr` — LP token. The `transfer` private entry uses sender's address only for note construction (encrypted), never for public emission.
- `protocol/factory/src/main.nr` — factory. All factory events are governance-related and do not contain end-user addresses.

The framework-level claims (encrypted-log delivery, tag construction, ECDH) are inherited from aztec-nr and are out of scope for verification by this document; see the aztec-nr docs.

## References

- Aztec framework `ONCHAIN_UNCONSTRAINED` message delivery: aztec-nr docs.
- SigalSwap entry-point classification: `protocol/core/src/main.nr`, `protocol/periphery/src/main.nr` (function annotations).
- Router buffer pattern: `protocol/periphery/src/main.nr:115-138` (single-hop), `538-590` (multi-hop).
