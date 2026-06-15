// Test-only stand-in for SigalSwapFactory's `get_pair_versioned_public` view.
// Periphery router tests pass this contract's address as `router.factory` so
// the router's PAIR_NOT_REGISTERED check has a real public-view target to
// dispatch to. Tests pre-register their pair via `set_registered_pair` so
// the check passes; canaries that exercise the unregistered case leave the
// relevant slot at the zero default so the check fires.
//
// Storage shape: Map<Field, pair_address> keyed on a defensively-sorted hash
// of the full (token0, token1, fee_tier_bps, version) tuple. Mirrors the real
// factory's `compute_pair_key` exactly so router tests verify the router passes
// the correct fee_tier and version to `get_pair_versioned_public`, not just the
// token pair. The defensive token sort also stops a token that's "smaller" in
// one pair and "larger" in another (e.g. setup_multi_hop's middle token in
// path A->B->C) from colliding across registrations.
//
// Selector match: `get_pair_versioned_public`'s signature mirrors
// `SigalSwapFactory::get_pair_versioned_public` exactly so the router's
// typed call dispatches to this contract.

use aztec::macros::aztec;

mod helpers;

#[aztec]
pub contract MockFactory {
    use aztec::{
        macros::{functions::{external, initializer, view}, storage::storage},
        protocol::address::AztecAddress,
        state_vars::{Map, PublicMutable},
    };
    use crate::helpers::pair_key;

    #[storage]
    struct Storage<Context> {
        registered_by_pair_key: Map<Field, PublicMutable<AztecAddress, Context>, Context>,
    }

    #[initializer]
    #[external("public")]
    fn constructor() {}

    /// Pre-register a pair for queries against the full
    /// `(token0, token1, fee_tier_bps, version)` tuple. Tokens are defensively
    /// sorted so callers don't need to pass them in canonical order. A
    /// subsequent `get_pair_versioned_public(token0, token1, fee_tier_bps,
    /// version)` with the SAME fee_tier/version returns `pair`; a mismatched
    /// fee_tier or version returns the zero default (matching the real factory).
    #[external("public")]
    fn set_registered_pair(
        token0: AztecAddress,
        token1: AztecAddress,
        fee_tier_bps: u32,
        version: u32,
        pair: AztecAddress,
    ) {
        let key = pair_key(token0, token1, fee_tier_bps, version);
        self.storage.registered_by_pair_key.at(key).write(pair);
    }

    #[external("public")]
    #[view]
    fn get_pair_versioned_public(
        token0: AztecAddress,
        token1: AztecAddress,
        fee_tier_bps: u32,
        version: u32,
    ) -> pub AztecAddress {
        let key = pair_key(token0, token1, fee_tier_bps, version);
        self.storage.registered_by_pair_key.at(key).read()
    }
}
