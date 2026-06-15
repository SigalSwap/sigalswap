// Minimal test contract for flash swap callback testing.
// Deployed in TXE tests to receive flash_swap callbacks from SigalSwapPair.

use aztec::macros::aztec;

#[aztec]
pub contract FlashBorrower {
    use aztec::{
        macros::functions::{external, initializer},
        protocol::{address::AztecAddress, traits::{FromField, ToField}},
    };
    use token::Token;

    #[initializer]
    #[external("public")]
    fn constructor() {}

    // Repays all token balances back to the pair.
    // Pre-fund this contract with extra tokens to cover the flash loan fee.
    #[external("public")]
    fn flash_callback(
        pair: Field,
        token0: Field,
        token1: Field,
        _amount0: Field,
        _amount1: Field,
        _data: Field,
    ) {
        let pair_addr = AztecAddress::from_field(pair);
        let token0_addr = AztecAddress::from_field(token0);
        let token1_addr = AztecAddress::from_field(token1);

        let bal0: u128 = self.view(Token::at(token0_addr).balance_of_public(self.address));
        if bal0 > 0 as u128 {
            Token::at(token0_addr)
                .transfer_in_public(self.address, pair_addr, bal0, 0)
                .call(self.context);
        }

        let bal1: u128 = self.view(Token::at(token1_addr).balance_of_public(self.address));
        if bal1 > 0 as u128 {
            Token::at(token1_addr)
                .transfer_in_public(self.address, pair_addr, bal1, 0)
                .call(self.context);
        }
    }

    // Does nothing -- for testing that non-repayment reverts the flash swap.
    #[external("public")]
    fn bad_callback(
        _pair: Field,
        _token0: Field,
        _token1: Field,
        _amount0: Field,
        _amount1: Field,
        _data: Field,
    ) {
        // Intentionally empty: no repayment
    }

    // Repays exactly 1 unit of whichever token(s) were borrowed. Passes the
    // pair's `INSUFFICIENT_REPAYMENT` check (amount > 0) but fails the K
    // invariant for any non-trivial borrow -- used by the K invariant test
    // to verify verify_k_invariant is wired correctly into flash_swap.
    #[external("public")]
    fn partial_repay_callback(
        pair: Field,
        token0: Field,
        token1: Field,
        amount0: Field,
        amount1: Field,
        _data: Field,
    ) {
        let pair_addr = AztecAddress::from_field(pair);
        let token0_addr = AztecAddress::from_field(token0);
        let token1_addr = AztecAddress::from_field(token1);
        let one_unit: u128 = 1;

        if amount0 != 0 {
            Token::at(token0_addr)
                .transfer_in_public(self.address, pair_addr, one_unit, 0)
                .call(self.context);
        }
        if amount1 != 0 {
            Token::at(token1_addr)
                .transfer_in_public(self.address, pair_addr, one_unit, 0)
                .call(self.context);
        }
    }

    // Callback for SigalSwapPair::swap_exact_out_public.
    // Transfers `amount` of `token` back to the pair. Pre-fund this contract
    // with enough tokens to cover the requested amount.
    #[external("public")]
    fn swap_payment_callback(
        pair: Field,
        token: Field,
        amount: Field,
    ) {
        let pair_addr = AztecAddress::from_field(pair);
        let token_addr = AztecAddress::from_field(token);
        let amount_u128 = amount as u128;
        Token::at(token_addr)
            .transfer_in_public(self.address, pair_addr, amount_u128, 0)
            .call(self.context);
    }

    // Empty callback for swap_exact_out_public -- does not pay.
    // Used to trigger INSUFFICIENT_PAYMENT on the pair side.
    #[external("public")]
    fn bad_swap_payment_callback(
        _pair: Field,
        _token: Field,
        _amount: Field,
    ) {
        // Intentionally empty: no repayment
    }

    // Reentrant callback used by the reentrancy lock-coverage test. Instead
    // of repaying the flash loan, calls back into the pair's public
    // `sync()` function, which also acquires the reentrancy lock. If the
    // pair's reentrancy guard holds, its `assert(!locked, "LOCKED")` at
    // the top of `sync` fires and the reentrant call reverts. If the lock
    // were ever released before the callback (or never acquired), the
    // reentry would succeed and the test would pass silently.
    //
    // `sync` is chosen because it's public (dispatchable from another
    // public context), no-argument, and acquires the lock unconditionally.
    #[external("public")]
    fn reentrant_sync_callback(
        pair: Field,
        _token0: Field,
        _token1: Field,
        _amount0: Field,
        _amount1: Field,
        _data: Field,
    ) {
        let pair_addr = AztecAddress::from_field(pair);
        let sync_selector =
            aztec::protocol::abis::function_selector::FunctionSelector::from_signature("sync()");
        let _ = self.context.call_public_function(
            pair_addr,
            sync_selector,
            [],
            aztec::context::gas::GasOpts::default(),
        );
    }
}
