// Drift probes for the router's off-chain multi-hop quote utilities:
//   - quote_exact_in_multi_hop(path, pairs, path_length, amount_in) -> u128
//   - quote_exact_out_multi_hop(path, pairs, path_length, amount_out) -> u128
//
// These utilities walk the path and call each pair's quote_amount_out /
// quote_amount_in utility through v4.3's end-to-end cross-contract utility
// call mechanism (#23007, #23064, #22822). One TXE-side simulate call replaces
// the N pair-level calls the SDK would have otherwise chained from TypeScript.
//
// TXE limitation: happy-path tests that seed pool reserves via add_liquidity
// (the only way to get non-zero reserves) and then execute_utility a quote
// fail under TXE with "Nullifier read request at index 5 is reading an
// unknown nullifier" -- the same authwit-state-bleed issue documented in
// router_integration.nr's header. Round-trip math is exercised end-to-end
// by the SDK e2e suite against the real sandbox, which doesn't suffer the
// TXE-internal state bleed. The boundary asserts here run pre-pair-call so
// no liquidity setup is needed.

use sigalswap_periphery::{libraries::MAX_HOPS, SigalSwapRouter};
use crate::test::utils::setup_single_pair;
use aztec::{
    protocol::address::AztecAddress,
    test::helpers::test_environment::TestEnvironment,
};

fn build_path(tokens: [AztecAddress]) -> [AztecAddress; MAX_HOPS + 1] {
    let mut out: [AztecAddress; MAX_HOPS + 1] = [AztecAddress::zero(); MAX_HOPS + 1];
    for i in 0..MAX_HOPS + 1 {
        if i < tokens.len() {
            out[i] = tokens[i];
        }
    }
    out
}

fn build_pairs(addrs: [AztecAddress]) -> [AztecAddress; MAX_HOPS] {
    let mut out: [AztecAddress; MAX_HOPS] = [AztecAddress::zero(); MAX_HOPS];
    for i in 0..MAX_HOPS {
        if i < addrs.len() {
            out[i] = addrs[i];
        }
    }
    out
}

/// path_length = 1 must revert with PATH_TOO_SHORT. The validator rejects
/// before any pair call, so no liquidity setup is needed.
#[test(should_fail_with = "PATH_TOO_SHORT")]
unconstrained fn test_quote_exact_in_path_length_one_reverts() {
    let (env, router_address, _p, token0, _token1, _lp, _admin) = setup_single_pair();
    let path = build_path(&[token0]);
    let pairs = build_pairs(&[]);

    let _ = env.execute_utility(
        SigalSwapRouter::at(router_address).quote_exact_in_multi_hop(path, pairs, 1, 100 as u128),
    );
}

/// path_length > MAX_HOPS + 1 must revert with PATH_TOO_LONG.
#[test(should_fail_with = "PATH_TOO_LONG")]
unconstrained fn test_quote_exact_in_path_length_overflow_reverts() {
    let (env, router_address, _p, token0, token1, _lp, _admin) = setup_single_pair();
    let path = build_path(&[token0, token1]);
    let pairs = build_pairs(&[]);

    let _ = env.execute_utility(
        SigalSwapRouter::at(router_address).quote_exact_in_multi_hop(
            path, pairs, (MAX_HOPS as u32) + 2, 100 as u128,
        ),
    );
}

/// amount_in = 0 must revert. The utility asserts on amount_in > 0 before any
/// pair call, so no liquidity setup is needed.
#[test(should_fail_with = "ZERO_INPUT_AMOUNT")]
unconstrained fn test_quote_exact_in_zero_amount_reverts() {
    let (env, router_address, pair_address, token0, token1, _lp, _admin) = setup_single_pair();
    let path = build_path(&[token0, token1]);
    let pairs = build_pairs(&[pair_address]);

    let _ = env.execute_utility(
        SigalSwapRouter::at(router_address).quote_exact_in_multi_hop(path, pairs, 2, 0 as u128),
    );
}

/// amount_out = 0 must revert on the symmetric exact-out walk.
#[test(should_fail_with = "ZERO_OUTPUT_AMOUNT")]
unconstrained fn test_quote_exact_out_zero_amount_reverts() {
    let (env, router_address, pair_address, token0, token1, _lp, _admin) = setup_single_pair();
    let path = build_path(&[token0, token1]);
    let pairs = build_pairs(&[pair_address]);

    let _ = env.execute_utility(
        SigalSwapRouter::at(router_address).quote_exact_out_multi_hop(path, pairs, 2, 0 as u128),
    );
}
