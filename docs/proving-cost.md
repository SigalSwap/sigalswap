# SigalSwap proving-cost profile

Per-function gate counts on aztec-packages v4.3.0, captured via `aztec profile gates` on each compiled contract artifact. These are the user-side private circuit sizes; aggregate end-user proving cost is the sum of the entry function plus any private callees in the user's private-call tree.

Numbers below are **gate counts** (the unit `bb gates` reports for ultra-honk circuits) measured 2026-05-25 on v4.3.0 stable. Gate count is the dominant input to proving time: time scales roughly linearly with gates for a fixed prover backend on fixed hardware. Concrete proving-time measurements on consumer hardware are pending an Aztec team consultation.

## Per-function gate counts

### SigalSwapPair (`protocol/core/`)

| Function | Gates |
|---|---:|
| `add_liquidity` | 16,353 |
| `remove_liquidity` | 16,078 |
| `swap_exact_in` | 12,040 |
| `swap_exact_out` | 12,116 |
| `skim` | 11,553 |

All public-direct entries (`add_liquidity_public`, `remove_liquidity_public`, `swap_*_public`, `flash_swap`, `sync`) execute as public functions and have **zero user-side proving cost** — those are sequencer-side state updates, not private circuits.

### SigalSwapRouter (`protocol/periphery/`)

| Function | Gates |
|---|---:|
| `add_liquidity` | 8,594 |
| `remove_liquidity` | 8,288 |
| `swap_exact_in` | 8,289 |
| `swap_exact_out` | 8,364 |
| `swap_exact_in_multi_hop` | 8,541 |
| `swap_exact_out_multi_hop` | 8,875 |

The router is a thin glue layer — its own private entries are very light. The constraint cost of the swap chain itself lives in the pair's public continuation (no user proving).

### SigalSwapLPToken (`protocol/lp-token/`)

The LP Token follows the canonical Aztec Token pattern (`BalanceSet`, partial notes, authwit consumption). These are the heaviest functions a user invokes:

| Function | Gates |
|---|---:|
| `transfer_in_private` | 131,496 |
| `transfer_to_public_and_prepare_private_balance_increase` | 112,216 |
| `finalize_transfer_to_private_from_private` | 111,972 |
| `transfer_to_public` | 108,773 |
| `burn_private` | 108,697 |
| `_recurse_subtract_balance` | 45,118 |
| `transfer` | 23,065 |
| `private_get_name` / `private_get_symbol` / `private_get_decimals` | ~11,008 |
| `prepare_private_balance_increase` | 7,416 |
| `transfer_to_private` | 7,503 |
| `cancel_authwit` | 7,192 |

These gate counts come from the underlying `BalanceSet` machinery and partial-note operations that the Aztec Token reference contract uses. SigalSwap inherits this cost; reducing it would require diverging from the canonical Token interface, which is not in scope for v1.

### Standard Aztec Token (used as pair tokens)

Identical structure to the LP Token, since both implement the same Token interface. Numbers match within rounding.

### SigalSwapFactory (`protocol/factory/`)

No private functions. All governance entries (`register_pair`, `set_fee_to`, `set_protocol_fee_percent`, timelock queue/execute, etc.) are public. **Zero user-side proving cost for factory operations.**

## End-user aggregate cost per flow

The user's PXE proves the entire chain of private functions invoked within the tx. For a typical end-user operation, the aggregate is the entry function plus any private token transfers the entry calls into.

| Flow | Composition | Total private gates |
|---|---|---:|
| Single-hop private swap | router.swap_exact_in (8.3K) + token transfer_to_public_and_prepare (112.2K) | **~120K** |
| Multi-hop private swap (any N hops) | router.swap_exact_in_multi_hop (8.5K) + 1× token transfer_to_public_and_prepare (112.2K) | **~121K** |
| Add liquidity | router.add_liquidity (8.6K) + 2× token transfer_to_public_and_prepare (224.4K) | **~233K** |
| Remove liquidity | router.remove_liquidity (8.3K) + LP transfer_to_public (108.8K) | **~117K** |
| Direct pair swap (private) | pair.swap_exact_in (12.0K) + 1 token transfer (112.2K) | **~124K** |

**Key observation:** SigalSwap-specific code contributes 8K–17K gates per flow. The remaining 100K–225K is canonical Aztec Token machinery. Roughly 90% of user proving cost is Token-interface overhead, not SigalSwap logic. This means future Aztec framework optimizations to the standard Token pattern flow directly through to SigalSwap users without contract-level work on our side.

**Multi-hop note:** Multi-hop swaps cost the same on the user side as single-hop. Each hop's pair swap runs in the public continuation (sequencer-side), so adding hops increases public execution but not user proving. The router's `swap_exact_in_multi_hop` is only ~250 gates heavier than the single-hop variant.

## How this maps to proving time

Aztec's official guidance on "tolerable end-user proving cost" depends on the prover backend (currently UltraHonk via bb), the user's hardware, and the kernel-circuit contribution that wraps every app circuit. This needs an Aztec team consultation to pin down.

Rough order-of-magnitude reference points from publicly available Aztec benchmarks (subject to verification with the Aztec team):

- **Desktop CPU (8-core, ~3 GHz):** typically a few seconds for app circuits in the 100K–250K range, plus the kernel overhead.
- **Laptop CPU (4-core, ~2 GHz):** roughly 2–3× the desktop time.
- **Mobile-class CPU:** typically not viable for end-user proving in v4.3; users on mobile rely on hosted proving.

Once the Aztec team confirms the gates-to-time relationship for v4.3 bb-UltraHonk on representative consumer hardware, this section will be updated with concrete numbers. The structural claim — that SigalSwap's app circuits are well within the budget — should hold; the open question is what specific UX latency users experience.

## Comparison to the public-bytecode budget

Separately from private proving cost, Aztec also imposes a `MAX_PACKED_PUBLIC_BYTECODE_SIZE_IN_FIELDS = 3000` cap on each contract's public dispatch. From `project_aztec_v42_migration`:

| Contract | Public bytecode fields | vs 3000 cap |
|---|---:|---:|
| SigalSwapPair | 1,979 | 66% (1,021 headroom) |
| SigalSwapFactory | 1,054 | 35% |
| SigalSwapLPToken | 391 | 13% |
| SigalSwapRouter | 820 | 27% |

All four contracts fit comfortably under the cap. The pair has the tightest headroom; the v4 migration's bytecode bloat was the primary blocker, resolved by upstream PR #23161.

## Open questions for Aztec team consultation

These need definitive answers before the proving-cost section of the core README can ship concrete UX numbers:

1. What's the gates-to-time multiplier for bb-UltraHonk on v4.3 against a representative consumer desktop and laptop?
2. What's the kernel-circuit contribution per tx (constant per tx, multiplied by depth, etc.)?
3. Is there an Aztec-published threshold for "tolerable end-user proving latency" that integrators should target?
4. What hardware specs do Aztec docs assume for the "good UX" path? Self-hosted prover vs. hosted-prover model?
5. Are there v5+ improvements to the bb prover backend that meaningfully change the v4.3 numbers?
6. For the SigalSwap-specific entries (add_liquidity, swap, etc.), is there a known optimization at the framework level (e.g., reducing partial-note overhead, batching multiple transfers into one private call) that would improve our 90%-Token-overhead ratio?

## References

- Raw measurements: re-run `aztec profile gates` in each `protocol/<package>/target/` directory.
- Per-contract circuit listings emitted by `aztec profile gates`: this tool dispatches `bb gates --scheme chonk` against each artifact's circuit; see `~/.aztec/versions/4.3.0/node_modules/@aztec/aztec/dest/cli/cmds/profile_gates.js`.
