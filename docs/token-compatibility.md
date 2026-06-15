# SigalSwap token-compatibility surface: what the pair assumes about its tokens

The pair (`protocol/core/`) calls a small subset of the Aztec `Token` interface and assumes specific behaviors at each call site. This document enumerates every assumption, classifies each by whether the pair defends against violation or trusts the token, and maps each to either a test (in `protocol/core-tests/src/test/token_quirks.nr`) or a code reference for the defense.

A token deployed against this pair is required to behave consistently with these assumptions. SigalSwap is permissionless: pair creation and registration are open to anyone, and the factory performs **no on-chain vetting of which tokens a pair uses** (see "Where token trust actually lives" below). The assumptions documented here are what the pair contract itself enforces or absorbs without operator intervention; everything tagged **Trusted** has no on-chain defense and is the responsibility of the off-chain integration layer (the curated token list shipped by the official UI / router, plus wallet trust signals).

## Token methods the pair invokes

The pair binds to the Aztec Token interface at compile time via `use token::Token` (see `protocol/core/Nargo.toml`). At runtime, any contract whose selectors match Token's can occupy a pair's `token0` / `token1` slot. The selector surface the pair actually exercises:

| Method | Used by | Purpose |
|---|---|---|
| `balance_of_public(owner) -> u128` | every public entry (`add_liquidity_public`, `remove_liquidity_public`, `swap_exact_in_public`, `swap_exact_out_public`, `flash_swap`, `_skim`, `sync`) | Balance-delta accounting: pair measures deposit / payment / payout by reading its own balance before and after token movement |
| `transfer_in_public(from, to, amount, authwit_nonce)` | swap payout (line 1701), router-mediated public flows | Public-to-public delivery of swap output |
| `transfer_to_public_and_prepare_private_balance_increase(...)` | private `add_liquidity` (line 490, 497) | Private user deposit + partial-note staging |
| `prepare_private_balance_increase(to)` | private `skim`, `swap`, `remove_liquidity` | Stage a partial note for the recipient |
| `finalize_transfer_to_private(amount, partial_note)` | public continuations of all private entries | Complete partial-note delivery with public amount |
| `total_supply() -> u128` | not currently called | — |

The mock test contract `protocol/test-contracts/hostile-token/` implements selector-compatible versions of the **public-side** methods (`balance_of_public`, `transfer_in_public`, `mint_to_public`) plus mode-switching admin functions. Private-side methods are not implemented — private flows assume well-behaved tokens by construction (see §"Private flows" below).

## Assumption surface

For each assumption the pair makes, we tag the **defense class** as one of:

- **Absorbed**: the pair's accounting tolerates the violation without operator action.
- **Detected-and-reverted**: the pair detects the violation at execution time and reverts cleanly.
- **Recoverable**: the violation breaks an invariant temporarily; a recovery entry (`sync`, `skim`) restores it permanently.
- **Trusted**: the pair has no on-chain defense. SigalSwap does not vet tokens on-chain (registration is permissionless), so this assumption is the responsibility of the off-chain integration layer -- the curated token list the official UI / router ships, and wallet trust signals -- not of any factory control.

### 1. `transfer_in_public(from, to, amount)` reduces `from`'s balance by `amount`

The pair credits its own balance via this call (router-mediated flows, swap output to recipient, etc.). It assumes the balance actually moves.

**Defense class:** Detected-and-reverted. The pair reads `balance_of_public(self.address)` after each transfer; a non-moving transfer (NOOP) surfaces as zero balance delta and trips `NO_TOKEN0_DEPOSIT` / `NO_TOKEN1_DEPOSIT` (on `add_liquidity_public`) or `INSUFFICIENT_PAYMENT` (on `swap_exact_in_public` line 1727).

**Test:** `test_noop_transfer_blocks_add_liquidity_public` (`token_quirks.nr`).

### 2. `transfer_in_public` may deliver LESS than `amount` (FoT / burn-on-transfer)

A token may take a transfer fee or burn a fraction in transit. The pair-direct entries support this because they measure the delivered amount via `balance - reserve`, not the requested amount.

**Defense class:** Absorbed (pair-direct only). The pair-direct paths credit only what actually arrived. Router-mediated flows do **not** support FoT input tokens: the router pre-commits the input amount, so an under-delivering token leaves the pair short of the input the swap math requires, and the **pair** rejects it at its own balance-delta check (`INSUFFICIENT_PAYMENT`, in `protocol/core/src/main.nr`) -- not at the router. (The router's only callback-amount assert, `EXCESSIVE_CALLBACK_AMOUNT` at `protocol/periphery/src/main.nr`, guards the opposite direction: it bounds the pair *over*-requesting beyond the pre-committed amount.)

**Test:** `test_under_delivery_pair_direct_absorbs_undershoot` (`token_quirks.nr`).

**Source:** `protocol/core/src/main.nr` "Note on FoT undershoot" comment block; CLAUDE.md design table: "Fee-on-Transfer Support: ✓ pair-direct only."

### 3. `transfer_in_public` may deliver MORE than `amount` (over-delivery / rebase-up / minting)

A token may credit the recipient more than `amount` (e.g., interest-accruing tokens, malicious tokens that mint to confuse the pair). The pair's balance-delta accounting captures the surplus into reserves on the next state-touching entry.

**Defense class:** Absorbed. The pair's reserves are updated from balance reads at the end of each entry (`packed_reserves.write(balance0, balance1)`). Any over-delivery becomes part of the next operation's effective reserves and benefits all current LPs proportionally on the subsequent mint/burn (V2-strict imbalanced-excess capture). The over-delivered amount can also be skimmed via the permissionless `skim()` entry if it exceeds the deposit ratio.

**Test:** `test_over_delivery_inflates_first_mint_lp` (`token_quirks.nr`).

**Caveat:** A token that over-delivers consistently is functionally a rebase-up token (see assumption 5). The pair tolerates this but downstream consumers of the public events (e.g., indexers, TWAP oracles) may show "ghost" volume that doesn't correspond to user-initiated swaps. This is observability noise, not a correctness bug.

### 4. `balance_of_public(owner)` returns the actual public balance

The pair's entire balance-delta accounting model depends on this. If a token lies about its own balance, the pair's deposit / payment / payout math is built on the lie.

**Defense class:** **Trusted**. The pair has no defense against a token mis-reporting its own state. A hostile token can:

- Return a balance larger than reality → pair thinks it received tokens it didn't → mints LP for a phantom deposit; subsequent operations carry the lie forward.
- Return a balance smaller than reality → pair underflows on `balance - reserve` or refuses to credit a real deposit.

There is no on-chain defense. The only screen is off-chain: the curated token list the official UI / router ships, and wallets warning users when they interact with a non-canonical token. Pair creation is permissionless, so a pair against a balance-lying token can exist and be registered; the integration layer is what keeps users from being routed to it.

**Test:** `test_hostile_balance_fools_pair` (`token_quirks.nr`) demonstrates the defense gap explicitly.

**Integrator action:** Because nothing on-chain rejects untrusted tokens, any front-end or integrating contract must screen `token0` / `token1` against its own curated token list before presenting or routing to a pair. The official SDK's `createPair` explicitly makes the caller responsible for ensuring both addresses are valid Token contracts.

### 5. Balances change only via explicit token calls

The pair assumes that between two `balance_of_public` reads, the balance only changes if a transfer call ran. Rebasing tokens, interest-accruing tokens, or tokens with admin-mutable balances violate this.

**Defense class:** Recoverable. The pair's `sync()` entry reads current balances and writes them back to reserves, restoring the invariant `reserves == balances`. `sync()` is permissionless, allowed during pause, and intentionally cheap. The pair's TWAP accumulator may capture price drift during the desync window — `docs/twap-security.md` covers the cost-of-manipulation analysis for that vector.

**Test:** `test_force_rebase_then_sync_restores_invariant` (`token_quirks.nr`).

**Caveat:** TWAP consumers must use long observation windows (30+ minutes) per `protocol/core/README.md` "Oracle consumer guidance"; a desync followed by sync can shift the accumulation. See `docs/twap-security.md` for the manipulation-cost model.

### 6. `transfer_in_public` reverts cleanly on failure

If the token has internal restrictions (recipient blocklist, paused state, insufficient balance), it must surface as a Noir assertion failure that the pair's call wrapper propagates as a tx revert.

**Defense class:** Detected-and-reverted. Aztec's call mechanism propagates revert messages from callee to caller. The pair's transaction reverts with the underlying token's assertion message.

**Test:** `test_revert_on_recipient_surfaces_cleanly` (`token_quirks.nr`) — hostile token reverts with `HOSTILE_TOKEN_REVERT`; the pair's `add_liquidity_public` call surfaces the same message.

**Note:** "Returns `false` instead of reverting" — the EVM ERC-20 footgun — does not apply on Aztec. The Token interface uses Noir-style assertion semantics; there is no boolean return on transfer functions.

### 7. Same token at both `token0` and `token1` is rejected at construction

The pair's constructor asserts `token0 != token1` (`protocol/core/src/main.nr` `IDENTICAL_TOKENS`) and `token0 < token1` (`TOKENS_NOT_SORTED`). A pair cannot be created with the same token on both sides.

**Defense class:** Detected-and-reverted at deploy.

### 8. Token contracts do not re-enter the pair during a transfer

A token whose `transfer_in_public` calls back into the pair (e.g., `pair.add_liquidity_public(...)` from within the transfer) would create reentrant state mutation.

**Defense class:** Detected-and-reverted. Every public state-touching entry on the pair calls `self.internal._acquire_lock()` as its first action (`protocol/core/src/main.nr`: search for `_acquire_lock`). The lock is a flag in `packed_flags`; acquisition asserts the flag is currently unset and then sets it. A reentrant call into a locked entry trips `LOCKED`.

**Code reference for the defense:**
- Lock acquisition: `_acquire_lock()` helper, called as first state-touching line of `add_liquidity_public` (line 916), `remove_liquidity_public` (line 1029), `swap_exact_in_public` (line 1629), `swap_exact_out_public` (line ~1810), `_skim` (line 1997), `sync` (line 2071), and the private-entry public continuations.
- Lock release: implicit at entry exit (flag reset in the same `_acquire_lock` / `_release_lock` pattern).

**No standalone reentrant-token mock is shipped:** the lock's correctness is verifiable from source review, and the defense is exercised every time any public-direct entry runs against any token. Building a token that calls back into the pair adds significant Aztec-context-setup overhead (the callback target must dispatch a typed public function call with the pair's exact signature) without proportionally improving coverage beyond the source-level inspection. If a future code change weakens `_acquire_lock`, the entry-level tests in `test/security.nr` will fail first.

### 9. Token `mint_to_public` is well-behaved

The pair calls `mint_to_public` only on its own LP token (`SigalSwapLPToken`), not on user tokens. The LP token is deployed by the pair's constructor at a derived address and is therefore trusted-by-construction; no external token's `mint_to_public` is invoked by the pair.

**Defense class:** N/A (by architecture).

### 10. Token addresses are stable

The pair stores `config.token0` and `config.token1` as `PublicImmutable<AztecAddress>`. Once set at construction, the pair always calls those exact addresses. A token that "moves" (e.g., via proxy upgrade pattern) cannot affect the pair's binding.

**Defense class:** N/A (the pair stores fixed addresses; the question is whether the token at that address remains the same contract, which is an Aztec-level concern: contract bytecode at an address is immutable in the standard deploy flow).

## Private flows: stronger assumptions

The pair's private entries (`add_liquidity`, `remove_liquidity`, `swap_exact_in`, `swap_exact_out`, `skim`) call **private-side** Token methods (`transfer_to_public_and_prepare_private_balance_increase`, `prepare_private_balance_increase`, `finalize_transfer_to_private`, `transfer_to_public`). (`flash_swap` is NOT in this list -- it is a public-only entry that pays out via `transfer_in_public` and uses no private-side methods.) These methods rely on:

- Correct partial-note construction and finalization.
- Correct private-balance tracking via the standard `BalanceSet`.
- Correct authwit consumption semantics.

A token that misbehaves on the private side can:
- Break partial-note finalization (refunds, payouts).
- Mis-allocate private notes.
- Bypass authwit consumption.

The pair has no mid-tx detection for these classes of misbehavior. Private flows require a Token contract that conforms to the canonical Aztec Token semantics on the private side; with no on-chain token vetting, this is the responsibility of the off-chain integration layer (curated token list + wallet trust signals). The `hostile-token` mock intentionally does not implement private-side methods because exercising those paths against a malicious implementation produces failures whose root cause is "the token is malformed," not a pair-level defense gap.

## Where token trust actually lives

The pair contract trusts that whatever token address occupies its `token0` / `token1` slot at deploy time will behave consistently with assumptions 1-10. **Nothing on-chain enforces this.** SigalSwap is permissionless by design:

- `register_pair` (factory entry) validates the pair's `class_id` against the canonical pair-class, the LP-token deployment, the fee-tier whitelist, and token sorting -- but it does **not** validate the tokens themselves, and there is no token-allowlist map anywhere in the factory's storage. Anyone can permissionlessly create and register a pair against any contract that presents the Token selector surface.
- The factory deliberately has **no admin-gated token-admission control**, and adding one is a non-goal: it would reintroduce exactly the kind of privileged key the protocol's governance posture rejects (see `docs/admin-compromise.md`). The factory's job is the pair registry plus fee-tier / pause / class-id governance, not deciding which tokens may list.
- Token trust is therefore enforced **off-chain, at the integration layer**: the official UI and router ship a curated token list, and wallets surface trust signals. A pair against a non-curated or hostile token can exist and be registered; what keeps users away from it is the integration layer not routing to it, not any on-chain gate.
- Fee-tier choice is an informational signal only (a high-fee-tier pair hints "thin / experimental market"); it is not a token-quality gate.

## Recommendations for integrators

- **Wallets / UIs:** Display a token-trust signal alongside pair info. Surface whether the token is on your curated token list. Refuse to interact with non-curated pairs by default; require explicit user opt-in.
- **Indexers:** Account for the possibility of over-delivery (rebase-up tokens, interest-accruing tokens) producing reserve increases without a `MintEvent`. The pair's `SyncEvent` is the source of truth for current reserves; reconciling balance changes against event volume may show drift for non-canonical tokens.
- **Token authors who want SigalSwap support:** Conform to the canonical Aztec Token contract semantics. If your token has non-standard behavior (rebase, FoT), declare it explicitly in your README; operators can then decide whether to admit it.

## Open questions / future work

- **Factory-level token allowlist:** Intentionally not implemented and not planned. On-chain token admission would require a privileged admin key, which is a deliberate non-goal (see `docs/admin-compromise.md`). Token curation is an off-chain integration-layer concern.
- **Private-side hostile token mock:** Not built. Would require selector-compatible implementations of `transfer_to_public_and_prepare_private_balance_increase`, partial-note machinery, and authwit handling. Coverage payoff vs. effort is low because private-flow trust is structural.
- **Class-id-based token attestation:** A permissionless, non-admin signal -- e.g. the factory or an external registry attesting that a pair's tokens match known-safe `class_id`s -- could let integrators distinguish canonical tokens without introducing a gatekeeper key. Aztec's class-id system makes this feasible; design is open. This would be an *informational* signal for the integration layer, not an on-chain admission gate.

## Test coverage summary

| Test | Assumption tested | Defense class |
|---|---|---|
| `test_noop_transfer_blocks_add_liquidity_public` | 1 (transfer moves balance) | Detected-and-reverted |
| `test_under_delivery_pair_direct_absorbs_undershoot` | 2 (FoT pair-direct) | Absorbed |
| `test_over_delivery_inflates_first_mint_lp` | 3 (over-delivery / rebase-up) | Absorbed |
| `test_hostile_balance_fools_pair` | 4 (balance honesty) | **Trusted** (no on-chain defense; off-chain curated token list is the screen) |
| `test_revert_on_recipient_surfaces_cleanly` | 6 (revert propagation) | Detected-and-reverted |
| `test_force_rebase_then_sync_restores_invariant` | 5 (spontaneous balance change) | Recoverable (via `sync`) |

Reentrancy (assumption 8): defense verified by source review of `_acquire_lock` callers + the pair's existing `test/security.nr` lock canaries. No standalone token-side reentrant mock needed.

## References

- Pair token call sites: `protocol/core/src/main.nr` (search `Token::at`)
- HostileToken mock contract: `protocol/test-contracts/hostile-token/src/main.nr`
- Token-quirk tests: `protocol/core-tests/src/test/token_quirks.nr`
- Reentrancy lock: `_acquire_lock()` helper in `protocol/core/src/main.nr`
- Canonical Aztec Token reference: `vendor/aztec-packages/noir-projects/noir-contracts/contracts/app/token_contract/src/main.nr`
- FoT design rationale: `protocol/core/src/main.nr` "Note on FoT undershoot"
- CLAUDE.md design table: "Fee-on-Transfer Support" row
- TWAP cost-of-manipulation analysis: `docs/twap-security.md`
