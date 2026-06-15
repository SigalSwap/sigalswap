# SigalSwapRouter

The stateless, upgradeable entry point for SigalSwap. Provides deadline enforcement, multi-hop routing, and the optimistic callback pattern for secure token settlement. Does not hold user funds between transactions.

## Storage

| Field | Type | Description |
|-------|------|-------------|
| `factory` | `PublicImmutable<AztecAddress>` | Factory address. **On-chain trust boundary**: every router entry that takes a pair address calls `factory.get_pair_versioned_public(...)` to verify the supplied pair is the registered routing target before any value moves or callback fires; a frontend swapping in a fake pair address fails this check before authwit consumption. Also used by the SDK for pair lookups. |
| `hop_active` | `PublicMutable<bool>` | Multi-hop guard flag (prevents callback abuse between transactions) |
| `expected_callback_token` | `PublicMutable<AztecAddress>` | Expected token for next callback payment |
| `expected_callback_amount` | `PublicMutable<u128>` | Expected amount for next callback payment |

## How it works (Option A pattern)

SigalSwap uses the "Router transfers, Pair does math" pattern:

1. User calls a private Router function, which transfers tokens from the user's private balance to the Router's public balance
2. The Router enqueues a public function that calls the Pair
3. The Pair computes swap/liquidity math and moves tokens
4. The Router measures balance deltas and finalizes partial notes back to the user's private balance

This pattern keeps the Pair's math isolated from token movement logic and enables clean balance-based accounting.

## Functions

### Constructor

```noir
#[external("public")]
#[initializer]
fn constructor(factory: AztecAddress)
```

### Add liquidity (single-hop)

```noir
#[external("private")]
fn add_liquidity(
    pair: AztecAddress,
    token0: AztecAddress,
    token1: AztecAddress,
    liquidity_token: AztecAddress,
    amount0_max: u128,
    amount1_max: u128,
    amount0_min: u128,
    amount1_min: u128,
    deadline: u64,
    authwit_nonce: Field,
)
```

Adds liquidity through the Router with deadline enforcement. The Router pulls `amount_i_max` of each token from the user's private balance into its own public balance, reads the pair's live reserves, computes the optimal pair-ratio match (V2-router `quote` logic), transfers exactly that to the pair, and refunds the unused remainder back to the user's private balance via partial notes. LP tokens are minted to the user's private balance the same way. Donations to the pair pre-existing this call are absorbed into reserves by the pair's V2-strict mint -- they cannot be extracted via this entry.

**Two-token authwit constraint.** `add_liquidity` takes a single `authwit_nonce: Field` but pulls from both `token0` and `token1`. Direct integrators must register **two** authwits sharing this nonce -- one per token transfer. Aztec's authwits bind to the call hash `(caller, target, function_selector, args_hash, nonce)`, so each token's transfer produces a distinct call hash even when the nonce matches. `add_liquidity` is the only entry that needs two authwit-bound transfers. The exact-output variants (`swap_exact_out`, `swap_exact_out_multi_hop`) need **one** authwit on the input token: each makes exactly one authwit-consuming transfer (`transfer_to_public_and_prepare_private_balance_increase` on the input token), while the output side uses `prepare_private_balance_increase`, which consumes no authwit. The SDK handles authwit creation internally; integrators calling the contract directly should mirror the pattern.

### Remove liquidity (single-hop)

```noir
#[external("private")]
fn remove_liquidity(
    pair: AztecAddress,
    token0: AztecAddress,
    token1: AztecAddress,
    liquidity_token: AztecAddress,
    liquidity: u128,
    amount0_min: u128,
    amount1_min: u128,
    deadline: u64,
    authwit_nonce: Field,
)
```

Removes liquidity through the Router with deadline enforcement. Burns LP tokens and returns proportional token amounts to the user's private balance.

### Swap exact input (single-hop)

```noir
#[external("private")]
fn swap_exact_in(
    pair: AztecAddress,
    token_in: AztecAddress,
    token_out: AztecAddress,
    amount_in: u128,
    amount_out_min: u128,                  // User's post-fee minimum received
    deadline: u64,
    authwit_nonce: Field,
    fee_recipient: AztecAddress,           // Interface fee recipient (zero = no fee)
    fee_bips: u32,                          // Interface fee in basis points (0 = no fee, max 500)
)
```

Swaps an exact amount of input tokens for maximum output via a single pair. Shares the per-hop executor with the multi-hop path; interface fee deducted from the pair's output before the `amount_out_min` check.

### Swap exact output (single-hop)

```noir
#[external("private")]
fn swap_exact_out(
    pair: AztecAddress,
    token_in: AztecAddress,
    token_out: AztecAddress,
    amount_out: u128,                      // User's post-fee minimum received
    amount_in_max: u128,
    deadline: u64,
    authwit_nonce: Field,
    fee_recipient: AztecAddress,
    fee_bips: u32,
)
```

Swaps for an exact output amount. The router derives the pair-level target on-chain by grossing up `amount_out` for the interface fee, so the post-fee balance still covers the user's target. After fee deduction, the router asserts the remaining balance `>= amount_out` before finalizing the output note.

### Swap exact input (multi-hop)

```noir
#[external("private")]
fn swap_exact_in_multi_hop(
    path: [AztecAddress; MAX_HOPS + 1],   // Up to 4 token addresses
    pairs: [AztecAddress; MAX_HOPS],       // Up to 3 pair addresses
    path_length: u32,                       // 2-4
    amount_in: u128,
    amount_out_min: u128,
    deadline: u64,
    authwit_nonce: Field,
    fee_recipient: AztecAddress,           // Interface fee recipient (zero = no fee)
    fee_bips: u32,                          // Interface fee in basis points (0 = no fee)
)
```

Routes a swap through up to 3 pairs. Each hop uses the callback pattern for settlement. Slippage is only checked on the final output.

**Path example** (A -> B -> C):
- `path = [tokenA, tokenB, tokenC, zero]`, `path_length = 3`
- `pairs = [pairAB, pairBC, zero]`

**Constraints**:
- `path_length >= 2` (at least one hop)
- `path_length <= MAX_HOPS + 1` (at most 3 hops = 4 tokens)
- `fee_bips <= 500` (5%). See "Interface fee cap" below.

### Get factory

```noir
#[external("utility")]
unconstrained fn get_factory() -> pub AztecAddress
```

Returns the factory address. Used by the SDK to resolve pairs.

### Quote exact-input multi-hop (off-chain)

```noir
#[external("utility")]
unconstrained fn quote_exact_in_multi_hop(
    path: [AztecAddress; MAX_HOPS + 1],
    pairs: [AztecAddress; MAX_HOPS],
    path_length: u32,
    amount_in: u128,
) -> u128
```

Walks the path on-chain, calling each pair's `quote_amount_out` utility in
turn, and returns the expected amount of `path[path_length - 1]` for a swap
of `amount_in` units of `path[0]`. Reverts on `PATH_TOO_SHORT`, `PATH_TOO_LONG`,
`ZERO_INPUT_AMOUNT`, or any per-hop pair revert (`TOKEN_IN_IS_INVALID`,
`INSUFFICIENT_LIQUIDITY`, etc.).

Enabled by v4.3's end-to-end cross-contract utility-call support: the router
makes utility-to-utility calls into each pair via `self.call(SigalSwapPair::at(pairs[i]).quote_amount_out(...))`,
so the SDK gets one simulate round-trip instead of N pair-level lookups
orchestrated from TypeScript. Does not subtract the router's interface fee;
callers that apply a fee should subtract `result * fee_bips / 10_000` to
mirror the on-chain `_deduct_interface_fee` step.

### Quote exact-output multi-hop (off-chain)

```noir
#[external("utility")]
unconstrained fn quote_exact_out_multi_hop(
    path: [AztecAddress; MAX_HOPS + 1],
    pairs: [AztecAddress; MAX_HOPS],
    path_length: u32,
    amount_out: u128,
) -> u128
```

Symmetric walk in reverse: given a desired `amount_out` of
`path[path_length - 1]`, returns the input amount of `path[0]` that must be
supplied. At each hop `i` (from `path_length - 2` down to 0), calls the
pair's `quote_amount_in(current_amount, path[i + 1])` to translate
desired-output-at-i+1 into required-input-at-i.

If the eventual swap applies an interface fee, scale the returned amount up
by `10_000 / (10_000 - fee_bips)` before granting the authwit, otherwise the
on-chain `_deduct_interface_fee` step will leave the recipient short.

## Optimistic callback pattern

The Router uses a synchronous callback pattern for swap settlement, preventing the frontrunning vulnerability present in the "approve then swap" approach:

```
1. Router writes expected_callback_token and expected_callback_amount to storage
2. Router sets hop_active = true
3. Router calls pair.swap_exact_in_public(token_in, token_out, amount_in, min_out, router, router, callback_sel)
4. Pair computes output and sends to Router
5. Pair calls router.swap_payment_callback(pair, token_in, amount_in)
6. Router verifies: msg_sender == pair, token == expected, amount == expected
7. Router transfers tokens to Pair
8. Pair verifies balance increased, confirms K invariant
9. Router sets hop_active = false
```

### swap_payment_callback

```noir
#[external("public")]
fn swap_payment_callback(
    pair: Field,
    token: Field,
    amount: Field,
)
```

Called by Pair contracts during `swap_exact_in_public` / `swap_exact_out_public` to request payment. Security layers:

- **`hop_active` guard**: Only callable during an active swap (prevents calls between transactions)
- **msg_sender verification**: Caller must be the Pair address passed in the parameter
- **Expected token check**: Token must match `expected_callback_token` (prevents a malicious pair from requesting the wrong asset)
- **Expected amount upper bound**: Amount must be `<=` `expected_callback_amount`. The pair's own `balance_after >= balance_before + amount_in` check enforces the matching *lower* bound on honest pairs; the router's `<=` here defends against a registered pair over-billing in the callback. Together they bracket the callback amount to exactly `amount_in` for honest pairs. A registered-malicious pair could still under-bill in the callback, but doing so reverts its own `balance_after` check on the same call.
- **Bounded by user deposit per tx**: Within a single transaction the Router's public balance of any token is bounded above by what the user explicitly deposited via the entry-point authwit, so a callback (or repeat-invoked callback) can only ever drain what the user already authorized for this swap

**Note on repeat invocation within one hop.** A pair could technically call `swap_payment_callback` more than once during a single `swap_*_public` execution. Each invocation transfers up to the `expected_callback_amount` of the expected token. This is not a theft vector: the transfer source is the Router's own public balance for *this* transaction, which is bounded by the user's deposit (the ceiling the user authorized). So even a pathological pair that loops the callback can only drain what the user explicitly put in. Adding an explicit "one callback per hop" guard was considered and ruled unnecessary given this containment; it adds storage/gas for no reduction in realistic attack surface.

### Public balance between transactions

The Router holds zero of any token in its public balance during normal operation between transactions. **Two paths can leave non-zero dust at the Router's address:**

1. **Cyclic exact-in paths.** A multi-hop swap with a path like `[A, B, A]` does per-hop delta accounting only -- if the Router happens to have a pre-existing balance `Z` of `A` at the start of the tx, that `Z` carries through the tx unchanged.
2. **External donations.** Anyone can call `Token.transfer_in_public(_, router, amount, 0)` and land tokens at the Router's address with no owner record. There is no automatic refund.

**Recovery: `skim_to(token, recipient)`.** Permissionless. Anyone can sweep the Router's full balance of `token` to a chosen `recipient`. Reverts with `HOP_ACTIVE` if a swap is in progress (defense-in-depth against future refactors that might leave the flag set across a sub-call), `ZERO_RECIPIENT` if `recipient` is the zero address (would permanently lock the swept tokens), and `NO_BALANCE` if the Router holds nothing of `token`. Donations are a known footgun (sending to a contract with no withdraw method); permissionless skim lets any party reclaim dust before someone else does. Matches the Pair contract's skim semantics. Indexers can track activity via `RouterSkimEvent { token, recipient, amount }`.

## Deadline enforcement

Every public operation checks:

```noir
assert(self.context.timestamp() as u64 <= deadline, "EXPIRED")
```

This prevents stale transactions from executing at unexpected prices. The check happens in the public phase (only public functions have access to the block timestamp).

## Interface fee

Both multi-hop variants support an optional interface fee for frontend operators:

```
fee_amount = (pair_output * fee_bips) / 10000
user_receives = pair_output - fee_amount
```

- `fee_recipient` receives the fee in their public balance
- `fee_bips` is capped at **500 (5%)** to bound the worst-case skim from a hostile frontend. Anything larger reverts with `FEE_BIPS_TOO_HIGH` at the private entry point.
- Direct callers pass `fee_bips = 0` and `fee_recipient = zero` to skip
- `fee_bips > 0` with `fee_recipient = zero` reverts with `INVALID_FEE_CONFIG` at the private entry. Without this guard, the public continuation's `_deduct_interface_fee` short-circuit would silently waive the fee (user receives gross output, frontend operator records expected revenue that never arrived). The boundary assert surfaces the misconfiguration explicitly.
- The fee is deducted BEFORE `amount_out_min` is enforced, so `amount_out_min` represents the user's actual post-fee minimum received.
- Reverts with `FEE_EXCEEDS_OUTPUT` if the fee would consume the entire output (unreachable under the 5% cap for any non-zero output, but kept as a defensive check).
- Reverts with `INSUFFICIENT_OUTPUT_AMOUNT` if, after the fee, the delivered amount is below `amount_out_min`.

## Fee-on-transfer tokens

Router-mediated paths (`swap_exact_in*`, `swap_exact_out*`, `add_liquidity`) require **non-FoT input tokens**. The router pulls `amount_in` (or `amount_max`) from the user via `transfer_to_public` to its own public balance, then transfers the declared amount onward to the pair via the V3 callback or the optimal-pull pattern. With a fee-on-transfer input token, the actual delivery to the router falls short of `amount_in` by the FoT tax; the subsequent transfer to the pair reverts with the token contract's underflow check (router holds less than declared).

The pair's **direct private** entries (`pair.swap_exact_in`, `pair.add_liquidity`) handle FoT correctly via balance-based accounting at the pair (the pair derives the actual swap input from `balance_after - balance_before`, capped at the user's authorization). FoT support is therefore real but only via that entry point. Frontends and SDK helpers that need to support FoT input tokens should route directly through the pair rather than the router.

Output-side FoT is fine for swaps regardless of routing: the router measures `out_after - out_before` per hop, so the user's post-fee output naturally reflects whatever the token contract actually delivered.

## Multi-hop execution

The multi-hop coordinator (`_swap_exact_in_multi_hop`) chains swaps in a single public function:

```
For each hop i in [0, path_length - 2]:
    1. Set callback expectations (token, amount)
    2. Measure output token balance before
    3. Call pair[i].swap_exact_in_public(path[i], path[i+1], current_amount, 0, router, router, callback)
    4. Pair calls back, Router pays, Pair verifies
    5. Measure output token balance after
    6. current_amount = delta

After all hops:
    7. final_amount = current_amount - interface fee (if any)
    8. Assert final_amount >= amount_out_min (POST-FEE floor)
    9. Finalize final_amount to user's private balance
```

Every hop calls the pair with `min_out = 0`; the router enforces `amount_out_min` once, after the interface fee, so the bound always reflects what the user actually receives. The swaps are atomic: if the final post-fee delivery falls below `amount_out_min`, the entire transaction reverts.

### Exact-output multi-hop: path restrictions

The private entry rejects any path where the final output token appears elsewhere in the path (either as the initial input or as any intermediate). Concretely: `[A, B, C, A]` (triangular cycle) and `[A, B, C, B]` (hub-routing to an intermediate) both revert with `FINAL_TOKEN_REPEATED`. These shapes break exact-output's refund logic — the change-refund on the input token and the dust refund on intermediates each measure balances that would overlap the final-output balance when the tokens coincide, leaving nothing for the final-output send.

The restriction is specific to exact-output. Exact-input multi-hop (`swap_exact_in_multi_hop`) handles cyclic paths correctly because it has no change-refund step and measures the final token's balance cleanly regardless of where it appears in the path. Triangular arbitrage (`[A, B, C, A]` exact-in) is supported.

### Exact-output multi-hop: on-chain `amounts` derivation + per-hop delta refund

`_swap_exact_out_multi_hop` derives per-hop input ceilings on-chain by walking
backward through the pairs, calling `pair.quote_amount_in_public(amount_out, token_out)`
at each hop. This matches Uniswap V2's `getAmountsIn` pattern and eliminates
the SDK-stale-quote drift class (since compute and execute happen atomically
in the same public continuation, the derived ceilings reflect tx-time reserves
rather than quote-time).

Each hop's input is then bounded by the derived ceiling via `expected_callback_amount`;
if the pair's true required input is less than that bound (reserves shifted
favorably between our backward compute and the pair's own forward execution
within the same tx), the leftover intermediate token lands transiently at
the router and is refunded to the user's private balance.

Refunds use **per-hop deltas, not aggregate balance reads**. Each
`_execute_one_hop_exact_out` returns the precise amount consumed from
`path[i]`, so:
- Change refund on `path[0]` is `amount_in_max - consumed[0]`.
- Intermediate dust at `path[j]` is `amounts[j] - consumed[j]` (hop j-1
  delivered exactly `amounts[j]` per the V3 exact-output guarantee, hop j
  consumed `consumed[j] <= amounts[j]`).
- Final amount is `amounts[path_length - 1]` (the gross-up the SDK and
  on-chain compute targeted), then the interface fee is deducted.

Because none of the refund magnitudes come from `balance_of_public(self.address)`
totals, any pre-existing router stuck balance of any path token (donations,
cyclic exact-in dust, same-token reuse across non-adjacent path positions
like `[A, B, A, C]`) stays at the router across the swap. Stuck balances
are recoverable via the documented permissionless `skim_to` path; see the
"Public balance between transactions" section above. The router's pre-tx
balance of every path token is preserved across exact-out multi-hop.

```
Backward compute (in public continuation):
    pair_target_out = ceil(amount_out * 10000 / (10000 - fee_bips))
    amounts[path_length - 1] = pair_target_out
    For idx in [path_length - 1, 1]:
        amounts[idx - 1] = pair[idx - 1].quote_amount_in_public(amounts[idx], path[idx])
    Assert amounts[0] <= amount_in_max

Forward execution:
    For each hop i in [0, path_length - 2]:
        consumed[i] = pair[i].swap_exact_out_public(path[i], path[i+1], amounts[i+1], amounts[i], ...)

After all hops:
    - Refund (amount_in_max - consumed[0]) of path[0] to user via change note
    - For each intermediate path[j] (j in [1, path_length - 2]):
        dust = amounts[j] - consumed[j]
        if dust > 0:
            finalize partial note with dust to user
    - Deduct interface fee from amounts[path_length - 1]
    - Assert final_amount >= amount_out (POST-FEE floor)
    - Finalize output to user
```

## Slippage model

The router enforces slippage differently for the two swap directions:

### Exact-input slippage

The user supplies `amount_out_min` — the minimum post-fee final output they'll accept. The router's per-hop pair call passes `min_out = 0` at the pair level; the aggregate check `final_amount >= amount_out_min` runs once at the end after the interface fee is deducted.

**Why a single aggregate bound is sufficient (not per-hop):** in exact-in multi-hop, the pair does not callback to request input — the router pushes input directly. A malicious intermediate pair can only make the trade less profitable by returning a worse-than-expected amount of its output token; that shortfall propagates forward through subsequent hops (each hop processes whatever it received), and the aggregate bound catches the accumulated end-to-end loss. There is no mid-trade extraction vector that a per-hop bound would catch which the aggregate wouldn't.

Per-hop bounds would be an ergonomic improvement (faster reverts in the failure case, tighter debugging signals) but would not close any additional attack surface. The aggregate bound is the security boundary.

### Exact-output slippage

The user supplies `amount_out` (post-fee minimum received) and `amount_in_max` (input ceiling). Each hop uses exact-output semantics: the router asks `pair.swap_exact_out_public` for a specific target, and the pair callbacks requesting some `amount_in <= hop_ceiling`. The router's `swap_payment_callback` enforces `amount <= expected_callback_amount` per hop, which is set to the per-hop input ceiling before each hop. The aggregate check `final_amount >= amount_out` still runs once at the end after fee deduction.

**Why per-hop bounds ARE structurally required here:** the pair's callback requests input — if the router didn't enforce a per-hop ceiling, a malicious pair could request more than the user authorized, extracting tokens mid-trade. The per-hop callback bound is load-bearing; there's no "catch at the end" fallback for already-extracted tokens.

### Practical guidance for integrators

- For exact-input: set `amount_out_min` tight to your expected output. A loose bound (e.g., 0) opts out of slippage protection end-to-end.
- For exact-output: the SDK sizes the per-hop input ceilings; the user's `amount_in_max` caps total input. Set `amount_in_max` tight to your expected input plus a reasonable buffer for reserve shifts between quote and execution.
- Deadlines (`deadline` param) are separate protection: they cap how long a quote remains valid in the mempool. Set short enough to bound MEV exposure.

## Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `MAX_HOPS` | 3 | Maximum hops in a swap path (4 tokens max) |

**Rationale for `MAX_HOPS = 3`.** Path length is fixed-size in Noir, so `MAX_HOPS` sets the circuit cost paid by *every* multi-hop swap, regardless of actual route length. Each additional hop slot adds a pair call, two `balance_of_public` reads, a callback round-trip, and (for exact-output) an extra intermediate partial note — roughly 25–30% added proving and execution cost per hop bump. Empirically, >90% of multi-hop swaps on production V2/V3 routers are 2-3 hops; past that, accumulated slippage outweighs better price discovery. Deeper aggregation (5+ hops) is the domain of cross-DEX aggregators like 1inch, not single-DEX routers. Keeping `MAX_HOPS` at 3 minimizes the cost paid by the common case; if real usage data later shows the cap is binding on legitimate routes, bumping to 4 is a router-only redeploy (pair and factory untouched).

## Events

### Private Events

Emitted as encrypted logs, delivered to the sender. Queryable via the wallet's `aztec_getPrivateEvents` API. These cover all router-mediated operations (the primary path for end users).

| Event | Fields | Emitted by |
|-------|--------|-----------|
| `RouterSwapExactInEvent` | `token_in`, `token_out`, `amount_in`, `amount_out_min` | `swap_exact_in`, `swap_exact_in_multi_hop` |
| `RouterSwapExactOutEvent` | `token_in`, `token_out`, `amount_in_max`, `amount_out` | `swap_exact_out`, `swap_exact_out_multi_hop` |
| `RouterMintEvent` | `token0`, `token1`, `amount0_max`, `amount1_max` | `add_liquidity` |
| `RouterBurnEvent` | `token0`, `token1`, `liquidity` | `remove_liquidity` |

**Note:** Swap events are split by direction so every field name accurately describes what was known at emission time. See the pair contract's `PrivateSwapExactInEvent` / `PrivateSwapExactOutEvent` docs for the full rationale (short version: a private event can be addressed to the sender but can't yet know the reserve-derived actual input for exact-out swaps). The `Router` prefix distinguishes these from the pair's events because Aztec requires unique event names per contract. Wallets should query all four swap event types (pair + router, exact-in + exact-out) for complete user history.

For exact-out swaps specifically: `amount_in_max` is the user's upper bound, **not** the actual input consumed. Reconcile actual spend via the refund partial note finalized in the same tx, or read the public `SwapEvent` emitted by the pair.

For multi-hop swaps, `token_in` is the first token in the path and `token_out` is the last. Intermediate tokens are not included in the event.

### Public Events

Emitted as plaintext logs and visible to anyone (indexers, block explorers, integrators).

| Event | Fields | Emitted by |
|-------|--------|-----------|
| `RouterSkimEvent` | `token`, `recipient`, `amount` | `skim_to` |

`skim_to` is permissionless dust recovery: anyone can call it to push a stuck token balance held by the router (e.g. from a failed mid-tx accounting edge or a direct token donation) to a recipient address. The event surfaces the operation for indexers tracking router-held balances.
