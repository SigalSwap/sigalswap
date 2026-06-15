# SigalSwapPair

The core AMM contract. Holds funds, computes swap math, manages reserves, and tracks TWAP price accumulators. Based on the constant-product algorithm described in the Uniswap V2 whitepaper, reimplemented in Noir for the Aztec privacy-preserving execution environment.

One pair contract is deployed per (token0, token1, fee_tier) combination. The pair is immutable once deployed -- governance is handled by the Factory.

## Storage layout

| Slot | Field | Type | Description |
|------|-------|------|-------------|
| 0 | `config` | `PublicImmutable<PairConfig>` | Token addresses, factory, fee tier (set once) |
| 1 | `lp_token` | `PublicImmutable<AztecAddress>` | This pair's LP Token address, derived from the pair's own address in the constructor using the compile-time `LP_TOKEN_CLASS_ID` constant |
| 2 | `packed_reserves` | `PublicMutable<ReservesPacked>` | reserve0 and reserve1 packed into one Field |
| 3 | `block_timestamp_last` | `PublicMutable<u64>` | Last TWAP update timestamp |
| 4 | `price0_cumul_int` | `PublicMutable<Field>` | TWAP price0 integer accumulator (wraps at BN254 scalar field order) |
| 5 | `price1_cumul_int` | `PublicMutable<Field>` | TWAP price1 integer accumulator (wraps at BN254 scalar field order) |
| 6 | `packed_twap_frac` | `PublicMutable<TwapFractions>` | price0_frac and price1_frac packed |
| 7 | `packed_reserves_last` | `PublicMutable<ReservesPacked>` | Previous reserves for protocol fee calculation |
| 8 | `fee_to` | `PublicMutable<AztecAddress>` | Protocol fee recipient |
| 9 | `packed_flags` | `PublicMutable<FlagsPacked>` | is_paused, locked, protocol_fee_active, protocol_fee_percent |

**Storage packing**: Reserves, TWAP fractional parts, and control flags are packed two-u112-values-per-Field via three typed wrappers (`ReservesPacked`, `TwapFractions`, `FlagsPacked`) declared in `src/types/packing.nr`. Each wrapper implements `Packable` so storage reads return a typed struct and writes accept the same shape, while the underlying `pack_u112_pair` / `pack_flags` helpers stay as the math primitives the impls delegate to. The wire format is one Field per slot regardless; the wrappers move pack/unpack from imperative call sites to a typed boundary, eliminating accidental Field-vs-u128 comparisons elsewhere in the contract.

### PairConfig

```noir
struct PairConfig {
    token0: AztecAddress,           // Lower address (canonical ordering)
    token1: AztecAddress,           // Higher address
    factory: AztecAddress,          // Factory that created this pair
    fee_tier_bps: u32,              // Fee tier in basis points (e.g., 25 = 0.25%)
    version: u32,                   // Populated from compile-time VERSION global
    lp_token: AztecAddress,         // Derived LP Token address (see below)
}
```

**Token-sort precision.** The pair constructor and the factory's `register_pair` both assert canonical ordering as `(token0.to_field() as u128) < (token1.to_field() as u128)` — the lower 128 bits of the BN254 field element. Two distinct addresses with identical lower-128 bits would pass the inequality check (`token0 != token1` is full-Field) but fail the sort assertion under both orderings, leaving them un-pair-able. For randomly-derived Aztec addresses (Poseidon hash of `class_id`, `salt`, `deployer`, `public_keys`), the realistic collision probability at any practical deployment scale is ~2^-88, far below any meaningful threat threshold. A vanity-mining attack on a specific 128-bit pattern costs ~2^128 hashes, computationally infeasible. The pair and factory MUST stay consistent on the comparison method; both currently use the u128 truncation, accepting the negligible collision tail in exchange for lower per-call constraint cost relative to a full-Field comparison.

### LP Token address derivation

The pair does not accept an LP Token address as a constructor argument. Its constructor derives the LP Token's address deterministically from the pair's own address, using the compile-time `LP_TOKEN_CLASS_ID` constant and canonical deploy inputs (`LP_TOKEN_SALT`, `deployer = zero`, `public_keys = default`). The derived address is cached in storage slot 1 (`lp_token`) and queried on every mint/burn/transfer call.

```noir
let lp_init_hash = compute_initialization_hash(
    LP_CONSTRUCTOR_SELECTOR,
    hash_args([self.address.to_field()]),
);
let salted = SaltedInitializationHash::compute(LP_TOKEN_SALT, lp_init_hash, AztecAddress::zero());
let lp_address = AztecAddress::compute_from_class_id(
    ContractClassId::from_field(LP_TOKEN_CLASS_ID),
    salted,
    PublicKeys::default(),
);
```

The LP Token implementation lives in `protocol/lp-token/` (contract `SigalSwapLPToken`). Its constructor takes only a `pair: AztecAddress` argument. The mint entries (`mint_to_public`, `finalize_mint_to_private`) are restricted to the stored pair (`msg_sender == pair`); the burn entries debit the owner's own balance and are authwit-gated rather than pair-gated -- the pair triggers burns through its remove-liquidity flow. Coupled with the derived-address design, this means:

- An attacker cannot substitute a malicious LP Token contract: the pair only ever interacts with `lp_token = compute_from_class_id(LP_TOKEN_CLASS_ID, hash([pair.address]), ...)`. Anything deployed at any other address is invisible to the pair.
- An attacker cannot deploy a "fake pair" that uses an existing LP Token: the LP Token's stored `pair` is set at construction and never changes; a different pair address derives a different LP Token address anyway.
- An attacker cannot call the mint entries (`mint_to_public`, `finalize_mint_to_private`) directly: the `assert(msg_sender == self.pair)` check rejects every caller except the specific paired pair contract. (The burn entries are gated by the owner's authwit, not by the pair, so a holder can always burn their own balance.)

The factory's `register_pair` asserts (via the `get_contract_instance_class_id_avm` AVM oracle) that the LP Token is deployed at the pair's derived address with the expected class id before completing registration. This catches the DOS case where a pair is registered but its LP Token was never deployed.

### Version

```noir
pub global VERSION: u32 = 1;
```

The pair self-describes its schema/behavior version via a compile-time global in `core/src/main.nr`. The constructor copies `VERSION` into `PairConfig.version`, so every pair instance carries its version immutably in storage. The factory cross-checks `pair.get_version()` against its admin-declared `pair_class_version` at `register_pair` time; a mismatch reverts with `VERSION_MISMATCH`. To ship a new pair implementation, bump this constant and run through the factory upgrade flow (see `factory/README.md`). Because `VERSION` is not a constructor argument, the factory's init-hash check only covers the four external constructor parameters (`token0`, `token1`, `factory`, `fee_tier_bps`).

## Functions

### Constructor

```noir
#[external("public")]
#[initializer]
fn constructor(
    token0: AztecAddress,
    token1: AztecAddress,
    factory: AztecAddress,
    fee_tier_bps: u32,
)
```

Initializes the pair's immutable config. Called once during deployment. The pair derives its LP Token address internally from `self.address` + the hardcoded `LP_TOKEN_CLASS_ID` constant -- there is no `liquidity_token` constructor argument because the binding is cryptographic, not caller-supplied (closes the malicious-LP-token attack surface).

### Add liquidity

#### Private entry point

```noir
#[external("private")]
fn add_liquidity(
    amount0_max: u128,
    amount1_max: u128,
    amount0_min: u128,
    amount1_min: u128,
    authwit_nonce: Field,
)
```

User adds liquidity from their private token balance. Transfers `amount0_max` and `amount1_max` from the caller's private balance to the pair's public balance. The public phase computes optimal amounts and refunds any excess back to the caller's private balance via partial notes.

**Flow**: Private (transfer tokens, prepare partial notes) -> Public (compute amounts, mint LP, refund excess)

#### Public entry point (router-mediated)

```noir
#[external("public")]
fn add_liquidity_public(
    recipient: AztecAddress,
    amount0_min: u128,
    amount1_min: u128,
)
```

Used by the Router. Tokens must already be deposited in the pair's public balance before this is called. The pair derives the deposit from its own balance delta (`balance_i - reserve_i`), so a direct caller who does not pre-deposit sees zero delta and reverts at `NO_TOKEN0_DEPOSIT` / `NO_TOKEN1_DEPOSIT`. No authwits needed (the caller has already moved the tokens). LP tokens are minted to `recipient`'s public balance.

This is safe only when the deposit and this call happen atomically in one transaction, as the Router and SDK arrange. Because the entry is permissionless and mints LP for whatever balance delta is present, a direct integrator who pre-deposits in one transaction and calls in a later one exposes that deposit: a third party can call `add_liquidity_public(attacker, ...)` first (the public mempool is fee-ordered) and claim the pending tokens. Direct (non-router) integrators must deposit-and-call in a single transaction, or use the atomic private `add_liquidity` entry.

V2-strict deposit semantics: the full `balance_i - reserve_i` is consumed and reserves grow to balance. LP is minted only for the matched (pair-ratio) portion via `compute_liquidity`'s `min(...)` formula; the **off-ratio remainder** of an imbalanced deposit flows into reserves and benefits all LPs proportionally on the next mint or burn -- mirroring V2's `mint`. **Important caveat on donations:** unlike the private `_add_liquidity` path (which caps the matched amount at the caller's authorized max, so a donation stays in reserves for all LPs), this public path has no cap, so a donation that is AT the pool ratio (balanced) is matched into the *next* `add_liquidity_public` caller's mint and credited as LP to *them* -- the standard V2 `mint` semantic, NOT a proportional gift to existing LPs. Existing LPs are never diluted (floor rounding preserves their per-share value), and only the off-ratio remainder stays in reserves. So a third party cannot reliably "gift to all LPs" via this path; an accidental donor recovers via `skim`. Direct callers are responsible for pre-computing the optimal pair-ratio deposit off-chain (the SDK and the Router both do this for their callers).

The `amount_i_min` bounds guard the caller against pool-ratio movement between the deposit transfer and this call: if matching the pool's current ratio would consume less than `amount_i_min` of token_i, the call reverts.

**Logic (both variants)**:
1. Assert `recipient != zero` and not paused; acquire lock
2. Read reserves and the pair's actual token balances; derive deposit = `balance - reserve`; assert both deltas > 0
3. Mint protocol fee LP tokens if fee is active (captures K growth)
4. Compute matched amounts via `get_amounts_to_add` (price-ratio matching, asserts `amount_i >= amount_i_min`)
5. Compute LP tokens: first deposit = `sqrt(a0 * a1) - MINIMUM_LIQUIDITY`, subsequent = `min(a0 * supply / r0, a1 * supply / r1)`
6. Lock `MINIMUM_LIQUIDITY` (10000) permanently on first deposit
7. Update TWAP accumulators
8. Write reserves from balance (imbalanced excess + any pre-existing donations captured for LPs); release lock

### Remove liquidity

#### Private entry point

```noir
#[external("private")]
fn remove_liquidity(
    liquidity: u128,
    amount0_min: u128,
    amount1_min: u128,
    authwit_nonce: Field,
)
```

Burns LP tokens and returns proportional token amounts to the caller's private balance. **Always allowed, even when paused** (recovery operation).

#### Public entry point (router-mediated)

```noir
#[external("public")]
fn remove_liquidity_public(
    recipient: AztecAddress,
    liquidity: u128,
    amount0_min: u128,
    amount1_min: u128,
)
```

Used by the Router. LP tokens must already be deposited.

**Logic (both variants)**:
1. Check locked flag only (not paused -- withdrawals always work)
2. Mint protocol fee LP tokens
3. Compute amounts: `amount = burn * balance / supply` (uses actual balances for fairness)
4. Burn LP tokens
5. Send tokens to user
6. Update TWAP and reserves

### Swap (exact input)

#### Private entry point

```noir
#[external("private")]
fn swap_exact_in(
    token_in: AztecAddress,
    token_out: AztecAddress,
    amount_in: u128,
    amount_out_min: u128,
    authwit_nonce: Field,
)
```

Swaps an exact amount of input tokens for as many output tokens as possible. Output goes to the caller's private balance.

**Logic**:
1. Check paused/locked
2. Read actual balance and cap input at declared `amount_in`: `swap_input = min(balance - reserve, amount_in)`. Fee-on-transfer (delivery undershoots) charges the actual-delivered amount; donations (delivery overshoots beyond declared) stay in reserves rather than inflating the user's output.
3. Compute output: `amountOut = (swap_input * (10000 - fee_bps) * reserveOut) / (reserveIn * 10000 + swap_input * (10000 - fee_bps))`
4. Send output to user's private balance
5. Update TWAP and reserves (donations on the input side land here)

### Swap (exact output)

#### Private entry point

```noir
#[external("private")]
fn swap_exact_out(
    token_in: AztecAddress,
    token_out: AztecAddress,
    amount_out: u128,
    amount_in_max: u128,
    authwit_nonce: Field,
)
```

Swaps up to `amount_in_max` input tokens for exactly `amount_out` output tokens. Authorized input that wasn't consumed is refunded to the caller's private balance.

**Logic**:
1. Read actual balance and cap at the user's authorization: `user_authorized = min(balance - reserve, amount_in_max)`. Fee-on-transfer (undershoots) caps at the actual delivery; donations (overshoots beyond `amount_in_max`) stay in reserves.
2. Compute required input: `amountIn = ceil((reserveIn * amountOut * 10000) / ((reserveOut - amountOut) * (10000 - fee_bps)))`
3. Refund `user_authorized - amountIn` to the caller's private balance
4. Send output to user
5. Update TWAP and reserves (donations on the input side land here)

### Swap (public, optimistic callback)

```noir
#[external("public")]
fn swap_exact_in_public(
    token_in: AztecAddress,
    token_out: AztecAddress,
    amount_in: u128,
    amount_out_min: u128,
    recipient: AztecAddress,
    callback_contract: AztecAddress,
    callback_selector: FunctionSelector,
)
```

Public swap using the optimistic transfer pattern. The pair:
1. Locks the pair (reentrancy guard)
2. Computes output and sends it to `recipient` optimistically
3. Calls `callback_contract` with `callback_selector(pair, token_in, amount_in)` to request payment
4. Verifies the pair's balance increased by at least `amount_in`
5. Updates TWAP and reserves
6. Unlocks

The callback contract must transfer `amount_in` of `token_in` to the pair before returning. `callback_contract` cannot be the zero address, the pair itself, either token contract, the LP token, or the factory.

#### Recipient validation across public entries

The four public entries (`add_liquidity_public`, `remove_liquidity_public`, `swap_exact_in_public`, `swap_exact_out_public`) each block a 6-element set of recipient addresses where minted LP or delivered tokens would be permanently stranded: `{zero, self, token0, token1, lp_token, factory}`. None of these addresses have a rescue surface for arbitrary deposits, so an off-by-one in caller code that lands tokens at one of them is unrecoverable.

The check structure differs by entry, by design:

- **Liquidity entries** (`add_liquidity_public`, `remove_liquidity_public`) emit `ZERO_RECIPIENT` for `recipient == zero` and `INVALID_RECIPIENT` for the other five. The split lets integrators distinguish "caller forgot to pass a recipient" (likely a wiring bug at the call site) from "caller passed a protocol-internal address" (likely a config/path bug).
- **Swap entries** (`swap_exact_in_public`, `swap_exact_out_public`) collapse all six into a single `INVALID_RECIPIENT`. Swap callers in practice always pass a derived recipient (router self-address, end-user wallet) and the disambiguation buys nothing — the caller fix is the same in either case.

Integrators that surface contract reverts to users should map both `ZERO_RECIPIENT` and `INVALID_RECIPIENT` to the same user-facing message ("invalid recipient address"); the distinction is for developer-side debugging only.

### Flash swap

```noir
#[external("public")]
fn flash_swap(
    amount0_out: u128,
    amount1_out: u128,
    borrower: AztecAddress,
    callback_selector: FunctionSelector,
    data: Field,
)
```

Atomic flash swap. The pair:
1. Locks, validates borrower
2. Sends requested amounts to `borrower` optimistically
3. Calls `borrower` with `callback_selector(pair, token0, token1, amount0_out, amount1_out, data)`
4. Verifies the K invariant: `(balance0 * 10000 - in0 * fee) * (balance1 * 10000 - in1 * fee) >= reserve0 * reserve1 * 10000^2`
5. Updates TWAP and reserves
6. Unlocks

**About the `data` argument.** `data` is a single `Field` by design — fixed-size args keep the circuit's constraint count bounded and predictable. This is sufficient for most use cases (e.g., pass a borrower-side storage key, a commitment to off-chain parameters, or a small enum/flag). Borrowers needing richer payloads should treat `data` as an opaque handle: store the full payload in their own contract's storage before calling `flash_swap`, then use `data` as the lookup key inside the callback. This pattern keeps the interface tight while imposing no practical limit on payload size.

The borrower must repay at least one side with the fee included. The transaction reverts atomically if K is violated.

### Recovery functions

```noir
#[external("private")]
fn skim(to: AztecAddress)
```

Sends excess tokens (balance - reserve) to `to`'s private balance. Allowed during pause. Most state-changing entries (burn, swap, flash, sync, and the private `_add_liquidity`) absorb pre-existing donations into reserves where they benefit LPs proportionally, capped by caller-supplied or authwit-bound declarations rather than raw balance-delta. The exception is `add_liquidity_public`, which has no such cap: a balanced (at-ratio) donation is matched into the next caller's mint (V2 `mint` semantic) rather than distributed to all LPs (see the `add_liquidity_public` section above). `skim` is the explicit recovery path for tokens that arrived at the pair outside any protocol interaction and would otherwise wait for the next state-changing call to be folded into reserves; it is permissionless because tokens at a contract with no withdrawal method are a known footgun.

```noir
#[external("public")]
fn sync()
```

Forces reserves to match current balances. Updates TWAP accumulators. Allowed during pause.

### Admin functions (factory-only)

```noir
#[external("public")]
fn set_pause(paused: bool)
```

Emergency pause/unpause. Only callable by the factory. When paused, deposits and swaps are blocked but withdrawals (`remove_liquidity`, `skim`, `sync`) always work.

```noir
#[external("public")]
fn set_protocol_fee(
    fee_to: AztecAddress,
    percent: u32,
    active: bool,
)
```

Updates protocol fee settings. Only callable by the factory. `percent` is 0-100 (percentage of LP fee added on top). Any fee-config change (`!active`, `percent` change, or `fee_to` rotation while active) zeroes `reserves_last`, so each governance change starts a fresh fee-accrual epoch — pre-change K-growth forfeits to LPs rather than being assessed at the new rate or redirected to the new recipient. A no-op push (no field changed) is silent (no event, no storage write).

### Utility functions (view, unconstrained)

All functions in this table are `#[external("utility")] unconstrained` — they run off-chain in the PXE simulator and are **not part of any proof**. SDKs and wallets may trust their return values for display and routing decisions. Contracts MUST NOT trust these values for authorization or state-gating — if another contract needs to gate on `isPaused`, it should call into the pair's constrained functions (which assert `PAUSED` internally) rather than consulting a utility.

The one exception is `get_version`, which is `#[external("public")] #[view]` — a constrained public static call. The factory uses this for its on-chain class-version cross-check at registration time.

| Function | Returns | Description |
|----------|---------|-------------|
| `get_reserves()` | `(u128, u128, u64)` | Current reserves and last update timestamp |
| `get_config()` | `PairConfig` | Immutable pair configuration (includes `version`) |
| `get_version()` | `u32` | Compile-time `VERSION` global; `#[view]` so the factory reads it on-chain at registration |
| `is_paused_view()` | `bool` | Off-chain pause check for SDK / wallet UI. On-chain callers should rely on the pair's constrained pause asserts instead. |
| `quote_amount_out(amount_in, token_in)` | `u128` | Expected output for given input (includes protocol fee) |
| `quote_amount_in(amount_out, token_out)` | `u128` | Required input for desired output (includes protocol fee) |
| `get_cumulative_prices()` | `(Field, u128, Field, u128, u64)` | TWAP accumulator values (int0, frac0, int1, frac1, timestamp). Integers are Field; compute TWAP via Field subtraction (`(cumul_T2 - cumul_T1) / (T2 - T1)`), which is correct for any realistic window since real deltas are always << BN254 scalar field order. |
| `get_spot_prices()` | `(u128, u128, u128, u128)` | Price ratios as fractions (num0, den0, num1, den1) |
| `get_position_value(lp_amount, total_supply)` | `(u128, u128)` | Token amounts represented by LP tokens |
| `get_pair_state()` | `(u128, u128, u64, bool, u32, bool)` | Full state: reserves, timestamp, paused, fee%, fee_active |

## Fee model

### LP fee

Configured per pair at deployment via `fee_tier_bps`. LPs receive 100% of this fee -- it is never diluted by the protocol. The trader-charged protocol markup is rounded up to whole basis points (integer bps cannot represent a fractional markup), so any sub-bps rounding remainder accrues to LPs, never the protocol; the protocol fee is therefore never floored to zero while fees are active.

### Protocol fee

An additive percentage on top of the LP fee:

```
total_fee_bps = lp_fee_bps + (protocol_active ? lp_fee_bps * protocol_percent / 100 : 0)
```

Protocol fees are captured lazily via LP token minting at the start of each `add_liquidity` or `remove_liquidity` call. The mint amount is computed from K growth:

```
fee_lp = totalSupply * (sqrt(K) - sqrt(K_last)) * protocol_percent / (sqrt(K) * 100 + sqrt(K_last) * protocol_percent)
```

At `protocol_percent = 20`, this produces the same 1/6 multiplier as Uniswap V2.

### Total fee computation

```
amountOut = (amountIn * (10000 - total_fee_bps) * reserveOut) / (reserveIn * 10000 + amountIn * (10000 - total_fee_bps))
```

## TWAP oracle

The pair maintains time-weighted average price accumulators in UQ112x112 fixed-point format (112-bit integer, 112-bit fraction). On every state-changing operation (mint, burn, swap, sync) where time has elapsed since the last block:

```
price0_cumulative += (reserve1 / reserve0) * time_elapsed
price1_cumulative += (reserve0 / reserve1) * time_elapsed
```

Oracle consumers read `get_cumulative_prices()` at two points in time and compute the TWAP as the difference divided by the time delta.

Accumulators are split into integer and fractional components stored in separate slots. The **integer component is a `Field`** (BN254 scalar, ~2^254), so the accumulator wraps modularly at the scalar field order rather than at 2^128. This mirrors Uniswap V2's uint256-wrapping semantic and eliminates silent truncation / brick risk for pools with extreme price ratios.

Each accumulator is a UQ112x112 split value: the true cumulative is `integer + fraction / Q112`, returned across the `Field` integer slot and the `u128` fractional slot. Consumers MUST reconstruct the full scaled value (`integer * Q112 + fraction`) **before** differencing. Dropping the fraction reads TWAP = 0 for any pair whose price ratio is below 1 in that direction (every decimal-mismatched pair, e.g. ETH/USDC) -- there the integer accumulator is permanently 0 and the entire price signal lives in the fraction.

```typescript
const Q112 = 1n << 112n; // 5192296858534827628530496329220096

const [int0_T1, frac0_T1, int1_T1, frac1_T1, ts_T1] = await pair.getCumulativePrices();
// ... later ...
const [int0_T2, frac0_T2, int1_T2, frac1_T2, ts_T2] = await pair.getCumulativePrices();

// Reconstruct the full UQ112x112 accumulator (integer * Q112 + fraction) per
// read, per direction, then difference. NEVER difference the integer alone.
const scaled0_T1 = int0_T1 * Q112 + frac0_T1;
const scaled0_T2 = int0_T2 * Q112 + frac0_T2;

// Only the integer slot is a Field (wraps mod FIELD_MODULUS); the fraction is a
// u128 < Q112. The reconstructed scaled value `integer * Q112 + fraction` therefore
// wraps at FIELD_MODULUS * Q112, NOT at FIELD_MODULUS -- correct the wrap in that
// modulus. (In practice real accumulation deltas are always << this for any
// realistic window, so the correction never fires; it must still use the right
// modulus to be correct if it ever does. The SDK's twapBetween uses exactly this.)
const ACC_MODULUS = FIELD_MODULUS * Q112;
const deltaScaled = (scaled0_T2 - scaled0_T1 + ACC_MODULUS) % ACC_MODULUS;

// twapScaled is the mean price over the window in UQ112x112 units (price * Q112).
// Keep it scaled for full precision, or divide by Q112 for the plain ratio.
const twapScaled = deltaScaled / BigInt(ts_T2 - ts_T1);
const twapPrice = twapScaled / Q112; // floor; loses sub-unit precision
```

The SDK's `SigalSwapPair.twapBetween(earlier, later)` helper performs this reconstruction for both directions; prefer it over hand-rolling the arithmetic.

### Oracle consumer guidance (important)

TWAP accumulators on a permissionless constant-product AMM are manipulable by donation timing. Any holder of `token0` or `token1` can transfer tokens directly to the pair address (bypassing swap/mint), which doesn't change reserves immediately — but the next call to `sync()` (or any reserves-touching operation) snaps reserves to the new balance and causes subsequent TWAP accumulation to happen at the post-donation price. The donor permanently loses the donated tokens to LP value (K grows), so the attack has a real cost; its only payoff is whatever the attacker can extract from a downstream oracle consumer reading a manipulated TWAP.

This is a class of issue inherent to any constant-product AMM with a permissionless `sync` (or any reserves-touching public entry). There is no contract-level fix: donations are a primitive of the underlying token system (the pair cannot refuse incoming transfers), and even restricting `sync()` only moves the manipulation vector — `swap()` and other balance-reading paths can drive the same TWAP shift.

**If you're consuming this pair's TWAP, follow these rules:**

1. **Use long observation windows.** 30 minutes minimum; 1 hour or more is safer. With active arbitrage, manipulation cost is linear in window length — a 4-hour TWAP costs an attacker 8x more than a 30-min TWAP to skew by the same amount. **Caveat (arb-sparse / early Aztec):** against a no-arb swap-and-hold attacker, a longer window does NOT raise the cost (one swap, held longer); window length is not a substitute for pool depth when arbs are sparse. See `docs/twap-security.md`.
2. **Sample at least two points and average.** A single reading is unprotected. Two samples separated by your window length, averaged, resists single-block spikes.
3. **Never use this TWAP for short-timeframe price-sensitive operations.** Sub-minute liquidations, instant price feeds, anything with immediate high-value consequences — use a different oracle source, or accept the manipulation risk.
4. **Consider pool depth.** Low-liquidity pairs are cheaper to manipulate per unit of TWAP shift. Size against the **swap-and-hold no-arb floor**, NOT the old donation heuristic `2 * X / S` (= the `S/2` donation floor), which `docs/twap-security.md` establishes is ~19x–666x too optimistic and would under-size your pool badly. The conservative requirement is `pool TVL ≥ acceptable_attacker_cost / one_shot_LVR(target_skew, fee)`; per the minimum-pool table in `docs/twap-security.md`, forcing an attacker to pay ≥ $10k to skew 5% at the 25bps tier needs roughly a **$31M** pool (not $400k), and a 1% skew needs far more — i.e. absent active arbitrage, a single SigalSwap TWAP is only robust for high-value low-skew thresholds at very large depth or very long windows, so aggregate multiple oracles. (Once a mature arb market exists, the higher with-arbs cost applies and required depth shrinks.)
5. **Read cumulative values, not instantaneous price.** `get_cumulative_prices()` is the oracle surface. `get_reserves()` gives you the current spot price, which is trivially manipulable by any single swap.

Full quantitative cost analysis (with tables for pool size × skew × window × Aztec phase, three worked consumer scenarios, and the underlying derivation) lives in [`docs/twap-security.md`](../../docs/twap-security.md). The numbers there are produced by `tools/twap/cost_model.py` — run that script to plug in your own scenario.

For higher-precision oracles, a future protocol version could add an on-chain observation ring buffer (a circular log of price snapshots so consumers can query any past window without manually sampling). SigalSwap v1 does not — consumer-side discipline is the mitigation.

## First-mint inflation

When a pair has never had liquidity minted, the first LP's deposit sets the initial exchange rate. A naive design admits a well-known front-run:

1. Attacker front-runs the legitimate first LP and mints a tiny amount, e.g. a deposit of `(1, 1)` which is the smallest valid first deposit.
2. Attacker donates a large amount of both tokens directly to the pair (`token.transfer(pair, X)` outside of `mint`).
3. `totalSupply` is tiny (the attacker's 1-LP-token share minus the locked floor), but reserves are now huge (donated amount).
4. Victim's `amount * totalSupply / reserve` calculation rounds down heavily; they receive very few (or zero) LP tokens for their deposit.
5. Attacker withdraws — their fraction of `totalSupply` captures a proportional chunk of the victim's deposit.

The pair mitigates this by permanently locking `MINIMUM_LIQUIDITY = 10000` LP tokens to the zero address on the first mint. The first LP gets `sqrt(amount0 * amount1) - 10000`. This floors `totalSupply` at 10000, bounding how severely the attacker can inflate the reserves-to-supply ratio.

**Why 10000 and not V2's 1000?** For 18/8/6-decimal tokens (the overwhelming majority of realistic pairs), the locked cost is dust — sub-cent even at very conservative valuations. For 2-decimal or 0-decimal tokens (rare, usually legacy or weird design choices) the locked cost grows into dollars or more, which acts as a deliberate tax on pair creation for tokens whose decimal designs would make the pool harder to reason about anyway.

**LP guidance.** Use the `amount0_min` and `amount1_min` slippage bounds on `add_liquidity` / `remove_liquidity`. These protect against rate movement during the tx; if an attacker's inflation causes the rate to shift beyond the LP's `_min` bounds, the tx reverts.

## Authwit pattern

All private functions that transfer tokens include an `authwit_nonce: Field` parameter. This integrates with Aztec's authentication witness system:

1. The SDK creates an authwit authorizing the pair contract to call `transfer_to_public` on the token contract, scoped to the specific nonce
2. The private function uses this authwit to move tokens from the caller's private balance to the pair's public balance
3. The nonce ensures each authwit is single-use

### Two-token entries: shared nonce, two authwits

`add_liquidity` takes a single `authwit_nonce: Field` but issues token transfers against **both** tokens in the pair. Aztec's authwits bind to the call hash — `(caller, target, function_selector, args_hash, nonce)` — so each token transfer produces a distinct call hash even when sharing the nonce. Direct integrators must register one authwit per token transfer (two total for `add_liquidity`); both authwits share the same `nonce` value the entry was called with, but each binds to its own call hash. Reusing the nonce across both transfers is correct and intentional — it lets the entry take a single Field parameter while still gating each underlying transfer through the authwit system.

The router's `swap_exact_out` variants differ: each makes exactly **one** authwit-consuming transfer, on the **input** token (`transfer_to_public_and_prepare_private_balance_increase`); the output side uses `prepare_private_balance_increase`, which consumes no authwit. So an exact-out flow needs a single authwit (the input token), not two. The SDK handles authwit creation internally; integrators calling the contract directly should mirror these patterns.

## Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `MINIMUM_LIQUIDITY` | 10000 | Permanently locked on first mint. Prevents first-mint inflation attack and acts as a mild deterrent against pairs over low-decimal tokens. See "First-mint inflation" section. |
| `MAX_RESERVE` | 2^112 - 1 | Maximum reserve value (ensures K fits in BN254 field) |
| `Q112` | 2^112 | UQ112x112 scaling factor for TWAP |
| `TIMELOCK_DELAY` | 172800 (48h) | Governance timelock delay |
| `EXECUTION_WINDOW` | 604800 (7d) | Governance execution window after delay |

## Math libraries

All arithmetic uses constrained wide math to prevent overflow:

- **`mul_div(a, b, c)`** -- `floor((a * b) / c)` computed via Field (~254 bits) with unconstrained hint and on-circuit verification
- **`mul_div_up(a, b, c)`** -- `ceil((a * b) / c)` (rounds up to favor the pool)
- **`sqrt_product(a, b)`** -- `floor(sqrt(a * b))` using schoolbook 256-bit multiplication + Babylonian method
- **`sqrt(y)`** -- Babylonian method, 128 iterations (converges for all u128)

## Balance-based accounting

All balance-mutating entries (swaps, mints, burns) read actual token balances rather than trusting declared amounts. This correctly handles fee-on-transfer (deflationary) tokens where the received amount differs from the sent amount. Reserve updates use `new_reserve = token.balance_of(pair)` after all token movements complete; LP minting and refund formulas use the balance delta `balance_i - reserve_i` rather than the caller's declared `amount_i_max`, so an FoT-driven undershoot maps to a correspondingly smaller LP mint and refund (no LP overmint, no over-refund).

## Proving cost and user experience

User-side proving cost per flow (private circuit gate counts, v4.3.0):

| Flow | Total private gates | Composition |
|------|---:|---|
| Single-hop private swap | ~120K | router (8K) + token transfer (112K) |
| Multi-hop private swap | ~121K | router (8.5K) + token transfer (112K) — N hops adds public-side cost only |
| Add liquidity | ~233K | router (8.6K) + 2× token transfer (224K) |
| Remove liquidity | ~117K | router (8.3K) + LP transfer (108.8K) |
| Direct pair swap (private) | ~124K | pair (12K) + token transfer (112K) |

Public-direct entries (`add_liquidity_public`, `swap_*_public`, `flash_swap`, `sync`, `skim` public path) have **zero user-side proving cost** — they execute as public functions on the sequencer.

**SigalSwap-specific code contributes 8K–17K gates per flow**; the remaining 100K–225K comes from canonical Aztec Token machinery (BalanceSet, partial notes, authwit). Roughly 90% of user proving cost is Token-interface overhead inherited from the standard Aztec Token reference, not SigalSwap logic. Framework-level optimizations to the Token pattern flow through directly.

For per-function detail and the open Aztec-team questions on real-hardware proving time, see `docs/proving-cost.md`.

## Emergency pause behavior

| Operation | Paused | Active |
|-----------|--------|--------|
| add_liquidity | Blocked | Allowed |
| swap_* | Blocked | Allowed |
| flash_swap | Blocked | Allowed |
| remove_liquidity | **Allowed** | Allowed |
| skim | **Allowed** | Allowed |
| sync | **Allowed** | Allowed |

## Events

### Public Events

Emitted as unencrypted public logs. Visible to indexers and analytics.

| Event | Fields | Emitted by |
|-------|--------|-----------|
| `SwapEvent` | `token_in`, `token_out`, `amount_in`, `amount_out` | `_swap_exact_in`, `_swap_exact_out` |
| `SwapPublicEvent` | `sender`, `token_in`, `token_out`, `amount_in`, `amount_out`, `recipient` | `swap_exact_in_public`, `swap_exact_out_public` |
| `MintEvent` | `amount0`, `amount1`, `liquidity` | `_add_liquidity` |
| `MintPublicEvent` | `sender`, `amount0`, `amount1`, `liquidity` | `add_liquidity_public` |
| `BurnEvent` | `amount0`, `amount1`, `liquidity` | `_remove_liquidity` |
| `BurnPublicEvent` | `sender`, `amount0`, `amount1`, `liquidity`, `recipient` | `remove_liquidity_public` |
| `SyncEvent` | `reserve0`, `reserve1` | Every function that updates reserves |
| `FlashSwapEvent` | `borrower`, `amount0_in`, `amount1_in`, `amount0_out`, `amount1_out` | `flash_swap` |
| `ProtocolFeeMintedEvent` | `fee_to`, `amount` | All four liquidity-changing entries (`_add_liquidity`, `_remove_liquidity`, `add_liquidity_public`, `remove_liquidity_public`) when `protocol_fee_amount > 0` |
| `PairPausedEvent` | (none) | `set_pause(true)` on inactive-to-paused transitions. Idempotent calls emit nothing. |
| `PairUnpausedEvent` | (none) | `set_pause(false)` on paused-to-inactive transitions. Idempotent calls emit nothing. |

**Privacy note:** `SwapEvent`, `MintEvent`, and `BurnEvent` intentionally omit sender/recipient — these are the public settlement of private operations where user identity is hidden. `SwapPublicEvent`, `MintPublicEvent`, and `BurnPublicEvent` include identity because these are fully public operations. `ProtocolFeeMintedEvent` carries `fee_to` (already a public storage value) and the LP-token quantity minted as protocol revenue — sum across pairs to compute total revenue without joining against the LP Token's per-balance mint logs.

### Private Events

Emitted as encrypted logs, delivered to the sender. Only the sender's wallet can decrypt and query them via `aztec_getPrivateEvents`.

| Event | Fields | Emitted by |
|-------|--------|-----------|
| `PrivateSwapExactInEvent` | `token_in`, `token_out`, `amount_in`, `amount_out_min` | `swap_exact_in` |
| `PrivateSwapExactOutEvent` | `token_in`, `token_out`, `amount_in_max`, `amount_out` | `swap_exact_out` |
| `PrivateMintEvent` | `token0`, `token1`, `amount0_max`, `amount1_max` | `add_liquidity` |
| `PrivateBurnEvent` | `token0`, `token1`, `liquidity` | `remove_liquidity` |

**Note:** Swap events are split by direction so every field name accurately describes what was known at emission time. In private, the pair knows the sender (for encrypted delivery) but not the reserve-dependent output; in public, it knows the reserve-derived actual amounts but not the sender. No single private event can carry both.

- `PrivateSwapExactInEvent.amount_in` is the user's declared input (the entry argument). The public `SwapEvent` emitted in the same tx logs `min(actual_delivered, declared)`, so a fee-on-transfer undershoot is reflected there but a third-party donation (delivery beyond `declared`) is excluded from event volume — donations stay in reserves rather than counting as the user's swap. Indexers needing the canonical settled amount should read the public `SwapEvent`.
- `PrivateSwapExactOutEvent.amount_in_max` is the user's upper bound, **not** the actual input consumed. The actual spend is `amount_in_max - refund_note_value`, where the refund partial note is delivered to the sender in the same tx. Wallets that need the actual figure should reconcile via that note or read the public `SwapEvent` in the same tx.
- `SwapPublicEvent.amount_in` (emitted by `swap_exact_in_public`) is the full balance delta `balance_after - balance_before`, INCLUDING any callback overpay — public-path overpay is callback-driven and is part of the swap's economic effect, in contrast to private-path donations which are pre-existing third-party transfers.

The router contract emits mirror events (`RouterSwapExactInEvent`, `RouterSwapExactOutEvent`, `RouterMintEvent`, `RouterBurnEvent`) for router-mediated operations. Wallets should query all four swap event types for a complete user history.

## Privacy threat model

SigalSwap's core promise is that a trader's address is not publicly linked to the trades they execute. This section documents **what that actually guarantees on-chain** — separating the cryptographic guarantees from the residual side-channels that no contract-level design can close.

Full quantitative threat model, channel-by-channel analysis, three worked end-user scenarios, and a complete observable-surface enumeration (every public state slot, every public event, every encrypted log, every nullifier source) lives in [`docs/privacy-model.md`](../../docs/privacy-model.md). The summary below is the pair-scoped subset.

### What the pair emits per private swap

A private swap (exact-in or exact-out, direct to the pair — router flows are structurally similar) produces on-chain effects in two phases:

| Effect | Context | Visibility | Contains |
|---|---|---|---|
| `SwapEvent` | public | cleartext, visible to all | `token_in`, `token_out`, `amount_in`, `amount_out` |
| `SyncEvent` | public | cleartext, visible to all | `reserve0`, `reserve1` (new) |
| `PrivateSwapExactInEvent` / `PrivateSwapExactOutEvent` | private | encrypted, recipient-scoped | trader's swap intent (tokens, bounds) |
| Partial-note finalizations (1–2 per swap) | private | encrypted, recipient-scoped | output token to trader; refund of unused input for exact-out |
| Reserves, TWAP, `packed_flags` writes | public | cleartext | new values |

The public pieces (`SwapEvent`, `SyncEvent`, reserves) **do not contain the trader's address**. They describe what happened to the pool, not who did it. That's the core privacy design: an observer can reconstruct the pool's state evolution but cannot attribute any individual trade.

### What the encrypted envelope guarantees

Aztec's `ONCHAIN_UNCONSTRAINED` message delivery (see `MessageDeliveryEnum` in aztec-nr) provides these guarantees, quoted from the framework docs:

> "No information is revealed on-chain about sender, recipient, or the message contents. The message itself reveals no information about the sender or recipient, and requires knowledge of the recipient's private address keys in order to obtain the plaintext."
>
> "Identifying that a log corresponds to a message between a given sender and recipient requires, among other things, knowledge of both of their addresses **and** either the sender's or recipient's private address key."

Concretely, each encrypted log is prefixed with a tag derived via (roughly): `tag = H( H( H(DH(sender_ivsk, recipient_ivpk), contract_address), recipient_address), index)`, where `DH` is an elliptic-curve Diffie-Hellman between the sender's incoming-viewing secret key and the recipient's incoming-viewing public key. An observer who knows only public information (addresses, public keys) cannot compute the tag — the DH step requires a private key from one side. The contract-address hop means tags are app-specific; the directional hop means A→B tags differ from B→A tags even at the same app.

This closes the claim in audit finding C-L6 that `msg_sender` leaks "via encrypted event delivery" at the cryptographic layer: it does not, as long as the trader's incoming-viewing secret stays secret.

### What the envelope does NOT hide

The Aztec framework docs are explicit that on-chain *metadata* remains visible:

> "Delivering the message does produce on-chain information in the form of private logs, so transactions that deliver many messages this way might be identifiable by the large number of logs."

For SigalSwap specifically, this implies a handful of side-channels that a determined observer can exploit:

1. **Transaction shape fingerprinting.** A private swap produces a characteristic number of encrypted logs (one `PrivateSwap*` event + one output partial-note finalization + optionally one refund partial-note finalization for exact-out). Combined with the public `SwapEvent` emitted at the pair in the same tx, the shape `(N encrypted logs, 1 SwapEvent)` is distinctive. An observer can reliably classify a tx as "a swap on pair X" without decrypting anything. This is structural to the architecture — public reserves demand a public `SwapEvent`, and private wallet-history events emit encrypted logs.

2. **Timing / submission patterns.** An adversary watching the mempool or a user's network traffic can time-correlate the submission of a tx with the user's online activity. This is a network-layer concern that no on-chain design can close.

3. **PXE query patterns.** The trader's Private Execution Environment (PXE) must fetch encrypted logs from a node to scan for their tags. A PXE operator or an adversary observing PXE↔node RPC traffic can potentially correlate *which PXE instance queried which tx's logs*, and from that infer wallet↔tx linkage. Self-hosting the PXE mitigates the operator-trust angle but not the network-observer angle.

4. **Sender secret compromise (closed in v4.2).** Aztec v4.1.x's `getSharedSecret` oracle returned the raw ECDH shared secret without app-siloing. A malicious contract the user interacted with could theoretically call the oracle for a SigalSwap-emitted log's ephemeral pubkey and derive the same shared secret, enabling cross-contract decryption inside the user's PXE. Aztec v4.2 app-siloed the oracle output and SigalSwap targets v4.3.0 (the C-L6 mitigation is in scope), so this residual surface is closed in production.

### What a trader should assume

- **On-chain observers (block explorers, indexers)**: cannot attribute any individual swap to a specific address at the cryptographic layer. They see pool state changes and can count txs by shape.
- **Network-layer observers (ISP, VPN exit, RPC provider)**: can correlate tx submission timing with user IP → identity. Use a trusted PXE + privacy-preserving transport (Tor / VPN / mix-net) for stronger guarantees.
- **The user's own PXE operator**: trusts self. Run your own PXE for maximum privacy.
- **Other contracts the user interacts with in the same session**: prior to Aztec v4.2 these could theoretically decrypt SigalSwap events via the cross-contract shared-secret issue; closed by the v4.2 app-siloing fix and so not applicable to SigalSwap on v4.3.

### What's in-scope for SigalSwap to close vs. out-of-scope

| Concern | In-scope (contract-level) | Out-of-scope (framework / infrastructure) |
|---|---|---|
| Tx shape fingerprinting | Partially — the placeholder partial notes in exact-out multi-hop deliberately normalize note count across path lengths. Swap vs. mint vs. burn still distinguishable. | Making *all* tx types indistinguishable would require architectural redesign. |
| Cross-contract decryption (pre-v4.2) | Nothing; the issue was in the aztec-nr ECDH oracle. | Fixed in v4.2 via app-siloed secrets; SigalSwap runs on v4.3. |
| PXE query timing | Nothing; contract has no visibility into how the wallet fetches logs. | Yes — Aztec framework / user infrastructure concern. |
| Timing / mempool correlation | Nothing. | Yes — user's transport stack. |
| Encrypted payload confidentiality | Covered by Aztec's ONCHAIN_UNCONSTRAINED delivery as long as secrets aren't leaked. | — |

The honest summary: **privacy of "who traded what" holds at the cryptographic on-chain layer**, but the tx shape and any network-layer side channels are a user-trust-model concern that's shared across every Aztec private contract. A future SigalSwap version could explore alternative delivery patterns (partial-notes only, no explicit swap event) to reduce tx-shape fingerprinting, but the tradeoff against wallet-history ergonomics is real and the current split — one encrypted event + partial notes — matches the normative Aztec pattern.
