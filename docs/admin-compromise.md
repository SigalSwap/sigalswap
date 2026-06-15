# Admin compromise: blast radius and recovery properties

Analysis of every privileged path on SigalSwap, the worst case under each, and the contract-level recovery properties when the admin key is in adversarial hands.

## 1. Threat model

**In scope.** The factory's `admin` private key is held by an attacker. This includes phishing of the operator, hardware-wallet supply-chain compromise, malware on the signing machine, coercion ("rubber-hose"), or insider abuse by a holder of the key.

**Out of scope.** Aztec sequencer compromise, Noir compiler compromise, individual user wallet compromise, Token contract bugs, PXE bugs.

**Asset under protection.** LP-held value (token reserves) and trader expected execution (slippage / fee).

**Custody facts.**
- LP reserves live in **immutable pair contracts**. Pair bytecode has zero admin paths.
- LP-token mint authority is **derived-address scoped** to the owning pair. The LP-token contract has zero admin paths.
- Router has zero admin paths.
- The factory **cannot move pair funds** under any function. Its only powers are governance: pair registration, fee parameters, pause, and class-ID blessing.

## 2. Inventory of privileged surfaces

### 2.1 Factory (admin-callable governance functions + permissionless `register_pair`)

Categorized by timing class. All require `msg_sender == admin`.

**Immediate (no timelock):**
- `pause_pair(pair)` — sets paused on a registered pair
- `unpause_pair(pair)` — clears paused
- `pause_registration()` — blocks new `register_pair` calls
- `unpause_registration()` — clears the registration block
- `sync_protocol_fee(pair)` — propagates current `(fee_to, percent, enabled)` triple to one pair
- `cancel_action(action_type, value)` — clears any queued timelock entry
- `set_pair_class_id(class_id, version)` — **first call only**; subsequent calls fall through to the timelocked path below
- `set_fee_to(new_fee_to)` — **first call only** (bootstrap from zero); subsequent calls timelocked

**Queue side of timelock (immediate, just records intent):**
- `queue_set_pair_class_id`
- `queue_set_fee_to`
- `queue_set_protocol_fee_percent` — caps `new_percent <= 100`
- `queue_set_protocol_fee_enabled` — gated on `fee_to != zero` and `percent > 0` when enabling
- `queue_add_fee_tier` — caps `0 < tier_bps < 5000`
- `queue_remove_fee_tier` — refuses to remove the last tier (`count >= 2`)
- `queue_set_admin` — refuses zero address
- `queue_clear_pair_slot`

**Execute side (gated on `queued_at + 48h <= now <= queued_at + 48h + 7d`):**
- `set_pair_class_id` (subsequent-call path), `set_fee_to` (subsequent-call path)
- `execute_set_protocol_fee_percent`, `execute_set_protocol_fee_enabled`
- `execute_add_fee_tier`, `execute_remove_fee_tier`
- `execute_set_admin`
- `execute_clear_pair_slot`

`TIMELOCK_DELAY = 172800s` (48h). `TIMELOCK_WINDOW = 604800s` (7d). Expired slots are never auto-zeroed: after `delay + window` expires, `execute` reverts `ACTION_EXPIRED` (rolling back), and every queue path asserts the slot is empty (`ALREADY_QUEUED`), so an identical re-queue over an expired entry also reverts. To re-queue an expired action the admin must first call `cancel_action` (which works on expired entries) to clear the slot, then re-queue.

### 2.2 Pair (zero admin; two factory-gated functions)

`set_pause(bool)` and `set_protocol_fee(fee_to, percent, active)` assert `msg_sender == config.factory`. They are reachable only from the factory's `pause_pair` / `unpause_pair` and `sync_protocol_fee`. Reserves, swap, mint, burn, skim, sync, and flash_swap have no admin or factory path.

### 2.3 LP-token (zero admin; two pair-gated functions)

`mint_to_public` and `finalize_mint_to_private` assert `msg_sender == storage.pair`. Reachable only from the owning pair's add-liquidity paths.

### 2.4 Router

Zero admin paths. The single privileged check is per-tx callback authentication (`msg_sender == pair_addr`) for swap settlement, not a governance role.

## 3. Action matrix

For every admin-callable function, the worst-case effect under hostile use.

| Function | Timing | Affects | Worst case under attack | Recovery path |
|---|---|---|---|---|
| `pause_pair(p)` | Immediate | One pair | Trading + add-liquidity halt on `p`. **LP withdrawals continue.** | Honest admin calls `unpause_pair(p)`. No timelock either direction. |
| `unpause_pair(p)` | Immediate | One pair | Re-enable trading on a pair an honest admin paused. | Re-pause. |
| `pause_registration` | Immediate | Whole factory | New pairs cannot register. Existing pairs unaffected. | `unpause_registration`. |
| `unpause_registration` | Immediate | Whole factory | Re-enable registration during attack. Existing pairs unaffected. | `pause_registration`. |
| `sync_protocol_fee(p)` | Immediate | One pair | Propagates the **current stored** `(fee_to, percent, enabled)` to pair `p`. Cannot pick the value — only the propagation. Combined with timelocked-and-just-executed bad values, instantly applies them. | Re-sync after honest admin restores values. |
| `cancel_action(t, v)` | Immediate | One queued action | Drops a queued timelock entry. **Can cancel the honest admin's recovery rotation.** See §5. | Re-queue (another 48h cycle). |
| `set_pair_class_id` (first) | Immediate | Future pairs at new version | Blesses a malicious bytecode class for new pair deployments. **No effect on existing pair contracts** (immutable). | Queue + timelocked re-bless of a known-good class. |
| `set_pair_class_id` (subsequent) | Timelocked 48h | Future pairs at new version | Same as above; with 48h notice. | Cancel during the queue window or counter-queue. |
| `set_fee_to` (first, bootstrap) | Immediate | All pairs after sync | Sets the protocol-fee recipient to the attacker. Has no effect until protocol fees are enabled (separate timelock) and synced to pairs. | Queue + timelocked rotation. |
| `set_fee_to` (subsequent) | Timelocked 48h | All pairs after sync | Same; 48h notice. | Cancel or counter-queue. |
| `execute_set_protocol_fee_percent` | Timelocked 48h | All pairs after sync | Up to **100% markup** on LP fee. Trader cost = LP fee × (1 + percent/100). At 1% LP fee tier, max trader cost = 2%. LPs unaffected (they always receive the LP-fee portion). | Queue counter-value. |
| `execute_set_protocol_fee_enabled` | Timelocked 48h | All pairs after sync | Turns protocol fees on. Requires `fee_to != zero` and `percent > 0` already set. | Queue `enabled=false`. |
| `execute_add_fee_tier` | Timelocked 48h | New pairs only | Adds a tier between 1 and 4999 bps. **Existing pairs snapshot their tier at registration** — adding a tier does not change any existing pair. | Queue `remove_fee_tier`. |
| `execute_remove_fee_tier` | Timelocked 48h | New pairs only | Removes a tier from the whitelist. Existing pairs at that tier continue trading. Cannot remove the last tier. | Queue `add_fee_tier`. |
| `execute_set_admin` | Timelocked 48h | Whole factory | Replaces the admin key. The OLD admin is overwritten; recovery from this point requires the NEW key. **Terminal action under successful attack.** | Pre-execute: cancel. Post-execute: no recovery from the contract. |
| `execute_clear_pair_slot` | Timelocked 48h | One pair's registry entry | Retracts a pair from the latest-at-base pointer. **Does not touch the pair contract** — LPs can still withdraw via direct pair calls. SDK routing stops pointing there. | Re-register a fresh pair at a higher version. |

### Constructor

`constructor(admin)` runs once at deploy. It seeds three default fee tiers (5/25/100 bps), `protocol_fee_percent=20`, `protocol_fee_enabled=false`, and `fee_to=zero`. It rejects `admin = zero` (otherwise the factory is permanently bricked: every privileged path gates on `msg_sender == admin`).

### Bounded-value summary

| Parameter | Bound | Source |
|---|---|---|
| `protocol_fee_percent` | 0–100 (inclusive cap, % markup on LP fee) | `queue_set_protocol_fee_percent` |
| `tier_bps` | 1–4999 (exclusive upper) | `queue_add_fee_tier`, `queue_remove_fee_tier` |
| Min allowed-tier count | ≥ 1 (last tier non-removable) | `queue_remove_fee_tier` |
| `admin` | non-zero | constructor + `queue_set_admin` |
| `fee_to` | non-zero (when set or when enabling fees) | `set_fee_to`, `queue_set_protocol_fee_enabled` |

## 4. Attack vector walks

### 4.A Fee-tier manipulation

**Goal.** Force LPs onto a predatory fee tier, or brick new-pair creation.

**Reachable mutations.**
1. Add a hostile tier (e.g. 4999 bps = 49.99%): timelocked 48h.
2. Remove a useful tier (e.g. 25 bps): timelocked 48h.
3. Set `protocol_fee_percent` to its 100 cap: timelocked 48h.

**What it cannot do.**
- Change the tier of an existing pair. Pairs snapshot their `fee_tier_bps` at registration; the whitelist gate runs only on `register_pair`. Adding a 4999-bps tier does nothing to a 25-bps pair already in the registry.
- Brick existing pairs. Removing a tier the existing pair uses also does nothing — the pair already passed the whitelist check at registration time.
- Force LPs anywhere. LPs choose which pair to add liquidity to.

**Maximum extractable value.** Bounded by traders who are tricked into routing through a newly-registered hostile-tier pair during the attack window. SDK and front-end should refuse to route through tiers above some operator-chosen threshold (e.g. 200 bps). With that off-chain guard, this attack's economic extraction is near zero.

**Net.** Limited blast radius. Attack is annoying (bricks new-pair creation, adds noise to the tier list) but not LP-draining.

### 4.B fee_to rotation extraction

**Goal.** Redirect protocol-fee accrual to the attacker's address.

**Reachable mutation flow.**
1. (If `fee_to` was never bootstrapped) `set_fee_to(attacker_addr)` — IMMEDIATE.
2. (If already bootstrapped) `queue_set_fee_to(attacker_addr)` → 48h → `set_fee_to(attacker_addr)`.
3. If protocol fees are off: `queue_set_protocol_fee_enabled(true)` → 48h → execute. (Requires `fee_to != zero` and `percent > 0` at queue time.)
4. After execute, `sync_protocol_fee(pair)` for every target pair to propagate. Sync is immediate.

**Bootstrap-immediate is the operationally-critical path.** If the operator deploys the factory and does not call `set_fee_to(operator_safe_addr)` immediately, an attacker who later compromises the admin key gets the immediate-set bootstrap path for the *recipient* only: `set_fee_to(attacker_addr)` lands with no 48h delay. Turning protocol fees ON is a separate action with no immediate path — `queue_set_protocol_fee_enabled(true)` always routes through the 48h public timelock before `execute_set_protocol_fee_enabled`. So the attacker can point the recipient at themselves instantly, but must still wait the 48h timelock to enable fees (per the numbered flow above).

**Operational requirement #1: bootstrap `fee_to` to a safe address as the very first post-deploy admin transaction.** Even if protocol fees are disabled. This forces all subsequent `set_fee_to` calls into the 48h timelock path.

**Maximum extractable value once fees are flowing to attacker.** Per-pair: `swap_volume × LP_fee_bps × (protocol_fee_percent / 100) / 10000` per swap. The protocol fee is **not paid out of LP reserves directly** — it accrues as LP-token mints to `fee_to` on subsequent mint/burn events (the standard Uniswap-V2 protocol-fee mechanism). So the attacker's extraction is gradual: it depends on LPs adding/removing liquidity to crystallize the fee-LP. An attacker who cannot also influence LP behavior gets a slow drain, not a flash drain.

**Detection.** `ActionQueuedEvent` emits at queue time. Any chain monitor catches this within blocks. 48h is plenty for honest detection.

**Recovery (if honest admin retains the key).** `cancel_action(ACTION_SET_FEE_TO, attacker_addr)`. Immediate. But see §5: in a full key compromise, the honest party does not retain the key.

**Net.** Slow drain bounded by LP turnover. Honest operator with monitoring + multi-sig defeats it.

### 4.C pair-class-id swap

**Goal.** Bless a malicious pair bytecode class so that pairs deployed under it drain LP funds.

**Reachable mutation flow.**
1. `queue_set_pair_class_id(malicious_class, version_n+1)` → 48h → `set_pair_class_id(malicious_class, version_n+1)`.

**What it cannot do.**
- Change the bytecode of any existing pair contract. Pairs are immutable. A class-ID change updates a registry pointer used by `register_pair` to validate future deployments.
- Force any user's tokens into a new pair. Users (and the SDK) explicitly target pair addresses.

**The actual exploit path.**
- Attacker swaps the blessed class to a malicious one.
- Attacker (or any party) deploys a new pair under the new class. `register_pair` accepts it because the class hash matches the new blessing.
- SDK / front-end starts routing through the new pair (it's the latest version at that base). Users add liquidity to the malicious pair; malicious bytecode drains.
- Front-end mitigation: pin the SDK to a specific class-ID range and refuse newer classes until reviewed.

**LP-funds-already-deposited risk.** Zero for funds in pairs registered before the swap. Real for funds added to the post-swap pair.

**Operational requirement #2: SDK and front-end should freeze on class-ID changes for human review before exposing the new version to users.** A CI check that fails when the published SDK's expected class-ID drifts from on-chain is sufficient.

**Recovery.** Counter-queue back to the known-good class. 48h. Or front-end refuses to route through the new version.

**Net.** Pair-class-id swap is the scariest function on paper but actually has the smallest LP-exposure surface, because it cannot retroactively touch any deployed pair. The operational requirement is detection + SDK pin, not a contract change.

## 5. Single-key recovery: structural limit

`cancel_action` is admin-immediate, and it can cancel any queued action -- including a `queue_set_admin` rotation:

1. Operator queues `set_admin(new_safe_addr)`. 48h timer starts.
2. Attacker observes the queue (public `ActionQueuedEvent`) and calls `cancel_action(ACTION_SET_ADMIN, new_safe_addr)`. Queue cleared.
3. Operator re-queues. Attacker re-cancels. Indefinitely.

With a single signer there is no second party holding independent rotation power, so **a fully-compromised single-key admin is terminal: there is no on-chain recovery.** The factory keeps operating, but the attacker holds the only rotation power.

This never traps LP funds. Pair contracts are immutable and `remove_liquidity` works regardless of factory state, so LPs can always withdraw directly from the pair while any incident is resolved.

Operational defenses, incident-response procedures, and key-custody requirements are maintained separately by the operator.

## 6. Detection summary

Every privileged mutation emits a chain event:
- `ActionQueuedEvent(action_type, value, execute_after)` — at queue time
- `ActionExecutedEvent` (or specific `*ChangedEvent`) — at execute time
- `ActionCancelledEvent(action_type, value)` — at cancellation
- `PairPausedEvent(pair)` / `PairUnpausedEvent(pair)` — immediate
- `RegistrationPausedEvent` / `RegistrationUnpausedEvent` — immediate, at `pause_registration` / `unpause_registration`
- `ProtocolFeeSyncedEvent(pair)` — at sync
- `AdminChangedEvent(new_admin)` — at admin rotation execute
- `FeeToChangedEvent(new_fee_to)` — at fee_to set/rotation

A chain monitor that watches the factory address and alerts on **any** of these events catches every privileged mutation within block-finality time. The 48h timelock window then provides reaction time for the timelocked subset.
