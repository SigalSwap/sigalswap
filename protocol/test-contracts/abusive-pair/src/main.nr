// Mock "malicious pair" for adversarial testing of the router's
// `swap_payment_callback` defense-in-depth. Impersonates
// `SigalSwapPair::swap_exact_out_public`'s selector but misuses the
// callback in four distinct ways. Each mode is paired with one of the
// router-side assertions, so a change that weakens any of those
// assertions surfaces as a test failure.

use aztec::macros::aztec;

#[aztec]
pub contract AbusivePair {
    use aztec::{
        context::gas::GasOpts,
        macros::{functions::{external, initializer, view}, storage::storage},
        protocol::{abis::function_selector::FunctionSelector, address::AztecAddress, traits::ToField},
        state_vars::PublicMutable,
    };
    use sigalswap_core::types::PairConfig;

    // Abuse mode selectors:
    //   0 = OVERCHARGE         -- request 2 * amount_in_max in the callback.
    //                              Trips EXCESSIVE_CALLBACK_AMOUNT.
    //   1 = WRONG_TOKEN        -- request amount_in_max of `wrong_token` instead
    //                              of token_in. Trips UNEXPECTED_TOKEN.
    //   2 = WRONG_PAIR_ADDRESS -- pass `wrong_pair` as the callback's `pair`
    //                              argument while msg_sender stays as this
    //                              contract. Trips UNAUTHORIZED_CALLBACK because
    //                              pair_addr != msg_sender.
    //   3 = HUGE_AMOUNT        -- pass a Field amount > u128::MAX so the router's
    //                              `amount as u128 as Field == amount` round-trip
    //                              check fails. Trips AMOUNT_OVERFLOW.
    //   4 = DOUBLE_INVOKE      -- call the callback twice with `amount_in_max`.
    //                              Each individual call clears the router's
    //                              `<= expected_callback_amount` check, but the
    //                              cumulative consumption (2 * amount_in_max)
    //                              exceeds what the router's exact-out caller
    //                              advanced. Trips CONSUMED_EXCEEDS_REQUESTED on
    //                              the refund path. Reachable only when the
    //                              router holds pre-existing balance >= a second
    //                              amount_in_max of `token_in` (donations or
    //                              cyclic dust) -- the canary funds the router
    //                              accordingly before invoking.
    #[storage]
    struct Storage<Context> {
        abuse_mode: PublicMutable<u32, Context>,
        wrong_token: PublicMutable<AztecAddress, Context>,
        wrong_pair: PublicMutable<AztecAddress, Context>,
        // Tokens this fixture claims to trade. The router's per-hop
        // PATH_TOKEN_MISMATCH check reads `get_config().token{0,1}` and
        // requires the swap's (token_in, token_out) to be drawn from that
        // pair; honest reflection here keeps the abuse modes reachable.
        // Zero by default; set via `set_tokens` from the test fixture.
        token0: PublicMutable<AztecAddress, Context>,
        token1: PublicMutable<AztecAddress, Context>,
    }

    #[initializer]
    #[external("public")]
    fn constructor() {}

    /// Mirrors `SigalSwapPair::get_config()` so the router's typed view
    /// call dispatches to this contract when pointed at this address.
    /// Returns the tokens declared via `set_tokens` (zero before that's
    /// called) and zeros for everything else. The router's per-hop
    /// PATH_TOKEN_MISMATCH check reads token0/token1 from this view, so
    /// the fixture's setup MUST call `set_tokens(t0, t1)` and register
    /// the abusive pair under those same tokens in MockFactory before
    /// the abuse modes are reachable.
    #[external("public")]
    #[view]
    fn get_config() -> PairConfig {
        PairConfig {
            token0: self.storage.token0.read(),
            token1: self.storage.token1.read(),
            factory: AztecAddress::zero(),
            fee_tier_bps: 0,
            version: 0,
            lp_token: AztecAddress::zero(),
        }
    }

    /// Set the tokens this fixture pretends to trade. Called once during
    /// test setup so router-side per-hop checks (PAIR_NOT_REGISTERED +
    /// PATH_TOKEN_MISMATCH) pass and execution reaches the abuse-mode
    /// dispatch in `swap_exact_out_public`.
    #[external("public")]
    fn set_tokens(token0: AztecAddress, token1: AztecAddress) {
        self.storage.token0.write(token0);
        self.storage.token1.write(token1);
    }

    #[external("public")]
    fn set_abuse_mode(
        mode: u32,
        wrong_token: AztecAddress,
        wrong_pair: AztecAddress,
    ) {
        self.storage.abuse_mode.write(mode);
        self.storage.wrong_token.write(wrong_token);
        self.storage.wrong_pair.write(wrong_pair);
    }

    // Matches SigalSwapPair::swap_exact_out_public exactly so the
    // router's typed call resolves to this selector when pointed at this address.
    #[external("public")]
    fn swap_exact_out_public(
        token_in: AztecAddress,
        _token_out: AztecAddress,
        _amount_out: u128,
        amount_in_max: u128,
        _recipient: AztecAddress,
        callback_contract: AztecAddress,
        callback_selector: FunctionSelector,
    ) {
        let mode = self.storage.abuse_mode.read();

        let pair_field: Field = if mode == 2 {
            self.storage.wrong_pair.read().to_field()
        } else {
            self.address.to_field()
        };

        let token_field: Field = if mode == 1 {
            self.storage.wrong_token.read().to_field()
        } else {
            token_in.to_field()
        };

        let amount_field: Field = if mode == 0 {
            (amount_in_max * 2) as Field
        } else if mode == 3 {
            // 2^128, exactly one above the u128 range. Casting to u128
            // truncates to 0; casting that 0 back to Field gives 0, which
            // does not equal the original 2^128 -- AMOUNT_OVERFLOW fires.
            0x100000000000000000000000000000000
        } else {
            amount_in_max as Field
        };

        let _result = self.context.call_public_function(
            callback_contract,
            callback_selector,
            [pair_field, token_field, amount_field],
            GasOpts::default(),
        );

        // DOUBLE_INVOKE: fire a second callback with the same args. The
        // router's `swap_payment_callback` accepts each call individually
        // (amount_u128 <= expected_callback_amount); the cumulative
        // consumption blows past amount_in_max and trips the router's
        // CONSUMED_EXCEEDS_REQUESTED on the refund subtraction.
        if mode == 4 {
            let _result2 = self.context.call_public_function(
                callback_contract,
                callback_selector,
                [pair_field, token_field, amount_field],
                GasOpts::default(),
            );
        }
    }
}
