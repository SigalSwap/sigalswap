// Test-only fixture that impersonates a future SigalSwapPair bytecode at
// VERSION = 2. Used exclusively by factory upgrade-path tests to exercise
// version progression, post-upgrade queries, rollback via clear_pair_slot,
// and NEW_LATEST_NOT_REGISTERED (which cannot be reached with only v1
// bytecode available).
//
// Surface area is deliberately minimal: we only implement what the factory
// touches during register_pair (get_version) and at the end of register_pair
// (set_protocol_fee). Constructor signature matches SigalSwapPair exactly so
// init_hash computation at the factory aligns. Cross-contract dispatch is
// selector-based, so as long as these functions match the real pair's
// signatures they route correctly when the factory calls through
// `SigalSwapPair::at(mock_addr).<method>`.

use aztec::macros::aztec;

pub global VERSION: u32 = 2;

#[aztec]
pub contract MockPairV2 {
    use aztec::{
        macros::{functions::{external, initializer, view}, storage::storage},
        protocol::address::AztecAddress,
    };

    #[storage]
    struct Storage<Context> {}

    // Match SigalSwapPair::constructor(token0, token1, factory, fee_tier_bps)
    // exactly. Args are ignored; the fixture doesn't hold funds or state, it
    // only exists to satisfy factory registration checks. No liquidity_token
    // arg: the real pair derives its LP token address internally from
    // `self.address`, so there's no constructor arg to mirror.
    #[initializer]
    #[external("public")]
    fn constructor(
        _token0: AztecAddress,
        _token1: AztecAddress,
        _factory: AztecAddress,
        _fee_tier_bps: u32,
    ) {}

    // The factory cross-checks this return against its blessed
    // pair_class_version during register_pair.
    #[external("public")]
    #[view]
    fn get_version() -> pub u32 {
        crate::VERSION
    }

    // The factory calls this at the end of register_pair to push protocol fee
    // settings. No-op: this fixture has no protocol-fee state to update.
    #[external("public")]
    fn set_protocol_fee(
        _fee_to: AztecAddress,
        _percent: u32,
        _active: bool,
    ) {}

    // The factory probes this selector with a no-op set_pause(false) during
    // register_pair, and calls it from pause_pair / unpause_pair. A blessed v2
    // pair MUST preserve the set_pause(bool) ABI so the immutable factory keeps
    // pause control; this fixture mirrors it as a no-op (no pause state).
    #[external("public")]
    fn set_pause(_paused: bool) {}
}
