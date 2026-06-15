// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 SigalSwap LLC. All rights reserved.
// Licensed under the Business Source License 1.1. See LICENSE in this directory.
//
// SigalSwap Core - Privacy-preserving AMM for Aztec
//
// This package contains the Pair contract (one deployed per trading pair).
// Factory is a separate package (protocol/factory/).
//
// Architecture:
// - Private entry points handle authwits, token transfers, and partial notes
// - Public internal functions compute amounts and update state
// - LP tokens managed by a separate token contract (Noir lacks inheritance)
// - Reserves stored explicitly for TWAP oracle support
//
// LOAD-BEARING INVARIANT: this contract MUST NOT include any call to
// Aztec's `ContractInstanceRegistry::update`. That primitive lets a deployed
// contract reschedule its own class_id (bytecode swap at the same address).
// Pairs are designed to be permanently immutable -- LPs and traders trust
// that the bytecode they interact with today cannot silently change. An
// `update` call would break that guarantee. The factory validates pair
// class only at registration; once registered, governance calls
// (`sync_protocol_fee`, `pause_pair`) route to whatever bytecode lives at
// that address, so a post-registration class swap could subvert governance
// signals. Upgrades are handled at the registry layer (new pair address,
// new version, factory updates routing) -- never via in-place bytecode
// swap.

// Shared types (PairConfig, QueuedAction)
pub mod types;

// Math libraries (safe math, sqrt, fixed-point)
pub mod math;

// Pair helper library (swap math, liquidity calculations).
// Exposed pub so dependent contracts (router) can re-use the quote logic
// (`get_amounts_to_add`) when computing the optimal deposit at tx time.
pub mod pair;

// Integration tests (TXE) live in the sibling `sigalswap_core_tests` crate so
// the test-fixture contracts stay out of this production build graph.

use aztec::macros::aztec;

/// Pair bytecode version. This constant is baked into the compiled bytecode:
/// any material change (logic, storage layout, public ABI) that should require
/// governance re-review MUST also bump VERSION. The factory queries this
/// constant during register_pair to verify it matches the admin-blessed
/// pair_class_version, making the governance pathway for a new pair class
/// explicit and tamper-evident.
///
/// Invariants:
///   - VERSION is strictly greater than zero.
///   - Every (pair_class_id, VERSION) pair is in 1:1 correspondence -- the same
///     compiled bytecode always reports the same VERSION.
pub global VERSION: u32 = 1;

/// The compiled class_id of SigalSwapLPToken. Baked in at compile time; the
/// pair uses this to derive its paired LP Token address in the constructor.
/// If the LP Token source changes, its class_id changes and the probe test
/// in `protocol/lp-token/src/test/class_id_probe.nr` fails, surfacing the
/// drift. Update both this constant and the probe constant together, then
/// recompile the pair.
pub global LP_TOKEN_CLASS_ID: Field =
    0x18d88f757fa7311208ca30529ea9cd60c78a2823a0e287ec661cbdc7f193f26c;

/// Salt used when deploying each pair's LP Token. Set to 1 to match TXE's
/// default deploy salt (TXE hardcodes `Fr.ONE`), so in-process tests can
/// land the LP Token at the pair's derived address without special salt
/// handling. The SDK's `createPair` helper must pass
/// `contractAddressSalt: new Fr(1n)` when deploying the LP Token in
/// production; any other salt lands the LP Token at a different address
/// than the pair derives, rendering the pair non-functional.
pub global LP_TOKEN_SALT: Field = 1;

#[aztec]
pub contract SigalSwapPair {
    use crate::{
        math::wide::{compute_amounts_in, mul_div, verify_k_invariant},
        pair::{
            MINIMUM_LIQUIDITY, assert_reserve_fits, compute_liquidity, compute_mint_fee,
            compute_quote_amount_in, compute_quote_amount_out, compute_twap_update,
            get_amount_in, get_amount_out, get_amounts_on_remove, get_amounts_to_add,
        },
        types::{PairConfig, FlagsPacked, ReservesPacked, TwapFractions},
    };
    use aztec::{
        context::gas::GasOpts,
        hash::hash_args,
        macros::{events::event, functions::{external, initializer, internal, only_self, view}, storage::storage},
        messages::message_delivery::MessageDelivery,
        protocol::{
            abis::function_selector::FunctionSelector,
            address::{AztecAddress, SaltedInitializationHash},
            contract_class_id::ContractClassId,
            public_keys::PublicKeys,
            traits::{FromField, Serialize, ToField},
        },
        state_vars::{PublicImmutable, PublicMutable},
    };
    use aztec::macros::functions::initialization_utils::compute_initialization_hash;
    use std::meta::derive;

    use token::Token;
    use sigalswap_lp_token::SigalSwapLPToken;
    use uint_note::PartialUintNote;

    // ================================================================
    // Events
    // ================================================================

    #[derive(Serialize)]
    #[event]
    struct SwapEvent { token_in: AztecAddress, token_out: AztecAddress, amount_in: u128, amount_out: u128 }

    #[derive(Serialize)]
    #[event]
    struct MintEvent { amount0: u128, amount1: u128, liquidity: u128 }

    #[derive(Serialize)]
    #[event]
    struct BurnEvent { amount0: u128, amount1: u128, liquidity: u128 }

    #[derive(Serialize)]
    #[event]
    struct SwapPublicEvent { sender: AztecAddress, token_in: AztecAddress, token_out: AztecAddress, amount_in: u128, amount_out: u128, recipient: AztecAddress }

    #[derive(Serialize)]
    #[event]
    struct MintPublicEvent { sender: AztecAddress, amount0: u128, amount1: u128, liquidity: u128 }

    #[derive(Serialize)]
    #[event]
    struct BurnPublicEvent { sender: AztecAddress, amount0: u128, amount1: u128, liquidity: u128, recipient: AztecAddress }

    #[derive(Serialize)]
    #[event]
    struct SyncEvent { reserve0: u128, reserve1: u128 }

    /// Emitted whenever the pair mints LP tokens to `fee_to` as protocol-fee
    /// accrual on a liquidity-changing operation. `amount` is the LP-token
    /// quantity minted; `fee_to` is the recipient at mint time. Indexers can
    /// sum this over time per pair to compute protocol revenue without
    /// joining against the LP Token's lower-level mint logs.
    #[derive(Serialize)]
    #[event]
    struct ProtocolFeeMintedEvent { fee_to: AztecAddress, amount: u128 }

    /// Emitted from `set_protocol_fee` when at least one of
    /// `(fee_to, percent, active)` actually changed. Lets indexers tracking
    /// pair-side state see a fee-config update without cross-correlating
    /// against the factory's governance events. Repeated `sync_protocol_fee`
    /// pushes that don't change state stay silent.
    #[derive(Serialize)]
    #[event]
    struct ProtocolFeeConfigChangedEvent { fee_to: AztecAddress, percent: u32, active: bool }

    /// Emitted from `set_pause(true)` when the pair transitions from active
    /// to paused. Mirrors the factory's `PairPausedEvent` so an indexer
    /// scoped to a single pair's address can observe pause-state changes
    /// without joining against the factory's governance event stream.
    /// Idempotent calls (`set_pause(true)` on an already-paused pair) emit
    /// no event.
    #[derive(Serialize)]
    #[event]
    struct PairPausedEvent {}

    /// Emitted from `set_pause(false)` on a paused-to-active transition.
    /// Sibling of `PairPausedEvent`; same idempotent-skip rule.
    #[derive(Serialize)]
    #[event]
    struct PairUnpausedEvent {}

    #[derive(Serialize)]
    #[event]
    struct FlashSwapEvent {
        borrower: AztecAddress,
        amount0_in: u128,
        amount1_in: u128,
        amount0_out: u128,
        amount1_out: u128,
    }

    // Private events -- encrypted to the sender, queryable via wallet's
    // getPrivateEvents. These log the user's requested parameters; actual
    // settlement amounts are determined in public and recorded by the
    // public `SwapEvent` above.
    //
    // Swaps are split by direction so every field name accurately describes
    // what was known at emission time:
    //   - PrivateSwapExactInEvent: `amount_in` is the actual input (known in
    //     private, enforced in public).
    //   - PrivateSwapExactOutEvent: `amount_in_max` is the user's upper bound;
    //     the actual input is computed in public and recoverable from the
    //     accompanying refund partial-note. The event intentionally does not
    //     claim an actual input amount it cannot know.
    //
    // The router defines a mirror pair of events (RouterSwapExactInEvent /
    // RouterSwapExactOutEvent) with the same fields. Wallets should query all
    // four types for a complete user history.

    #[derive(Serialize)]
    #[event]
    struct PrivateSwapExactInEvent { token_in: AztecAddress, token_out: AztecAddress, amount_in: u128, amount_out_min: u128 }

    #[derive(Serialize)]
    #[event]
    struct PrivateSwapExactOutEvent { token_in: AztecAddress, token_out: AztecAddress, amount_in_max: u128, amount_out: u128 }

    #[derive(Serialize)]
    #[event]
    struct PrivateMintEvent { token0: AztecAddress, token1: AztecAddress, amount0_max: u128, amount1_max: u128 }

    #[derive(Serialize)]
    #[event]
    struct PrivateBurnEvent { token0: AztecAddress, token1: AztecAddress, liquidity: u128 }

    // ================================================================
    // Storage
    // ================================================================

    #[storage]
    struct Storage<Context> {
        /// Immutable pair configuration (tokens, factory, fee tier)
        config: PublicImmutable<PairConfig, Context>,

        /// This pair's LP Token address. Computed in the constructor from
        /// this pair's own address using `LP_TOKEN_CLASS_ID` and the
        /// canonical deploy inputs (salt=LP_TOKEN_SALT (=1), deployer=zero, default keys).
        /// Set once; read on every mint/burn/transfer call. Matches the
        /// address the SDK's `createPair` helper computes and deploys the
        /// LP Token at.
        lp_token: PublicImmutable<AztecAddress, Context>,

        /// Current reserves packed into one slot (updated on every mint/burn/swap/sync).
        /// Packed as: reserve0 * 2^112 + reserve1. Both capped at u112.
        packed_reserves: PublicMutable<ReservesPacked, Context>,

        /// Block timestamp of last reserve update (for TWAP)
        block_timestamp_last: PublicMutable<u64, Context>,

        /// TWAP price accumulators (UQ112x112 split into integer + fraction).
        /// Integer parts are Field so the accumulator wraps modularly at the
        /// BN254 scalar field order rather than at 2^128 -- this avoids silent
        /// corruption / brick risk for pools with extreme price ratios. TWAP
        /// consumers compute `(cumul_T2 - cumul_T1) / (T2 - T1)` in Field; the
        /// subtraction is correct for any realistic accumulation window.
        price0_cumul_int: PublicMutable<Field, Context>,
        price1_cumul_int: PublicMutable<Field, Context>,
        /// TWAP fractional parts packed into one slot (both < Q112, fits in one Field)
        packed_twap_frac: PublicMutable<TwapFractions, Context>,

        /// Reserves at the last liquidity event, packed into one slot.
        /// Used for protocol fee calculation (compute_mint_fee computes sqrt via Field).
        /// Packed as: reserve0_last * 2^112 + reserve1_last.
        packed_reserves_last: PublicMutable<ReservesPacked, Context>,

        /// Protocol fee recipient address (set by factory via timelock)
        fee_to: PublicMutable<AztecAddress, Context>,

        /// Packed control flags: is_paused, locked, protocol_fee_active, protocol_fee_percent.
        /// Encoded as: percent * 8 + (is_paused | locked<<1 | fee_active<<2).
        /// Max value: 100 * 8 + 7 = 807. Fits in one Field trivially.
        packed_flags: PublicMutable<FlagsPacked, Context>,
    }

    // ================================================================
    // Constructor
    // ================================================================

    /// Initialize a new trading pair. Called by the Factory during pair creation.
    ///
    /// Caps fee_tier_bps at 4999 (49.99%) as defense in depth: the factory's
    /// whitelist enforces the policy cap, but an attacker could deploy a pair
    /// directly (bypassing the factory) with a nonsensical tier. Tiers >= 5000
    /// combined with the max 100% protocol markup would push total fee_bps to
    /// 10000+, which get_amount_out/get_amount_in reject with FEE_TOO_HIGH --
    /// we fail earlier and with a clearer error.
    ///
    /// `version` is NOT a parameter: the field in PairConfig is populated from
    /// the compile-time VERSION global (see the module-level constant above).
    /// This keeps version identity tied to bytecode -- no deployer input can
    /// cause a pair to claim a version its bytecode does not actually implement.
    #[external("public")]
    #[initializer]
    fn constructor(
        token0: AztecAddress,
        token1: AztecAddress,
        factory: AztecAddress,
        fee_tier_bps: u32,
    ) {
        assert(fee_tier_bps < 5000, "FEE_TIER_TOO_HIGH");
        // Defense-in-depth: the factory's register_pair already enforces
        // these, but a direct deployment (bypassing the factory) would
        // otherwise leave the pair in an unusable state. Fail at
        // construction so an unregistered pair can never exist in a
        // broken configuration.
        assert(!token0.is_zero(), "TOKEN0_ZERO");
        assert(!token1.is_zero(), "TOKEN1_ZERO");
        assert(!factory.is_zero(), "FACTORY_ZERO");
        assert(token0 != token1, "IDENTICAL_TOKENS");
        // Mirror the factory's canonical-ordering rule. The factory's
        // `register_pair` already enforces this, but a direct deployment
        // (bypassing the factory) would otherwise leave the pair in an
        // unregisterable but functionally-active state -- relabeled-but-
        // working tokens that split liquidity from the canonical pair.
        assert(
            token0.to_field() as u128 < token1.to_field() as u128,
            "TOKENS_NOT_SORTED",
        );
        // Derive this pair's LP Token address deterministically from the
        // pair's own address using the canonical salt (`LP_TOKEN_SALT`,
        // see module-level constant for rationale). The SDK's `createPair`
        // helper deploys the LP Token at the matching address using the
        // same inputs; any deviation (different salt, non-universal deploy,
        // custom public keys, wrong class_id) lands the LP Token at a
        // different address and the pair's mint/burn calls will hit a
        // non-existent contract.
        let lp_constructor_selector =
            FunctionSelector::from_signature("constructor((Field))");
        let lp_init_args_hash = hash_args([self.address.to_field()]);
        let lp_init_hash =
            compute_initialization_hash(lp_constructor_selector, lp_init_args_hash);
        let lp_salted_init = SaltedInitializationHash::compute(
            crate::LP_TOKEN_SALT,
            lp_init_hash,
            AztecAddress::zero(),
        );
        let lp_address = AztecAddress::compute_from_class_id(
            ContractClassId::from_field(crate::LP_TOKEN_CLASS_ID),
            lp_salted_init,
            PublicKeys::default(),
        );
        self.storage.lp_token.initialize(lp_address);

        self.storage.config.initialize(PairConfig {
            token0,
            token1,
            factory,
            fee_tier_bps,
            version: crate::VERSION,
            lp_token: lp_address,
        });
    }

    /// Returns this pair's LP Token address. Cached at construction.
    /// Used by the SDK to route balance queries and by the factory to emit
    /// the LP address in `PairCreatedEvent` without re-deriving.
    #[external("public")]
    #[view]
    fn get_lp_token() -> AztecAddress {
        self.storage.lp_token.read()
    }

    /// Returns the pair's bytecode version. Called cross-contract by the
    /// factory during register_pair to verify this pair's self-declared
    /// version matches the admin-declared pair_class_version. Because VERSION
    /// is a compile-time global and this function simply returns it, the
    /// return value is an immutable property of the bytecode -- it cannot be
    /// manipulated at runtime.
    ///
    /// Marked `#[view]` so callers (the factory in particular) can invoke it
    /// via `self.view(...)` as a read-only staticcall without consuming gas
    /// for state modifications.
    #[external("public")]
    #[view]
    fn get_version() -> pub u32 {
        crate::VERSION
    }

    /// Returns the pair's current pause state. Off-chain / SDK-side helper
    /// for deciding whether to route users to this pair when it appears as
    /// `latest_pair` in the factory's registry.
    #[external("utility")]
    unconstrained fn is_paused_view() -> pub bool {
        let is_paused = self.storage.packed_flags.read().is_paused;
        is_paused
    }

    // ================================================================
    // Reentrancy lock helpers
    // ================================================================

    /// Acquire the packed_flags reentrancy lock. Asserts !locked, then writes
    /// `locked = true` while preserving the other flag bits. Returns the
    /// pre-acquire values of `is_paused`, `fee_active`, and `fee_percent` so
    /// callers can enforce PAUSED checks and use fee settings in their logic
    /// without re-reading storage.
    ///
    /// Called via `self.internal._acquire_lock()` at the entry of every
    /// mutating public-internal function. The caller is responsible for the
    /// `PAUSED` assertion when applicable -- not every mutating function
    /// refuses to run while paused (e.g. `sync`, `_skim`, `set_pause` itself).
    #[internal("public")]
    fn _acquire_lock() -> pub (bool, bool, u32) {
        let flags = self.storage.packed_flags.read();
        let is_paused = flags.is_paused;
        let locked = flags.locked;
        let fee_active = flags.protocol_fee_active;
        let fee_percent = flags.protocol_fee_percent;
        assert(!locked, "LOCKED");
        self.storage.packed_flags.write(FlagsPacked { is_paused, locked: true, protocol_fee_active: fee_active, protocol_fee_percent: fee_percent });
        (is_paused, fee_active, fee_percent)
    }

    /// Release the packed_flags reentrancy lock. Reads fresh flag state to
    /// preserve any mid-function pause toggles (set by `set_pause` reentrantly
    /// would be impossible under the lock, but `set_protocol_fee` mutates
    /// fee bits and uses its own release path). Writes `locked = false`.
    ///
    /// Called via `self.internal._release_lock()` at the exit of every
    /// mutating public-internal function.
    #[internal("public")]
    fn _release_lock() {
        let flags_end = self.storage.packed_flags.read();
        let is_paused_end = flags_end.is_paused;
        let fee_active_end = flags_end.protocol_fee_active;
        let fee_percent_end = flags_end.protocol_fee_percent;
        self.storage.packed_flags.write(FlagsPacked { is_paused: is_paused_end, locked: false, protocol_fee_active: fee_active_end, protocol_fee_percent: fee_percent_end });
    }

    /// Shared preamble for the factory-only admin entries (`set_pause`,
    /// `set_protocol_fee`). Reads packed_flags, asserts !locked, reads
    /// config, asserts msg_sender is the registered factory. Returns the
    /// pre-write `(is_paused, fee_active, fee_percent)` tuple so callers
    /// can reuse those values when repacking flags. Mirrors the return
    /// shape of `_acquire_lock`. These admin entries don't acquire the
    /// lock because they make no outbound calls; they only need to refuse
    /// to run while another locked operation is in progress.
    #[internal("public")]
    fn _assert_factory_and_unlocked() -> pub (bool, bool, u32) {
        let flags = self.storage.packed_flags.read();
        let is_paused = flags.is_paused;
        let locked = flags.locked;
        let fee_active = flags.protocol_fee_active;
        let fee_percent = flags.protocol_fee_percent;
        assert(!locked, "LOCKED");
        let config = self.storage.config.read();
        assert(self.msg_sender() == config.factory, "ONLY_FACTORY");
        (is_paused, fee_active, fee_percent)
    }

    // ================================================================
    // Add Liquidity (Mint)
    // ================================================================

    /// Privately add liquidity to the pool.
    ///
    /// The caller specifies min/max bounds for both tokens to handle price movement.
    /// Max amounts are transferred to the pair's public balance, and partial notes
    /// are prepared for refunds (if the full amount isn't needed) and LP tokens.
    ///
    /// The actual amounts and LP tokens are computed in public (_add_liquidity),
    /// but the caller's identity remains private.
    ///
    /// `authwit_nonce` isolates token transfer authwits to this specific call.
    #[external("private")]
    fn add_liquidity(
        amount0_max: u128,
        amount1_max: u128,
        amount0_min: u128,
        amount1_min: u128,
        authwit_nonce: Field,
    ) {
        // Validate bounds
        assert(
            (amount0_min < amount0_max) | (amount0_min == amount0_max),
            "INCORRECT_TOKEN0_LIMITS",
        );
        assert(
            (amount1_min < amount1_max) | (amount1_min == amount1_max),
            "INCORRECT_TOKEN1_LIMITS",
        );
        assert(
            (0 as u128 < amount0_max) & (0 as u128 < amount1_max),
            "INSUFFICIENT_INPUT_AMOUNTS",
        );

        let config = self.storage.config.read();
        let token0 = Token::at(config.token0);
        let token1 = Token::at(config.token1);
        let liquidity_token = SigalSwapLPToken::at(self.storage.lp_token.read());
        let sender = self.msg_sender();

        // Transfer max amounts from sender's private balance to pair's public balance.
        // Each call also prepares a partial note for refunding any excess back to sender.
        let refund_token0_partial_note =
            self.call(token0.transfer_to_public_and_prepare_private_balance_increase(
                sender,
                self.address,
                amount0_max,
                authwit_nonce,
            ));
        let refund_token1_partial_note =
            self.call(token1.transfer_to_public_and_prepare_private_balance_increase(
                sender,
                self.address,
                amount1_max,
                authwit_nonce,
            ));

        // Prepare partial note for LP tokens (amount determined in public execution)
        let liquidity_partial_note =
            self.call(liquidity_token.prepare_private_balance_increase(sender));

        // By the time _add_liquidity runs, the token transfers above have
        // already completed (they were enqueued first).
        // Encrypted wallet history. Logs max amounts; actual deposit computed in public (excess refunded).
        self.emit(PrivateMintEvent { token0: config.token0, token1: config.token1, amount0_max, amount1_max })
            .deliver_to(sender, MessageDelivery.ONCHAIN_UNCONSTRAINED);

        self.enqueue_self._add_liquidity(
            config,
            refund_token0_partial_note,
            refund_token1_partial_note,
            liquidity_partial_note,
            amount0_max,
            amount1_max,
            amount0_min,
            amount1_min,
        );
    }

    /// Public internal: compute amounts, mint LP tokens, refund excess.
    ///
    /// Constant-product mint with variable fee tiers, the additive protocol
    /// fee model, stored reserves for the TWAP oracle, and partial notes for
    /// private token returns.
    #[external("public")]
    #[only_self]
    fn _add_liquidity(
        config: PairConfig, // Passed from private to avoid re-reading in public
        refund_token0_partial_note: PartialUintNote,
        refund_token1_partial_note: PartialUintNote,
        liquidity_partial_note: PartialUintNote,
        amount0_max: u128,
        amount1_max: u128,
        amount0_min: u128,
        amount1_min: u128,
    ) {
        let (is_paused, fee_active, fee_percent) = self.internal._acquire_lock();
        assert(!is_paused, "PAUSED");

        let token0 = Token::at(config.token0);
        let token1 = Token::at(config.token1);
        let liquidity_token = SigalSwapLPToken::at(self.storage.lp_token.read());

        // --- Step 1: Read current reserves ---
        let reserves_now = self.storage.packed_reserves.read(); let reserve0 = reserves_now.reserve0; let reserve1 = reserves_now.reserve1;

        // --- Step 2: Protocol fee mint ---
        // Read total_supply once. After fee mint, compute the new supply arithmetically
        // (total_supply + protocol_fee_amount) instead of re-querying.
        let total_supply = self.view(liquidity_token.total_supply());
        assert_reserve_fits(total_supply); // LP supply must fit u112 for mul_div safety
        let fee_on = fee_active;
        let reserves_last = self.storage.packed_reserves_last.read(); let r0_last = reserves_last.reserve0; let r1_last = reserves_last.reserve1;
        let protocol_fee_amount = if fee_on {
            compute_mint_fee(
                reserve0,
                reserve1,
                r0_last,
                r1_last,
                total_supply,
                fee_percent as u128,
            )
        } else {
            0
        };
        if protocol_fee_amount > 0 as u128 {
            let fee_to = self.storage.fee_to.read();
            liquidity_token.mint_to_public(fee_to, protocol_fee_amount).call(self.context);
            self.emit(ProtocolFeeMintedEvent { fee_to, amount: protocol_fee_amount });
        }

        // --- Step 3: Compute amounts to add ---
        // Derive what the pair actually received from the balance delta, then
        // cap each side at the caller-authorized maximum before matching. The
        // cap is what mirrors `add_liquidity_public`'s V2-strict semantic: any
        // pre-existing donation to the pair stays in reserves where it benefits
        // LPs proportionally on the next mint/burn, rather than flowing back
        // out as a caller refund. For non-FoT non-donation deposits the cap is
        // a no-op (`deposited_i == max_i`). For FoT undershoot it preserves
        // the pair's solvency (cap == deposited when actual < max). For
        // pre-existing donations the cap excludes the donation portion from
        // matching and from the refund pool. The protocol-fee mint above is
        // LP-only and does not move token0/token1, so the balance read here
        // still reflects (reserve_i + arrived_i).
        let balance0 = self.view(token0.balance_of_public(self.address));
        let balance1 = self.view(token1.balance_of_public(self.address));
        let amount0_deposited = balance0 - reserve0;
        let amount1_deposited = balance1 - reserve1;
        let amount0_capped = if amount0_deposited > amount0_max { amount0_max } else { amount0_deposited };
        let amount1_capped = if amount1_deposited > amount1_max { amount1_max } else { amount1_deposited };
        let (amount0, amount1) = get_amounts_to_add(
            amount0_capped,
            amount1_capped,
            amount0_min,
            amount1_min,
            reserve0,
            reserve1,
        );
        // Defense-in-depth: `get_amounts_to_add` already bounds matched at its
        // input caps, and the input caps here are <= amount_i_max. A future
        // refactor that drops the cap (or substitutes a different matcher)
        // would silently re-open the donation-extraction path; this assert
        // turns that regression back into a revert.
        assert(amount0 <= amount0_max, "MATCHED_EXCEEDS_MAX");
        assert(amount1 <= amount1_max, "MATCHED_EXCEEDS_MAX");

        // --- Step 4: Refund excess tokens ---
        // Refund is computed against the user-authorized cap, NOT the raw
        // balance delta. `amount_i_capped <= amount_i_max` (Step 3) and
        // `amount_i <= amount_i_capped` (matched bounded by its input cap),
        // so the subtraction is non-negative. The pair holds at least
        // `amount_i_capped` worth of token_i (it holds `amount_i_deposited`
        // which is >= capped), so the refund is always solvent. Donation
        // surplus (`deposited - capped`) stays in pair and is captured into
        // reserves at Step 8's balance-derived write.
        // Skip finalization if refund is 0 -- Aztec's PartialUintNote rejects
        // zero-value completion. Uncompleted partial notes are harmless.
        let refund0 = amount0_capped - amount0;
        let refund1 = amount1_capped - amount1;
        if refund0 > 0 as u128 {
            self.call(
                token0.finalize_transfer_to_private(refund0, refund_token0_partial_note),
            );
        }
        if refund1 > 0 as u128 {
            self.call(
                token1.finalize_transfer_to_private(refund1, refund_token1_partial_note),
            );
        }

        // --- Step 5: Compute liquidity tokens to mint ---
        // total_supply_after accounts for any protocol fee LP tokens just minted
        let total_supply_after = total_supply + protocol_fee_amount;
        let liquidity = compute_liquidity(amount0, amount1, reserve0, reserve1, total_supply_after);
        assert(liquidity > 0 as u128, "INSUFFICIENT_LIQUIDITY_MINTED");

        // --- Step 6: Mint LP tokens ---
        if total_supply == 0 as u128 {
            // First deposit: permanently lock MINIMUM_LIQUIDITY to prevent pool from emptying.
            // These tokens are minted to the zero address and can never be redeemed.
            liquidity_token.mint_to_public(AztecAddress::zero(), MINIMUM_LIQUIDITY).call(
                self.context,
            );
        }
        // Mint the user's LP tokens directly into their private balance via partial note
        liquidity_token.finalize_mint_to_private(liquidity, liquidity_partial_note).call(
            self.context,
        );

        // --- Step 7: Update TWAP accumulators (using OLD reserves, before writing new ones) ---
        // Gate the entire read+compute on the same-block check so a same-block
        // add doesn't pay for 3 storage reads + a Babylonian sqrt that gets
        // thrown away. Mirrors the pattern used in `_remove_liquidity`,
        // `_swap_exact_in`, etc.
        let timestamp_last = self.storage.block_timestamp_last.read();
        let current_timestamp = self.context.timestamp() as u64;
        if current_timestamp > timestamp_last {
            let twap_fracs = self.storage.packed_twap_frac.read(); let p0_frac = twap_fracs.price0_cumul_frac; let p1_frac = twap_fracs.price1_cumul_frac;
            let twap = compute_twap_update(
                reserve0, reserve1,
                self.storage.price0_cumul_int.read(),
                p0_frac,
                self.storage.price1_cumul_int.read(),
                p1_frac,
                timestamp_last,
                current_timestamp,
            );
            self.storage.price0_cumul_int.write(twap.price0_cumul_int);
            self.storage.packed_twap_frac.write(TwapFractions { price0_cumul_frac: twap.price0_cumul_frac, price1_cumul_frac: twap.price1_cumul_frac });
            self.storage.price1_cumul_int.write(twap.price1_cumul_int);
            self.storage.block_timestamp_last.write(twap.block_timestamp);
        }

        // --- Step 8: Update reserves from actual balances (handles fee-on-transfer) ---
        let new_r0 = self.view(token0.balance_of_public(self.address));
        let new_r1 = self.view(token1.balance_of_public(self.address));

        // --- Step 9: Emit events ---
        self.emit(MintEvent { amount0: amount0, amount1: amount1, liquidity });
        self.storage.packed_reserves.write(ReservesPacked { reserve0: new_r0, reserve1: new_r1 });
        self.emit(SyncEvent { reserve0: new_r0, reserve1: new_r1 });

        // --- Step 10: Update reserves_last for protocol fee tracking ---
        if fee_on {
            self.storage.packed_reserves_last.write(ReservesPacked { reserve0: new_r0, reserve1: new_r1 });
        } else if !self.storage.packed_reserves_last.read().is_zero() {
            self.storage.packed_reserves_last.write(ReservesPacked::zero());
        }

        self.internal._release_lock();
    }

    // ================================================================
    // Remove Liquidity (Burn)
    // ================================================================

    /// Privately remove liquidity from the pool.
    ///
    /// Burns `liquidity` LP tokens and returns proportional amounts of both tokens.
    /// The caller specifies minimum amounts to protect against price movement.
    ///
    /// NOTE: Withdrawals are ALWAYS allowed, even during emergency pause.
    /// This ensures users can exit their positions regardless of protocol state.
    #[external("private")]
    fn remove_liquidity(
        liquidity: u128,
        amount0_min: u128,
        amount1_min: u128,
        authwit_nonce: Field,
    ) {
        assert(liquidity > 0 as u128, "INSUFFICIENT_LIQUIDITY");

        let config = self.storage.config.read();
        let liquidity_token = SigalSwapLPToken::at(self.storage.lp_token.read());
        let token0 = Token::at(config.token0);
        let token1 = Token::at(config.token1);
        let sender = self.msg_sender();

        // Transfer LP tokens from sender's private balance to pair's public balance.
        // They will be burned in the public function.
        self.call(liquidity_token.transfer_to_public(
            sender,
            self.address,
            liquidity,
            authwit_nonce,
        ));

        // Prepare partial notes for token returns (amounts determined in public)
        let token0_partial_note =
            self.call(token0.prepare_private_balance_increase(sender));
        let token1_partial_note =
            self.call(token1.prepare_private_balance_increase(sender));

        // Encrypted wallet history. Logs LP amount burned; actual token returns computed in public.
        self.emit(PrivateBurnEvent { token0: config.token0, token1: config.token1, liquidity })
            .deliver_to(sender, MessageDelivery.ONCHAIN_UNCONSTRAINED);

        self.enqueue_self._remove_liquidity(
            config,
            liquidity,
            token0_partial_note,
            token1_partial_note,
            amount0_min,
            amount1_min,
        );
    }

    /// Public internal: compute proportional amounts, burn LP, return tokens.
    ///
    /// Removes liquidity via the constant-product burn. Uses actual token balances
    /// (not stored reserves) for the calculation to ensure pro-rata distribution of
    /// any excess tokens in the pool.
    #[external("public")]
    #[only_self]
    fn _remove_liquidity(
        config: PairConfig,
        liquidity: u128,
        token0_partial_note: PartialUintNote,
        token1_partial_note: PartialUintNote,
        amount0_min: u128,
        amount1_min: u128,
    ) {
        // NO pause check -- withdrawals are always allowed
        let (_is_paused, fee_active, fee_percent) = self.internal._acquire_lock();

        let token0 = Token::at(config.token0);
        let token1 = Token::at(config.token1);
        let liquidity_token = SigalSwapLPToken::at(self.storage.lp_token.read());

        // --- Step 1: Read current state ---
        // Use actual token balances (not stored reserves) for pro-rata distribution,
        // the standard constant-product burn behavior. This distributes any excess
        // tokens fairly.
        let balance0 = self.view(token0.balance_of_public(self.address));
        let balance1 = self.view(token1.balance_of_public(self.address));

        // --- Step 2: Protocol fee mint ---
        // Read total_supply once and reuse arithmetically below: post-fee
        // supply is exactly `total_supply_pre_fee + protocol_fee_amount` since
        // mint_to_public is the only inflow on this path.
        let reserves_now = self.storage.packed_reserves.read(); let reserve0 = reserves_now.reserve0; let reserve1 = reserves_now.reserve1;
        let fee_on = fee_active;
        let reserves_last = self.storage.packed_reserves_last.read(); let r0_last = reserves_last.reserve0; let r1_last = reserves_last.reserve1;
        let total_supply_pre_fee = self.view(liquidity_token.total_supply());
        let protocol_fee_amount = if fee_on {
            compute_mint_fee(
                reserve0,
                reserve1,
                r0_last,
                r1_last,
                total_supply_pre_fee,
                fee_percent as u128,
            )
        } else {
            0
        };
        if protocol_fee_amount > 0 as u128 {
            let fee_to = self.storage.fee_to.read();
            liquidity_token.mint_to_public(fee_to, protocol_fee_amount).call(self.context);
            self.emit(ProtocolFeeMintedEvent { fee_to, amount: protocol_fee_amount });
        }

        // --- Step 3: Compute token amounts ---
        // Post-fee supply derived arithmetically -- avoids a redundant cross
        // contract `total_supply()` view. Matches `_add_liquidity`'s pattern.
        let total_supply = total_supply_pre_fee + protocol_fee_amount;
        assert_reserve_fits(total_supply); // LP supply must fit u112 for mul_div safety
        let (amount0, amount1) =
            get_amounts_on_remove(liquidity, total_supply, balance0, balance1);
        assert(amount0 > 0 as u128, "INSUFFICIENT_0_AMOUNT");
        assert(amount1 > 0 as u128, "INSUFFICIENT_1_AMOUNT");
        assert(amount0 >= amount0_min, "BELOW_MINIMUM_0");
        assert(amount1 >= amount1_min, "BELOW_MINIMUM_1");

        // --- Step 4: Burn LP tokens from pair's public balance ---
        self.call(liquidity_token.burn_public(self.address, liquidity, 0));

        // --- Step 5: Send tokens to user's private balance via partial notes ---
        self.call(token0.finalize_transfer_to_private(amount0, token0_partial_note));
        self.call(token1.finalize_transfer_to_private(amount1, token1_partial_note));

        // --- Step 6: Update TWAP accumulators (skip writes if same block) ---
        let timestamp_last = self.storage.block_timestamp_last.read();
        let current_timestamp = self.context.timestamp() as u64;
        if current_timestamp > timestamp_last {
            let twap_fracs = self.storage.packed_twap_frac.read(); let p0_frac = twap_fracs.price0_cumul_frac; let p1_frac = twap_fracs.price1_cumul_frac;
            let twap = compute_twap_update(
                reserve0, reserve1,
                self.storage.price0_cumul_int.read(),
                p0_frac,
                self.storage.price1_cumul_int.read(),
                p1_frac,
                timestamp_last,
                current_timestamp,
            );
            self.storage.price0_cumul_int.write(twap.price0_cumul_int);
            self.storage.packed_twap_frac.write(TwapFractions { price0_cumul_frac: twap.price0_cumul_frac, price1_cumul_frac: twap.price1_cumul_frac });
            self.storage.price1_cumul_int.write(twap.price1_cumul_int);
            self.storage.block_timestamp_last.write(twap.block_timestamp);
        }

        // --- Step 7: Update stored reserves ---
        let new_reserve0 = balance0 - amount0;
        let new_reserve1 = balance1 - amount1;

        // --- Step 8: Emit events ---
        self.emit(BurnEvent { amount0, amount1, liquidity });
        self.storage.packed_reserves.write(ReservesPacked { reserve0: new_reserve0, reserve1: new_reserve1 });
        self.emit(SyncEvent { reserve0: new_reserve0, reserve1: new_reserve1 });

        // --- Step 9: Update reserves_last ---
        if fee_on {
            self.storage.packed_reserves_last.write(ReservesPacked { reserve0: new_reserve0, reserve1: new_reserve1 });
        } else if !self.storage.packed_reserves_last.read().is_zero() {
            self.storage.packed_reserves_last.write(ReservesPacked::zero());
        }

        self.internal._release_lock();
    }

    // ================================================================
    // Public entry points for router (tokens pre-deposited)
    // ================================================================

    /// Add liquidity on behalf of `recipient` using tokens the caller has
    /// already deposited into the pair's public balance. LP tokens are
    /// minted to `recipient`'s public balance. The caller (router) handles
    /// finalization to the user's private balance via partial notes.
    ///
    /// V2-strict deposit semantics: the caller's deposit IS `balance_i -
    /// reserve_i` -- the full balance-delta is consumed. LP tokens are
    /// minted only for the matched (pair-ratio) portion via
    /// `compute_liquidity`'s `min(...)` formula; any imbalanced excess
    /// flows into reserves and benefits LPs proportionally on the next
    /// mint or burn (V2's `mint` semantic). This entry is permissionless and
    /// credits LP for whatever balance delta is present to the caller-supplied
    /// `recipient`, so it is safe ONLY when the deposit and this call happen
    /// atomically in one tx (the Router/SDK path). A direct integrator who
    /// pre-deposits in one tx and calls in a later one can have that deposit
    /// claimed by a third party who calls this entry first (the public mempool
    /// is fee-ordered); such integrators must deposit-and-call atomically or
    /// use the private `add_liquidity` entry. Fee-on-transfer tokens are
    /// handled transparently: whatever actually arrived in the pair is the
    /// deposit.
    ///
    /// Pre-existing donations to the pair (tokens transferred outside any
    /// protocol interaction) interact with THIS public-direct path differently
    /// from the private `_add_liquidity` path, which caps the matched amount at
    /// the caller's authorized max. Here there is no such cap, so a donation
    /// that is AT the pool ratio (balanced) is matched into this call's mint and
    /// credited as LP to whoever calls `add_liquidity_public` next -- the
    /// standard V2 `mint` semantic, NOT a proportional distribution to all
    /// existing LPs. (Existing LPs are never diluted -- floor rounding preserves
    /// their per-share value -- and only the OFF-ratio remainder stays in
    /// reserves for all LPs.) A donor who wants a true "gift to all LPs" cannot
    /// achieve it on this path; an accidental donor recovers via `skim`, which
    /// remains the explicit recovery path for off-protocol transfers.
    ///
    /// `amount_i_min` guards the caller against price movement between
    /// the deposit transfer and this call: if the pool's ratio shifted
    /// enough that matching the deposit at the new ratio would consume
    /// less than `amount_i_min`, the call reverts.
    ///
    /// `recipient` trust model: the pair blindly mints LP to whatever
    /// address the caller provides. The router resolves this to the
    /// user's address from `msg_sender` in its private entry; a direct
    /// integrator is responsible for setting `recipient` correctly.
    /// Direct callers are responsible for pre-computing the optimal
    /// pair-ratio deposit off-chain (V2-router-style) -- any imbalanced
    /// pre-deposit donates the excess to LPs.
    #[external("public")]
    fn add_liquidity_public(
        recipient: AztecAddress,
        amount0_min: u128,
        amount1_min: u128,
    ) {
        assert(!recipient.is_zero(), "ZERO_RECIPIENT");

        let config = self.storage.config.read();
        let (is_paused, fee_active, fee_percent) = self.internal._acquire_lock();
        assert(!is_paused, "PAUSED");

        let token0 = Token::at(config.token0);
        let token1 = Token::at(config.token1);
        let liquidity_token = SigalSwapLPToken::at(self.storage.lp_token.read());

        // Recipient blocklist: minting LP to a protocol-internal address
        // permanently strands the position (none of these contracts have an
        // LP-rescue surface). Matches the `INVALID_CALLBACK_TARGET` blocklist
        // on the V3 swap entries; same set of addresses minus zero (covered
        // separately above with its own message).
        assert(recipient != self.address, "INVALID_RECIPIENT");
        assert(recipient != config.token0, "INVALID_RECIPIENT");
        assert(recipient != config.token1, "INVALID_RECIPIENT");
        assert(recipient != self.storage.lp_token.read(), "INVALID_RECIPIENT");
        assert(recipient != config.factory, "INVALID_RECIPIENT");

        let reserves_now = self.storage.packed_reserves.read(); let reserve0 = reserves_now.reserve0; let reserve1 = reserves_now.reserve1;

        // Derive deposit amounts from the caller's actual balance contribution.
        // Underflow here (balance < reserve) would mean storage and balances
        // diverged -- `sync()` is the recovery path, not this entry.
        let balance0 = self.view(token0.balance_of_public(self.address));
        let balance1 = self.view(token1.balance_of_public(self.address));
        let amount0_deposited = balance0 - reserve0;
        let amount1_deposited = balance1 - reserve1;
        assert(amount0_deposited > 0 as u128, "NO_TOKEN0_DEPOSIT");
        assert(amount1_deposited > 0 as u128, "NO_TOKEN1_DEPOSIT");

        // Protocol fee mint
        let total_supply = self.view(liquidity_token.total_supply());
        assert_reserve_fits(total_supply);
        let fee_on = fee_active;
        let reserves_last = self.storage.packed_reserves_last.read(); let r0_last = reserves_last.reserve0; let r1_last = reserves_last.reserve1;
        let protocol_fee_amount = if fee_on {
            compute_mint_fee(reserve0, reserve1, r0_last, r1_last, total_supply, fee_percent as u128)
        } else { 0 };
        if protocol_fee_amount > 0 as u128 {
            let fee_to = self.storage.fee_to.read();
            liquidity_token.mint_to_public(fee_to, protocol_fee_amount).call(self.context);
            self.emit(ProtocolFeeMintedEvent { fee_to, amount: protocol_fee_amount });
        }

        // Compute the matched (pair-ratio) portion of the deposit. Slippage
        // assertions inside `get_amounts_to_add` enforce `amount_i >= amount_i_min`.
        let (amount0, amount1) = get_amounts_to_add(
            amount0_deposited, amount1_deposited, amount0_min, amount1_min, reserve0, reserve1,
        );

        // V2-strict: LP minted for the matched portion only. Any imbalanced
        // excess (`amount_i_deposited - amount_i`) stays in the pair and is
        // captured into reserves via the balance-derived write below, where
        // it benefits all LPs proportionally on the next mint/burn.
        let total_supply_after = total_supply + protocol_fee_amount;
        let liquidity = compute_liquidity(amount0, amount1, reserve0, reserve1, total_supply_after);
        assert(liquidity > 0 as u128, "INSUFFICIENT_LIQUIDITY_MINTED");
        if total_supply == 0 as u128 {
            liquidity_token.mint_to_public(AztecAddress::zero(), MINIMUM_LIQUIDITY).call(self.context);
        }
        liquidity_token.mint_to_public(recipient, liquidity).call(self.context);

        // Update TWAP -- gate read+compute on same-block check (matches
        // `_remove_liquidity`, `_swap_exact_in`, etc.).
        let timestamp_last = self.storage.block_timestamp_last.read();
        let current_timestamp = self.context.timestamp() as u64;
        if current_timestamp > timestamp_last {
            let twap_fracs = self.storage.packed_twap_frac.read(); let p0_frac = twap_fracs.price0_cumul_frac; let p1_frac = twap_fracs.price1_cumul_frac;
            let twap = compute_twap_update(
                reserve0, reserve1,
                self.storage.price0_cumul_int.read(), p0_frac,
                self.storage.price1_cumul_int.read(), p1_frac,
                timestamp_last, current_timestamp,
            );
            self.storage.price0_cumul_int.write(twap.price0_cumul_int);
            self.storage.packed_twap_frac.write(TwapFractions { price0_cumul_frac: twap.price0_cumul_frac, price1_cumul_frac: twap.price1_cumul_frac });
            self.storage.price1_cumul_int.write(twap.price1_cumul_int);
            self.storage.block_timestamp_last.write(twap.block_timestamp);
        }

        // No tokens left the pair after the protocol-fee LP mint, so the
        // token0/token1 balances we read at entry still hold. Reserves
        // grow to balance, capturing any imbalanced excess + donations.
        self.emit(MintPublicEvent { sender: self.msg_sender(), amount0, amount1, liquidity });
        self.storage.packed_reserves.write(ReservesPacked { reserve0: balance0, reserve1: balance1 });
        self.emit(SyncEvent { reserve0: balance0, reserve1: balance1 });

        if fee_on {
            self.storage.packed_reserves_last.write(ReservesPacked { reserve0: balance0, reserve1: balance1 });
        } else if !self.storage.packed_reserves_last.read().is_zero() {
            self.storage.packed_reserves_last.write(ReservesPacked::zero());
        }

        self.internal._release_lock();
    }

    /// Remove liquidity (math-only version for router). LP tokens are
    /// pre-deposited. Token0/token1 amounts are sent to `recipient`'s
    /// public balance. The caller handles finalization to private.
    ///
    /// `recipient` trust model: same as `add_liquidity_public` -- the pair
    /// doesn't validate the caller/recipient relationship. Callers must
    /// ensure `recipient` is what the user intended; the router does this
    /// by taking `recipient` implicitly from `msg_sender` in its private
    /// entry.
    #[external("public")]
    fn remove_liquidity_public(
        recipient: AztecAddress,
        liquidity: u128,
        amount0_min: u128,
        amount1_min: u128,
    ) {
        // Rejecting the zero address keeps tokens from being sent to an
        // unrecoverable address on a caller mistake. Defense-in-depth --
        // the router never passes zero, but a direct integrator might.
        assert(recipient != AztecAddress::zero(), "ZERO_RECIPIENT");

        let config = self.storage.config.read();
        // NO pause check -- withdrawals always allowed
        let (_is_paused, fee_active, fee_percent) = self.internal._acquire_lock();

        let token0 = Token::at(config.token0);
        let token1 = Token::at(config.token1);
        let liquidity_token = SigalSwapLPToken::at(self.storage.lp_token.read());

        // Recipient blocklist: tokens delivered to a protocol-internal
        // address are permanently stranded (Token contracts, LP token, and
        // factory have no rescue surface for arbitrary deposits). Matches
        // the `INVALID_CALLBACK_TARGET` blocklist on the V3 swap entries.
        assert(recipient != self.address, "INVALID_RECIPIENT");
        assert(recipient != config.token0, "INVALID_RECIPIENT");
        assert(recipient != config.token1, "INVALID_RECIPIENT");
        assert(recipient != self.storage.lp_token.read(), "INVALID_RECIPIENT");
        assert(recipient != config.factory, "INVALID_RECIPIENT");

        let balance0 = self.view(token0.balance_of_public(self.address));
        let balance1 = self.view(token1.balance_of_public(self.address));

        // Protocol fee mint -- read total_supply once and derive post-fee
        // arithmetically. Mirrors `_add_liquidity`'s pattern; saves one
        // cross-contract `total_supply()` view per call.
        let reserves_now = self.storage.packed_reserves.read(); let reserve0 = reserves_now.reserve0; let reserve1 = reserves_now.reserve1;
        let fee_on = fee_active;
        let reserves_last = self.storage.packed_reserves_last.read(); let r0_last = reserves_last.reserve0; let r1_last = reserves_last.reserve1;
        let total_supply_pre_fee = self.view(liquidity_token.total_supply());
        let protocol_fee_amount = if fee_on {
            compute_mint_fee(reserve0, reserve1, r0_last, r1_last,
                total_supply_pre_fee, fee_percent as u128)
        } else { 0 };
        if protocol_fee_amount > 0 as u128 {
            let fee_to = self.storage.fee_to.read();
            liquidity_token.mint_to_public(fee_to, protocol_fee_amount).call(self.context);
            self.emit(ProtocolFeeMintedEvent { fee_to, amount: protocol_fee_amount });
        }

        let total_supply = total_supply_pre_fee + protocol_fee_amount;
        assert_reserve_fits(total_supply);
        let (amount0, amount1) = get_amounts_on_remove(liquidity, total_supply, balance0, balance1);
        assert(amount0 > 0 as u128, "INSUFFICIENT_0_AMOUNT");
        assert(amount1 > 0 as u128, "INSUFFICIENT_1_AMOUNT");
        assert(amount0 >= amount0_min, "BELOW_MINIMUM_0");
        assert(amount1 >= amount1_min, "BELOW_MINIMUM_1");

        // Burn LP tokens, send token0/token1 to recipient's public balance
        self.call(liquidity_token.burn_public(self.address, liquidity, 0));
        token0.transfer_in_public(self.address, recipient, amount0, 0).call(self.context);
        token1.transfer_in_public(self.address, recipient, amount1, 0).call(self.context);

        // Update TWAP
        let timestamp_last = self.storage.block_timestamp_last.read();
        let current_timestamp = self.context.timestamp() as u64;
        if current_timestamp > timestamp_last {
            let twap_fracs = self.storage.packed_twap_frac.read(); let p0_frac = twap_fracs.price0_cumul_frac; let p1_frac = twap_fracs.price1_cumul_frac;
            let twap = compute_twap_update(
                reserve0, reserve1,
                self.storage.price0_cumul_int.read(), p0_frac,
                self.storage.price1_cumul_int.read(), p1_frac,
                timestamp_last, current_timestamp,
            );
            self.storage.price0_cumul_int.write(twap.price0_cumul_int);
            self.storage.packed_twap_frac.write(TwapFractions { price0_cumul_frac: twap.price0_cumul_frac, price1_cumul_frac: twap.price1_cumul_frac });
            self.storage.price1_cumul_int.write(twap.price1_cumul_int);
            self.storage.block_timestamp_last.write(twap.block_timestamp);
        }

        // Update reserves
        let new_reserve0 = balance0 - amount0;
        let new_reserve1 = balance1 - amount1;

        // Emit events
        self.emit(BurnPublicEvent { sender: self.msg_sender(), amount0, amount1, liquidity, recipient });
        self.storage.packed_reserves.write(ReservesPacked { reserve0: new_reserve0, reserve1: new_reserve1 });
        self.emit(SyncEvent { reserve0: new_reserve0, reserve1: new_reserve1 });

        if fee_on {
            self.storage.packed_reserves_last.write(ReservesPacked { reserve0: new_reserve0, reserve1: new_reserve1 });
        } else if !self.storage.packed_reserves_last.read().is_zero() {
            self.storage.packed_reserves_last.write(ReservesPacked::zero());
        }

        self.internal._release_lock();
    }

    // ================================================================
    // View / Utility Functions
    // ================================================================

    /// Read current reserves and last update timestamp. The standard
    /// constant-product reserve getter. Public-callable so the router can
    /// fetch live reserves via `self.view(...)` when computing the
    /// optimal pair-ratio deposit at tx time (V2-router pattern).
    #[external("public")]
    #[view]
    fn get_reserves() -> pub (u128, u128, u64) {
        let reserves_now = self.storage.packed_reserves.read(); let reserve0 = reserves_now.reserve0; let reserve1 = reserves_now.reserve1;
        let timestamp = self.storage.block_timestamp_last.read();
        (reserve0, reserve1, timestamp)
    }

    /// Public-callable version of `quote_amount_in`: given a desired output
    /// amount and output token, returns the required input amount at current
    /// reserves (fee-aware). Used by the router's exact-output multi-hop
    /// path to derive per-hop input ceilings on-chain. The utility version of
    /// `quote_amount_in` is PXE-only; this one is callable from another
    /// contract's public context.
    #[external("public")]
    #[view]
    fn quote_amount_in_public(amount_out: u128, token_out: AztecAddress) -> pub u128 {
        let config = self.storage.config.read();
        let reserves_now = self.storage.packed_reserves.read(); let reserve0 = reserves_now.reserve0; let reserve1 = reserves_now.reserve1;
        let flags = self.storage.packed_flags.read();
        let fee_active = flags.protocol_fee_active;
        let fee_percent = flags.protocol_fee_percent;
        compute_quote_amount_in(
            amount_out, token_out, config, reserve0, reserve1, fee_active, fee_percent,
        )
    }

    /// Read the pair configuration. Public view so the router (and any
    /// other integrator) can fetch the authoritative token0/token1/factory
    /// addresses without trusting caller-supplied copies. Also used by the
    /// SDK off-chain via `simulate`.
    #[external("public")]
    #[view]
    fn get_config() -> pub PairConfig {
        self.storage.config.read()
    }

    /// Read the pair-side `fee_to` recipient. Updated by factory's
    /// `sync_protocol_fee` and may lag the factory's current `fee_to`
    /// between a global change and the next per-pair sync. Indexers showing
    /// "who currently receives protocol fees on this specific pair" should
    /// query here, not the factory's getter.
    #[external("utility")]
    unconstrained fn get_fee_to() -> pub AztecAddress {
        self.storage.fee_to.read()
    }

    /// Read the cached reserves snapshot used as the protocol-fee K-growth
    /// baseline. Returns `(reserves_last_0, reserves_last_1)`. Combined with
    /// current `get_reserves`, `total_supply`, and `fee_percent`, callers can
    /// preview the next protocol-fee mint amount via the same `compute_mint_fee`
    /// formula the contract uses.
    #[external("utility")]
    unconstrained fn get_reserves_last() -> pub (u128, u128) {
        let r = self.storage.packed_reserves_last.read();
        (r.reserve0, r.reserve1)
    }

    /// Compute swap output for a given input amount (off-chain helper).
    /// Includes protocol fee in the calculation to match actual swap behavior.
    #[external("utility")]
    unconstrained fn quote_amount_out(amount_in: u128, token_in: AztecAddress) -> u128 {
        let config = self.storage.config.read();
        let reserves_now = self.storage.packed_reserves.read(); let reserve0 = reserves_now.reserve0; let reserve1 = reserves_now.reserve1;
        let flags = self.storage.packed_flags.read();
        let fee_active = flags.protocol_fee_active;
        let fee_percent = flags.protocol_fee_percent;
        compute_quote_amount_out(
            amount_in, token_in, config, reserve0, reserve1, fee_active, fee_percent,
        )
    }

    /// Read TWAP price accumulators and timestamp for oracle consumers.
    ///
    /// Usage: sample at T1 and T2, then TWAP = (cumul_T2 - cumul_T1) / (T2 - T1).
    /// The subtraction and division must be done in Field (modular around the
    /// BN254 scalar field order); the result is correct for any realistic
    /// accumulation window since real accumulated deltas are << Field modulus.
    ///
    /// Returns (price0_int, price0_frac, price1_int, price1_frac, block_timestamp_last).
    /// Integer parts are Field (widened from u128 to support high-ratio pools);
    /// fractional parts stay u128 (bounded by Q112).
    #[external("utility")]
    unconstrained fn get_cumulative_prices() -> (Field, u128, Field, u128, u64) {
        let twap_fracs = self.storage.packed_twap_frac.read(); let p0_frac = twap_fracs.price0_cumul_frac; let p1_frac = twap_fracs.price1_cumul_frac;
        (
            self.storage.price0_cumul_int.read(),
            p0_frac,
            self.storage.price1_cumul_int.read(),
            p1_frac,
            self.storage.block_timestamp_last.read(),
        )
    }

    /// Compute required input for a desired output amount (off-chain helper).
    /// Includes protocol fee in the calculation to match actual swap behavior.
    #[external("utility")]
    unconstrained fn quote_amount_in(amount_out: u128, token_out: AztecAddress) -> u128 {
        let config = self.storage.config.read();
        let reserves_now = self.storage.packed_reserves.read(); let reserve0 = reserves_now.reserve0; let reserve1 = reserves_now.reserve1;
        let flags = self.storage.packed_flags.read();
        let fee_active = flags.protocol_fee_active;
        let fee_percent = flags.protocol_fee_percent;
        compute_quote_amount_in(
            amount_out, token_out, config, reserve0, reserve1, fee_active, fee_percent,
        )
    }

    // ================================================================
    // Swap
    // ================================================================

    /// Privately swap an exact amount of input tokens for as many output tokens as possible.
    ///
    /// The caller specifies the input token, output token, exact input amount, and
    /// minimum acceptable output. The actual output is computed in public based on
    /// live reserves. The caller's identity remains private.
    #[external("private")]
    fn swap_exact_in(
        token_in: AztecAddress,
        token_out: AztecAddress,
        amount_in: u128,
        amount_out_min: u128,
        authwit_nonce: Field,
    ) {
        let config = self.storage.config.read();

        // Fail-fast at the entry so a zero-amount call doesn't burn the
        // user's authwit nonce on the token-side `transfer_to_public(0)`
        // and the public continuation gas before the deep
        // `INSUFFICIENT_INPUT_AMOUNT` revert in `get_amount_out`.
        // Symmetric with the `add_liquidity` entry's INSUFFICIENT_INPUT_AMOUNTS guard.
        assert(amount_in > 0 as u128, "INSUFFICIENT_INPUT_AMOUNT");

        assert(
            (token_in == config.token0) | (token_in == config.token1),
            "TOKEN_IN_IS_INVALID",
        );
        assert(
            (token_out == config.token0) | (token_out == config.token1),
            "TOKEN_OUT_IS_INVALID",
        );
        assert(token_in != token_out, "SAME_TOKEN_SWAP");

        let sender = self.msg_sender();

        // Transfer exact input amount from sender's private balance to pair's public balance
        self.call(Token::at(token_in).transfer_to_public(
            sender,
            self.address,
            amount_in,
            authwit_nonce,
        ));

        // Prepare partial note for output tokens (amount determined in public)
        let token_out_partial_note =
            self.call(Token::at(token_out).prepare_private_balance_increase(sender));

        // Encrypted wallet-history event. `amount_in` is the actual input
        // the pair will consume (identical to the user's declared `amount_in`
        // modulo fee-on-transfer slippage, which the pair accounts for via
        // balance-based settlement). `amount_out_min` is the slippage bound;
        // actual output is settled in public and logged by the public
        // `SwapEvent`. ONCHAIN_UNCONSTRAINED: sender is self-interested in
        // accurate history.
        self.emit(PrivateSwapExactInEvent { token_in, token_out, amount_in, amount_out_min })
            .deliver_to(sender, MessageDelivery.ONCHAIN_UNCONSTRAINED);

        self.enqueue_self._swap_exact_in(
            token_in,
            token_out,
            amount_in,
            amount_out_min,
            token_out_partial_note,
        );
    }

    /// Public internal: compute output amount and execute exact-input swap.
    ///
    /// Cap the swap input at the user's declared `amount_in`:
    ///   - non-FoT case: `balance - reserve == amount_in`, swap_input = amount_in.
    ///   - fee-on-transfer (delivery undershoots): swap_input = balance - reserve.
    ///   - donation (delivery overshoots): swap_input = amount_in; the excess
    ///     `(balance - reserve) - amount_in` stays in the pair and is captured
    ///     into reserves at the balance-derived write below, V2-equivalent.
    /// This isolates donations to LPs (matching the public V3 path's behavior)
    /// while preserving native FoT support.
    #[external("public")]
    #[only_self]
    fn _swap_exact_in(
        token_in: AztecAddress,
        token_out: AztecAddress,
        amount_in: u128,
        amount_out_min: u128,
        token_out_partial_note: PartialUintNote,
    ) {
        let (is_paused, fee_active, fee_percent) = self.internal._acquire_lock();
        assert(!is_paused, "PAUSED");

        let config = self.storage.config.read();
        let lp_fee_bps = config.fee_tier_bps as u128;
        let fee_bps = if fee_active {
            let protocol_percent = fee_percent as u128;
            // ceil: round the protocol markup up so it is never floored to 0
            // (keeps LPs' fee whole and the protocol fee non-zero); mirrors
            // quote_fee_bps. ceil(a/100) == (a + 99) / 100 for integer a.
            lp_fee_bps + ((lp_fee_bps * protocol_percent + 99) / 100)
        } else {
            lp_fee_bps
        };

        let reserves_now = self.storage.packed_reserves.read(); let reserve0 = reserves_now.reserve0; let reserve1 = reserves_now.reserve1;

        // Determine direction
        let is_token0_in = token_in == config.token0;
        let (reserve_in, reserve_out) = if is_token0_in {
            (reserve0, reserve1)
        } else {
            (reserve1, reserve0)
        };

        // Read actual delivery (FoT may undershoot, donation may overshoot)
        // and cap at declared `amount_in` so donations stay in reserves.
        let balance_in = self.view(Token::at(token_in).balance_of_public(self.address));
        let actual_amount_in = balance_in - reserve_in;
        let swap_input = if actual_amount_in < amount_in { actual_amount_in } else { amount_in };

        let amount_out = get_amount_out(swap_input, reserve_in, reserve_out, fee_bps);
        assert(amount_out >= amount_out_min, "INSUFFICIENT_OUTPUT_AMOUNT");

        // Transfer output to user's private balance via partial note
        Token::at(token_out)
            .finalize_transfer_to_private(amount_out, token_out_partial_note)
            .call(self.context);

        // Update TWAP accumulators (skip writes if same block -- saves 5 SSTOREs)
        let timestamp_last = self.storage.block_timestamp_last.read();
        let current_timestamp = self.context.timestamp() as u64;
        if current_timestamp > timestamp_last {
            let twap_fracs = self.storage.packed_twap_frac.read(); let p0_frac = twap_fracs.price0_cumul_frac; let p1_frac = twap_fracs.price1_cumul_frac;
            let twap = compute_twap_update(
                reserve0, reserve1,
                self.storage.price0_cumul_int.read(),
                p0_frac,
                self.storage.price1_cumul_int.read(),
                p1_frac,
                timestamp_last,
                current_timestamp,
            );
            self.storage.price0_cumul_int.write(twap.price0_cumul_int);
            self.storage.packed_twap_frac.write(TwapFractions { price0_cumul_frac: twap.price0_cumul_frac, price1_cumul_frac: twap.price1_cumul_frac });
            self.storage.price1_cumul_int.write(twap.price1_cumul_int);
            self.storage.block_timestamp_last.write(twap.block_timestamp);
        }

        // Update reserves from actual balances (both sides)
        let new_r0 = self.view(Token::at(config.token0).balance_of_public(self.address));
        let new_r1 = self.view(Token::at(config.token1).balance_of_public(self.address));

        // Defense-in-depth K invariant verification, mirroring the public V3
        // and flash_swap paths. The math implies K is preserved (get_amount_out
        // is K-preserving by formula and the lock prevents reentrant balance
        // mutation), but a future refactor of the formula or the swap_input
        // clamp could break the invariant silently. The wide-int budget is
        // already proven affordable on the public swap paths.
        let amount0_in_k = if is_token0_in { swap_input } else { 0 as u128 };
        let amount1_in_k = if is_token0_in { 0 as u128 } else { swap_input };
        verify_k_invariant(
            new_r0, new_r1,
            reserve0, reserve1,
            amount0_in_k, amount1_in_k,
            fee_bps,
        );

        // SwapEvent's amount_in is the value the swap math actually consumed
        // (`swap_input`). Any pre-existing donation that arrived as part of
        // `balance_in - reserve_in` is excluded -- it's not part of this
        // swap's volume; it was a gift to LPs and is reflected in the
        // SyncEvent reserve delta instead.
        self.emit(SwapEvent { token_in, token_out, amount_in: swap_input, amount_out });
        self.storage.packed_reserves.write(ReservesPacked { reserve0: new_r0, reserve1: new_r1 });
        self.emit(SyncEvent { reserve0: new_r0, reserve1: new_r1 });

        self.internal._release_lock();
    }

    /// Privately swap tokens to receive an exact amount of output tokens.
    ///
    /// The caller specifies the desired output amount and the maximum input they're
    /// willing to spend. Any excess input is refunded via partial note.
    #[external("private")]
    fn swap_exact_out(
        token_in: AztecAddress,
        token_out: AztecAddress,
        amount_out: u128,
        amount_in_max: u128,
        authwit_nonce: Field,
    ) {
        let config = self.storage.config.read();

        // Fail-fast at the entry so zero-amount calls don't burn the user's
        // authwit nonce on token-side prepares and the public continuation
        // gas before the deep `INSUFFICIENT_OUTPUT_AMOUNT` revert in
        // `get_amount_in`. Symmetric with the `swap_exact_in` and
        // `add_liquidity` entry guards.
        assert(amount_out > 0 as u128, "INSUFFICIENT_OUTPUT_AMOUNT");
        assert(amount_in_max > 0 as u128, "INSUFFICIENT_INPUT_MAX");

        assert(
            (token_in == config.token0) | (token_in == config.token1),
            "TOKEN_IN_IS_INVALID",
        );
        assert(
            (token_out == config.token0) | (token_out == config.token1),
            "TOKEN_OUT_IS_INVALID",
        );
        assert(token_in != token_out, "SAME_TOKEN_SWAP");

        let sender = self.msg_sender();

        // Transfer max input and prepare partial note for refunding excess
        let change_token_in_partial_note =
            self.call(Token::at(token_in)
                .transfer_to_public_and_prepare_private_balance_increase(
                    sender,
                    self.address,
                    amount_in_max,
                    authwit_nonce,
                ));

        // Prepare partial note for output tokens
        let token_out_partial_note =
            self.call(Token::at(token_out).prepare_private_balance_increase(sender));

        // Encrypted wallet-history event. Logs the user's authorized
        // `amount_in_max` (upper bound) and the exact `amount_out` requested.
        // The actual input the pair ends up consuming is computed in public
        // from current reserves and may be strictly less than `amount_in_max`;
        // the difference is returned via the refund partial note prepared
        // above. Wallets that want the actual spend should compute
        // `amount_in_max - refund_note_value` or read the public `SwapEvent`
        // in the same tx -- this event intentionally does not claim an
        // actual-input figure it cannot know at emission time.
        self.emit(PrivateSwapExactOutEvent { token_in, token_out, amount_in_max, amount_out })
            .deliver_to(sender, MessageDelivery.ONCHAIN_UNCONSTRAINED);

        self.enqueue_self._swap_exact_out(
            token_in,
            token_out,
            amount_in_max,
            amount_out,
            change_token_in_partial_note,
            token_out_partial_note,
        );
    }

    /// Public internal: compute required input, refund excess, execute exact-output swap.
    ///
    /// The user's authwit authorizes up to `amount_in_max`; the change refund
    /// is bounded by that authorization, NOT by `balance - reserve`. Three
    /// cases:
    ///   - non-FoT: `balance - reserve == amount_in_max`, change = max - amount_in.
    ///   - fee-on-transfer (delivery undershoots): change = (balance - reserve) - amount_in.
    ///   - donation (delivery overshoots): change capped at amount_in_max - amount_in;
    ///     the surplus `(balance - reserve) - amount_in_max` stays in the pair
    ///     and is captured into reserves below, V2-equivalent.
    /// This isolates donations to LPs while preserving native FoT support.
    #[external("public")]
    #[only_self]
    fn _swap_exact_out(
        token_in: AztecAddress,
        token_out: AztecAddress,
        amount_in_max: u128,
        amount_out: u128,
        change_token_in_partial_note: PartialUintNote,
        token_out_partial_note: PartialUintNote,
    ) {
        let (is_paused, fee_active, fee_percent) = self.internal._acquire_lock();
        assert(!is_paused, "PAUSED");

        let config = self.storage.config.read();
        let lp_fee_bps = config.fee_tier_bps as u128;
        let fee_bps = if fee_active {
            let protocol_percent = fee_percent as u128;
            // ceil: round the protocol markup up so it is never floored to 0
            // (keeps LPs' fee whole and the protocol fee non-zero); mirrors
            // quote_fee_bps. ceil(a/100) == (a + 99) / 100 for integer a.
            lp_fee_bps + ((lp_fee_bps * protocol_percent + 99) / 100)
        } else {
            lp_fee_bps
        };

        let reserves_now = self.storage.packed_reserves.read(); let reserve0 = reserves_now.reserve0; let reserve1 = reserves_now.reserve1;

        let is_token0_in = token_in == config.token0;
        let (reserve_in, reserve_out) = if is_token0_in {
            (reserve0, reserve1)
        } else {
            (reserve1, reserve0)
        };

        // Read actual delivery (FoT may undershoot, donation may overshoot)
        // and cap the refundable amount at the user's authorized `amount_in_max`.
        let balance_in = self.view(Token::at(token_in).balance_of_public(self.address));
        let actual_received = balance_in - reserve_in;
        let user_authorized = if actual_received < amount_in_max { actual_received } else { amount_in_max };

        // Compute required input for desired output
        let amount_in = get_amount_in(amount_out, reserve_in, reserve_out, fee_bps);
        assert(amount_in <= user_authorized, "EXCESSIVE_INPUT_AMOUNT");

        // Refund only what the user authorized but didn't get used. Any
        // overshoot beyond `amount_in_max` (donation) stays in the pair
        // and lands in reserves via the balance-derived write below.
        let change = user_authorized - amount_in;
        // Skip finalization if change is 0 -- Aztec's PartialUintNote rejects
        // zero-value completion. Uncompleted partial notes are harmless.
        if change > 0 as u128 {
            self.call(Token::at(token_in).finalize_transfer_to_private(
                change,
                change_token_in_partial_note,
            ));
        }

        // Transfer output to user's private balance
        Token::at(token_out)
            .finalize_transfer_to_private(amount_out, token_out_partial_note)
            .call(self.context);

        // Update TWAP accumulators (skip writes if same block -- saves 5 SSTOREs)
        let timestamp_last = self.storage.block_timestamp_last.read();
        let current_timestamp = self.context.timestamp() as u64;
        if current_timestamp > timestamp_last {
            let twap_fracs = self.storage.packed_twap_frac.read(); let p0_frac = twap_fracs.price0_cumul_frac; let p1_frac = twap_fracs.price1_cumul_frac;
            let twap = compute_twap_update(
                reserve0, reserve1,
                self.storage.price0_cumul_int.read(),
                p0_frac,
                self.storage.price1_cumul_int.read(),
                p1_frac,
                timestamp_last,
                current_timestamp,
            );
            self.storage.price0_cumul_int.write(twap.price0_cumul_int);
            self.storage.packed_twap_frac.write(TwapFractions { price0_cumul_frac: twap.price0_cumul_frac, price1_cumul_frac: twap.price1_cumul_frac });
            self.storage.price1_cumul_int.write(twap.price1_cumul_int);
            self.storage.block_timestamp_last.write(twap.block_timestamp);
        }

        // Update reserves from actual balances (both sides)
        let new_r0 = self.view(Token::at(config.token0).balance_of_public(self.address));
        let new_r1 = self.view(Token::at(config.token1).balance_of_public(self.address));

        // Defense-in-depth K invariant verification, mirroring the public V3
        // and flash_swap paths. amount_in is the K-preserving input computed
        // by get_amount_in; any donation excess (amount_in_max < actual_received)
        // increases balance_in_after without being fee-charged, so K-after with
        // donation is at least K-after without donation, which preserves K.
        let amount0_in_k = if is_token0_in { amount_in } else { 0 as u128 };
        let amount1_in_k = if is_token0_in { 0 as u128 } else { amount_in };
        verify_k_invariant(
            new_r0, new_r1,
            reserve0, reserve1,
            amount0_in_k, amount1_in_k,
            fee_bps,
        );

        // Emit events
        self.emit(SwapEvent { token_in, token_out, amount_in, amount_out });
        self.storage.packed_reserves.write(ReservesPacked { reserve0: new_r0, reserve1: new_r1 });
        self.emit(SyncEvent { reserve0: new_r0, reserve1: new_r1 });

        self.internal._release_lock();
    }

    // ================================================================
    // Public Swap (V3 callback pattern -- for composability)
    // ================================================================

    /// Public swap with callback payment (V3 pattern).
    ///
    /// 1. Computes the output from the declared amount_in and current reserves
    /// 2. Sends output tokens to recipient
    /// 3. Calls back to the caller to pay the input tokens
    /// 4. Verifies the pair's input token balance increased by at least amount_in
    ///
    /// The caller's contract must implement a public callback function matching
    /// callback_selector that transfers amount_in of token_in to this pair.
    ///
    /// Settling input via the callback (rather than a separate deposit the pair
    /// later claims) closes the frontrunning vector where an attacker could
    /// claim another user's pre-deposited tokens.
    ///
    /// Note: Fee-on-transfer tokens as token_in require the callback to overpay
    /// to account for the transfer tax. The balance check verifies the pair
    /// received at least amount_in. The private swap functions handle
    /// fee-on-transfer natively via balance-based accounting.
    #[external("public")]
    fn swap_exact_in_public(
        token_in: AztecAddress,
        token_out: AztecAddress,
        amount_in: u128,
        amount_out_min: u128,
        recipient: AztecAddress,
        callback_contract: AztecAddress,
        callback_selector: FunctionSelector,
    ) {
        let (is_paused, fee_active, fee_percent) = self.internal._acquire_lock();
        assert(!is_paused, "PAUSED");

        let config = self.storage.config.read();
        assert(
            (token_in == config.token0) | (token_in == config.token1),
            "TOKEN_IN_IS_INVALID",
        );
        assert(
            (token_out == config.token0) | (token_out == config.token1),
            "TOKEN_OUT_IS_INVALID",
        );
        assert(token_in != token_out, "SAME_TOKEN_SWAP");

        // Validate callback target. Same blocklist as flash_swap for the
        // same reasons (pair, tokens, LP, factory are either the pair itself
        // or contracts whose private/public surface could be abused if a
        // caller tricked them into executing the callback selector). We do
        // NOT forbid `callback_contract == recipient`: the router legitimately
        // passes itself as both (router receives the output for fee deduction
        // + forwarding, and router is the callback contract that pays the
        // pair), and the reentrancy lock held through this function prevents
        // the recipient-is-callback case from opening a cross-call attack.
        let lp_token_addr = self.storage.lp_token.read();
        assert(callback_contract != AztecAddress::zero(), "INVALID_CALLBACK_TARGET");
        assert(callback_contract != self.address, "INVALID_CALLBACK_TARGET");
        assert(callback_contract != config.token0, "INVALID_CALLBACK_TARGET");
        assert(callback_contract != config.token1, "INVALID_CALLBACK_TARGET");
        assert(callback_contract != lp_token_addr, "INVALID_CALLBACK_TARGET");
        assert(callback_contract != config.factory, "INVALID_CALLBACK_TARGET");

        // Recipient blocklist: tokens delivered to a protocol-internal address
        // are permanently stranded. Same set as the callback blocklist; the
        // distinct revert message lets integrators tell the two guards apart.
        // Subsumes a standalone ZERO_RECIPIENT check.
        assert(recipient != AztecAddress::zero(), "INVALID_RECIPIENT");
        assert(recipient != self.address, "INVALID_RECIPIENT");
        assert(recipient != config.token0, "INVALID_RECIPIENT");
        assert(recipient != config.token1, "INVALID_RECIPIENT");
        assert(recipient != lp_token_addr, "INVALID_RECIPIENT");
        assert(recipient != config.factory, "INVALID_RECIPIENT");

        let lp_fee_bps = config.fee_tier_bps as u128;
        let fee_bps = if fee_active {
            let protocol_percent = fee_percent as u128;
            // ceil: round the protocol markup up so it is never floored to 0
            // (keeps LPs' fee whole and the protocol fee non-zero); mirrors
            // quote_fee_bps. ceil(a/100) == (a + 99) / 100 for integer a.
            lp_fee_bps + ((lp_fee_bps * protocol_percent + 99) / 100)
        } else {
            lp_fee_bps
        };

        let reserves_now = self.storage.packed_reserves.read(); let reserve0 = reserves_now.reserve0; let reserve1 = reserves_now.reserve1;

        let is_token0_in = token_in == config.token0;
        let (reserve_in, reserve_out) = if is_token0_in {
            (reserve0, reserve1)
        } else {
            (reserve1, reserve0)
        };

        // Step 1: Compute output from declared amount_in
        let amount_out = get_amount_out(amount_in, reserve_in, reserve_out, fee_bps);
        assert(amount_out >= amount_out_min, "INSUFFICIENT_OUTPUT_AMOUNT");

        // Step 2: Send output tokens to recipient (optimistic, like V3)
        Token::at(token_out)
            .transfer_in_public(self.address, recipient, amount_out, 0)
            .call(self.context);

        // Step 3: Record balance before callback, then call back to caller to pay
        let balance_before = self.view(Token::at(token_in).balance_of_public(self.address));

        let _callback_result = self.context.call_public_function(
            callback_contract,
            callback_selector,
            [
                self.address.to_field(),
                token_in.to_field(),
                amount_in as Field,
            ],
            GasOpts::default(),
        );

        // Step 4: Read both token balances after the callback. Measuring both
        // sides (like flash_swap) makes any incidental `token_out` that the
        // callback transferred into the pair show up as reserve growth, so the
        // donation flows to LPs rather than sitting orphaned for whoever calls
        // skim first.
        let balance0_after = self.view(Token::at(config.token0).balance_of_public(self.address));
        let balance1_after = self.view(Token::at(config.token1).balance_of_public(self.address));
        let balance_in_after = if is_token0_in { balance0_after } else { balance1_after };
        assert(balance_in_after >= balance_before + amount_in, "INSUFFICIENT_PAYMENT");

        // Defense-in-depth K invariant check. The pair's `get_amount_out` /
        // `get_amount_in` formula plus the INSUFFICIENT_PAYMENT check above
        // already imply K >= K_old for the expected flow, but a future
        // refactor breaking either of those invariants would slip past
        // silently without an ex-post check. Routes through the same wide-int
        // helper as flash_swap so attacker-dumped balances past 2^112 don't
        // cause Field wraparound to accept a violation.
        let (amount0_out_k, amount1_out_k) = if is_token0_in {
            (0 as u128, amount_out)
        } else {
            (amount_out, 0 as u128)
        };
        let (amount0_in_k, amount1_in_k) = compute_amounts_in(
            reserve0, reserve1,
            amount0_out_k, amount1_out_k,
            balance0_after, balance1_after,
        );
        verify_k_invariant(
            balance0_after, balance1_after,
            reserve0, reserve1,
            amount0_in_k, amount1_in_k,
            fee_bps,
        );

        // Update TWAP (skip writes if same block)
        let timestamp_last = self.storage.block_timestamp_last.read();
        let current_timestamp = self.context.timestamp() as u64;
        if current_timestamp > timestamp_last {
            let twap_fracs = self.storage.packed_twap_frac.read(); let p0_frac = twap_fracs.price0_cumul_frac; let p1_frac = twap_fracs.price1_cumul_frac;
            let twap = compute_twap_update(
                reserve0, reserve1,
                self.storage.price0_cumul_int.read(),
                p0_frac,
                self.storage.price1_cumul_int.read(),
                p1_frac,
                timestamp_last,
                current_timestamp,
            );
            self.storage.price0_cumul_int.write(twap.price0_cumul_int);
            self.storage.packed_twap_frac.write(TwapFractions { price0_cumul_frac: twap.price0_cumul_frac, price1_cumul_frac: twap.price1_cumul_frac });
            self.storage.price1_cumul_int.write(twap.price1_cumul_int);
            self.storage.block_timestamp_last.write(twap.block_timestamp);
        }

        // Update reserves from both actual balances. Any overpayment (input)
        // or donation (output) during the callback is captured for the LPs.
        // `amount_in` here is the actual paid input (balance delta), not the
        // declared argument: a callback that overpays beyond the declared
        // `amount_in` deposits the surplus into reserves, and the event must
        // reflect what was actually paid so indexer-aggregated volume matches
        // reserve deltas. This DIFFERS from `_swap_exact_in`'s private-path
        // event, which logs `min(actual, declared)` because donations on the
        // private path are pre-existing third-party transfers (not user-driven
        // volume). Public-path "overpay" is callback-driven and is part of
        // this swap's economic effect; private-path "donation" is not.
        let actual_amount_in = balance_in_after - balance_before;
        self.emit(SwapPublicEvent {
            sender: self.msg_sender(),
            token_in,
            token_out,
            amount_in: actual_amount_in,
            amount_out,
            recipient,
        });
        self.storage.packed_reserves.write(ReservesPacked { reserve0: balance0_after, reserve1: balance1_after });
        self.emit(SyncEvent { reserve0: balance0_after, reserve1: balance1_after });

        self.internal._release_lock();
    }

    /// Public exact-output swap with callback payment (V3 pattern).
    ///
    /// Mirror of swap_exact_in_public for the exact-output direction:
    ///   1. Compute the required input from the desired output and current reserves
    ///   2. Assert required input <= amount_in_max
    ///   3. Send output tokens to recipient (optimistic, V3-style)
    ///   4. Callback to caller requesting the exact required input (not amount_in_max)
    ///   5. Verify the pair's input-token balance increased by at least amount_in
    ///
    /// The caller's callback must match callback_selector and transfer amount_in of
    /// token_in to this pair. Any excess headroom stays with the caller, which is
    /// how the router refunds unspent input to the user's private balance.
    ///
    /// Does not support fee-on-transfer input tokens (the callback must deliver
    /// exactly amount_in to the pair's balance).
    #[external("public")]
    fn swap_exact_out_public(
        token_in: AztecAddress,
        token_out: AztecAddress,
        amount_out: u128,
        amount_in_max: u128,
        recipient: AztecAddress,
        callback_contract: AztecAddress,
        callback_selector: FunctionSelector,
    ) {
        let (is_paused, fee_active, fee_percent) = self.internal._acquire_lock();
        assert(!is_paused, "PAUSED");

        let config = self.storage.config.read();
        assert(
            (token_in == config.token0) | (token_in == config.token1),
            "TOKEN_IN_IS_INVALID",
        );
        assert(
            (token_out == config.token0) | (token_out == config.token1),
            "TOKEN_OUT_IS_INVALID",
        );
        assert(token_in != token_out, "SAME_TOKEN_SWAP");

        // Validate callback target (same blocklist as swap_exact_in_public /
        // flash_swap). `callback_contract == recipient` is intentionally
        // allowed -- see the comment on swap_exact_in_public for the rationale.
        let lp_token_addr = self.storage.lp_token.read();
        assert(callback_contract != AztecAddress::zero(), "INVALID_CALLBACK_TARGET");
        assert(callback_contract != self.address, "INVALID_CALLBACK_TARGET");
        assert(callback_contract != config.token0, "INVALID_CALLBACK_TARGET");
        assert(callback_contract != config.token1, "INVALID_CALLBACK_TARGET");
        assert(callback_contract != lp_token_addr, "INVALID_CALLBACK_TARGET");
        assert(callback_contract != config.factory, "INVALID_CALLBACK_TARGET");

        // Recipient blocklist: tokens delivered to a protocol-internal address
        // are permanently stranded. Same set as the callback blocklist; the
        // distinct revert message lets integrators tell the two guards apart.
        // Subsumes a standalone ZERO_RECIPIENT check.
        assert(recipient != AztecAddress::zero(), "INVALID_RECIPIENT");
        assert(recipient != self.address, "INVALID_RECIPIENT");
        assert(recipient != config.token0, "INVALID_RECIPIENT");
        assert(recipient != config.token1, "INVALID_RECIPIENT");
        assert(recipient != lp_token_addr, "INVALID_RECIPIENT");
        assert(recipient != config.factory, "INVALID_RECIPIENT");

        let lp_fee_bps = config.fee_tier_bps as u128;
        let fee_bps = if fee_active {
            let protocol_percent = fee_percent as u128;
            // ceil: round the protocol markup up so it is never floored to 0
            // (keeps LPs' fee whole and the protocol fee non-zero); mirrors
            // quote_fee_bps. ceil(a/100) == (a + 99) / 100 for integer a.
            lp_fee_bps + ((lp_fee_bps * protocol_percent + 99) / 100)
        } else {
            lp_fee_bps
        };

        let reserves_now = self.storage.packed_reserves.read(); let reserve0 = reserves_now.reserve0; let reserve1 = reserves_now.reserve1;

        let is_token0_in = token_in == config.token0;
        let (reserve_in, reserve_out) = if is_token0_in {
            (reserve0, reserve1)
        } else {
            (reserve1, reserve0)
        };

        // Step 1: Compute required input for the requested output
        let amount_in = get_amount_in(amount_out, reserve_in, reserve_out, fee_bps);
        assert(amount_in <= amount_in_max, "EXCESSIVE_INPUT_AMOUNT");

        // Step 2: Send output tokens to recipient (optimistic)
        Token::at(token_out)
            .transfer_in_public(self.address, recipient, amount_out, 0)
            .call(self.context);

        // Step 3: Record balance before callback, then request payment of amount_in
        let balance_before = self.view(Token::at(token_in).balance_of_public(self.address));

        let _callback_result = self.context.call_public_function(
            callback_contract,
            callback_selector,
            [
                self.address.to_field(),
                token_in.to_field(),
                amount_in as Field,
            ],
            GasOpts::default(),
        );

        // Step 4: Read both token balances after the callback. Measuring both
        // sides (like flash_swap) makes any incidental `token_out` that the
        // callback transferred into the pair show up as reserve growth, so the
        // donation flows to LPs rather than sitting orphaned for whoever calls
        // skim first.
        let balance0_after = self.view(Token::at(config.token0).balance_of_public(self.address));
        let balance1_after = self.view(Token::at(config.token1).balance_of_public(self.address));
        let balance_in_after = if is_token0_in { balance0_after } else { balance1_after };
        assert(balance_in_after >= balance_before + amount_in, "INSUFFICIENT_PAYMENT");

        // Defense-in-depth K invariant check. The pair's `get_amount_out` /
        // `get_amount_in` formula plus the INSUFFICIENT_PAYMENT check above
        // already imply K >= K_old for the expected flow, but a future
        // refactor breaking either of those invariants would slip past
        // silently without an ex-post check. Routes through the same wide-int
        // helper as flash_swap so attacker-dumped balances past 2^112 don't
        // cause Field wraparound to accept a violation.
        let (amount0_out_k, amount1_out_k) = if is_token0_in {
            (0 as u128, amount_out)
        } else {
            (amount_out, 0 as u128)
        };
        let (amount0_in_k, amount1_in_k) = compute_amounts_in(
            reserve0, reserve1,
            amount0_out_k, amount1_out_k,
            balance0_after, balance1_after,
        );
        verify_k_invariant(
            balance0_after, balance1_after,
            reserve0, reserve1,
            amount0_in_k, amount1_in_k,
            fee_bps,
        );

        // Update TWAP (skip writes if same block)
        let timestamp_last = self.storage.block_timestamp_last.read();
        let current_timestamp = self.context.timestamp() as u64;
        if current_timestamp > timestamp_last {
            let twap_fracs = self.storage.packed_twap_frac.read(); let p0_frac = twap_fracs.price0_cumul_frac; let p1_frac = twap_fracs.price1_cumul_frac;
            let twap = compute_twap_update(
                reserve0, reserve1,
                self.storage.price0_cumul_int.read(),
                p0_frac,
                self.storage.price1_cumul_int.read(),
                p1_frac,
                timestamp_last,
                current_timestamp,
            );
            self.storage.price0_cumul_int.write(twap.price0_cumul_int);
            self.storage.packed_twap_frac.write(TwapFractions { price0_cumul_frac: twap.price0_cumul_frac, price1_cumul_frac: twap.price1_cumul_frac });
            self.storage.price1_cumul_int.write(twap.price1_cumul_int);
            self.storage.block_timestamp_last.write(twap.block_timestamp);
        }

        // Update reserves from both actual balances. Any overpayment (input)
        // or donation (output) during the callback is captured for the LPs.

        // Emit events
        self.emit(SwapPublicEvent {
            sender: self.msg_sender(), token_in, token_out, amount_in, amount_out, recipient,
        });
        self.storage.packed_reserves.write(ReservesPacked { reserve0: balance0_after, reserve1: balance1_after });
        self.emit(SyncEvent { reserve0: balance0_after, reserve1: balance1_after });

        self.internal._release_lock();
    }

    // ================================================================
    // skim() and sync()
    // ================================================================

    /// Skim excess tokens (balance - reserves) to a recipient.
    /// The standard constant-product skim recovery function.
    ///
    /// Permissionless recovery function. If tokens are sent directly to the pair
    /// (bypassing swap/mint), this allows recovering them.
    /// Allowed during pause (recovery operation).
    #[external("private")]
    fn skim(to: AztecAddress) {
        // Reject the zero address: a partial note targeted at the zero
        // address can never be completed (no signer for zero), so any
        // tokens transferred via the public `_skim` continuation would be
        // permanently locked out of reach. Mirrors the recipient guards
        // on `add_liquidity_public` and `remove_liquidity_public`.
        assert(!to.is_zero(), "ZERO_RECIPIENT");

        let config = self.storage.config.read();

        // Prepare partial notes for the excess tokens to be sent to `to`
        let token0_partial_note =
            self.call(Token::at(config.token0).prepare_private_balance_increase(to));
        let token1_partial_note =
            self.call(Token::at(config.token1).prepare_private_balance_increase(to));

        self.enqueue_self._skim(config, token0_partial_note, token1_partial_note);
    }

    #[external("public")]
    #[only_self]
    fn _skim(
        config: PairConfig,
        token0_partial_note: PartialUintNote,
        token1_partial_note: PartialUintNote,
    ) {
        // No pause check -- recovery always allowed
        let (_is_paused, _fee_active, _fee_percent) = self.internal._acquire_lock();
        let token0 = Token::at(config.token0);
        let token1 = Token::at(config.token1);

        let balance0 = self.view(token0.balance_of_public(self.address));
        let balance1 = self.view(token1.balance_of_public(self.address));
        let reserves_now = self.storage.packed_reserves.read(); let reserve0 = reserves_now.reserve0; let reserve1 = reserves_now.reserve1;

        let excess0 = balance0 - reserve0;
        let excess1 = balance1 - reserve1;

        // Skip finalization if excess is 0 -- Aztec's PartialUintNote rejects
        // zero-value completion. Uncompleted partial notes are harmless.
        if excess0 > 0 as u128 {
            self.call(token0.finalize_transfer_to_private(excess0, token0_partial_note));
        }
        if excess1 > 0 as u128 {
            self.call(token1.finalize_transfer_to_private(excess1, token1_partial_note));
        }

        // Advance the TWAP timestamp to mirror sync()'s behavior. _skim does
        // not change reserves, so the price ratio is unchanged and the
        // accumulator only needs its block_timestamp_last bumped (the inner
        // compute_twap_update returns block_timestamp == current_timestamp on
        // the no-price-change branch). Keeps every state-touching mutating
        // entry consistent on TWAP advancement; closes the asymmetry where a
        // TWAP consumer sampling at moments bracketing only skim calls would
        // see T2 == T1 and have to special-case 0/0.
        let timestamp_last = self.storage.block_timestamp_last.read();
        let current_timestamp = self.context.timestamp() as u64;
        if current_timestamp > timestamp_last {
            let twap_fracs = self.storage.packed_twap_frac.read(); let p0_frac = twap_fracs.price0_cumul_frac; let p1_frac = twap_fracs.price1_cumul_frac;
            let twap = compute_twap_update(
                reserve0, reserve1,
                self.storage.price0_cumul_int.read(),
                p0_frac,
                self.storage.price1_cumul_int.read(),
                p1_frac,
                timestamp_last,
                current_timestamp,
            );
            self.storage.price0_cumul_int.write(twap.price0_cumul_int);
            self.storage.packed_twap_frac.write(TwapFractions { price0_cumul_frac: twap.price0_cumul_frac, price1_cumul_frac: twap.price1_cumul_frac });
            self.storage.price1_cumul_int.write(twap.price1_cumul_int);
            self.storage.block_timestamp_last.write(twap.block_timestamp);
        }

        self.internal._release_lock();
    }

    /// Force reserves to match current token balances.
    /// The standard constant-product sync recovery function.
    ///
    /// Permissionless recovery function. Updates stored reserves to reflect
    /// actual token balances. Useful after direct transfers or edge cases.
    /// Allowed during pause (recovery operation).
    ///
    /// TWAP manipulation note: because `sync()` is permissionless, a caller
    /// can time donations-then-sync to shift the TWAP accumulation onto a
    /// skewed price. This is inherent to constant-product +
    /// permissionless-sync; removing `sync()` only moves the vector to
    /// `swap()` (which also reads balances). There is no contract-level fix;
    /// oracle consumers must use long observation windows (30+ minutes) and
    /// multi-sample averaging. See the "Oracle consumer guidance" section in
    /// the pair README for details.
    #[external("public")]
    fn sync() {
        // No pause check -- recovery always allowed
        let (_is_paused, _fee_active, _fee_percent) = self.internal._acquire_lock();
        let config = self.storage.config.read();

        let balance0 = self.view(Token::at(config.token0).balance_of_public(self.address));
        let balance1 = self.view(Token::at(config.token1).balance_of_public(self.address));

        // Update TWAP accumulators (skip writes if same block)
        let reserves_now = self.storage.packed_reserves.read(); let reserve0 = reserves_now.reserve0; let reserve1 = reserves_now.reserve1;
        let timestamp_last = self.storage.block_timestamp_last.read();
        let current_timestamp = self.context.timestamp() as u64;
        if current_timestamp > timestamp_last {
            let twap_fracs = self.storage.packed_twap_frac.read(); let p0_frac = twap_fracs.price0_cumul_frac; let p1_frac = twap_fracs.price1_cumul_frac;
            let twap = compute_twap_update(
                reserve0, reserve1,
                self.storage.price0_cumul_int.read(),
                p0_frac,
                self.storage.price1_cumul_int.read(),
                p1_frac,
                timestamp_last,
                current_timestamp,
            );
            self.storage.price0_cumul_int.write(twap.price0_cumul_int);
            self.storage.packed_twap_frac.write(TwapFractions { price0_cumul_frac: twap.price0_cumul_frac, price1_cumul_frac: twap.price1_cumul_frac });
            self.storage.price1_cumul_int.write(twap.price1_cumul_int);
            self.storage.block_timestamp_last.write(twap.block_timestamp);
        }

        // Force reserves to match actual balances (capped at u112)
        self.storage.packed_reserves.write(ReservesPacked { reserve0: balance0, reserve1: balance1 });
        self.emit(SyncEvent { reserve0: balance0, reserve1: balance1 });

        // reserves_last is deliberately NOT touched here. It is the protocol-
        // fee baseline snapshot, owned by mint/burn (which advance it when
        // fees are active) and by `set_protocol_fee` (which zeros it on
        // active->inactive transitions and percent changes). Writing it
        // from sync() would erase legitimate fee accrual between the last
        // mint/burn and the next one, letting any caller zero the protocol
        // fee by running sync() before every liquidity event.
        //
        // Trade-off: donations to the pool between mints are attributed to
        // the next mint's fee accrual (a sliver goes to fee_to). Documented
        // under "Oracle consumer guidance" in the pair README.

        self.internal._release_lock();
    }

    // ================================================================
    // Factory Admin Functions (callable only by the factory contract)
    // ================================================================

    /// Set the emergency pause state. Only callable by the factory.
    ///
    /// Emits `PairPausedEvent` on inactive-to-paused transitions and
    /// `PairUnpausedEvent` on paused-to-inactive transitions. No event on
    /// idempotent calls (e.g. `set_pause(true)` against an already-paused
    /// pair, which can happen via repeated factory admin calls).
    #[external("public")]
    fn set_pause(paused: bool) {
        let (was_paused, fee_active, fee_percent) = self.internal._assert_factory_and_unlocked();
        if paused != was_paused {
            self.storage.packed_flags.write(FlagsPacked { is_paused: paused, locked: false, protocol_fee_active: fee_active, protocol_fee_percent: fee_percent });
            if paused {
                self.emit(PairPausedEvent {});
            } else {
                self.emit(PairUnpausedEvent {});
            }
        }
    }

    /// Set the protocol fee configuration. Only callable by the factory.
    ///
    /// Semantically, there are two canonical configurations:
    /// - Enabled:  `active == true` and `percent > 0` (fee accrues)
    /// - Disabled: `active == false` (no fee, `reserves_last` zeroed)
    ///
    /// The pair rejects `active == true` with `percent == 0` to prevent a
    /// windfall scenario: if an admin accidentally sets that state, K-growth
    /// accumulates against a stale `reserves_last` baseline (because the
    /// `!active` branch that zeroes it doesn't fire). Later restoring
    /// `percent > 0` would then mint a fee on the cumulative growth,
    /// including the period the admin intended to be fee-free. Forcing
    /// `active = false` as the disabled-fee signal eliminates this ambiguity
    /// and ensures `reserves_last` is always zeroed when fees turn off.
    #[external("public")]
    fn set_protocol_fee(fee_to: AztecAddress, percent: u32, active: bool) {
        let (is_paused, old_active, old_percent) =
            self.internal._assert_factory_and_unlocked();
        assert(percent <= 100, "PERCENT_TOO_HIGH");
        assert(!(active & (percent == 0)), "ACTIVE_WITH_ZERO_PERCENT");
        assert(!(active & fee_to.is_zero()), "ACTIVE_WITH_ZERO_FEE_TO");

        // No-op when nothing would change. Prevents the factory's
        // `sync_protocol_fee` from emitting redundant storage writes on
        // repeated identical pushes. A real governance change always moves
        // at least one of (fee_to, percent, active), so this only suppresses
        // redundant work.
        let old_fee_to = self.storage.fee_to.read();
        let unchanged =
            (fee_to == old_fee_to) & (percent == old_percent) & (active == old_active);
        if !unchanged {
            self.storage.fee_to.write(fee_to);
            self.storage.packed_flags.write(FlagsPacked { is_paused, locked: false, protocol_fee_active: active, protocol_fee_percent: percent });

            // Reset reserves_last on any fee-config change so that K-growth
            // accrued under one configuration cannot be retroactively
            // assessed at a different one or redirected to a different
            // recipient. Every governance change starts a fresh epoch:
            //
            // - `!active`: fees being disabled. Zero so re-enabling later
            //   doesn't attribute disabled-period growth as fee revenue.
            // - `percent != old_percent` while active: the rate is changing;
            //   we forgive accumulated growth under the old rate rather than
            //   charging it at the new rate.
            // - `fee_to != old_fee_to` while active: the destination is
            //   changing. Without the reset, the next mint would mint LP
            //   for all K-growth accrued under the prior recipient to the
            //   new recipient. Forgiving that accrual to LPs (via the
            //   reset) is consistent with the percent-change semantics and
            //   removes an admin footgun on fee_to rotation.
            if !active {
                self.storage.packed_reserves_last.write(ReservesPacked::zero());
            } else if (percent != old_percent) | (fee_to != old_fee_to) {
                self.storage.packed_reserves_last.write(ReservesPacked::zero());
            }

            // Emit so indexers tracking pair state can detect a fee-config
            // change without cross-correlating against factory governance
            // events. Only emitted when at least one of (fee_to, percent,
            // active) actually changed; redundant `sync_protocol_fee` pushes
            // on the no-op branch above are silent.
            self.emit(ProtocolFeeConfigChangedEvent { fee_to, percent, active });
        }
    }

    // ================================================================
    // Flash Swap (atomic single-function with callback)
    // ================================================================

    /// Execute a flash swap: borrow tokens, callback to borrower, verify K invariant.
    ///
    /// Implements the constant-product swap. Uses Aztec's synchronous public-to-public
    /// call mechanism (context.call_public_function) to invoke the borrower's
    /// callback mid-execution, exactly like Solidity's external call pattern.
    ///
    /// Flow (all within this single function):
    ///   1. Transfer tokens to borrower (optimistic)
    ///   2. Synchronous callback to borrower's contract
    ///   3. Borrower does arbitrage/operation, repays tokens to pair
    ///   4. Control returns here
    ///   5. Verify K invariant (if violated, entire tx reverts atomically)
    ///   6. Update TWAP and reserves
    ///
    /// The borrower's contract must implement a public function matching the
    /// callback_selector. It receives (pair_address, token0, token1, amount0_out,
    /// amount1_out, data) as Field arguments and must repay tokens before returning.
    ///
    /// Public function because flash swaps are inherently public operations
    /// (amounts visible).
    ///
    /// Supported token types: flash_swap assumes the underlying tokens do NOT
    /// charge a transfer fee. The K-invariant check compares pair balances
    /// against the declared amount_in on the repayment side; a fee-on-transfer
    /// token would deliver less to the pair than the borrower sent, causing
    /// spurious K_INVARIANT_VIOLATED reverts. Private swap paths
    /// (_swap_exact_in / _swap_exact_out) are balance-based and handle
    /// fee-on-transfer natively; flash_swap does not.
    #[external("public")]
    fn flash_swap(
        amount0_out: u128,
        amount1_out: u128,
        borrower: AztecAddress,
        callback_selector: FunctionSelector,
        data: Field,
    ) {
        let (is_paused, fee_active, fee_percent) = self.internal._acquire_lock();
        assert(!is_paused, "PAUSED");

        assert(
            (amount0_out > 0 as u128) | (amount1_out > 0 as u128),
            "INSUFFICIENT_OUTPUT_AMOUNT",
        );

        let config = self.storage.config.read();
        let reserves_now = self.storage.packed_reserves.read(); let reserve0 = reserves_now.reserve0; let reserve1 = reserves_now.reserve1;

        // Gate per-side liquidity checks on whether that side was actually
        // requested. The top-of-function INSUFFICIENT_OUTPUT_AMOUNT guard
        // ensures at least one side is non-zero. Without gating, a one-sided
        // flash that requested only token0 would mis-attribute a zero-reserve
        // condition to the unrequested side ("INSUFFICIENT_LIQUIDITY_1" on a
        // token0-only flash). Practically unreachable in production -- the
        // permanently-locked MINIMUM_LIQUIDITY floor keeps both reserves
        // non-zero -- but the gate makes the source self-documenting and
        // produces an accurate error message under any future state change
        // that could surface a one-sided pool.
        if amount0_out > 0 as u128 {
            assert(amount0_out < reserve0, "INSUFFICIENT_LIQUIDITY_0");
        }
        if amount1_out > 0 as u128 {
            assert(amount1_out < reserve1, "INSUFFICIENT_LIQUIDITY_1");
        }
        assert(
            (borrower != config.token0) & (borrower != config.token1),
            "INVALID_BORROWER",
        );
        assert(borrower != AztecAddress::zero(), "INVALID_BORROWER");
        assert(borrower != self.address, "INVALID_BORROWER");
        assert(borrower != self.storage.lp_token.read(), "INVALID_BORROWER");
        assert(borrower != config.factory, "INVALID_BORROWER");

        // Step 1: Optimistic transfer to borrower
        if amount0_out > 0 as u128 {
            Token::at(config.token0)
                .transfer_in_public(self.address, borrower, amount0_out, 0)
                .call(self.context);
        }
        if amount1_out > 0 as u128 {
            Token::at(config.token1)
                .transfer_in_public(self.address, borrower, amount1_out, 0)
                .call(self.context);
        }

        // Step 2: Synchronous callback to borrower's contract.
        // The borrower receives (pair, token0, token1, amount0, amount1, data)
        // and must repay tokens to this pair before returning.
        let _callback_result = self.context.call_public_function(
            borrower,
            callback_selector,
            [
                self.address.to_field(),
                config.token0.to_field(),
                config.token1.to_field(),
                amount0_out as Field,
                amount1_out as Field,
                data,
            ],
            GasOpts::default(),
        );

        // Step 3: Verify K invariant after callback returns.
        // Read actual balances (borrower should have repaid by now).
        let token0 = Token::at(config.token0);
        let token1 = Token::at(config.token1);
        let balance0 = self.view(token0.balance_of_public(self.address));
        let balance1 = self.view(token1.balance_of_public(self.address));

        // Derive amount_i_in once via the shared helper. Reused for both the
        // INSUFFICIENT_REPAYMENT check and the K-invariant call below, so the
        // balance-vs-expected formula lives in exactly one place.
        let (amount0_in, amount1_in) = compute_amounts_in(
            reserve0, reserve1,
            amount0_out, amount1_out,
            balance0, balance1,
        );

        // Enforce INSUFFICIENT_REPAYMENT (at least one side saw net input).
        // Enforces the standard constant-product `INSUFFICIENT_INPUT_AMOUNT` check before the K
        // assertion: a borrower that takes tokens and returns literally
        // nothing gets the targeted error rather than the more general K one.
        assert(
            (amount0_in > 0 as u128) | (amount1_in > 0 as u128),
            "INSUFFICIENT_REPAYMENT",
        );

        let lp_fee_bps = config.fee_tier_bps as u128;
        let fee_bps = if fee_active {
            let protocol_percent = fee_percent as u128;
            // ceil: round the protocol markup up so it is never floored to 0
            // (keeps LPs' fee whole and the protocol fee non-zero); mirrors
            // quote_fee_bps. ceil(a/100) == (a + 99) / 100 for integer a.
            lp_fee_bps + ((lp_fee_bps * protocol_percent + 99) / 100)
        } else {
            lp_fee_bps
        };
        assert(fee_bps < 10000, "FEE_TOO_HIGH");

        // Constant-product K invariant, run in u128/u256/u512 limb arithmetic so
        // attacker-dumped balances past 2^112 don't cause Field wraparound to
        // silently accept a violation. See `math::wide::verify_k_invariant`.
        verify_k_invariant(
            balance0, balance1,
            reserve0, reserve1,
            amount0_in, amount1_in,
            fee_bps,
        );

        // Step 4: Update TWAP (skip writes if same block)
        let timestamp_last = self.storage.block_timestamp_last.read();
        let current_timestamp = self.context.timestamp() as u64;
        if current_timestamp > timestamp_last {
            let twap_fracs = self.storage.packed_twap_frac.read(); let p0_frac = twap_fracs.price0_cumul_frac; let p1_frac = twap_fracs.price1_cumul_frac;
            let twap = compute_twap_update(
                reserve0, reserve1,
                self.storage.price0_cumul_int.read(),
                p0_frac,
                self.storage.price1_cumul_int.read(),
                p1_frac,
                timestamp_last,
                current_timestamp,
            );
            self.storage.price0_cumul_int.write(twap.price0_cumul_int);
            self.storage.packed_twap_frac.write(TwapFractions { price0_cumul_frac: twap.price0_cumul_frac, price1_cumul_frac: twap.price1_cumul_frac });
            self.storage.price1_cumul_int.write(twap.price1_cumul_int);
            self.storage.block_timestamp_last.write(twap.block_timestamp);
        }

        // Emit events
        self.emit(FlashSwapEvent {
            borrower,
            amount0_in,
            amount1_in,
            amount0_out,
            amount1_out,
        });
        self.storage.packed_reserves.write(ReservesPacked { reserve0: balance0, reserve1: balance1 });
        self.emit(SyncEvent { reserve0: balance0, reserve1: balance1 });

        self.internal._release_lock();
    }

    // ================================================================
    // Utility Views (Private State)
    // ================================================================

    /// Get the current value of an LP position in terms of underlying tokens.
    /// Takes lp_amount and total_supply as parameters since utility functions
    /// cannot make cross-contract calls. The SDK provides total_supply.
    ///
    /// `lp_amount` is unbounded by design -- callers can pass arbitrary values
    /// (including amounts greater than `total_supply`) for hypothetical
    /// queries like "what would N LP at supply S be worth at current
    /// reserves?" The math returns `(lp_amount * reserve_i) / total_supply`
    /// in both cases; values above `total_supply` simply produce results
    /// above the current pool, which is the meaningful answer for that kind
    /// of query. Callers who want their actual current position should use
    /// the SDK's `getMyPositionValue` helper, which reads the caller's real
    /// LP balance and the burn-side balance-aware divisor.
    #[external("utility")]
    unconstrained fn get_position_value(lp_amount: u128, total_supply: u128) -> (u128, u128) {
        let reserves_now = self.storage.packed_reserves.read(); let reserve0 = reserves_now.reserve0; let reserve1 = reserves_now.reserve1;

        if (total_supply == 0) | (lp_amount == 0) {
            (0, 0)
        } else {
            (
                mul_div(lp_amount, reserve0, total_supply),
                mul_div(lp_amount, reserve1, total_supply),
            )
        }
    }

    /// Get the current spot price of token0 in terms of token1 (and vice versa).
    /// Returns (price0_numerator, price0_denominator, price1_numerator, price1_denominator)
    /// where price0 = reserve1/reserve0 and price1 = reserve0/reserve1.
    /// Runs locally.
    #[external("utility")]
    unconstrained fn get_spot_prices() -> (u128, u128, u128, u128) {
        let reserves_now = self.storage.packed_reserves.read(); let reserve0 = reserves_now.reserve0; let reserve1 = reserves_now.reserve1;
        // Return as fractions to avoid precision loss
        (reserve1, reserve0, reserve0, reserve1)
    }

    /// Get full pair state in a single call (for SDK efficiency).
    #[external("utility")]
    unconstrained fn get_pair_state() -> (u128, u128, u64, bool, u32, bool) {
        let reserves_now = self.storage.packed_reserves.read(); let reserve0 = reserves_now.reserve0; let reserve1 = reserves_now.reserve1;
        let flags = self.storage.packed_flags.read();
        let is_paused = flags.is_paused;
        let protocol_fee_active = flags.protocol_fee_active;
        let protocol_fee_percent = flags.protocol_fee_percent;
        (
            reserve0,
            reserve1,
            self.storage.block_timestamp_last.read(),
            is_paused,
            protocol_fee_percent,
            protocol_fee_active,
        )
    }
}
