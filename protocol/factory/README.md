# SigalSwapFactory

The governance and registry contract for SigalSwap. Manages pair registration, fee tier whitelisting, protocol fee configuration, and emergency controls. All admin actions beyond pause/unpause require a 48-hour timelock.

## Storage

| Field | Type | Description |
|-------|------|-------------|
| `admin` | `PublicMutable<AztecAddress>` | Single admin address (V1 governance) |
| `fee_to` | `PublicMutable<AztecAddress>` | Protocol fee recipient |
| `protocol_fee_percent` | `PublicMutable<u32>` | Global protocol fee markup (0-100, as % of LP fee) |
| `protocol_fee_enabled` | `PublicMutable<bool>` | Global protocol fee on/off |
| `registration_paused` | `PublicMutable<bool>` | When true, `register_pair` reverts. Does NOT pause trading on already-registered pairs — freezing trading protocol-wide requires iterating `pause_pair` across the registry (see "Immediate actions" below) |
| `allowed_fee_tiers` | `Map<Field, PublicMutable<bool>>` | Whitelisted fee tiers |
| `pairs` | `Map<Field, PublicMutable<AztecAddress>>` | Historical pair registry, keyed by `pair_key = poseidon2(token0, token1, fee_tier, version)` |
| `pair_count` | `PublicMutable<u32>` | Total historical registrations (all versions) |
| `pair_by_index` | `Map<Field, PublicMutable<AztecAddress>>` | Historical index `0..pair_count` (all versions) |
| `latest_version` | `Map<Field, PublicMutable<u32>>` | Current latest version at `base_key = poseidon2(token0, token1, fee_tier)` (0 = none) |
| `latest_pair` | `Map<Field, PublicMutable<AztecAddress>>` | Latest pair address at each `base_key` (zero = cleared) |
| `base_count` | `PublicMutable<u32>` | Distinct bases ever registered |
| `base_by_index` | `Map<Field, PublicMutable<Field>>` | Distinct-base enumeration `0..base_count` |
| `base_seen` | `Map<Field, PublicMutable<bool>>` | Sticky "has this base ever been registered" flag. Set on first register, never unset; used to prevent duplicate entries in `base_by_index` when re-registering after a clear |
| `register_pair_locked` | `PublicMutable<bool>` | Transient reentrancy guard for `register_pair`. Acquired near the top of `register_pair`, released after the `set_protocol_fee` outbound call. Prevents any reentrant `register_pair` invocation while a prior one is in flight; defense in depth against future pair bytecode adding outbound calls from `set_protocol_fee` |
| `timelock` | `Map<Field, PublicMutable<u64>>` | Action hash -> queued_at timestamp |
| `pair_class_id` | `PublicMutable<Field>` | Currently blessed SigalSwapPair bytecode hash |
| `pair_class_version` | `PublicMutable<u32>` | Version the blessed class ID advertises (must match `get_version()` of registering pair) |

## Pair registration

```noir
#[external("public")]
fn register_pair(
    pair_address: AztecAddress,
    token0: AztecAddress,
    token1: AztecAddress,
    fee_tier_bps: u32,
    pair_salt: Field,
)
```

**Permissionless** -- anyone can register a new pair after deploying it. The Factory verifies:

1. **Canonical-address match (subsumes bytecode + init_hash checks)**: the factory reconstructs the expected pair address from `(pair_class_id, init_hash(token0, token1, factory, fee_tier_bps), pair_salt, deployer = zero, public_keys = default)` and asserts `pair_address == expected`. An Aztec address commits cryptographically to all five of those inputs, so a successful match implies the bytecode is the blessed `pair_class_id`, the constructor was called with the declared args, the salt is what the caller claims, the deployer was universal (`AztecAddress::zero()`), and the public keys are `PublicKeys::default()`. This single assertion replaces the two AVM oracle calls (`get_contract_instance_class_id_avm`, `get_contract_instance_initialization_hash_avm`) and additionally closes the public-keys attack (pairs deployed with custom public keys land at a different address and fail the match).
2. **LP Token deployed at derived address**: the factory re-derives the pair's LP Token address using the same logic the pair uses internally (`compute_from_class_id(LP_TOKEN_CLASS_ID, hash(pair_address), LP_TOKEN_SALT, zero, default)`) and calls the AVM oracle `get_contract_instance_class_id_avm(lp_address)` to confirm a contract is deployed there. Reverts `LP_TOKEN_NOT_DEPLOYED` otherwise. This catches the DOS case where a pair was deployed and registered without its LP Token counterpart -- the pair would otherwise be registered but non-functional (mint calls would hit a non-existent contract).
3. **Version cross-check**: `pair.get_version()` must equal the factory's `pair_class_version`. Catches operator errors where the admin blessed `(class_id, v_a)` but the bytecode hard-codes `VERSION = v_b`. Not subsumed by the address-match because `VERSION` is a compile-time global baked into bytecode, not a constructor arg.
4. **Fee tier check**: `fee_tier_bps` must be in the whitelisted set
5. **Token ordering**: `(token0.to_field() as u128) < (token1.to_field() as u128)` — canonical sorting by the lower 128 bits of the BN254 field element, not the full field value
6. **Monotonic version at base**: `pair_class_version > latest_version[base_key]`. Strict-greater, so re-registering the same version at the same base reverts with `VERSION_NOT_ADVANCING`. Registering a new base (where `latest_version == 0`) requires `pair_class_version >= 1`.
7. **Registration not paused**: `registration_paused` must be false (see "Immediate actions" for the pause semantics)

After registration, the Factory updates both the historical registry (`pairs[pair_key]`, `pair_by_index`) and the latest-per-base pointers (`latest_version[base_key]`, `latest_pair[base_key]`). The first registration at a base also pushes the base onto `base_by_index`. The Factory then pushes the current protocol fee settings to the new pair via `pair.set_protocol_fee()`.

**Why `pair_salt` is a caller-supplied argument**: Aztec contract addresses commit to the deploy-time salt. The factory has no way to recover a deployed pair's salt from chain state (neither oracle queryable nor derivable from the pair's address alone), so the caller echoes the salt they used at deployment. If the caller lies about the salt, the reconstructed address doesn't match the actual `pair_address` and the check fails. SDK consumers should use the canonical salt `1` (both `LP_TOKEN_SALT` and the pair's deploy salt agree on this value; any other value works but the SDK's `createPair` helper hard-codes `1` for simplicity).

**Base-squatting tradeoff and recovery (permissionless registration)**: `register_pair` is permissionless and keys routing on `(token0, token1, fee_tier)` (salt-independent) under a strict-greater version rule, so the FIRST validly-deployed pair of the blessed class to register a base wins `latest_pair` for that version — any later same-version pair at the same base (including the canonical salt-1 pair the SDK deploys) reverts `VERSION_NOT_ADVANCING`. An attacker who front-runs a team's `register_pair` with a different-salt clone (same class, identical honest behavior) can therefore squat the base and lock out the canonical pair. This is **griefing, not theft**: no funds are at risk (the clone is honest bytecode; any liquidity seeded into the canonical pair before registration stays withdrawable on that pair address directly via `remove_liquidity`), the attacker pays full deploy + mempool-fee-race cost, and the routing pointer is recoverable by the admin via `clear_pair_slot` — scoped to the single affected base, **not** a protocol-wide pair-class rotation. Mitigations: (1) the SDK / front-end should verify the registered `latest_pair` equals the expected canonical (salt-1) address before routing to or surfacing a pool, treating a mismatch as "unverified"; (2) operators monitor `PairCreatedEvent` and use `clear_pair_slot` to retract a squatted base. (Open test gap: the assert is documented and load-bearing in `register_pair_reverts.nr`, but a TXE test exercising the salt-2-clone → `VERSION_NOT_ADVANCING` path is not yet added — the non-canonical-salt deploy path needs a custom-salt deploy helper.)

The entire body of `register_pair` runs under a transient reentrancy guard (`register_pair_locked`). The guard is acquired near the top of the function and released after the `set_protocol_fee` call returns. Any reentrant `register_pair` invocation — e.g., if a future pair bytecode's `set_protocol_fee` made outbound calls that looped back into the factory — reverts immediately with `REENTRANT_REGISTER_PAIR`. Today's pair bytecode does not egress from `set_protocol_fee`, but this defense-in-depth protects future blessings without requiring per-upgrade manual audit of the full cross-contract call graph.

## Governance model

### Immediate actions (admin-only, no delay)

| Function | Description |
|----------|-------------|
| `pause_registration()` | Block new pair registrations. Does NOT stop trading on already-registered pairs. |
| `unpause_registration()` | Re-allow new pair registrations. |
| `pause_pair(pair)` | Stop all user-facing flows on one pair (swaps, mints, burns, flash swaps). Withdrawals via `remove_liquidity`, `skim`, `sync` remain available. |
| `unpause_pair(pair)` | Resume a specific pair. |

Both `pause_pair` and `unpause_pair` require `pair` to be present in the factory's `registered` map (set on `register_pair`, never cleared) — admin can only act on pairs registered through this factory. A typo or stale list referencing some other contract that happens to bake this factory's address into its constructor reverts `PAIR_NOT_REGISTERED`. Cleared pairs (post-`execute_clear_pair_slot`) keep their registered flag and so remain pausable for emergency control even when no longer the routing target.

Pause actions are the only immediate admin actions because emergency response cannot wait 48 hours.

**There is no single on-chain "pause everything" kill switch.** `pause_registration` only stops future registrations; existing pairs keep trading until an admin calls `pause_pair` on each one. Admin tooling is the load-bearing piece: a protocol-wide freeze is implemented off-chain as "call `pause_registration`, then iterate `pause_pair` over every address in the historical pair registry." This mirrors the `sync_protocol_fee` pattern (see "Protocol fee propagation"): the factory deliberately exposes single-pair primitives so tooling can decide batching, ordering, and error handling, and so the on-chain surface stays small.

If an indexer or SDK consumer needs to know whether trading is currently frozen across the protocol, it must iterate the pair registry and read each pair's `is_paused_view` — no factory-level flag represents this state.

### Timelocked actions (48-hour delay, 7-day execution window)

All non-emergency governance changes follow the queue -> wait -> execute pattern:

| Queue function | Execute function | What it changes |
|---------------|-----------------|-----------------|
| `queue_set_fee_to(addr)` | `set_fee_to(addr)` | Protocol fee recipient (first call is immediate; subsequent calls require the queue) |
| `queue_set_protocol_fee_percent(pct)` | `execute_set_protocol_fee_percent(pct)` | Protocol fee markup (0-100) |
| `queue_set_protocol_fee_enabled(bool)` | `execute_set_protocol_fee_enabled(bool)` | Protocol fee on/off |
| `queue_add_fee_tier(bps)` | `execute_add_fee_tier(bps)` | Add fee tier (0 < bps < 5000) |
| `queue_remove_fee_tier(bps)` | `execute_remove_fee_tier(bps)` | Remove fee tier |
| `queue_set_admin(addr)` | `execute_set_admin(addr)` | Admin address (non-zero) |
| `queue_set_pair_class_id(id, version)` | `set_pair_class_id(id, version)` | Pair bytecode hash + advertised version (strictly monotonic after first) |
| `queue_clear_pair_slot(pair, t0, t1, tier, new_latest_version)` | `execute_clear_pair_slot(...)` | Clear latest-pair pointer at a base; optionally roll back to a prior version |

**Timelock flow**:
1. Admin calls `queue_*` function. The action hash (`poseidon2_hash(action_type, param)`) is stored with the current timestamp.
2. After 48 hours (`TIMELOCK_DELAY`), admin calls `execute_*` with the same parameters.
3. The Factory verifies the delay has elapsed and the execution is within the 7-day window (`TIMELOCK_WINDOW`). Both bounds are inclusive: `queued_at + DELAY <= now <= queued_at + DELAY + WINDOW`. One second past the upper bound and the action reverts `ACTION_EXPIRED`.
4. The action is applied and the timelock entry is cleared.

Queue-side fast-fail: several timelocked actions validate their semantic preconditions at queue time so the admin isn't locked into a 48-hour wait on an intent that will only be rejected at execute. Specifically, `queue_set_pair_class_id` rejects non-advancing versions with `VERSION_NOT_INCREASING`; `queue_clear_pair_slot` rejects clears on bases with no registered pair (`NO_PAIR_AT_BASE`) or non-downgrade `new_latest_version` (`NEW_LATEST_NOT_LOWER`); `queue_remove_fee_tier` rejects removal of a tier that's not currently allowed with `TIER_NOT_ALLOWED` and refuses to remove the last tier with `LAST_FEE_TIER`. The authoritative checks remain at execute time; queue-side is purely fail-fast.

Because queue-side checks are evaluated at queue time and execute-side checks at execute time, state may drift between the two. The most common drift cases:

- **`clear_pair_slot`**: another clear or upgrade changed `latest_pair` between queue and execute, so the targeted pair is no longer the current latest -- execute reverts `NOT_LATEST`.
- **`set_pair_class_id`**: a *different* class-id-version blessing was queued and executed in the same window, advancing `pair_class_version` past the version this action committed to. The earlier action becomes permanently un-executable for the rest of the WINDOW (~7 days) and reverts `VERSION_NOT_INCREASING` at any execute attempt. Recovery is `cancel_action` (which requires recomputing the action's `value` via `compute_class_id_version_param` off-chain) or natural expiry. This is rare because it requires admin to queue two overlapping class-id changes; the queue-side check still helps the common single-action case.
- **`remove_fee_tier`**: vanishingly unlikely because `queue_remove_fee_tier` blocks `ALREADY_QUEUED` for the same `(action_type, value)` and the only way for a tier to flip allowed→disallowed without going through this same path is non-existent in the current contract. The execute-side `TIER_NOT_ALLOWED` assert is defense-in-depth against future-refactor regressions.

If execute reverts due to any of the above, admin must call `cancel_action` first, then re-queue against the new state. Expired timelock slots are never zeroed, so an identical re-queue (same `action_type` and `value`) before `cancel_action` reverts with `ALREADY_QUEUED`; `cancel_action` works on expired entries and clears the slot so the re-queue can succeed. (A re-queue with different parameters hashes to a different slot and is unaffected.)

Queue calls that fail their pre-emit assertions do NOT emit `ActionQueuedEvent`. This is symmetric with how other validation errors (ZERO_ADDRESS, ONLY_ADMIN, ALREADY_QUEUED, etc.) short-circuit before the emit. Indexers should not assume every `queue_*` transaction produces a queued event — only successful queues do.

**Bootstrap orphans.** Two paths emit `ActionExecutedEvent` (and the matching typed event, e.g. `PairClassIdChangedEvent`) without any preceding `ActionQueuedEvent`:

1. The factory **constructor** emits initial-state events (`AdminChangedEvent`, three `FeeTierAddedEvent`s, `ProtocolFeePercentChangedEvent`, `ProtocolFeeEnabledChangedEvent`) so an indexer replaying from genesis can reconstruct the full bootstrap configuration without reading the contract's compile-time defaults.
2. The first call to `set_pair_class_id` (before any timelocked subsequent change) is immediate and emits `ActionExecutedEvent` + `PairClassIdChangedEvent` directly -- a timelocked first-blessing would be chicken-and-egg (no pair class for 48 hours after deploy).

Indexers reconciling queue/execute pairs should treat these orphans as expected. The in-source comment at the immediate `set_pair_class_id` branch documents the design choice: emit `ActionExecutedEvent` from both branches so observers see a uniform signal regardless of which path was taken.

Any queued action can be cancelled before execution:

```noir
#[external("public")]
fn cancel_action(action_type: Field, value: Field)
```

Admin-only. The factory recomputes the action hash internally from `(action_type, value)` — the same inputs the admin used at queue time. On success it zeroes the timelock entry and emits `ActionCancelledEvent { action_type, value }`, which is self-describing so observers can decode the cancel without cross-referencing the earlier `ActionQueuedEvent`.

Note on compound-param actions: for `ACTION_SET_PAIR_CLASS_ID` (type 7) and `ACTION_CLEAR_PAIR_SLOT` (type 8), the `value` field is itself a Poseidon2 hash over the action's full intent (`compute_class_id_version_param` and `compute_clear_slot_param` respectively). The emitted event carries the opaque hash, not the plaintext `(class_id, version)` or `(pair, t0, t1, tier, new_latest)`. Indexers displaying a human-readable cancel history should pair this event with the earlier `ActionQueuedEvent` for the same `value` — both events share the same opaque `value` field, so the join is a direct hash match. If the queue event is unavailable (e.g., pruned indexer window), the cancel is still cryptographically authentic but its plaintext intent cannot be reconstructed from the on-chain data alone.

### Interaction with pause

`pause_registration` gates `register_pair`; `pause_pair(pair)` gates user-facing flows on that specific pair (swaps, mints, burns). Neither gates governance itself: `queue_*`, `execute_*`, and `cancel_action` all remain callable during any pause. This is intentional — governance must be able to act during an emergency (e.g., roll admin, clear a malfunctioning pair, bless a hotfix bytecode). Operationally, this means an `execute_clear_pair_slot` can change `latest_pair` routing while pairs are paused from the user's point of view; SDK consumers caching routing should re-read after any unpause.

### Admin handoff hazard

The timelock map is keyed by `action_hash` and has no notion of "which admin queued this action." That means a queued action from the outgoing admin remains executable under the incoming admin — standard behavior for `OpenZeppelin`-style timelock patterns, but worth being explicit about.

**The exposure**: an outgoing admin could, in their final minutes, queue something bad-faith (e.g., `queue_set_fee_to(malicious_address)`). Since the execute-side check only verifies `msg_sender == admin`, the new admin (or anyone who calls the execute function thinking it's a routine pending change) can still push that action through after the 48-hour delay elapses.

**Mitigation**: admin handoff should include a manual audit of pending actions. Specifically:

1. Subscribe to `ActionQueuedEvent` logs from the factory for the full window prior to handoff — at minimum, the last 48 hours, ideally the full tenure of the outgoing admin if trust is low.
2. For each queued event, recompute the action hash off-chain as `poseidon2_hash(action_type, value)`. The `action_type` is a constant per queue function (see "Action type IDs" below); `value` is the second field of the `ActionQueuedEvent`.
3. For any action the incoming admin doesn't want, call `cancel_action(action_type, value)` with the `action_type` constant and the `value` field from the queued event. Admin-only; emits `ActionCancelledEvent { action_type, value }`, creating a self-describing on-chain record of the cleanup.
4. Any action *not* cancelled remains executable — this is intentional. Legitimate pending changes (fee tier additions, `set_pair_class_id`, etc.) continue to work across the handoff.

**Pay special attention to `clear_pair_slot` during handoff.** Of all timelocked actions, `clear_pair_slot` is the most structurally destructive: executing it retracts a registered pair from `latest_pair` routing, which breaks SDK pair lookups and the router's ability to resolve that pool. LPs retain their funds — the pair contract is immutable and `remove_liquidity` still works on the pair address directly — but users discovering the pool through the factory will suddenly see it gone. Auditing pending `ACTION_CLEAR_PAIR_SLOT` queues (action_type 8) before accepting an admin rotation is especially important.

The SDK exports event metadata via `SigalSwapEvents.factory` (covers `ActionQueuedEvent`, `ActionExecutedEvent`, and `ActionCancelledEvent`); pair these with `aztec.js`'s `getPublicEvents` to scan the relevant history without hand-rolling ABI decoding.

If the outgoing admin cooperates, they can pre-empt this by cancelling their own pending non-essential actions before the rotation executes.

### Pair class ID and version

`set_pair_class_id` takes two arguments: the class ID (bytecode hash) and the version that bytecode advertises via its compile-time `VERSION` global. Both are stored on the factory (`pair_class_id` and `pair_class_version`). Subsequent blessings must strictly advance the version (`version > pair_class_version`), enforced at `execute_*` time.

The first call is immediate (there are no pairs to protect yet). Subsequent changes require the full timelock, giving users time to evaluate new bytecode before any pairs can be registered with it.

**Required post-deploy step.** `register_pair` asserts `pair_class_id != 0`, so **the factory is inert until `set_pair_class_id` is called for the first time**. Any attempt to register a pair before that call reverts with `PAIR_CLASS_ID_NOT_SET`. The deployment runbook must include:

1. Deploy the factory.
2. Deploy the first pair (or compute the `SigalSwapPair` class ID by any means available).
3. Call `factory.set_pair_class_id(<SigalSwapPair_class_id>, <SigalSwapPair_VERSION>)` from the admin. Pass the same integer that `core/src/main.nr` sets as `pub global VERSION: u32 = N`.
4. Only after step 3 can any pair be registered via `register_pair`.

### Upgrading pair bytecode

Deploying a new pair implementation is a two-step governance action:

1. Bump `VERSION` in `core/src/main.nr` and build the new artifact. The new bytecode will have a new class ID.
2. Admin calls `queue_set_pair_class_id(new_class_id, new_version)` and, after the 48-hour delay, `set_pair_class_id(new_class_id, new_version)`. `new_version` must be strictly greater than the previously blessed version.

Once blessed, anyone can deploy a `v_new` pair at any base (new or existing) and call `register_pair`. The factory:

- Rejects it if the bytecode's `get_version()` doesn't match `pair_class_version` (`VERSION_MISMATCH`).
- Rejects it if `v_new <= latest_version[base_key]` at that base (`VERSION_NOT_ADVANCING`).
- On success: stores the pair under the versioned `pair_key`, updates `latest_pair[base_key]`, and bumps `latest_version[base_key]`.

Consumers see upgrades automatically through `get_pair` (which reads `latest_pair`). Historical versions remain queryable via `get_pair_versioned(tokens, tier, version)` for auditability.

**Constraint: the new pair class must keep the same `LP_TOKEN_CLASS_ID`.** The factory imports `LP_TOKEN_CLASS_ID` from `sigalswap_core` at compile time and bakes the value into its bytecode. `register_pair` re-derives the LP-token address using the baked-in constant and asserts both that a contract is deployed there and that its class_id matches. A pair-class rotation that changes the LP-token bytecode (and therefore `LP_TOKEN_CLASS_ID`) cannot be deployed against the existing factory — `register_pair` will revert with `LP_TOKEN_NOT_DEPLOYED` or `LP_TOKEN_WRONG_CLASS` for any pair of the new class. Such rotations require a fresh factory deploy (along with a fresh pair-class blessing on the new factory). LP-only changes that don't shift the class ID — additional metadata, view helpers, internal refactors that preserve the bytecode hash — are not affected.

**Registration-window discontinuity.** During the 48-hour timelock between `queue_set_pair_class_id(new_class, new_version)` and `set_pair_class_id(...)`:

- `pair_class_id` storage still points at the OLD class.
- `register_pair` continues to accept pairs of the OLD class, and rejects pairs of the NEW class with `PAIR_NOT_CANONICAL` (the canonical-address check fails because the address embeds `pair_class_id`).
- Users CAN still deploy and register OLD-class pairs in this window.

The instant the execute lands, `pair_class_id` flips to the NEW class. From that point forward `register_pair` rejects OLD-class pairs and accepts NEW-class pairs. There is no overlap window where both are accepted; the rotation is atomic at the execute boundary.

**Implication for in-flight deployers.** A user who deployed an OLD-class pair before the execute but hadn't called `register_pair` yet discovers, post-execute, that their pair is no longer registerable. Their funds are not at risk (the pair is just an unregistered contract; no LPs have minted yet), but their deploy gas is sunk and they must redeploy under the NEW class to register. The SDK's `createPair` helper re-derives the canonical pair address from `factory.getPairClassVersion()` on every call; integrators implementing their own deploy flow should re-read `pair_class_version` at the start of any deploy attempt to catch a recent rotation before submitting the deploy tx.

### Clearing a pair slot

Governance can clear a registered pair via `queue_clear_pair_slot` / `execute_clear_pair_slot`. The queue param commits the full intent (pair address, base identifiers, and `new_latest_version`) so it cannot be altered at execute time. The execute call asserts:

- `msg_sender == admin` (`ONLY_ADMIN`)
- The queued action exists and has elapsed its delay without expiring
- The declared pair is the current latest at the base (`NOT_LATEST`)
- `new_latest_version < current_latest_version` (`NEW_LATEST_NOT_LOWER`) — either zero (fully clear) or a strictly smaller version to roll back to
- If rolling back (`new_latest_version > 0`): the rollback target must exist in `pairs` (`NEW_LATEST_NOT_REGISTERED`) so `latest_pair` is never pointed at a zero address

On success: the versioned `pairs[pair_key]` slot is zeroed, and `latest_pair`/`latest_version` are either cleared (if `new_latest_version == 0`) or rolled back to the prior version. `pair_by_index` (historical enumeration) is intentionally not rewritten -- past registrations remain visible for audit.

**Clearing is permanent at the address level.** `register_pair` is one-shot per pair contract address: once a pair address has been registered (and thus written into the sticky `registered` map), any subsequent `register_pair` call with the same address reverts `PAIR_ADDRESS_ALREADY_REGISTERED`. This holds across clears -- `execute_clear_pair_slot` deliberately preserves the `registered` flag (so admin can keep paussing/syncing the retired contract) and that same flag blocks the cleared address from being permissionlessly re-registered to undo the retraction. To re-introduce routing for the same `(t0, t1, fee_tier)` base after a full clear, governance must bless a new pair bytecode (`queue_set_pair_class_id` / `set_pair_class_id` to a higher version) and deploy a fresh pair instance -- the new class_id produces a different canonical address, so the new pair is a distinct contract that is registerable. Roll-back to a *prior* version (`new_latest_version > 0`) does not need a new deploy because rollback re-uses the existing `pairs[(t0, t1, tier, v_old)]` entry; it never goes through `register_pair`.

### Fee tier whitelist: removal semantics

`queue_add_fee_tier(bps)` / `execute_add_fee_tier(bps)` adds a tier to the whitelist; `queue_remove_fee_tier(bps)` / `execute_remove_fee_tier(bps)` removes one. The whitelist is consulted **only at `register_pair` time** (via the "Fee tier check" on the pair-registration list above).

**Removal is prospective-only.** Removing a tier from the whitelist blocks *new* pair registrations at that tier but does nothing to pairs already registered at it. An existing pair's `fee_tier_bps` is baked into its immutable `PairConfig` at construction and governs all of that pair's subsequent swaps, mints, and burns regardless of the factory's current whitelist. There is no mechanism to retroactively rewrite or disable a live pair's fee tier, and `sync_protocol_fee` does not consult the whitelist — it pushes `(fee_to, percent, enabled)`, not the tier.

This is intentional. Pair contracts are immutable; LPs who deposited at a specific fee tier have an economic expectation the tier won't change under them. Removing the tier from the whitelist is the factory's way of saying "no new pools here," not "shut down existing pools."

**SDK / indexer guidance.** When displaying pair lists or routing quotes, do not filter pairs by their `fee_tier_bps` against the factory's current `is_fee_tier_allowed(tier)`. A removed tier can still have live pairs with real liquidity — hiding them would steer users away from functional pools. Use `is_fee_tier_allowed` only for the creation-UI path (i.e., "which tiers can I deploy a new pool at?"). For routing and LP operations, treat the pair's own `get_config().fee_tier_bps` as authoritative.

**No on-chain enumeration of allowed tiers.** The factory exposes `is_fee_tier_allowed(tier)` as a per-tier check but does not provide a bulk view that returns the full allowed set. Cross-contract callers that need the live whitelist must check each candidate tier individually; off-chain consumers should reconstruct the set by subscribing to `FeeTierAddedEvent` / `FeeTierRemovedEvent` from genesis (the constructor emits one `FeeTierAddedEvent` per default tier at deploy) and folding additions / removals into a client-side set. The SDK consumes this pattern; third-party integrators implementing their own creation UI should mirror it. Adding an on-chain enumeration would couple the factory's bytecode to a fixed set of tiers or require iteration over a sparse map, both of which trade ergonomics for circuit cost; the event-replay approach has no on-chain cost beyond what the existing add/remove flows already pay.

## Protocol fee propagation

When the admin changes protocol fee settings (`fee_to`, `protocol_fee_percent`, `protocol_fee_enabled`), the factory updates its own storage, but the new values are **not** automatically mirrored into every pair contract. Each pair holds its own copy of those settings in its `packed_flags` slot and must be updated explicitly:

```noir
#[external("public")]
fn sync_protocol_fee(pair: AztecAddress)
```

Admin-only. Calls `pair.set_protocol_fee(fee_to, percent, enabled)` on the given pair with the current global settings.

### Intended semantics

Protocol fee settings in the factory are **global by intent**: when admin bumps `protocol_fee_percent` from 20 to 30, the intent is that every live pair charges 30%. Pair-side fee settings are authoritative for trades on that specific pair, so an unsynced pair keeps charging its last-synced value until `sync_protocol_fee` is called on it.

### Admin iteration recipe (important)

After a global fee change, admin tooling MUST iterate the **historical** pair enumeration — not just the latest-per-base set — and call `sync_protocol_fee` on each entry:

```typescript
const total = await factory.getPairCount();       // historical count
for (let i = 0; i < total; i++) {
  const pair = await factory.getPairAt(i);        // historical enumeration
  await factory.methods.sync_protocol_fee(pair).send(...);
}
```

Iterating `getLatestPairCount()` + `getLatestPairAtIndex(i)` instead would **miss every older-version pair at every upgraded base**. Those older pairs are immutable contracts that may still hold unwithdrawn LP liquidity; users who interact with them directly (bypassing the router) would transact against stale fee settings. Iterating the historical set covers every live pair contract regardless of whether the factory currently routes to it.

Cleared pairs (via `clear_pair_slot`) are included in the historical enumeration and SHOULD also be synced, for the same reason — the pair contract still exists and may hold liquidity.

### Batching and cost management

Iterating every historical pair is linear in `pair_count`. As the registry grows, admin tooling should implement its own batching (e.g., chunk into groups of 10–20 pairs per tx; defer cold pairs until the next sync cycle; or skip pairs confirmed empty by reading reserves). The on-chain `sync_protocol_fee` is deliberately single-pair so tooling can make these tradeoffs — the factory does not attempt to auto-batch on-chain.

### Drift is possible; the intent is to prevent it

The architecture does not *prevent* per-pair fee drift — any pair whose `sync_protocol_fee` is skipped keeps its old setting. Admin tooling is the load-bearing piece that enforces "global" semantics. If a future protocol version chooses to intentionally allow per-pair drift (e.g., grandfathered fees on old versions), the same on-chain surface supports that policy — just change the tooling, not the contracts.

### Transition order: enabling and disabling fees

The pair contract's `set_protocol_fee` rejects two states:
- `(enabled=true, percent=0)` with `ACTIVE_WITH_ZERO_PERCENT` (meaningless rate), and
- `(enabled=true, fee_to=zero)` with `ACTIVE_WITH_ZERO_FEE_TO` (mint destination would be unrecoverable).

The factory mirrors both invariants at the queue and execute sides of `set_protocol_fee_enabled` and `set_protocol_fee_percent`. This keeps the factory's stored config consistent with what a pair would accept, so `sync_protocol_fee(pair)` never reverts due to a factory-side state the pair can't process.

What this means for admin operations:

**Prerequisite: `fee_to` must be initialized** via `set_fee_to` before any `set_protocol_fee_enabled(true)`. The first call to `set_fee_to` after factory deploy is immediate (see "Deployment runbook" below); subsequent changes require the standard queue + timelock.

**To disable protocol fees entirely** (both `enabled=false` and `percent=0`): always queue+execute `set_protocol_fee_enabled(false)` FIRST, then queue+execute `set_protocol_fee_percent(0)`. Executing them in the opposite order is blocked — `set_protocol_fee_percent(0)` asserts `!protocol_fee_enabled` at both queue and execute time. The safe intermediate state is `(enabled=false, percent=X)` where X > 0.

**To re-enable protocol fees from a fully-disabled state**: always queue+execute `set_protocol_fee_percent(X)` for X > 0 FIRST, then queue+execute `set_protocol_fee_enabled(true)`. Executing them in the opposite order is blocked — `set_protocol_fee_enabled(true)` asserts `protocol_fee_percent > 0` and `fee_to != zero`. The safe intermediate state is again `(enabled=false, percent=X)`.

**To change only the percent while fees stay enabled**: single queue+execute of `set_protocol_fee_percent(new_percent)` with `new_percent > 0`. No ordering concern.

**To pause fee accrual temporarily without zeroing the rate**: single queue+execute of `set_protocol_fee_enabled(false)`. Re-enable later with another single queue+execute of `set_protocol_fee_enabled(true)` — permitted because `percent` is already > 0 and `fee_to` was set earlier.

If admin queues in the wrong order by mistake, the doomed action fails at queue time with `ACTIVE_WITH_ZERO_PERCENT` or `ACTIVE_WITH_ZERO_FEE_TO` (48-hour delay not burned). If an action is queued correctly but admin tries to execute it too early (before the OTHER transition is also ready), the execute-side check fires with the same error. Admin fixes by queuing the missing transition in the correct sequence.

## Default configuration

| Setting | Default value |
|---------|--------------|
| Fee tiers | 5 bps (0.05%), 25 bps (0.25%), 100 bps (1.00%) |
| Protocol fee percent | 20 (20% markup on LP fee) |
| Protocol fee enabled | false |
| Registration paused | false |

## Deployment runbook

Two factory functions use a first-call-immediate / subsequent-timelocked pattern:

- **`set_pair_class_id(class_id, version)`** — gates which pair bytecode the factory accepts during `register_pair`. First call is immediate; subsequent changes require `queue_set_pair_class_id` + 48-hour timelock. A timelocked bootstrap would be chicken-and-egg: no pair class for 48 hours after deploy.
- **`set_fee_to(addr)`** — sets the protocol-fee recipient. First call is immediate; subsequent changes require `queue_set_fee_to` + 48-hour timelock. `fee_to` defaults to the zero address at construction; enabling protocol fees is gated on `fee_to != zero`, so bootstrapping this is a prerequisite to any `set_protocol_fee_enabled(true)`.

**Consequence:** between factory deployment and these first calls, any admin-keyed caller can set either value without delay. If the admin key leaks in that window, an attacker can bless malicious pair bytecode or redirect future protocol fees — both without community notice.

**Runbook:**

1. Deploy the factory and capture the deployed address.
2. **In the same transaction batch**, from the admin key:
   - Call `set_pair_class_id(blessed_class_id, 1)`.
   - Call `set_fee_to(protocol_treasury_address)`.
   Do not separate these steps into different announcements or blocks.
3. Only after step 2 lands successfully, announce the factory address publicly.
4. To enable protocol fees, queue+execute `set_protocol_fee_enabled(true)` — the default `protocol_fee_percent = 20` from the constructor makes this valid immediately; otherwise queue+execute `set_protocol_fee_percent(X)` first.
5. Once `set_pair_class_id` and `set_fee_to` have been called once, subsequent changes require queueing + the 48-hour timelock, which restores the normal governance guarantee.

A front-run or MEV attacker cannot exploit the window without the admin key. The concern is strictly key-compromise during the gap.

## Pair key computation

Two keys are used:

- `base_key = poseidon2(token0, token1, fee_tier_bps)` -- identifies a pool slot independent of pair version. Used by `latest_pair` / `latest_version`.
- `pair_key = poseidon2(token0, token1, fee_tier_bps, version)` -- identifies a specific versioned registration. Used by `pairs`.

Token sorting (`(token0.to_field() as u128) < (token1.to_field() as u128)` — the lower 128 bits of the BN254 field element, not the full field value) ensures `(A, B)` and `(B, A)` resolve to the same key. Multiple fee tiers at the same token pair are distinct bases; multiple versions at the same `(tokens, tier)` share a base but occupy different `pair_key` slots.

## Enumeration semantics

Two enumerations coexist:

- **Historical** (`pair_by_index`, length `pair_count`): every registration, all versions, in chronological order. Never rewritten when a slot is cleared -- `get_pair_at(i)` always returns what was registered there. Each pair contract address appears at most once across the full log: `register_pair` asserts `!registered[pair_address]` at entry, so a cleared pair cannot be re-appended via re-registration.
- **Latest-per-base** (`base_by_index`, length `base_count`): each distinct base appears exactly once. `get_latest_pair_at_index(i)` reads `latest_pair[base_by_index[i]]`, so it returns the current latest pair at that base -- or `AztecAddress::zero()` if the base was cleared. Iterate `[0, get_indexed_base_count())` and skip zeros to enumerate active bases. Use `get_active_pair_count()` if you only need the post-skip count without iterating.

The "exactly once" guarantee holds across the full lifecycle: first register, version upgrades, full clear, and re-register at a cleared base all resolve through the same `base_by_index` slot. Re-registering at a cleared base reuses the original index (its `latest_pair` flips from zero back to the fresh pair); it does NOT append a new entry. This is enforced by the sticky `base_seen` flag in register_pair.

Indexers wanting a live pair list should use the latest-per-base enumeration. Indexers building audit trails or replaying history should use the historical enumeration.

## View functions

Two flavors of read-only views: `#[external("utility")]` (the bulk; off-chain callers via the SDK) and one `#[external("public")] #[view]` (`get_pair_versioned_public`, callable on-chain by the router for trust-boundary verification).

### Pair lookup

| Function | Returns | Description |
|----------|---------|-------------|
| `get_pair(token0, token1, fee_tier_bps)` | `AztecAddress` | Latest pair at the base; zero if cleared |
| `get_pair_versioned(token0, token1, fee_tier_bps, version)` | `AztecAddress` | Specific versioned pair; zero if not registered |
| `get_pair_versioned_public(token0, token1, fee_tier_bps, version)` | `AztecAddress` | On-chain version of `get_pair_versioned`. Public callable via `self.view(...)` -- router uses it as the pair-address trust boundary |
| `get_latest_version(token0, token1, fee_tier_bps)` | `u32` | Current latest version at the base (0 = none) |

### Enumeration

| Function | Returns | Description |
|----------|---------|-------------|
| `get_pair_at(i)` | `AztecAddress` | Historical enumeration (reverts on out-of-bounds) |
| `get_pair_count()` | `u32` | Total historical registrations (all versions) |
| `get_latest_pair_at_index(i)` | `AztecAddress` | Latest pair at the i-th distinct base (zero if cleared) |
| `get_indexed_base_count()` | `u32` | Distinct bases ever registered. Iteration upper bound for `get_latest_pair_at_index` -- monotonically increasing, never decremented on `execute_clear_pair_slot` |
| `get_active_pair_count()` | `u32` | Bases currently routable (latest_pair non-zero). Differs from `get_indexed_base_count` when bases have been cleared. Computed on-chain in one call to save off-chain N+1 round-trips |

### Configuration

| Function | Returns | Description |
|----------|---------|-------------|
| `get_pair_class_version()` | `u32` | Currently blessed pair version (what `get_version()` must return to register) |
| `is_fee_tier_allowed(tier_bps)` | `bool` | Check if fee tier is whitelisted |
| `get_admin()` | `AztecAddress` | Current admin address |
| `get_fee_to()` | `AztecAddress` | Protocol fee recipient |
| `get_protocol_fee_config()` | `(AztecAddress, u32, bool)` | Protocol fee recipient (`fee_to`), percent, and enabled flag in one call |
| `is_registration_paused()` | `bool` | Whether new pair registrations are currently blocked. Does NOT reflect per-pair trading pause state (query each pair's `is_paused_view` for that) |

### Timelock introspection

| Function | Returns | Description |
|----------|---------|-------------|
| `get_timelock(action_hash)` | `u64` | `queued_at` timestamp for a timelocked action; 0 if not queued (never queued, already executed, or cancelled). `action_hash = poseidon2([action_type, value])` -- see SDK's `computeActionHash` |
| `get_timelock_params()` | `(u64, u64)` | `(TIMELOCK_DELAY, TIMELOCK_WINDOW)` in seconds. On-chain source of truth so off-chain callers don't hardcode the values |

### Admin tooling: read-side recipes

Aggregated read-side queries ("how many pairs are paused?", "which pairs have stale protocol-fee config?") are intentionally implemented off-chain via the SDK rather than as on-chain factory utilities. The architectural reason is that aztec-nr's `UtilityContext` (used by `unconstrained #[external("utility")]` functions) does not expose a cross-contract `.view()` method — only `raw_storage_read` against arbitrary addresses, which would couple the factory's bytecode to the pair's storage layout. The off-chain pattern avoids that coupling at the cost of N+1 PXE round-trips per aggregate query, which is acceptable for admin dashboard cadence.

The canonical per-pair iteration recipe (TypeScript pseudocode):

```
const count = await factory.getActivePairCount();
const candidates = await Promise.all(
    Array.from({ length: count }, (_, i) => factory.getLatestPairAtIndex(i))
);
const live = candidates.filter(p => !p.isZero()); // skip cleared bases
const pausedFlags = await Promise.all(
    live.map(p => SigalSwapPair.at(p).isPausedView())
);
const pausedCount = pausedFlags.filter(Boolean).length;
```

`getLatestPairAtIndex` iterates *live* (currently routable) pairs only — superseded versions and cleared bases are skipped or returned as the zero address. Pause state on a non-routable pair has no operational meaning, so the live iterator is the right scope for admin tooling. (For historical / per-version pause queries — e.g. recovering an older LP position from a paused legacy pair — iterate `getPairAt(i)` over `[0, getPairCount())` instead, which walks every registered version.)

`Promise.all` parallelizes the per-pair read; for a 100-pair registry the wall-time is bounded by single-PXE-call latency (typically tens to hundreds of milliseconds). The same shape applies to "protocol-fee drift" queries — fetch each pair's `get_pair_state()` and `get_fee_to()` and compare against `factory.getProtocolFeeConfig()`.

The SDK ships typed helpers (`factory.getPairPauseStates({ start?, end? })`, `factory.getProtocolFeeDriftStates({ start?, end? })`) wrapping this pattern with pagination; admin tooling consumes those rather than reimplementing.

## Action type IDs

Used in Poseidon2 hash computation for timelock keys:

| ID | Action | `param` |
|----|--------|---------|
| 1 | Set fee_to | new fee_to address |
| 2 | Set protocol fee percent | new percent |
| 3 | Set protocol fee enabled | new flag (0 or 1) |
| 4 | Add fee tier | tier bps |
| 5 | Remove fee tier | tier bps |
| 6 | Set admin | new admin address |
| 7 | Set pair class ID | `poseidon2(class_id, version)` |
| 8 | Clear pair slot | `poseidon2(pair, sorted_t0, sorted_t1, tier, new_latest_version)` |

## Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `TIMELOCK_DELAY` | 172,800 (48 hours) | Minimum wait after queuing |
| `TIMELOCK_WINDOW` | 604,800 (7 days) | Execution window after delay |

## Events

All factory events are public (unencrypted). Factory operations are governance actions — transparency is the goal.

| Event | Fields | Emitted by |
|-------|--------|-----------|
| `PairCreatedEvent` | `token0`, `token1`, `pair`, `lp_token`, `fee_tier_bps`, `version`, `pair_count` | `register_pair` |
| `PairSlotClearedEvent` | `pair`, `token0`, `token1`, `fee_tier_bps`, `cleared_version`, `new_latest_version`, `new_latest_pair` | `execute_clear_pair_slot` |
| `RegistrationPausedEvent` | (none) | `pause_registration` |
| `RegistrationUnpausedEvent` | (none) | `unpause_registration` |
| `PairPausedEvent` | `pair` | `pause_pair` (every admin call, including idempotent ones) |
| `PairUnpausedEvent` | `pair` | `unpause_pair` (every admin call, including idempotent ones) |
| `ProtocolFeeSyncedEvent` | `pair` | `sync_protocol_fee` (every admin call, including no-op pushes against already-current pairs) |
| `ActionQueuedEvent` | `action_type`, `value`, `execute_after` | All `queue_*` functions |
| `ActionExecutedEvent` | `action_type`, `value` | All `execute_*` functions |
| `ActionCancelledEvent` | `action_type`, `value` | `cancel_action` |
| `AdminChangedEvent` | `new_admin` | `execute_set_admin` |
| `FeeToChangedEvent` | `new_fee_to` | `set_fee_to` |
| `FeeTierAddedEvent` | `tier_bps` | `execute_add_fee_tier` |
| `FeeTierRemovedEvent` | `tier_bps` | `execute_remove_fee_tier` |
| `PairClassIdChangedEvent` | `class_id`, `version` | `set_pair_class_id` (both first-call and timelocked) |
| `ProtocolFeePercentChangedEvent` | `new_percent` | `execute_set_protocol_fee_percent` (also constructor) |
| `ProtocolFeeEnabledChangedEvent` | `enabled` | `execute_set_protocol_fee_enabled` (also constructor) |

**Pair-pause event observability split.** The factory emits `PairPausedEvent` / `PairUnpausedEvent` on every successful admin call to `pause_pair` / `unpause_pair`, regardless of whether the underlying pair's state actually changed. The pair contract emits the same-named events (see `protocol/core/README.md`'s "Public Events" table) only on real `inactive ↔ paused` transitions; idempotent calls against an already-paused or already-unpaused pair emit nothing on the pair side. Indexers tracking *governance activity* (every admin pause/unpause attempt) should consume the factory's events; indexers tracking *trading state* (when a pair actually became unavailable) should consume the pair's events. The SDK exposes both as distinct typed-data interfaces (`FactoryPairPausedEventData` vs `PairPausedEventData`).
