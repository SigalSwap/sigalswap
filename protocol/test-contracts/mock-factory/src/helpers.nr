use aztec::protocol::{address::AztecAddress, hash::poseidon2_hash, traits::ToField};

/// Defensively-sorted hash of the full (token0, token1, fee_tier_bps, version)
/// tuple used as the registration key in MockFactory's `registered_by_pair_key`
/// storage. Mirrors the real factory's `compute_pair_key` -- the 4-tuple the
/// router's `get_pair_versioned_public` check keys on -- so router tests verify
/// the router passes the correct fee_tier and version, not just the token pair.
pub fn pair_key(token0: AztecAddress, token1: AztecAddress, fee_tier_bps: u32, version: u32) -> Field {
    let (t0, t1) = if (token0.to_field() as u128) < (token1.to_field() as u128) {
        (token0, token1)
    } else {
        (token1, token0)
    };
    poseidon2_hash([t0.to_field(), t1.to_field(), fee_tier_bps as Field, version as Field])
}
