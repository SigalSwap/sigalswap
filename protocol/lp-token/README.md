# SigalSwapLPToken

Minimal fungible token representing LP positions in a single SigalSwapPair. One LP Token instance is deployed alongside each pair; its address is derived deterministically from the pair's address (see "Bidirectional binding" below). The LP Token has no admin, no minter map, and no upgrade surface — the paired pair address is fixed at construction and is the only caller permitted to mint.

The LP Token's public ABI implements the core Token transfer/burn interface plus LP-specific methods (and `get_pair`); it omits the reference Token's mint-to-private, off-chain-delivery, and admin/minter surface. External composition (router, third-party integrations) can use the generic `Token::at(addr)` interface for transfer-side operations.

## Storage layout

| Slot | Field | Type | Description |
|------|-------|------|-------------|
| 0 | `pair` | `PublicImmutable<AztecAddress>` | The single pair allowed to mint. Set once at construction; never changes. |
| 1 | `balances` | `Owned<BalanceSet>` | Private LP balance per owner (note set) |
| 2 | `total_supply` | `PublicMutable<u128>` | Aggregate supply across private and public balances |
| 3 | `public_balances` | `Map<AztecAddress, PublicMutable<u128>>` | Public LP balance per address |
| 4 | `symbol` | `PublicImmutable<FieldCompressedString>` | Always `SSLP` |
| 5 | `name` | `PublicImmutable<FieldCompressedString>` | Always `SigalSwap LP` |
| 6 | `decimals` | `PublicImmutable<u8>` | Always 18 |

Token metadata is identical across every LP Token instance — wallets distinguish LP positions by contract address, and the pool tokens (token0, token1) are readable from the paired pair.

## Bidirectional binding

The LP Token's identity is bound to its pair in two cryptographic directions, so neither side can be substituted without the substitution being detectable.

### Pair → LP Token

The pair derives its LP Token address inside its own constructor using the compile-time `LP_TOKEN_CLASS_ID` constant and canonical deploy inputs:

```noir
// In SigalSwapPair's constructor:
let lp_init_hash = compute_initialization_hash(
    LP_CONSTRUCTOR_SELECTOR,
    hash_args([self.address.to_field()]),
);
let salted = SaltedInitializationHash::compute(
    LP_TOKEN_SALT, lp_init_hash, AztecAddress::zero(),
);
let lp_address = AztecAddress::compute_from_class_id(
    ContractClassId::from_field(LP_TOKEN_CLASS_ID),
    salted,
    PublicKeys::default(),
);
```

The derived address is cached in the pair's `lp_token` storage slot (and in `PairConfig.lp_token`) and is the only address the pair ever calls for mint/burn operations. Anything deployed at any other address is invisible to the pair.

### LP Token → Pair

The LP Token's `pair` field is a `PublicImmutable<AztecAddress>` initialized in the constructor from the single constructor argument and never written again. Mint paths assert `msg_sender == pair.read()`; only the specific paired pair contract can mint. The LP Token has no setter on this field, no governance entry, and no `ContractInstanceRegistry::update` call — the binding is permanent.

### Why neither direction can be spoofed

- **Fake LP Token bound to a real pair**: a fake LP Token deployed with `pair = real_pair_addr` lands at a different address than the canonical derivation (different bytecode → different `class_id`). The real pair only calls the canonical-derived address; the fake is unreachable.
- **Real LP Token bound to a fake pair**: the LP Token's stored `pair` is set at construction. A different pair address would produce a different LP-Token address by the canonical derivation; that LP Token (if deployed) wouldn't accept mints from the original real pair.
- **Class-id swap after deploy**: forbidden at the source level (no `update` call). The factory's `LP_TOKEN_WRONG_CLASS` check at `register_pair` time verifies the deployed LP Token's class_id matches `LP_TOKEN_CLASS_ID` before registration, catching any post-deploy bytecode swap that the contract-instance registry might otherwise allow.
- **Class-id collision attack**: `LP_TOKEN_CLASS_ID` is a Poseidon hash of compiled bytecode; collision = field-modulus brute force, infeasible.

The factory's `register_pair` enforces the same derivation a third time (using the same `LP_TOKEN_CLASS_ID` baked into the factory at compile time) before allowing the pair to be added to the registry. See `protocol/factory/README.md` for the registration-side perspective on the same binding.

## Public ABI

Entries grouped by gating model.

### Pair-only entries (mint paths)

| Function | Visibility | Description |
|----------|-----------|-------------|
| `mint_to_public(to, amount)` | public | Mints `amount` to `to`'s public balance. Asserts `msg_sender == pair`. Used by the pair on protocol-fee accrual and on the V2 first-mint zero-address lock. |
| `finalize_mint_to_private(amount, partial_note)` | public | Mints `amount` to a previously-prepared partial note. Asserts `msg_sender == pair`. Used by the pair's `_add_liquidity` to deliver freshly-minted LP into the user's private balance. |

### Authwit-gated entries

| Function | Visibility | Description |
|----------|-----------|-------------|
| `transfer_in_public(from, to, amount, authwit_nonce)` | public | Public-to-public transfer. Authwit on `from`. |
| `burn_public(from, amount, authwit_nonce)` | public | Public burn. Authwit on `from`. Used by the pair on `remove_liquidity_public`. |
| `transfer_to_public(from, to, amount, authwit_nonce)` | private | Private-to-public transfer (drains a private balance into a public balance). Authwit on `from`. Used by the router during `remove_liquidity` to move LP from the user's private balance to the pair before burn. |
| `transfer_to_public_and_prepare_private_balance_increase(...)` | private | Same as above, plus returns a partial note for a follow-on private deposit. |
| `transfer_in_private(from, to, amount, authwit_nonce)` | private | Private-to-private transfer. Authwit on `from`. |
| `burn_private(from, amount, authwit_nonce)` | private | Private burn. Authwit on `from`. |
| `finalize_transfer_to_private_from_private(from, partial_note, amount, authwit_nonce)` | private | Debits `from`'s private balance and completes a partial note. Authwit on `from`. **Note**: the completer-match in `complete_from_private` is against `msg_sender`, NOT `from` — the partial note was prepared by `msg_sender` and only `msg_sender` can complete it. The `from` parameter authorizes the private-balance debit via the standard authwit mechanism. |

### Self-call entries (sender-derived `from`)

| Function | Visibility | Description |
|----------|-----------|-------------|
| `transfer(to, amount)` | private | Private-to-private transfer using `msg_sender` as `from`. **The only path that emits an event** (see "Events" below). |
| `transfer_to_private(to, amount)` | private | public-to-private ramp (debits caller's public balance, credits recipient's private note). |
| `cancel_authwit(inner_hash)` | private | Standard self-cancel for authwits. |

### Permissionless entries

| Function | Visibility | Description |
|----------|-----------|-------------|
| `prepare_private_balance_increase(to)` | private | Returns a partial note that any later caller can complete (with the right completer and value). No authwit. The caller pays for the validity-commitment nullifier. |
| `finalize_transfer_to_private(amount, partial_note)` | public | Completes a partial note using `msg_sender` as both the `from` (debited public balance) and the completer. The partial note's validity commitment was prepared with the same `msg_sender` as completer; mismatched completer reverts at the partial-note layer. |

### Views

`public_get_name` / `private_get_name`, `public_get_symbol` / `private_get_symbol`, `public_get_decimals` / `private_get_decimals`, `get_pair`, `total_supply`, `balance_of_public(owner)`, and the unconstrained utility `balance_of_private(owner)` (PXE-only, returns 0 for any owner whose private keys the wallet doesn't manage).

## Mint authorization

Mint paths exist only at `mint_to_public` and `finalize_mint_to_private`. Both gate on `msg_sender == pair`. Removed in earlier hardening passes were `mint_to_private` (replaced by the partial-note flow) and `_finalize_mint_to_private_unsafe` (an `only_self` shortcut that previously allowed a parameterized completer; removed because the completer is now always the pair).

The pair calls these from eight sites:
- Protocol-fee accrual on each of the four mint/burn paths (`mint_to_public(fee_to, protocol_fee_amount)`).
- V2 first-deposit lock (`mint_to_public(zero, MINIMUM_LIQUIDITY)`) — fires on BOTH first-deposit paths, the private `_add_liquidity` and `add_liquidity_public` (two sites).
- `_add_liquidity` private path (`finalize_mint_to_private(liquidity, liquidity_partial_note)`).
- `add_liquidity_public` (`mint_to_public(recipient, liquidity)`).

## Burn paths

Three burn entries: `burn_public` (authwit), `burn_private` (authwit), and the public `_reduce_total_supply` (`only_self`, used by `burn_private` to mutate supply via the public-context enqueue). The pair burns its own LP balance via `burn_public(self.address, liquidity, 0)` — the `nonce = 0` self-call exemption applies because `msg_sender == from`.

## Total-supply conservation

`total_supply` is mutated at exactly four sites, each paired with a balance write of the exact same `amount`:

| Site | Supply change | Balance change |
|------|--------------|----------------|
| `mint_to_public` | `+amount` | `public_balances[to] += amount` |
| `_finalize_mint_to_private` | `+amount` | partial-note complete with `value = amount` (private credit) |
| `burn_public` | `-amount` | `public_balances[from] -= amount` |
| `_reduce_total_supply` (via `burn_private`) | `-amount` | `balances[from].sub(amount)` (private debit) |

Transfer entries do NOT touch supply — they preserve it by construction (each transfer is a `(sub, add)` pair on either the public balance map or the private note set, or one of each for the to-public / to-private paths).

u128 arithmetic panics on overflow / underflow. The pair-side `assert_reserve_fits(total_supply)` (u112 cap) bounds aggregate supply growth in practice far below u128 saturation.

## Note fragmentation and per-call note caps

A holder's private balance is a SET of notes (one note is created per credit: each `add_liquidity` mints exactly one LP note, each incoming `transfer` adds one). Spending reads and nullifies notes, and Aztec bounds how many notes a single call can consume.

- The framework `BalanceSet::sub` path (`transfer_to_public`, `transfer_in_private`, `burn_private`, the finalize-from-private path) does ONE `try_sub(amount, 16)` — at most 16 notes per call.
- Only `transfer` recurses (`subtract_balance`: 2 notes, then 8 per recursive frame), reaching ~58 notes before the per-tx nullifier cap binds.

`try_sub` selects notes value-**descending** and stops once the running sum reaches `amount`, so the LARGEST notes are spent first.

**Consequence for LP exit (L-class).** `pair.remove_liquidity` debits the LP via `transfer_to_public` (the 16-note path). A holder whose position is spread across more than ~16 notes (more than ~16 separate `add_liquidity` calls) whose 16 largest do not sum to the requested `liquidity` gets a clean `"Balance too low"` revert despite genuinely owning the balance. This is **recoverable, never a loss**: remove in chunks each `<=` the sum of the 16 largest notes, or first consolidate by self-`transfer`ing the full balance (the recursive path collapses up to ~58 notes into a single change note). The SDK's `removeLiquidity` docstring flags this; auto-consolidation is a planned SDK convenience.

**Dust-flooding is NOT an attack.** A third party can only ADD notes to a holder (every `from != msg_sender` spend path is authwit-gated, so an attacker cannot touch a victim's existing notes), and any note they push is value they donate. Because selection is value-descending and stops at the target, attacker dust (small notes) sorts LAST and is never consumed ahead of the holder's real notes — so flooding cannot strand a holder's position or force their spend to recurse deeper. NOTE FOR MAINTAINERS: this safety depends on the descending sort. Flipping the selector to ascending would let pushed dust block real-note selection and IS a regression.

**Over-fragmented `transfer` (>~58 notes).** A holder whose own balance is spread across more notes than the recursion can reach in one tx produces an unprovable transaction (the per-tx nullifier cap is hit mid-recursion) rather than a clean revert. No supply is created or destroyed; the remedy is to transfer a smaller amount or consolidate. Self-inflicted only — per the dust analysis above, a third party cannot drive a holder into this state.

## Permissionless `prepare_private_balance_increase`

The entry is callable by anyone with no authwit. Each call writes a fresh validity-commitment nullifier into the LP Token's nullifier subtree, paid for by the caller. This matches the Aztec reference Token's pattern.

A griefer could spam this entry to write useless commitments. The cost is borne by the spammer (gas grows with tree size), the LP Token's storage is unaffected (the contract doesn't store anything proportional to outstanding partial notes), and outstanding-but-never-completed partial notes are harmless garbage in the validity-commitment subtree. The design accepts the theoretical griefing surface in exchange for ergonomic composability with arbitrary contract callers (routers, aggregators, future periphery extensions).

## Partial-note replay (security boundary)

`PartialUintNote::complete()` checks the validity commitment via `nullifier_exists_unsafe` rather than `push_nullifier`, so the validity commitment is NOT consumed on completion — multiple completions of the same partial note are technically permitted at the framework layer.

Replay protection comes from the note-hash tree's uniqueness rule: the second insert of `compute_complete_note_hash(value)` reverts. So:

- **Same-value double completion**: second insert lands on a duplicate note hash → revert at the note-hash layer.
- **Different-value double completion**: both inserts succeed at the note-hash layer (different note hashes), but `finalize_mint_to_private`'s `assert msg_sender == pair` requires the pair to call twice, and the pair's `_add_liquidity` only calls `finalize_mint_to_private` once per `add_liquidity` invocation. The pair-side single-call invariant is the load-bearing constraint.

The transfer-flavored partial-note paths (`finalize_transfer_to_private` / `finalize_transfer_to_private_from_private`) require completer-match, which adds a second guard: only the original preparer can complete.

## Events

| Event | Visibility | Fields | Emitted by |
|-------|-----------|--------|-----------|
| `LPTransfer` | Private (encrypted to `to`) | `from`, `to`, `amount` | private `transfer` only |

### What `LPTransfer` is (and is not)

`LPTransfer` is emitted **only** by the private `transfer` entry, delivered **encrypted to `to`** via `deliver_to(to, MessageDelivery.ONCHAIN_UNCONSTRAINED)`. Per the aztec-nr message-delivery model, all `deliver_to` modes encrypt to the recipient's address key, so an `LPTransfer` log is readable **only by `to`** — it is **not** public, cleartext, or indexer-readable.

Its purpose is recipient-side wallet history: a delivered note already records the *amount* the recipient received (notes are self-recording in the UTXO model), but the note alone does not carry the *sender*. `LPTransfer` supplies that sender attribution, encrypted so only the recipient learns it.

This matches the Aztec reference Token exactly: that contract emits its `Transfer` event only on the `transfer` path (encrypted to the recipient) and emits nothing on mint, burn, the public-balance paths, or the ramps. SigalSwap follows the same design.

### Why the other balance-changing paths emit no event

Every other path that moves an LP balance is already recorded by a lower-level primitive the affected party observes directly, so a typed event would be redundant (and, for private logs, an extra observable on-chain footprint):

- **Private credits** (`finalize_mint_to_private`, the credit side of `transfer` / `transfer_in_private` / `transfer_to_private` / the finalize-to-private paths): the recipient's note is delivered encrypted to the owner. Receiving the note *is* the record of the increase.
- **Private debits**: publish a nullifier the spender's own wallet tracks.
- **Public balances** (`mint_to_public`, `transfer_in_public`, `burn_public`, the public legs of the ramps): change the `public_balances` map and `total_supply`, both readable directly from public state.

**Implication for indexers.** LP supply and the add/remove-liquidity lifecycle are reconstructed from the **pair's** public events — `MintEvent` / `MintPublicEvent` / `BurnEvent` / `BurnPublicEvent` / `ProtocolFeeMintedEvent`, each carrying the `liquidity` delta — not from LP-token events. Public LP balances are read from the `public_balances` map; the LP token deliberately emits no public-balance event, matching the reference Token. Private-to-private movement is, by design, visible only to the parties via note discovery (and the encrypted `LPTransfer`).

> **Attribution scope.** Sender attribution (the encrypted `LPTransfer`) is provided on the `transfer` path only; the authwit-mediated private-receive paths (`transfer_in_private`, `transfer_to_private`, `finalize_transfer_to_private_from_private`) deliver the recipient's note without a paired attribution event. This too matches the reference Token, whose plain `transfer_in_private` emits nothing. The recipient always sees the *amount* (the note); they do not always see the *sender*.

### Why `LPTransfer` and not `Transfer`

The standard Aztec Token's transfer event is named `Transfer`. SigalSwap's pair contract handles `token0` and `token1` via the Aztec Token interface AND mints LP tokens via this contract — both would otherwise emit a same-named `Transfer` with potentially-overlapping selectors when a single consumer decodes both in one tx. The `LP` prefix keeps the LP-position event distinct from pool-token `Transfer` activity in the same transaction.

## LOAD-BEARING invariants

These are constraints that LPs and external integrators implicitly trust. The source-level comment block at `lp-token/src/main.nr:11-18` carries the same statement; treat any change here that diverges from the source as a doc bug.

1. **No `ContractInstanceRegistry::update` call.** The lp-token contract MUST NOT include any call to Aztec's `ContractInstanceRegistry::update`, which would let a deployed contract reschedule its own class_id (bytecode swap at the same address). LPs are trusting that the bytecode they signed up with cannot silently change. The factory's `LP_TOKEN_WRONG_CLASS` check is the canary that catches a class swap at registration time, but the source-level invariant ensures this contract never authors such a swap from inside.
2. **`pair` is `PublicImmutable`.** Set in the constructor from the single argument; no setter, no governance entry. A different `pair` value would produce a different LP-Token address by the canonical derivation, so even if the binding were mutable, a switched-pair LP Token would no longer be reachable from the original pair's calls.
3. **Mint paths are pair-only.** No admin override, no governance unlock. The `assert msg_sender == pair` guard on `mint_to_public` and `finalize_mint_to_private` is the only authorization model.

## Cross-contract coupling note

The factory's `LP_TOKEN_CLASS_ID` import is the binding mechanism between factory and LP token: the factory bakes the value into its bytecode at compile time, and uses it at `register_pair` to verify the LP token deployed at the pair's derived address matches the blessed class. **A pair-class rotation that requires a NEW `LP_TOKEN_CLASS_ID` cannot be deployed against the existing factory** — the factory's baked-in constant won't match, and `register_pair` will revert with `LP_TOKEN_NOT_DEPLOYED` or `LP_TOKEN_WRONG_CLASS`. Pair-class rotations that change the LP class require a fresh factory deploy. See `protocol/factory/README.md`'s "Pair class ID and version" section for the rotation runbook.
