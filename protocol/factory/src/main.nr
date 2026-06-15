// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 SigalSwap LLC. All rights reserved.
// Licensed under the Business Source License 1.1. See LICENSE in this directory.

// SigalSwap Factory - Pair registry, governance, and protocol fee management
//
// Governance model:
// - Immutable: core AMM math, pair logic, minimum liquidity, TWAP
// - Timelocked (48hr): fee tiers, protocol fee %, feeTo, admin rotation
// - Immediate admin: pause/unpause (global + per-pair)
// - Permissionless: register pairs (cryptographic checks gate validity), swap, liquidity, skim, sync, flash_swap

pub mod helpers; // pub so the sibling sigalswap_factory_tests crate can reach it
// Integration tests (TXE) live in the sibling `sigalswap_factory_tests` crate so
// the mock_pair_v2 test fixture stays out of this production build graph.

use aztec::macros::aztec;

#[aztec]
pub contract SigalSwapFactory {
    use aztec::{
        hash::hash_args,
        macros::{events::event, functions::{external, initializer, internal, view}, storage::storage},
        oracle::get_contract_instance::get_contract_instance_class_id_avm,
        protocol::{
            abis::function_selector::FunctionSelector,
            address::{AztecAddress, SaltedInitializationHash},
            contract_class_id::ContractClassId,
            public_keys::PublicKeys,
            traits::{FromField, Serialize, ToField},
        },
        state_vars::{Map, PublicMutable},
    };
    use std::meta::derive;
    use crate::helpers::{
        compute_action_hash, compute_base_key, compute_class_id_version_param,
        compute_clear_slot_param, compute_pair_key,
    };
    // Pair version's LP Token class_id and salt. Single source of truth lives
    // in the pair's source; we import here so the factory's address-match for
    // the derived LP Token uses the exact same inputs the pair bakes in.
    use sigalswap_core::{LP_TOKEN_CLASS_ID, LP_TOKEN_SALT};

    // ================================================================
    // Events
    // ================================================================

    #[derive(Serialize)]
    #[event]
    struct PairCreatedEvent {
        token0: AztecAddress,
        token1: AztecAddress,
        pair: AztecAddress,
        lp_token: AztecAddress,
        fee_tier_bps: u32,
        version: u32,
        pair_count: u32,
    }

    /// Emitted by `execute_clear_pair_slot`. Carries the cleared pair address,
    /// the base_key it was registered under, the version that was cleared, and
    /// the rollback target (`new_latest_version`, where 0 means the base is
    /// fully cleared). Indexer notes:
    ///   - The cleared pair contract is NOT removed from the historical log.
    ///     `pair_by_index`, `pair_count`, `base_by_index`, `base_count`, and
    ///     `base_seen` all stay intact -- the clear only zeroes the routing
    ///     pointers (`pairs[pair_key]` and `latest_pair[base_key]` /
    ///     `latest_version[base_key]`).
    ///   - The `pair` address is permanently barred from re-registration. The
    ///     `registered` flag stays set after clear, and `register_pair` asserts
    ///     `!registered[pair_address]` at entry. To re-introduce routing for the
    ///     same `(t0, t1, fee_tier)` base, governance must bless a new pair
    ///     bytecode (different class_id -> different canonical address).
    /// Emitted from `execute_clear_pair_slot` when admin retires a registered pair
    /// (via timelocked governance). All fields plaintext so indexers rendering
    /// "pool retired" UX can build a self-contained record without joining
    /// against `PairCreatedEvent` to recover `(token0, token1, fee_tier_bps)`
    /// from a hash. `new_latest_pair == AztecAddress::zero()` when the base is
    /// fully cleared (`new_latest_version == 0`); otherwise it's the
    /// rolled-back-to canonical pair.
    #[derive(Serialize)]
    #[event]
    struct PairSlotClearedEvent {
        pair: AztecAddress,
        token0: AztecAddress,
        token1: AztecAddress,
        fee_tier_bps: u32,
        cleared_version: u32,
        new_latest_version: u32,
        new_latest_pair: AztecAddress,
    }

    #[derive(Serialize)]
    #[event]
    struct RegistrationPausedEvent {}

    #[derive(Serialize)]
    #[event]
    struct RegistrationUnpausedEvent {}

    #[derive(Serialize)]
    #[event]
    struct PairPausedEvent { pair: AztecAddress }

    #[derive(Serialize)]
    #[event]
    struct PairUnpausedEvent { pair: AztecAddress }

    /// Emitted on every successful `sync_protocol_fee` admin call, regardless
    /// of whether the targeted pair's protocol-fee config actually changed.
    /// Mirrors the factory-side observability shape of `PairPausedEvent` /
    /// `PairUnpausedEvent`: factory emits on every admin action; the pair-side
    /// `ProtocolFeeConfigChangedEvent` continues to fire only on real state
    /// transitions. Indexers tracking governance activity should consume this
    /// event for the full admin-action audit trail; indexers tracking pair
    /// state should consume the pair-side event.
    #[derive(Serialize)]
    #[event]
    struct ProtocolFeeSyncedEvent { pair: AztecAddress }

    #[derive(Serialize)]
    #[event]
    struct ActionQueuedEvent { action_type: Field, value: Field, execute_after: u64 }

    #[derive(Serialize)]
    #[event]
    struct ActionExecutedEvent { action_type: Field, value: Field }

    #[derive(Serialize)]
    #[event]
    struct ActionCancelledEvent { action_type: Field, value: Field }

    #[derive(Serialize)]
    #[event]
    struct AdminChangedEvent { new_admin: AztecAddress }

    #[derive(Serialize)]
    #[event]
    struct FeeToChangedEvent { new_fee_to: AztecAddress }

    #[derive(Serialize)]
    #[event]
    struct FeeTierAddedEvent { tier_bps: u32 }

    #[derive(Serialize)]
    #[event]
    struct FeeTierRemovedEvent { tier_bps: u32 }

    /// Emitted when admin executes a protocol-fee-percent change. Symmetric
    /// with the typed events for `set_fee_to`, `set_admin`, and the fee-tier
    /// changes -- gives indexers using typed-event streaming a uniform shape
    /// instead of forcing them to decode `ActionExecutedEvent` for this one
    /// action type.
    #[derive(Serialize)]
    #[event]
    struct ProtocolFeePercentChangedEvent { new_percent: u32 }

    /// Emitted when admin executes a protocol-fee-enabled change. Same
    /// symmetry argument as `ProtocolFeePercentChangedEvent`.
    #[derive(Serialize)]
    #[event]
    struct ProtocolFeeEnabledChangedEvent { enabled: bool }

    /// Emitted when the blessed pair bytecode class ID and/or version
    /// changes. Observers tracking which bytecode the factory will accept
    /// for registration should key off this event. Emitted from
    /// `set_pair_class_id` in both the first-call (immediate) and
    /// subsequent (timelocked) branches.
    #[derive(Serialize)]
    #[event]
    struct PairClassIdChangedEvent { class_id: Field, version: u32 }

    use aztec::macros::functions::initialization_utils::compute_initialization_hash;
    use sigalswap_core::SigalSwapPair;

    /// Timelock delay: 48 hours in seconds
    pub global TIMELOCK_DELAY: u64 = 172800;
    /// Execution window after delay: 7 days in seconds
    pub global TIMELOCK_WINDOW: u64 = 604800;

    // Action type identifiers for timelock hashing
    global ACTION_SET_FEE_TO: Field = 1;
    global ACTION_SET_PROTOCOL_FEE_PERCENT: Field = 2;
    global ACTION_SET_PROTOCOL_FEE_ENABLED: Field = 3;
    global ACTION_ADD_FEE_TIER: Field = 4;
    global ACTION_REMOVE_FEE_TIER: Field = 5;
    global ACTION_SET_ADMIN: Field = 6;
    global ACTION_SET_PAIR_CLASS_ID: Field = 7;
    global ACTION_CLEAR_PAIR_SLOT: Field = 8;

    #[storage]
    struct Storage<Context> {
        /// Admin address (single admin for V1)
        admin: PublicMutable<AztecAddress, Context>,

        /// Protocol fee recipient
        fee_to: PublicMutable<AztecAddress, Context>,

        /// Protocol fee as % of LP fee (e.g., 20 = 20% markup). Applied globally.
        protocol_fee_percent: PublicMutable<u32, Context>,

        /// Whether protocol fee is enabled globally
        protocol_fee_enabled: PublicMutable<bool, Context>,

        /// Registration pause flag. When true, `register_pair` reverts.
        /// This flag does NOT pause trading on already-registered pairs:
        /// freezing trading requires iterating `pause_pair` across the
        /// registry. See factory README for the "global pause" procedure.
        registration_paused: PublicMutable<bool, Context>,

        /// Fee tier whitelist: field(tier_bps) => allowed
        allowed_fee_tiers: Map<Field, PublicMutable<bool, Context>, Context>,

        /// Count of currently-allowed fee tiers. Maintained alongside
        /// `allowed_fee_tiers`: incremented on every successful add,
        /// decremented on every successful remove. The tier-removal path
        /// asserts this stays >= 1 so admin operator error can't drain the
        /// whitelist and brick `register_pair` for a full timelock cycle.
        /// To intentionally block new registrations, admin uses
        /// `pause_registration` (immediate, no timelock) instead.
        allowed_fee_tier_count: PublicMutable<u32, Context>,

        /// Pair registry: compute_pair_key(token0, token1, fee_tier, version) =>
        /// registered pair address. Each pair version gets its own slot so
        /// multiple versions of the same (tokens, tier) pool can coexist
        /// during migration windows.
        pairs: Map<Field, PublicMutable<AztecAddress, Context>, Context>,

        /// Total number of pair registrations (includes every historical
        /// version, not just the latest-at-base). Paired with pair_by_index
        /// for full historical enumeration.
        pair_count: PublicMutable<u32, Context>,

        /// Historical enumeration: every registered pair across all versions.
        /// Index (as Field) => pair address (0-indexed, never cleared).
        pair_by_index: Map<Field, PublicMutable<AztecAddress, Context>, Context>,

        /// Address-keyed membership set: true iff the address was registered
        /// via `register_pair`. Admin-only functions like `sync_protocol_fee`
        /// assert on this to prevent an admin typo from silently touching a
        /// pair the factory doesn't know about. Never cleared -- a pair whose
        /// slot was `clear_pair_slot`'d still exists as a contract and
        /// remains in this set.
        registered: Map<AztecAddress, PublicMutable<bool, Context>, Context>,

        /// Timelock: action_hash => queued_at timestamp (0 = not queued)
        timelock: Map<Field, PublicMutable<u64, Context>, Context>,

        /// Expected contract class ID for SigalSwapPair. Admin sets this via
        /// set_pair_class_id (first call immediate, subsequent timelocked).
        /// register_pair verifies the pair's on-chain bytecode class ID matches
        /// this value.
        pair_class_id: PublicMutable<Field, Context>,

        /// Version associated with the currently-blessed pair_class_id.
        /// Monotonically increases via execute_set_pair_class_id; register_pair
        /// cross-checks this against the pair's self-reported get_version() to
        /// ensure governance's declared version matches the bytecode's version.
        pair_class_version: PublicMutable<u32, Context>,

        /// Latest version registered at each (token0, token1, fee_tier) base.
        /// Key: compute_base_key(t0, t1, tier).
        /// 0 = no pair registered at this base yet.
        latest_version: Map<Field, PublicMutable<u32, Context>, Context>,

        /// Direct pointer to the latest-version pair at each base, for cheap
        /// `get_pair` lookups. Kept in sync with latest_version.
        /// Key: compute_base_key(t0, t1, tier).
        /// AztecAddress::zero() = no pair registered at this base.
        latest_pair: Map<Field, PublicMutable<AztecAddress, Context>, Context>,

        /// Count of unique (token0, token1, fee_tier) bases ever registered.
        /// Used with base_by_index to enumerate only the latest-per-base pairs
        /// (useful for SDK consumers who want the "current" set without
        /// scanning every historical version).
        base_count: PublicMutable<u32, Context>,

        /// Enumeration of unique bases in registration order. Index => base_key.
        /// Only grows on the first-ever registration at a base; subsequent
        /// version upgrades at the same base do not increment base_count.
        base_by_index: Map<Field, PublicMutable<Field, Context>, Context>,

        /// Sticky flag set the first time a base_key is registered; never
        /// unset. Lets register_pair distinguish "first ever" from "after
        /// clear" -- both have latest_version == 0, but only the former
        /// should push onto base_by_index. Without this, re-registering at
        /// a cleared base would duplicate the entry in base_by_index.
        base_seen: Map<Field, PublicMutable<bool, Context>, Context>,

        /// Transient reentrancy guard for register_pair. `register_pair`
        /// makes a public-to-public call to `pair.set_protocol_fee(...)` at
        /// the end of registration -- today's pair bytecode never egresses
        /// from that function, but a future blessed bytecode could
        /// (intentionally or via bug). This lock prevents any reentrant
        /// register_pair call while a prior one is in flight: acquired near
        /// the top of register_pair, released after set_protocol_fee
        /// returns. Set+clear within the same tx; if the tx reverts the
        /// write rolls back and the lock is effectively never held.
        ///
        /// LOAD-BEARING INVARIANT: the guard only protects `register_pair`,
        /// which is the only permissionless mutating public function on the
        /// factory. Every other mutating public function (all `queue_*`,
        /// `execute_*`, `pause_*`, `sync_protocol_fee`, `cancel_action`,
        /// `set_pair_class_id`) is admin-gated, so a reentrant call from
        /// the pair's `set_protocol_fee` (where msg_sender is the factory,
        /// not admin) cannot reach them. If any future change adds another
        /// permissionless mutating public function, that function MUST
        /// either check `!register_pair_locked` at entry or be proven safe
        /// during an in-flight registration. Violating this invariant
        /// re-opens the reentrancy surface the guard was designed to close.
        register_pair_locked: PublicMutable<bool, Context>,
    }

    // ================================================================
    // Constructor
    // ================================================================

    #[external("public")]
    #[initializer]
    fn constructor(admin: AztecAddress) {
        // Reject zero-admin at construction. Every privileged surface
        // (`set_pair_class_id`, all `queue_*` / `execute_*`, `pause_pair`,
        // `unpause_pair`, `sync_protocol_fee`, `cancel_action`) gates on
        // `msg_sender == admin`. With `admin = zero`, no real account can
        // satisfy this and the factory is permanently bricked. Mirrors the
        // analogous zero-arg checks on the pair and router constructors.
        assert(!admin.is_zero(), "ZERO_ADMIN");
        self.storage.admin.write(admin);

        // Default fee tiers: 0.05%, 0.25%, 1.00%
        self.storage.allowed_fee_tiers.at(5 as Field).write(true);
        self.storage.allowed_fee_tiers.at(25 as Field).write(true);
        self.storage.allowed_fee_tiers.at(100 as Field).write(true);
        self.storage.allowed_fee_tier_count.write(3);

        // Protocol fee: 20% markup, disabled by default
        self.storage.protocol_fee_percent.write(20);
        self.storage.protocol_fee_enabled.write(false);

        // Emit initial-state events so indexers can reconstruct the full
        // factory configuration from event history alone (without having to
        // know to read constants or initial storage directly). `fee_to`
        // defaults to zero (unset) and is intentionally NOT emitted here:
        // admin's first `set_fee_to` call already emits `FeeToChangedEvent`,
        // so emitting a sentinel-zero event would be noise.
        self.emit(AdminChangedEvent { new_admin: admin });
        self.emit(FeeTierAddedEvent { tier_bps: 5 });
        self.emit(FeeTierAddedEvent { tier_bps: 25 });
        self.emit(FeeTierAddedEvent { tier_bps: 100 });
        self.emit(ProtocolFeePercentChangedEvent { new_percent: 20 });
        self.emit(ProtocolFeeEnabledChangedEvent { enabled: false });
    }

    // ================================================================
    // Pair Registration
    // ================================================================

    /// Bless a contract class ID as the accepted bytecode for SigalSwapPair,
    /// together with the version that class ID represents.
    ///
    /// First call is immediate (no pairs exist yet, nothing to protect) and
    /// initializes `pair_class_version` to the given version. Subsequent
    /// changes require the 48-hour timelock (queue via `queue_set_pair_class_id`
    /// then invoke this function again with the same args once the delay
    /// elapses) and must advance the version strictly upward.
    ///
    /// `version` MUST match the value reported by `pair.get_version()` for any
    /// pair compiled from the bytecode hashed by `class_id` -- `register_pair`
    /// cross-checks this at registration time and rejects mismatches.
    #[external("public")]
    fn set_pair_class_id(class_id: Field, version: u32) {
        assert(self.msg_sender() == self.storage.admin.read(), "ONLY_ADMIN");
        assert(class_id != 0, "ZERO_CLASS_ID");
        assert(version > 0, "INVALID_VERSION");
        // Leave headroom below u32::MAX so the monotonic "strictly greater"
        // check above can always be satisfied by at least one future
        // version. Practically unbounded -- there's no realistic deployment
        // pattern that approaches 4 billion versions.
        assert(version < 0xffffffff, "VERSION_SATURATED");

        // Monotonic enforcement, unconditional. On first call,
        // pair_class_version == 0 so `version > 0` is trivially satisfied
        // (already asserted above). Keeping this check outside the
        // first-call/subsequent branch guarantees pair_class_version is
        // append-only across any future code path -- if some future feature
        // ever resets pair_class_id to 0, this invariant survives and
        // prevents a compromised admin from downgrading the blessed version.
        assert(
            version > self.storage.pair_class_version.read(),
            "VERSION_NOT_INCREASING",
        );

        let current = self.storage.pair_class_id.read();
        let action_param = compute_class_id_version_param(class_id, version);
        if current == 0 {
            // First set: immediate (no existing pairs to protect).
            self.storage.pair_class_id.write(class_id);
            self.storage.pair_class_version.write(version);
        } else {
            // Subsequent change: require timelock. Monotonic version was
            // already asserted above.
            let action_hash =
                compute_action_hash(ACTION_SET_PAIR_CLASS_ID, action_param);
            let queued_at = self.storage.timelock.at(action_hash).read();
            assert(queued_at > 0, "NOT_QUEUED");
            let now = self.context.timestamp() as u64;
            assert(now >= queued_at + TIMELOCK_DELAY, "TIMELOCK_NOT_ELAPSED");
            assert(now <= queued_at + TIMELOCK_DELAY + TIMELOCK_WINDOW, "ACTION_EXPIRED");
            self.storage.timelock.at(action_hash).write(0);
            self.storage.pair_class_id.write(class_id);
            self.storage.pair_class_version.write(version);
        }

        // Emit events for BOTH branches. The immediate first-call and the
        // timelocked subsequent path produce the same state transition
        // (class_id + version advance), so observers get a uniform signal
        // regardless of which path was taken. ActionExecutedEvent carries
        // the action-type + param commitment; PairClassIdChangedEvent is the
        // typed, decodable form with the plaintext (class_id, version).
        self.emit(ActionExecutedEvent {
            action_type: ACTION_SET_PAIR_CLASS_ID,
            value: action_param,
        });
        self.emit(PairClassIdChangedEvent { class_id, version });
    }

    /// Queue a change to the pair class ID and its associated version.
    /// Only valid after the first (immediate) blessing; use `set_pair_class_id`
    /// directly for the initial deployment.
    ///
    /// The queued action hash commits to BOTH class_id and version, so queuing
    /// (class_id, v2) and (class_id, v3) simultaneously produces distinct
    /// timelock entries and they cannot collide.
    #[external("public")]
    fn queue_set_pair_class_id(new_class_id: Field, new_version: u32) {
        assert(self.msg_sender() == self.storage.admin.read(), "ONLY_ADMIN");
        assert(new_class_id != 0, "ZERO_CLASS_ID");
        assert(new_version > 0, "INVALID_VERSION");
        assert(new_version < 0xffffffff, "VERSION_SATURATED");
        assert(self.storage.pair_class_id.read() != 0, "CLASS_ID_NOT_SET_YET");
        // Fail fast on downgrade attempts at queue time so admin doesn't burn
        // a 48-hour delay on an action that will only be rejected at execute.
        // Mirrors the authoritative check in set_pair_class_id.
        assert(
            new_version > self.storage.pair_class_version.read(),
            "VERSION_NOT_INCREASING",
        );
        let action_param =
            compute_class_id_version_param(new_class_id, new_version);
        let action_hash =
            compute_action_hash(ACTION_SET_PAIR_CLASS_ID, action_param);
        let existing = self.storage.timelock.at(action_hash).read();
        assert(existing == 0, "ALREADY_QUEUED");
        let queued_at = self.context.timestamp() as u64;
        self.storage.timelock.at(action_hash).write(queued_at);
        // Emit `value = action_param` (a commitment to both class_id and
        // version); off-chain observers recompute via compute_class_id_version_param.
        self.emit(ActionQueuedEvent {
            action_type: ACTION_SET_PAIR_CLASS_ID,
            value: action_param,
            execute_after: queued_at + TIMELOCK_DELAY,
        });
    }

    /// Register an already-deployed pair contract.
    ///
    /// Permissionless -- anyone can deploy a SigalSwapPair and register it.
    /// The factory cryptographically verifies:
    /// 1. The contract at pair_address is genuine SigalSwapPair bytecode
    ///    (class ID matches the blessed `pair_class_id`).
    /// 2. The constructor was called with the declared token/fee parameters
    ///    and this factory's address (initialization hash matches).
    /// 3. The pair's self-reported bytecode version (from `get_version()`)
    ///    matches the admin-declared `pair_class_version`. This catches
    ///    class-id/version mismatches blessed by governance before they can
    ///    affect the registry.
    /// 4. The pair's version strictly advances the `latest_version` for its
    ///    (token0, token1, fee_tier) base -- so each base can only progress
    ///    forward in version, never revert or duplicate.
    ///
    /// Registration also exercises the pair's `set_pause` selector (via a
    /// no-op `set_pause(false)` on the freshly-deployed, unpaused pair) so a
    /// future blessed class that drifts `set_pause`'s ABI fails CLOSED here.
    /// `get_version` and `set_protocol_fee` are already exercised during
    /// registration; `set_pause` is otherwise only reached from
    /// `pause_pair`/`unpause_pair`, so without this probe a drifted-pause
    /// class could register and route yet be permanently un-pausable by this
    /// immutable factory. Any class blessed via `set_pair_class_id` MUST
    /// preserve the exact ABI of all three factory->pair entrypoints.
    ///
    /// On success the pair is recorded in three places:
    /// - `pairs[pair_key]` (pair_key includes version, historical)
    /// - `pair_by_index[pair_count]` (historical enumeration, all versions)
    /// - `latest_pair[base_key]` and `latest_version[base_key]` (current pointer)
    ///
    /// The first registration at a previously-empty base also pushes the new
    /// base onto `base_by_index` for the latest-only enumeration.
    /// `pair_salt` is caller-supplied. The factory enforces only that the
    /// supplied salt + the standard universal-deploy parameters reproduce
    /// the supplied `pair_address` (the canonical-address check below) --
    /// any deterministic salt is accepted. The SDK uses
    /// `CANONICAL_DEPLOY_SALT = 1` by convention; pairs deployed at
    /// non-canonical salts register successfully but are not discoverable
    /// by SDK consumers that derive addresses without first querying
    /// `get_pair(...)`. Routing through the factory registry is the
    /// canonical discovery path either way, so this caller flexibility is
    /// not a security or routing-integrity concern.
    #[external("public")]
    fn register_pair(
        pair_address: AztecAddress,
        token0: AztecAddress,
        token1: AztecAddress,
        fee_tier_bps: u32,
        pair_salt: Field,
    ) {
        assert(!self.storage.registration_paused.read(), "REGISTRATION_PAUSED");
        assert(pair_address != AztecAddress::zero(), "ZERO_ADDRESS");
        assert(token0 != AztecAddress::zero(), "ZERO_ADDRESS");
        assert(token1 != AztecAddress::zero(), "ZERO_ADDRESS");

        // --- Address-level one-shot registration ---
        // `registered` is sticky: once a pair address enters this map it stays
        // forever (`execute_clear_pair_slot` deliberately preserves it so admin
        // can `pause_pair` / `sync_protocol_fee` on retired pairs). Treating
        // the same flag as a one-shot guard at registration entry makes the
        // semantic permanent at the address level: a cleared pair contract
        // cannot be re-registered to undo the admin's retraction, and a
        // single deployed contract address cannot occupy multiple historical
        // slots in `pair_by_index`. Recovery from a misclear requires deploying
        // a fresh pair contract (bump `pair_class_version` -> different
        // canonical address), which is intentional.
        assert(
            !self.storage.registered.at(pair_address).read(),
            "PAIR_ADDRESS_ALREADY_REGISTERED",
        );

        // --- Reentrancy guard (acquire) ---
        // register_pair makes outbound calls (pair.get_version, LP-token
        // class-id oracle, pair.set_protocol_fee, pair.set_pause). Today's pair
        // bytecode is non-egressing from these, but a future blessed bytecode
        // could re-enter. This lock is defense in depth: any reentrant
        // register_pair call during those outbound calls hits this assertion
        // and reverts.
        //
        // The lock is explicitly released at the end of the happy path (the
        // `register_pair_locked.write(false)` near the bottom of this
        // function). If any assert between here and the release reverts, the
        // acquisition `write(true)` below is rolled back by Aztec's
        // tx-atomic storage semantics: the lock is observably `false` after
        // any reverted tx, so a subsequent legitimate `register_pair` call
        // proceeds normally. Keep these two writes (acquire + release) as a
        // matched pair; moving the release into a narrower scope that
        // doesn't cover every revert path would still be safe thanks to
        // rollback, but would muddy the intent.
        assert(
            !self.storage.register_pair_locked.read(),
            "REENTRANT_REGISTER_PAIR",
        );
        self.storage.register_pair_locked.write(true);

        // --- Verify the pair's address is the canonical derivation ---
        // Aztec addresses cryptographically commit to (class_id, init_hash,
        // salt, deployer, public_keys). Reconstructing the expected address
        // from the declared constructor args and asserting equality with
        // `pair_address` SUBSUMES separate class_id and init_hash oracle
        // calls: a matching address implies both the correct bytecode and
        // the correct constructor inputs. Forces pair deployments to use
        // universal deploy (deployer=zero) with default public keys, which
        // closes the non-canonical-pair attack surface.
        let expected_class_id = self.storage.pair_class_id.read();
        assert(expected_class_id != 0, "PAIR_CLASS_ID_NOT_SET");
        let pair_constructor_selector = FunctionSelector::from_signature(
            "constructor((Field),(Field),(Field),u32)",
        );
        let pair_init_args_hash = hash_args([
            token0.to_field(),
            token1.to_field(),
            self.address.to_field(),
            fee_tier_bps as Field,
        ]);
        let pair_init_hash =
            compute_initialization_hash(pair_constructor_selector, pair_init_args_hash);
        let pair_salted_init = SaltedInitializationHash::compute(
            pair_salt,
            pair_init_hash,
            AztecAddress::zero(),
        );
        let expected_pair_address = AztecAddress::compute_from_class_id(
            ContractClassId::from_field(expected_class_id),
            pair_salted_init,
            PublicKeys::default(),
        );
        assert(pair_address == expected_pair_address, "PAIR_NOT_CANONICAL");

        // --- Verify pair version matches the admin-declared version ---
        // Cross-contract call into the pair's bytecode-defined version getter.
        // The address-match above establishes that the bytecode is the
        // blessed one, so get_version() reports the value baked into that
        // bytecode; we verify it matches what the admin declared when
        // blessing this class ID. A mismatch here can only happen if
        // governance declared (class_id, v_a) but the source hard-codes
        // VERSION = v_b -- an operator error we want to fail fast.
        let expected_version = self.storage.pair_class_version.read();
        let actual_version =
            self.view(SigalSwapPair::at(pair_address).get_version());
        assert(actual_version == expected_version, "VERSION_MISMATCH");

        // --- Derive the pair's LP Token address and verify it's deployed ---
        // The pair's constructor computes this exact same derivation and
        // caches the result; we re-derive here to include the LP address in
        // `PairCreatedEvent` and to assert the LP Token is actually deployed
        // at the expected address (so the DOS case where a pair is
        // registered but its LP Token was never deployed fails at
        // registration time, not later at first mint).
        let lp_constructor_selector = FunctionSelector::from_signature(
            "constructor((Field))",
        );
        let lp_init_args_hash = hash_args([pair_address.to_field()]);
        let lp_init_hash =
            compute_initialization_hash(lp_constructor_selector, lp_init_args_hash);
        let lp_salted_init = SaltedInitializationHash::compute(
            LP_TOKEN_SALT,
            lp_init_hash,
            AztecAddress::zero(),
        );
        let lp_token = AztecAddress::compute_from_class_id(
            ContractClassId::from_field(LP_TOKEN_CLASS_ID),
            lp_salted_init,
            PublicKeys::default(),
        );
        // Verify the contract at the derived address is actually our LP Token
        // bytecode -- not just "something is deployed." Defense-in-depth
        // against Aztec's `ContractInstanceRegistry::update` primitive, which
        // lets a deployed contract reschedule its own
        // class_id via DelayedPublicMutable, swapping bytecode at the same
        // address. Today's LP Token source has no `update` call so the
        // precondition is unreachable; this check is the canary that catches
        // any future blessed LP Token bytecode that introduces `update`
        // functionality. See `lp-token/src/main.nr` header for the matching
        // constraint on LP Token maintainers.
        let lp_class_id = get_contract_instance_class_id_avm(lp_token);
        assert(lp_class_id.is_some(), "LP_TOKEN_NOT_DEPLOYED");
        assert(
            lp_class_id.unwrap().to_field() == LP_TOKEN_CLASS_ID,
            "LP_TOKEN_WRONG_CLASS",
        );

        // --- Standard registration checks ---
        assert(
            self.storage.allowed_fee_tiers.at(fee_tier_bps as Field).read(),
            "INVALID_FEE_TIER",
        );
        assert(token0 != token1, "IDENTICAL_TOKENS");
        assert(
            token0.to_field() as u128 < token1.to_field() as u128,
            "TOKENS_NOT_SORTED",
        );

        // --- Compute keys and enforce monotonic progression at this base ---
        let base_key = compute_base_key(token0, token1, fee_tier_bps);
        let current_latest = self.storage.latest_version.at(base_key).read();
        // Strict-greater forbids re-registering the same version at a base
        // (which also makes the versioned pair_key collision check below
        // redundant in well-formed governance state -- kept for defense in
        // depth).
        assert(expected_version > current_latest, "VERSION_NOT_ADVANCING");

        let pair_key =
            compute_pair_key(token0, token1, fee_tier_bps, expected_version);
        let existing = self.storage.pairs.at(pair_key).read();
        assert(existing == AztecAddress::zero(), "PAIR_EXISTS");

        // --- Register: historical + latest pointers ---
        self.storage.pairs.at(pair_key).write(pair_address);
        let count = self.storage.pair_count.read();
        // u32::MAX guard: economically unreachable (~4.3 billion successful
        // registrations, each gas-paid and rate-limited by `pause_registration`),
        // but mirrors the `VERSION_SATURATED` pattern at line 366 so saturation
        // never silently wraps the historical enumeration.
        assert(count < 0xffffffff, "PAIR_COUNT_SATURATED");
        self.storage.pair_by_index.at(count as Field).write(pair_address);
        self.storage.pair_count.write(count + 1);
        // Membership set, checked by `sync_protocol_fee`.
        self.storage.registered.at(pair_address).write(true);

        // Update the latest-per-base pointers. Always runs because we've
        // already asserted `expected_version > current_latest`, so this
        // registration IS the new latest for this base.
        self.storage.latest_version.at(base_key).write(expected_version);
        self.storage.latest_pair.at(base_key).write(pair_address);

        // First-ever registration at this base => push onto base_by_index.
        // Gated on the sticky `base_seen` flag (not `current_latest == 0`)
        // because a cleared base has latest_version == 0 but was already
        // indexed in a prior registration. Using `base_seen` ensures each
        // base_key appears at most once in base_by_index; later upgrades or
        // re-registrations after clear reuse the existing slot.
        if !self.storage.base_seen.at(base_key).read() {
            let base_idx = self.storage.base_count.read();
            // Same saturation guard as `pair_count`. `base_count` grows even
            // more slowly (only on first-ever registration at a distinct
            // (t0, t1, tier) tuple) so this is even further out of reach,
            // but kept for symmetry with the historical enumeration above.
            assert(base_idx < 0xffffffff, "BASE_COUNT_SATURATED");
            self.storage.base_by_index.at(base_idx as Field).write(base_key);
            self.storage.base_count.write(base_idx + 1);
            self.storage.base_seen.at(base_key).write(true);
        }

        self.emit(PairCreatedEvent {
            token0,
            token1,
            pair: pair_address,
            lp_token,
            fee_tier_bps,
            version: expected_version,
            pair_count: count + 1,
        });

        // Push protocol fee settings to the new pair. This is the outbound
        // call the reentrancy guard was acquired for.
        let fee_to = self.storage.fee_to.read();
        let percent = self.storage.protocol_fee_percent.read();
        let enabled = self.storage.protocol_fee_enabled.read();
        SigalSwapPair::at(pair_address)
            .set_protocol_fee(fee_to, percent, enabled)
            .call(self.context);

        // ABI probe: exercise the pair's set_pause selector so a future
        // blessed class that drifts set_pause's signature fails CLOSED at
        // registration. Unlike get_version and set_protocol_fee (both
        // exercised above), set_pause is otherwise only reached from
        // pause_pair/unpause_pair -- without this probe a drifted-pause class
        // would register, route, and then be permanently un-pausable by this
        // immutable factory. set_pause(false) is a clean no-op on a fresh
        // (unpaused) pair: the pair writes no state and emits no event on an
        // idempotent call, so this only validates that the selector resolves.
        SigalSwapPair::at(pair_address).set_pause(false).call(self.context);

        // --- Reentrancy guard (release) ---
        self.storage.register_pair_locked.write(false);
    }

    // ================================================================
    // Immediate Admin: Pause / Unpause
    // ================================================================

    // Halts new pair registrations. Existing pairs continue to trade;
    // freezing trading requires admin tooling that iterates `pause_pair`
    // across the registry.
    #[external("public")]
    fn pause_registration() {
        assert(self.msg_sender() == self.storage.admin.read(), "ONLY_ADMIN");
        self.storage.registration_paused.write(true);
        self.emit(RegistrationPausedEvent {});
    }

    #[external("public")]
    fn unpause_registration() {
        assert(self.msg_sender() == self.storage.admin.read(), "ONLY_ADMIN");
        self.storage.registration_paused.write(false);
        self.emit(RegistrationUnpausedEvent {});
    }

    #[external("public")]
    fn pause_pair(pair: AztecAddress) {
        assert(self.msg_sender() == self.storage.admin.read(), "ONLY_ADMIN");
        // Reject addresses that were never registered through this factory so
        // an admin typo (or an iteration over a stale list) can't pause a
        // knockoff pair that happens to bake our factory address into its
        // constructor. Symmetric with `sync_protocol_fee` and `unpause_pair`.
        assert(self.storage.registered.at(pair).read(), "PAIR_NOT_REGISTERED");
        SigalSwapPair::at(pair).set_pause(true).call(self.context);
        self.emit(PairPausedEvent { pair });
    }

    #[external("public")]
    fn unpause_pair(pair: AztecAddress) {
        assert(self.msg_sender() == self.storage.admin.read(), "ONLY_ADMIN");
        assert(self.storage.registered.at(pair).read(), "PAIR_NOT_REGISTERED");
        SigalSwapPair::at(pair).set_pause(false).call(self.context);
        self.emit(PairUnpausedEvent { pair });
    }

    // ================================================================
    // Timelocked Admin Actions
    // ================================================================

    // --- Queue functions ---

    /// Queue a `set_fee_to` change. Only valid once `fee_to` has been
    /// initialized. For the initial assignment from the post-deploy zero
    /// state, call `set_fee_to` directly -- the first-call path there is
    /// immediate (no prior commitment to protect with a timelock) and
    /// doesn't use the queue.
    #[external("public")]
    fn queue_set_fee_to(new_fee_to: AztecAddress) {
        assert(self.msg_sender() == self.storage.admin.read(), "ONLY_ADMIN");
        assert(new_fee_to != AztecAddress::zero(), "ZERO_ADDRESS");
        assert(
            !self.storage.fee_to.read().is_zero(),
            "USE_IMMEDIATE_SET_FOR_INITIAL",
        );
        let action_hash = compute_action_hash(ACTION_SET_FEE_TO, new_fee_to.to_field());
        let existing = self.storage.timelock.at(action_hash).read();
        assert(existing == 0, "ALREADY_QUEUED");
        let queued_at = self.context.timestamp() as u64;
        self.storage.timelock.at(action_hash).write(queued_at);
        self.emit(ActionQueuedEvent {
            action_type: ACTION_SET_FEE_TO,
            value: new_fee_to.to_field(),
            execute_after: queued_at + TIMELOCK_DELAY,
        });
    }

    #[external("public")]
    fn queue_set_protocol_fee_percent(new_percent: u32) {
        assert(self.msg_sender() == self.storage.admin.read(), "ONLY_ADMIN");
        assert(new_percent <= 100, "PERCENT_TOO_HIGH");
        // Fail-fast: setting percent=0 while fees are enabled produces the
        // invalid (enabled=true, percent=0) state that `set_protocol_fee`
        // on the pair rejects. Admin must disable fees first.
        if new_percent == 0 {
            assert(
                !self.storage.protocol_fee_enabled.read(),
                "ACTIVE_WITH_ZERO_PERCENT",
            );
        }
        let action_hash =
            compute_action_hash(ACTION_SET_PROTOCOL_FEE_PERCENT, new_percent as Field);
        let existing = self.storage.timelock.at(action_hash).read();
        assert(existing == 0, "ALREADY_QUEUED");
        let queued_at = self.context.timestamp() as u64;
        self.storage.timelock.at(action_hash).write(queued_at);
        self.emit(ActionQueuedEvent {
            action_type: ACTION_SET_PROTOCOL_FEE_PERCENT,
            value: new_percent as Field,
            execute_after: queued_at + TIMELOCK_DELAY,
        });
    }

    #[external("public")]
    fn queue_set_protocol_fee_enabled(enabled: bool) {
        assert(self.msg_sender() == self.storage.admin.read(), "ONLY_ADMIN");
        // Fail-fast: enabling while percent is 0 produces the invalid
        // (enabled=true, percent=0) state that `set_protocol_fee` on the
        // pair rejects. Admin must set a positive percent first.
        // Also require fee_to to be initialized -- enabling fees with
        // fee_to=zero would silently mint protocol-fee LP to the zero
        // address on every subsequent mint/burn.
        if enabled {
            assert(
                self.storage.protocol_fee_percent.read() > 0,
                "ACTIVE_WITH_ZERO_PERCENT",
            );
            assert(
                !self.storage.fee_to.read().is_zero(),
                "ACTIVE_WITH_ZERO_FEE_TO",
            );
        }
        let action_hash =
            compute_action_hash(ACTION_SET_PROTOCOL_FEE_ENABLED, enabled as Field);
        let existing = self.storage.timelock.at(action_hash).read();
        assert(existing == 0, "ALREADY_QUEUED");
        let queued_at = self.context.timestamp() as u64;
        self.storage.timelock.at(action_hash).write(queued_at);
        self.emit(ActionQueuedEvent {
            action_type: ACTION_SET_PROTOCOL_FEE_ENABLED,
            value: enabled as Field,
            execute_after: queued_at + TIMELOCK_DELAY,
        });
    }

    #[external("public")]
    fn queue_add_fee_tier(tier_bps: u32) {
        assert(self.msg_sender() == self.storage.admin.read(), "ONLY_ADMIN");
        assert((tier_bps > 0) & (tier_bps < 5000), "INVALID_FEE_TIER");
        // Fail-fast on already-allowed tiers. Without this guard, queue+execute
        // on a tier that's already in the whitelist completes after the full
        // 48-hour delay as a silent no-op (the execute branch is gated by
        // `was_allowed`) and emits a misleading FeeTierAddedEvent. Symmetric
        // with `queue_remove_fee_tier`'s `TIER_NOT_ALLOWED` guard. The execute
        // side keeps a defense-in-depth assert against state drift.
        assert(
            !self.storage.allowed_fee_tiers.at(tier_bps as Field).read(),
            "TIER_ALREADY_ALLOWED",
        );
        let action_hash = compute_action_hash(ACTION_ADD_FEE_TIER, tier_bps as Field);
        let existing = self.storage.timelock.at(action_hash).read();
        assert(existing == 0, "ALREADY_QUEUED");
        let queued_at = self.context.timestamp() as u64;
        self.storage.timelock.at(action_hash).write(queued_at);
        self.emit(ActionQueuedEvent {
            action_type: ACTION_ADD_FEE_TIER,
            value: tier_bps as Field,
            execute_after: queued_at + TIMELOCK_DELAY,
        });
    }

    #[external("public")]
    fn queue_remove_fee_tier(tier_bps: u32) {
        assert(self.msg_sender() == self.storage.admin.read(), "ONLY_ADMIN");
        // Bounds check is symmetric with `queue_add_fee_tier`. An
        // out-of-bounds tier was never addable, so removal would be a no-op
        // (write `false` to a slot that's already `false`). Failing fast at
        // queue time spares the admin a wasted 48-hour delay on a
        // semantically-meaningless action.
        assert((tier_bps > 0) & (tier_bps < 5000), "INVALID_FEE_TIER");
        // Fail-fast on never-added (or already-removed) tiers. Without this
        // guard, queue+execute on a disallowed tier completes after the full
        // 48-hour delay as a silent no-op (the execute branch is gated by
        // `was_allowed`) and emits a misleading FeeTierRemovedEvent. The
        // execute side keeps a defense-in-depth assert against state drift.
        assert(
            self.storage.allowed_fee_tiers.at(tier_bps as Field).read(),
            "TIER_NOT_ALLOWED",
        );
        // Fail-fast min-1-tier guard. Authoritative check is on execute
        // (count is mutated there), but the queue-side check catches the
        // common single-removal case immediately. Multi-queue races still
        // get caught by the execute guard, just at execute time after the
        // 48h delay -- which matches `queue_clear_pair_slot`'s pattern.
        assert(self.storage.allowed_fee_tier_count.read() >= 2, "LAST_FEE_TIER");
        let action_hash = compute_action_hash(ACTION_REMOVE_FEE_TIER, tier_bps as Field);
        let existing = self.storage.timelock.at(action_hash).read();
        assert(existing == 0, "ALREADY_QUEUED");
        let queued_at = self.context.timestamp() as u64;
        self.storage.timelock.at(action_hash).write(queued_at);
        self.emit(ActionQueuedEvent {
            action_type: ACTION_REMOVE_FEE_TIER,
            value: tier_bps as Field,
            execute_after: queued_at + TIMELOCK_DELAY,
        });
    }

    #[external("public")]
    fn queue_set_admin(new_admin: AztecAddress) {
        assert(self.msg_sender() == self.storage.admin.read(), "ONLY_ADMIN");
        assert(new_admin != AztecAddress::zero(), "ZERO_ADDRESS");
        let action_hash = compute_action_hash(ACTION_SET_ADMIN, new_admin.to_field());
        let existing = self.storage.timelock.at(action_hash).read();
        assert(existing == 0, "ALREADY_QUEUED");
        let queued_at = self.context.timestamp() as u64;
        self.storage.timelock.at(action_hash).write(queued_at);
        self.emit(ActionQueuedEvent {
            action_type: ACTION_SET_ADMIN,
            value: new_admin.to_field(),
            execute_after: queued_at + TIMELOCK_DELAY,
        });
    }

    // --- Execute functions ---

    /// Set `fee_to`. First call from the post-deploy zero state is
    /// immediate (no prior commitment, no pairs producing fee LP yet --
    /// enabling fees is independently gated on `fee_to != zero`).
    /// Subsequent changes require the standard queue + timelock elapse
    /// via `queue_set_fee_to`. Same first-call-immediate pattern as
    /// `set_pair_class_id`.
    #[external("public")]
    fn set_fee_to(new_fee_to: AztecAddress) {
        assert(self.msg_sender() == self.storage.admin.read(), "ONLY_ADMIN");
        assert(new_fee_to != AztecAddress::zero(), "ZERO_ADDRESS");

        let current = self.storage.fee_to.read();
        if current.is_zero() {
            // First set: immediate.
            self.storage.fee_to.write(new_fee_to);
        } else {
            // Subsequent change: require queued + elapsed action.
            let action_hash = compute_action_hash(ACTION_SET_FEE_TO, new_fee_to.to_field());
            let queued_at = self.storage.timelock.at(action_hash).read();
            assert(queued_at > 0, "NOT_QUEUED");
            let now = self.context.timestamp() as u64;
            assert(now >= queued_at + TIMELOCK_DELAY, "TIMELOCK_NOT_ELAPSED");
            assert(now <= queued_at + TIMELOCK_DELAY + TIMELOCK_WINDOW, "ACTION_EXPIRED");
            self.storage.timelock.at(action_hash).write(0);
            self.storage.fee_to.write(new_fee_to);
        }

        // Emit events uniformly for both branches so observers get the
        // same signal regardless of path.
        self.emit(ActionExecutedEvent {
            action_type: ACTION_SET_FEE_TO,
            value: new_fee_to.to_field(),
        });
        self.emit(FeeToChangedEvent { new_fee_to });
    }

    #[external("public")]
    fn execute_set_protocol_fee_percent(new_percent: u32) {
        assert(self.msg_sender() == self.storage.admin.read(), "ONLY_ADMIN");
        let action_hash =
            compute_action_hash(ACTION_SET_PROTOCOL_FEE_PERCENT, new_percent as Field);
        let queued_at = self.storage.timelock.at(action_hash).read();
        assert(queued_at > 0, "NOT_QUEUED");
        let now = self.context.timestamp() as u64;
        assert(now >= queued_at + TIMELOCK_DELAY, "TIMELOCK_NOT_ELAPSED");
        assert(now <= queued_at + TIMELOCK_DELAY + TIMELOCK_WINDOW, "ACTION_EXPIRED");
        self.storage.timelock.at(action_hash).write(0);
        assert(new_percent <= 100, "PERCENT_TOO_HIGH");
        // Mirror the pair's invariant: (enabled=true, percent=0) is a
        // nonsensical state the pair rejects in `set_protocol_fee`. Prevent
        // the factory from ever storing it -- admin must disable fees first
        // (set enabled=false), then drop percent to 0.
        if new_percent == 0 {
            assert(
                !self.storage.protocol_fee_enabled.read(),
                "ACTIVE_WITH_ZERO_PERCENT",
            );
        }
        self.storage.protocol_fee_percent.write(new_percent);
        self.emit(ActionExecutedEvent {
            action_type: ACTION_SET_PROTOCOL_FEE_PERCENT,
            value: new_percent as Field,
        });
        self.emit(ProtocolFeePercentChangedEvent { new_percent });
    }

    #[external("public")]
    fn execute_set_protocol_fee_enabled(enabled: bool) {
        assert(self.msg_sender() == self.storage.admin.read(), "ONLY_ADMIN");
        let action_hash =
            compute_action_hash(ACTION_SET_PROTOCOL_FEE_ENABLED, enabled as Field);
        let queued_at = self.storage.timelock.at(action_hash).read();
        assert(queued_at > 0, "NOT_QUEUED");
        let now = self.context.timestamp() as u64;
        assert(now >= queued_at + TIMELOCK_DELAY, "TIMELOCK_NOT_ELAPSED");
        assert(now <= queued_at + TIMELOCK_DELAY + TIMELOCK_WINDOW, "ACTION_EXPIRED");
        self.storage.timelock.at(action_hash).write(0);
        // Mirror the pair's invariants: admin cannot enable fees while
        // percent is 0 (meaningless rate) or fee_to is zero (fees would
        // be minted to an unrecoverable address). Both must be set
        // before enabled transitions to true.
        if enabled {
            assert(
                self.storage.protocol_fee_percent.read() > 0,
                "ACTIVE_WITH_ZERO_PERCENT",
            );
            assert(
                !self.storage.fee_to.read().is_zero(),
                "ACTIVE_WITH_ZERO_FEE_TO",
            );
        }
        self.storage.protocol_fee_enabled.write(enabled);
        self.emit(ActionExecutedEvent {
            action_type: ACTION_SET_PROTOCOL_FEE_ENABLED,
            value: enabled as Field,
        });
        self.emit(ProtocolFeeEnabledChangedEvent { enabled });
    }

    #[external("public")]
    fn execute_add_fee_tier(tier_bps: u32) {
        assert(self.msg_sender() == self.storage.admin.read(), "ONLY_ADMIN");
        assert((tier_bps > 0) & (tier_bps < 5000), "INVALID_FEE_TIER");
        let action_hash = compute_action_hash(ACTION_ADD_FEE_TIER, tier_bps as Field);
        let queued_at = self.storage.timelock.at(action_hash).read();
        assert(queued_at > 0, "NOT_QUEUED");
        let now = self.context.timestamp() as u64;
        assert(now >= queued_at + TIMELOCK_DELAY, "TIMELOCK_NOT_ELAPSED");
        assert(now <= queued_at + TIMELOCK_DELAY + TIMELOCK_WINDOW, "ACTION_EXPIRED");
        self.storage.timelock.at(action_hash).write(0);
        // Defense-in-depth: queue side already asserts `TIER_ALREADY_ALLOWED`,
        // so by the time we reach execute the tier is guaranteed to be absent
        // from the whitelist (no parallel queued add can race because the
        // queue-side `ALREADY_QUEUED` and `TIER_ALREADY_ALLOWED` together
        // serialize state transitions). Mirror of `execute_remove_fee_tier`'s
        // `TIER_NOT_ALLOWED` defense-in-depth.
        assert(
            !self.storage.allowed_fee_tiers.at(tier_bps as Field).read(),
            "TIER_ALREADY_ALLOWED",
        );
        self.storage.allowed_fee_tiers.at(tier_bps as Field).write(true);
        let count = self.storage.allowed_fee_tier_count.read();
        self.storage.allowed_fee_tier_count.write(count + 1);
        self.emit(ActionExecutedEvent {
            action_type: ACTION_ADD_FEE_TIER,
            value: tier_bps as Field,
        });
        self.emit(FeeTierAddedEvent { tier_bps });
    }

    #[external("public")]
    fn execute_remove_fee_tier(tier_bps: u32) {
        assert(self.msg_sender() == self.storage.admin.read(), "ONLY_ADMIN");
        // Symmetric with `execute_add_fee_tier`. Defense in depth in case a
        // future queue-side refactor drops the matching check.
        assert((tier_bps > 0) & (tier_bps < 5000), "INVALID_FEE_TIER");
        let action_hash = compute_action_hash(ACTION_REMOVE_FEE_TIER, tier_bps as Field);
        let queued_at = self.storage.timelock.at(action_hash).read();
        assert(queued_at > 0, "NOT_QUEUED");
        let now = self.context.timestamp() as u64;
        assert(now >= queued_at + TIMELOCK_DELAY, "TIMELOCK_NOT_ELAPSED");
        assert(now <= queued_at + TIMELOCK_DELAY + TIMELOCK_WINDOW, "ACTION_EXPIRED");
        self.storage.timelock.at(action_hash).write(0);
        // Authoritative on-tier guard. The queue side fails fast on a
        // never-added (or already-removed) tier; this defense-in-depth assert
        // catches future-refactor regressions and any state-drift race where
        // a parallel remove flipped the tier between queue and execute. With
        // both sides asserting, the no-op-execute path is unreachable and
        // FeeTierRemovedEvent is only ever emitted on a real state transition.
        let was_allowed = self.storage.allowed_fee_tiers.at(tier_bps as Field).read();
        assert(was_allowed, "TIER_NOT_ALLOWED");
        // Authoritative min-1-tier guard: count >= 2 BEFORE this removal so
        // at least one tier remains afterward. Admin who genuinely wants to
        // block all new registrations should use `pause_registration` (no
        // timelock, no recovery window) -- removing the last tier instead
        // would brick `register_pair` with a misleading `INVALID_FEE_TIER`
        // for a full timelock cycle.
        let count = self.storage.allowed_fee_tier_count.read();
        assert(count >= 2, "LAST_FEE_TIER");
        self.storage.allowed_fee_tier_count.write(count - 1);
        self.storage.allowed_fee_tiers.at(tier_bps as Field).write(false);
        self.emit(ActionExecutedEvent {
            action_type: ACTION_REMOVE_FEE_TIER,
            value: tier_bps as Field,
        });
        self.emit(FeeTierRemovedEvent { tier_bps });
    }

    #[external("public")]
    fn execute_set_admin(new_admin: AztecAddress) {
        assert(self.msg_sender() == self.storage.admin.read(), "ONLY_ADMIN");
        assert(new_admin != AztecAddress::zero(), "ZERO_ADDRESS");
        let action_hash = compute_action_hash(ACTION_SET_ADMIN, new_admin.to_field());
        let queued_at = self.storage.timelock.at(action_hash).read();
        assert(queued_at > 0, "NOT_QUEUED");
        let now = self.context.timestamp() as u64;
        assert(now >= queued_at + TIMELOCK_DELAY, "TIMELOCK_NOT_ELAPSED");
        assert(now <= queued_at + TIMELOCK_DELAY + TIMELOCK_WINDOW, "ACTION_EXPIRED");
        self.storage.timelock.at(action_hash).write(0);
        self.storage.admin.write(new_admin);
        self.emit(ActionExecutedEvent {
            action_type: ACTION_SET_ADMIN,
            value: new_admin.to_field(),
        });
        self.emit(AdminChangedEvent { new_admin });
    }

    // --- Cancel ---

    /// Cancel a previously-queued timelock action before it executes.
    ///
    /// Admin passes the action's `(type, value)` pair -- the same inputs used
    /// at queue time. The factory recomputes `action_hash` internally; this
    /// keeps the emitted `ActionCancelledEvent` self-describing so fresh
    /// indexers (or bounded-window observers) can decode the cancel without
    /// needing to cross-reference the earlier `ActionQueuedEvent`.
    ///
    /// `action_type` is one of the `ACTION_*` constants documented under
    /// "Action type IDs". `value` is the same `param` field that
    /// `ActionQueuedEvent` emitted -- an address-field, a packed Field, or
    /// a small integer promoted to Field, depending on the action type.
    #[external("public")]
    fn cancel_action(action_type: Field, value: Field) {
        assert(self.msg_sender() == self.storage.admin.read(), "ONLY_ADMIN");
        let action_hash = compute_action_hash(action_type, value);
        let queued_at = self.storage.timelock.at(action_hash).read();
        // LOAD-BEARING: blocks bogus ActionCancelledEvent emissions for
        // never-queued actions. Must precede the emit. A future refactor
        // that drops or relaxes this assert (or moves the emit before it)
        // re-opens an admin-grief / indexer-confusion surface where admin
        // can spam fake cancel events for arbitrary (action_type, value)
        // tuples that were never queued.
        assert(queued_at > 0, "NOT_QUEUED");
        self.storage.timelock.at(action_hash).write(0);
        self.emit(ActionCancelledEvent { action_type, value });
    }

    // ================================================================
    // Timelocked Admin: Clear Pair Slot
    // ================================================================
    //
    // Safety valve for the rare case where a pair's LATEST registration at a
    // base was misconfigured (e.g., LP token mint permissions wired wrong,
    // wrong token addresses discovered post-deploy) and must be retracted
    // from the registry so a corrected v_N pair can be deployed in its place
    // without having to bump to v_{N+1}.
    //
    // This is explicitly NOT a general "unregister" mechanism. Clearing is
    // restricted to the current latest-at-base and requires the admin to
    // declare the version that becomes the new latest (or 0 to clear the
    // base entirely). 48-hour timelock applies.
    //
    // The clear does NOT mutate the pair contract itself (which is immutable);
    // it only removes the entries from the factory's registry so SDK routing
    // stops pointing users at a broken pair. The pair contract continues to
    // exist at its address and remains usable by anyone who has it saved --
    // but withdrawals always work on any pair, so no LP funds can be trapped
    // by this action.

    /// Queue a clear-pair-slot action. Admin commits now to the full intent
    /// (which pair at which base + what version replaces it) so nothing can
    /// be altered between queue and execute.
    #[external("public")]
    fn queue_clear_pair_slot(
        pair_address: AztecAddress,
        token0: AztecAddress,
        token1: AztecAddress,
        fee_tier_bps: u32,
        new_latest_version: u32,
    ) {
        assert(self.msg_sender() == self.storage.admin.read(), "ONLY_ADMIN");
        assert(pair_address != AztecAddress::zero(), "ZERO_ADDRESS");
        assert(token0 != AztecAddress::zero(), "ZERO_ADDRESS");
        assert(token1 != AztecAddress::zero(), "ZERO_ADDRESS");

        // Fail fast on semantically-invalid intents at queue time so admin
        // doesn't burn a 48-hour delay on an action that will be rejected at
        // execute. The authoritative checks still run in execute (state can
        // drift between queue and execute if another clear lands in between).
        //
        // Split into distinct assertions so admin tooling gets a distinct
        // error for each failure mode: "base has no pair to clear", "you're
        // trying to stay at or above the current latest", and "the rollback
        // target was never registered." All three are also caught at execute
        // time as defense-in-depth.
        let base_key = compute_base_key(token0, token1, fee_tier_bps);
        let queue_time_latest = self.storage.latest_version.at(base_key).read();
        assert(queue_time_latest > 0, "NO_PAIR_AT_BASE");
        // Verify the caller-supplied `pair_address` actually IS the current
        // latest at this base. Symmetric with execute-side `NOT_LATEST` at
        // line ~1086 -- we mirror it at queue time so a typo on
        // `pair_address` doesn't burn a 48-hour delay before surfacing.
        // The execute-side check still fires authoritatively in case state
        // drifts between queue and execute (e.g. another clear lands).
        assert(
            self.storage.latest_pair.at(base_key).read() == pair_address,
            "NOT_LATEST",
        );
        assert(new_latest_version < queue_time_latest, "NEW_LATEST_NOT_LOWER");
        // If rolling back (not fully clearing), the rollback target must
        // already be registered. `new_latest_version == 0` is the
        // full-clear case and bypasses this check.
        if new_latest_version > 0 {
            let new_pair_key =
                compute_pair_key(token0, token1, fee_tier_bps, new_latest_version);
            assert(
                self.storage.pairs.at(new_pair_key).read() != AztecAddress::zero(),
                "NEW_LATEST_NOT_REGISTERED",
            );
        }

        let param = compute_clear_slot_param(
            pair_address,
            token0,
            token1,
            fee_tier_bps,
            new_latest_version,
        );
        let action_hash = compute_action_hash(ACTION_CLEAR_PAIR_SLOT, param);
        let existing = self.storage.timelock.at(action_hash).read();
        assert(existing == 0, "ALREADY_QUEUED");
        let queued_at = self.context.timestamp() as u64;
        self.storage.timelock.at(action_hash).write(queued_at);
        self.emit(ActionQueuedEvent {
            action_type: ACTION_CLEAR_PAIR_SLOT,
            value: param,
            execute_after: queued_at + TIMELOCK_DELAY,
        });
    }

    /// Execute a previously-queued clear_pair_slot after the 48-hour delay.
    /// All args must match the queued action exactly (they're committed into
    /// the action_hash). The factory verifies:
    ///   - `pair_address` is the current latest_pair for the base.
    ///   - `new_latest_version < current_latest` (monotonic downgrade ok only
    ///     because we're retracting a registration, not re-registering it).
    ///   - If `new_latest_version > 0`, a pair at that version must already
    ///     be registered at the same base (has a non-zero pairs[pair_key]
    ///     entry); if 0, the base is fully cleared.
    ///
    /// Note on `pair_count` / `pair_by_index`: the historical enumeration
    /// is NOT rewritten. The cleared pair retains its historical index (it
    /// really did exist, for auditability); only the latest-at-base pointer
    /// and the versioned pair_key slot are affected. This also means
    /// `base_count` / `base_by_index` are NOT decremented -- even if the
    /// base is fully cleared, it stays indexed. `get_latest_pair_at_index`
    /// will return `AztecAddress::zero()` for that index until a new pair
    /// is registered there.
    #[external("public")]
    fn execute_clear_pair_slot(
        pair_address: AztecAddress,
        token0: AztecAddress,
        token1: AztecAddress,
        fee_tier_bps: u32,
        new_latest_version: u32,
    ) {
        assert(self.msg_sender() == self.storage.admin.read(), "ONLY_ADMIN");

        let param = compute_clear_slot_param(
            pair_address,
            token0,
            token1,
            fee_tier_bps,
            new_latest_version,
        );
        let action_hash = compute_action_hash(ACTION_CLEAR_PAIR_SLOT, param);
        let queued_at = self.storage.timelock.at(action_hash).read();
        assert(queued_at > 0, "NOT_QUEUED");
        let now = self.context.timestamp() as u64;
        assert(now >= queued_at + TIMELOCK_DELAY, "TIMELOCK_NOT_ELAPSED");
        assert(now <= queued_at + TIMELOCK_DELAY + TIMELOCK_WINDOW, "ACTION_EXPIRED");
        self.storage.timelock.at(action_hash).write(0);

        let base_key = compute_base_key(token0, token1, fee_tier_bps);
        let current_latest_version = self.storage.latest_version.at(base_key).read();
        let current_latest_pair = self.storage.latest_pair.at(base_key).read();

        // The pair being cleared must be the current latest at this base.
        // Clearing an older version is neither useful (it's not the routing
        // target) nor well-defined (latest_pair would still point to v_N,
        // but the historical v_{N-1} slot would be zeroed -- confusing).
        assert(current_latest_pair == pair_address, "NOT_LATEST");
        // Defensive: if the storage is consistent these are equivalent, but
        // checking both catches any storage drift.
        assert(current_latest_version > 0, "NO_PAIR_AT_BASE");

        // new_latest_version must be strictly less than current (we're rolling
        // back, not staying or advancing).
        assert(
            new_latest_version < current_latest_version,
            "NEW_LATEST_NOT_LOWER",
        );

        // Intentionally NOT clearing `self.storage.registered.at(pair_address)`.
        // `registered` records ever-was-a-canonical-pair, not currently-routable;
        // clearing only removes routing entries (`pairs`, `latest_*`). Keeping
        // the registered flag serves two purposes: (1) admin can still call
        // `pause_pair`, `unpause_pair`, and `sync_protocol_fee` on a cleared
        // pair so it remains emergency-controllable while no longer routing,
        // and (2) `register_pair` rejects any attempt to re-register the same
        // pair address (one-shot guard at entry), so the clear cannot be
        // permissionlessly undone.

        // Clear the versioned pair_key slot.
        let cleared_pair_key =
            compute_pair_key(token0, token1, fee_tier_bps, current_latest_version);
        self.storage.pairs.at(cleared_pair_key).write(AztecAddress::zero());

        let new_latest_pair = if new_latest_version == 0 {
            // Base is fully cleared -- no version remains as latest.
            self.storage.latest_version.at(base_key).write(0);
            self.storage.latest_pair.at(base_key).write(AztecAddress::zero());
            AztecAddress::zero()
        } else {
            // Revert to the admin-declared prior version. Verify that the
            // prior version is actually registered (the admin could have made
            // a mistake naming a version that was never deployed or was
            // itself previously cleared).
            let new_pair_key =
                compute_pair_key(token0, token1, fee_tier_bps, new_latest_version);
            let new_pair_addr = self.storage.pairs.at(new_pair_key).read();
            assert(
                !new_pair_addr.is_zero(),
                "NEW_LATEST_NOT_REGISTERED",
            );
            self.storage.latest_version.at(base_key).write(new_latest_version);
            self.storage.latest_pair.at(base_key).write(new_pair_addr);
            new_pair_addr
        };

        self.emit(PairSlotClearedEvent {
            pair: pair_address,
            token0,
            token1,
            fee_tier_bps,
            cleared_version: current_latest_version,
            new_latest_version,
            new_latest_pair,
        });
        self.emit(ActionExecutedEvent {
            action_type: ACTION_CLEAR_PAIR_SLOT,
            value: param,
        });
    }

    // ================================================================
    // Admin: Push Protocol Fee to Pair
    // ================================================================

    /// Push current protocol fee settings to a specific pair.
    /// Admin-only -- the admin pushes updated settings after governance changes.
    /// The SDK automates batching this across all registered pairs.
    #[external("public")]
    fn sync_protocol_fee(pair: AztecAddress) {
        assert(self.msg_sender() == self.storage.admin.read(), "ONLY_ADMIN");
        // Reject addresses that were never registered through this factory
        // so an admin typo can't touch a stray pair's fee config.
        assert(self.storage.registered.at(pair).read(), "PAIR_NOT_REGISTERED");
        let fee_to = self.storage.fee_to.read();
        let percent = self.storage.protocol_fee_percent.read();
        let enabled = self.storage.protocol_fee_enabled.read();
        SigalSwapPair::at(pair).set_protocol_fee(fee_to, percent, enabled).call(self.context);
        self.emit(ProtocolFeeSyncedEvent { pair });
    }

    // ================================================================
    // View / Utility Functions
    // ================================================================

    /// Return the latest pair address registered at the (token0, token1, tier)
    /// base, or `AztecAddress::zero()` if none exists (never registered or
    /// fully cleared via `execute_clear_pair_slot`).
    ///
    /// This is the default SDK routing target. Callers that need to route
    /// around a paused latest can check pair state client-side via the pair's
    /// `is_paused_view()` utility and fall back to `get_pair_versioned` with
    /// an explicit earlier version as policy allows.
    #[external("utility")]
    unconstrained fn get_pair(
        token0: AztecAddress,
        token1: AztecAddress,
        fee_tier_bps: u32,
    ) -> pub AztecAddress {
        let base_key = compute_base_key(token0, token1, fee_tier_bps);
        self.storage.latest_pair.at(base_key).read()
    }

    /// Return the pair registered at a specific (token0, token1, tier, version)
    /// slot, or `AztecAddress::zero()` if that exact version was never
    /// registered (e.g., an old version was cleared, or a version between
    /// blessings was skipped because no one deployed a pair at it for this
    /// base). Useful for historical lookups and explicit-version fallback.
    #[external("utility")]
    unconstrained fn get_pair_versioned(
        token0: AztecAddress,
        token1: AztecAddress,
        fee_tier_bps: u32,
        version: u32,
    ) -> pub AztecAddress {
        let pair_key = compute_pair_key(token0, token1, fee_tier_bps, version);
        self.storage.pairs.at(pair_key).read()
    }

    /// Public view variant of `get_pair_versioned`, callable from another
    /// contract's public context. The router uses this to verify that a
    /// caller-supplied `pair` argument is the address the factory currently
    /// has registered at the (token0, token1, fee_tier_bps, version) slot
    /// the pair self-reports via `get_config()`. Without this check, a
    /// fully-fabricated pair contract whose `get_config()` returns
    /// internally-consistent lies would pass the router's pair-side
    /// assertions; the factory's registry is the only source of truth that
    /// can refute such a pair.
    ///
    /// Returns `AztecAddress::zero()` for unregistered slots and for slots
    /// that were once registered but have since been cleared via
    /// `execute_clear_pair_slot`. The router asserts equality against the
    /// caller-supplied pair, so a zero return value cannot pass since
    /// callers cannot supply the zero address as a usable pair.
    #[external("public")]
    #[view]
    fn get_pair_versioned_public(
        token0: AztecAddress,
        token1: AztecAddress,
        fee_tier_bps: u32,
        version: u32,
    ) -> AztecAddress {
        let pair_key = compute_pair_key(token0, token1, fee_tier_bps, version);
        self.storage.pairs.at(pair_key).read()
    }

    /// Return the latest version registered at a (token0, token1, tier) base,
    /// or 0 if no pair has ever been registered there (or the base has been
    /// fully cleared). Useful for iterating through historical versions via
    /// `get_pair_versioned`.
    #[external("utility")]
    unconstrained fn get_latest_version(
        token0: AztecAddress,
        token1: AztecAddress,
        fee_tier_bps: u32,
    ) -> pub u32 {
        let base_key = compute_base_key(token0, token1, fee_tier_bps);
        self.storage.latest_version.at(base_key).read()
    }

    /// Total number of pair registrations the factory has ever accepted,
    /// across all versions of all bases. Paired with `get_pair_at` for full
    /// historical enumeration.
    #[external("utility")]
    unconstrained fn get_pair_count() -> pub u32 {
        self.storage.pair_count.read()
    }

    /// Historical enumeration: the i-th pair ever registered (0-indexed),
    /// regardless of version or current latest-at-base status. This never
    /// compacts -- an index always points to the same historical pair, even
    /// if that pair was later superseded or its slot was cleared.
    #[external("utility")]
    unconstrained fn get_pair_at(index: u32) -> pub AztecAddress {
        assert((index as u32) < self.storage.pair_count.read(), "INDEX_OUT_OF_BOUNDS");
        self.storage.pair_by_index.at(index as Field).read()
    }

    /// Number of unique (token0, token1, fee_tier) bases ever registered, also
    /// the upper bound for `get_latest_pair_at_index` iteration. Backs the
    /// `base_by_index` storage array. Monotonically increasing -- does NOT
    /// decrement when a base is cleared via `execute_clear_pair_slot`; the
    /// entry in `base_by_index` remains and `latest_pair[base_key]` returns
    /// zero for that slot until a new pair is registered. Use this to iterate
    /// every base slot ever used (live or cleared); use `get_active_pair_count`
    /// for the count of currently-routable bases.
    #[external("utility")]
    unconstrained fn get_indexed_base_count() -> pub u32 {
        self.storage.base_count.read()
    }

    /// Number of bases currently routable -- bases whose `latest_pair` is
    /// non-zero. Differs from `get_indexed_base_count` when one or more bases
    /// have been fully cleared via `execute_clear_pair_slot`. Computed by
    /// iterating indexed bases and counting non-zero `latest_pair` entries
    /// in this single utility call (saves the SDK an N-round-trip walk).
    #[external("utility")]
    unconstrained fn get_active_pair_count() -> pub u32 {
        let total = self.storage.base_count.read();
        let mut active: u32 = 0;
        for i in 0..total {
            let base_key = self.storage.base_by_index.at(i as Field).read();
            if self.storage.latest_pair.at(base_key).read() != AztecAddress::zero() {
                active += 1;
            }
        }
        active
    }

    /// Return the latest pair address for the i-th unique base registered
    /// (0-indexed). Returns `AztecAddress::zero()` if the base at that index
    /// has been fully cleared. Use this to enumerate the current set of pools
    /// without scanning historical versions; the SDK can iterate 0..get_indexed_base_count()
    /// and filter zeros to produce a "current pools" list.
    #[external("utility")]
    unconstrained fn get_latest_pair_at_index(index: u32) -> pub AztecAddress {
        assert(
            (index as u32) < self.storage.base_count.read(),
            "INDEX_OUT_OF_BOUNDS",
        );
        let base_key = self.storage.base_by_index.at(index as Field).read();
        self.storage.latest_pair.at(base_key).read()
    }

    /// Return the currently-blessed pair bytecode version. Useful for SDK
    /// pre-registration sanity checks: a pair compiled from source whose
    /// VERSION constant does not match this value cannot be registered.
    #[external("utility")]
    unconstrained fn get_pair_class_version() -> pub u32 {
        self.storage.pair_class_version.read()
    }

    #[external("utility")]
    unconstrained fn is_fee_tier_allowed(tier_bps: u32) -> pub bool {
        self.storage.allowed_fee_tiers.at(tier_bps as Field).read()
    }

    #[external("utility")]
    unconstrained fn get_admin() -> pub AztecAddress {
        self.storage.admin.read()
    }

    #[external("utility")]
    unconstrained fn get_fee_to() -> pub AztecAddress {
        self.storage.fee_to.read()
    }

    /// Read the complete protocol fee configuration -- `(fee_to, percent, enabled)`.
    /// All three fields are conceptually one config (who gets fees, how much,
    /// whether it's active) and most callers want them together. Returning
    /// them in a single utility call avoids the round-trip cost of pairing
    /// `get_fee_to()` with the previous `(percent, enabled)` shape.
    #[external("utility")]
    unconstrained fn get_protocol_fee_config() -> pub (AztecAddress, u32, bool) {
        (
            self.storage.fee_to.read(),
            self.storage.protocol_fee_percent.read(),
            self.storage.protocol_fee_enabled.read(),
        )
    }

    #[external("utility")]
    unconstrained fn is_registration_paused() -> pub bool {
        self.storage.registration_paused.read()
    }

    /// Returns the `queued_at` timestamp for a timelocked action, or 0 if not
    /// queued (never queued, already executed, or cancelled). Both queue and
    /// execute paths reset this slot to 0 on transition, so only the in-flight
    /// queued window holds a nonzero value.
    ///
    /// `action_hash` is `poseidon2([action_type, value])` -- see the SDK's
    /// `computeActionHash` helper, or the inline `compute_action_hash` helper
    /// in this contract's source. Action type IDs are the `ACTION_*` globals
    /// at the top of this file.
    ///
    /// Status interpretation (caller-side, with `now = block.timestamp`):
    /// - `queued_at == 0`             : not queued.
    /// - `now <  queued_at + DELAY`   : queued, waiting out the delay.
    /// - `now <= queued_at + DELAY+W` : executable.
    /// - `now >  queued_at + DELAY+W` : expired (call cancel_action, then re-queue).
    ///
    /// Without this view, indexers would have to compute the storage slot for
    /// `timelock: Map<Field, ...>` against Aztec's slot-derivation scheme and
    /// issue raw state reads, which couples the SDK to Aztec storage internals.
    #[external("utility")]
    unconstrained fn get_timelock(action_hash: Field) -> pub u64 {
        self.storage.timelock.at(action_hash).read()
    }

    /// Returns `(delay_seconds, window_seconds)` for the protocol's timelock.
    /// Both are compile-time globals (`TIMELOCK_DELAY`, `TIMELOCK_WINDOW`);
    /// this view is the on-chain source of truth so off-chain callers don't
    /// hardcode the values.
    #[external("utility")]
    unconstrained fn get_timelock_params() -> pub (u64, u64) {
        (TIMELOCK_DELAY, TIMELOCK_WINDOW)
    }

}
