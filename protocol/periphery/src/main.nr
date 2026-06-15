// SPDX-License-Identifier: MIT
// Copyright (c) 2026 SigalSwap LLC

// SigalSwap Router - User-facing convenience layer (upgradeable, stateless)
//
// The pair contract handles the core private->public flow. The router adds:
// - Deadline enforcement
// - Multi-hop routing through public swap_exact_in_public()
//
// The SDK resolves pair addresses via the factory before calling the router.
// The router itself is stateless (no factory lookup in private context,
// since private functions cannot call utility functions cross-contract).

pub mod libraries; // pub so the sibling sigalswap_periphery_tests crate can reach MAX_HOPS etc.
// Integration tests (TXE) live in the sibling `sigalswap_periphery_tests` crate
// so the abusive_pair / mock_factory fixtures stay out of this production build.

use aztec::macros::aztec;

#[aztec]
pub contract SigalSwapRouter {
    use crate::libraries::{
        MAX_HOPS,
        validate_interface_fee_bips,
        validate_path_length,
        validate_path_no_cycle_to_final,
    };
    use sigalswap_core::pair::get_amounts_to_add;
    use aztec::{
        macros::{events::event, functions::{external, initializer, internal, only_self}, storage::storage},
        messages::message_delivery::MessageDelivery,
        protocol::{
            abis::function_selector::FunctionSelector,
            address::AztecAddress,
            traits::{FromField, Serialize},
        },
        state_vars::{PublicImmutable, PublicMutable},
    };
    use std::meta::derive;

    use sigalswap_core::SigalSwapPair;
    use sigalswap_factory::SigalSwapFactory;
    use token::Token;
    use uint_note::PartialUintNote;

    // Private events -- encrypted to the sender for wallet history.
    // Same shape as the pair's Private* events, but prefixed with Router to
    // avoid selector collision (Aztec requires unique event names per
    // compilation unit). Swap events are split by direction so field names
    // accurately describe what was known at emission time -- see the pair
    // contract's event block for the full rationale. Wallets should query
    // all four swap event types (pair exact-in/out + router exact-in/out)
    // for a complete history.

    #[derive(Serialize)]
    #[event]
    struct RouterSwapExactInEvent { token_in: AztecAddress, token_out: AztecAddress, amount_in: u128, amount_out_min: u128 }

    #[derive(Serialize)]
    #[event]
    struct RouterSwapExactOutEvent { token_in: AztecAddress, token_out: AztecAddress, amount_in_max: u128, amount_out: u128 }

    #[derive(Serialize)]
    #[event]
    struct RouterMintEvent { token0: AztecAddress, token1: AztecAddress, amount0_max: u128, amount1_max: u128 }

    #[derive(Serialize)]
    #[event]
    struct RouterBurnEvent { token0: AztecAddress, token1: AztecAddress, liquidity: u128 }

    #[derive(Serialize)]
    #[event]
    struct RouterSkimEvent { token: AztecAddress, recipient: AztecAddress, amount: u128 }

    #[storage]
    struct Storage<Context> {
        /// Factory address (informational -- SDK reads this to find pairs)
        factory: PublicImmutable<AztecAddress, Context>,

        /// True while a multi-hop swap is executing. Authorizes swap_payment_callback.
        /// Between transactions this is false, so the callback is blocked.
        hop_active: PublicMutable<bool, Context>,

        /// Expected callback parameters for the current hop. Written before each
        /// swap_exact_in_public call, verified in swap_payment_callback. Prevents a
        /// malicious pair from requesting payment for a different token or amount.
        expected_callback_token: PublicMutable<AztecAddress, Context>,
        expected_callback_amount: PublicMutable<u128, Context>,
    }

    #[external("public")]
    #[initializer]
    fn constructor(factory: AztecAddress) {
        // Defensive zero check. `factory` is PublicImmutable so a misdeploy
        // is unrecoverable -- every entry that resolves a pair would dispatch
        // to a non-existent contract and revert with an opaque "no contract"
        // error. Mirrors the analogous zero-arg checks on the pair constructor.
        assert(!factory.is_zero(), "ZERO_FACTORY");
        self.storage.factory.initialize(factory);
    }

    // ================================================================
    // Shared internal hop executors
    //
    // Both the 1-hop and N-hop public continuations delegate per-hop work
    // to these helpers so the logic lives in one place. Neither manages
    // `hop_active` -- the caller sets it true for the lifetime of the
    // full swap and clears it at the end. Both use min_out = 0 at the
    // pair level; callers enforce the user's post-fee minimum.
    // ================================================================

    /// Execute one exact-input hop against `pair` and return the amount of
    /// `token_out` received by the router.
    #[internal("public")]
    fn _execute_one_hop_exact_in(
        pair: AztecAddress,
        token_in: AztecAddress,
        token_out: AztecAddress,
        amount_in: u128,
    ) -> pub u128 {
        let callback_sel = FunctionSelector::from_signature(
            "swap_payment_callback(Field,Field,Field)",
        );

        self.storage.expected_callback_token.write(token_in);
        self.storage.expected_callback_amount.write(amount_in);

        let out_before = self.view(Token::at(token_out).balance_of_public(self.address));

        SigalSwapPair::at(pair)
            .swap_exact_in_public(
                token_in, token_out, amount_in, 0 as u128,
                self.address, self.address, callback_sel,
            )
            .call(self.context);

        let out_after = self.view(Token::at(token_out).balance_of_public(self.address));
        out_after - out_before
    }

    /// Execute one exact-output hop against `pair`. The pair delivers exactly
    /// `amount_out` of `token_out` and requests up to `amount_in_max` of
    /// `token_in` from the router's `swap_payment_callback`. Returns the
    /// amount of `token_in` actually consumed by the callback (always
    /// `<= amount_in_max`; the upper bound is enforced inside
    /// `swap_payment_callback` via `EXCESSIVE_CALLBACK_AMOUNT`).
    ///
    /// The consumed amount is measured here as the delta of the router's
    /// `token_in` public balance across the pair call. Measuring it
    /// per-hop (rather than aggregating across all hops in the caller)
    /// keeps each hop's accounting scoped to its own pair, so neither
    /// pre-existing router stuck balances nor same-token reuse across
    /// non-adjacent path positions can leak into another hop's refund.
    /// Robust against a pair invoking the callback more than once within
    /// a single `swap_*_public` execution -- the delta captures total
    /// consumption regardless.
    #[internal("public")]
    fn _execute_one_hop_exact_out(
        pair: AztecAddress,
        token_in: AztecAddress,
        token_out: AztecAddress,
        amount_out: u128,
        amount_in_max: u128,
    ) -> pub u128 {
        let callback_sel = FunctionSelector::from_signature(
            "swap_payment_callback(Field,Field,Field)",
        );

        self.storage.expected_callback_token.write(token_in);
        self.storage.expected_callback_amount.write(amount_in_max);

        let in_before = self.view(Token::at(token_in).balance_of_public(self.address));

        SigalSwapPair::at(pair)
            .swap_exact_out_public(
                token_in, token_out, amount_out, amount_in_max,
                self.address, self.address, callback_sel,
            )
            .call(self.context);

        let in_after = self.view(Token::at(token_in).balance_of_public(self.address));
        in_before - in_after
    }

    /// Clear the per-hop callback expectation slots. Called by the public
    /// continuations after the last hop completes. The `hop_active` flag is
    /// already the authoritative gate on `swap_payment_callback`; this
    /// additional zeroing is defensive -- leaves the storage in a clean
    /// "nothing in flight" state between transactions so a hypothetical
    /// future bug dropping the `hop_active` check can't pick up stale
    /// expectation state.
    #[internal("public")]
    fn _clear_callback_expectations() {
        self.storage.expected_callback_token.write(AztecAddress::zero());
        self.storage.expected_callback_amount.write(0 as u128);
    }


    /// Deduct an interface fee from an amount of `token` held by the router,
    /// transfer it to `fee_recipient`, and return the net remaining amount.
    /// No-op when `fee_bips == 0` or `fee_recipient == zero`.
    #[internal("public")]
    fn _deduct_interface_fee(
        token: AztecAddress,
        amount: u128,
        fee_recipient: AztecAddress,
        fee_bips: u32,
    ) -> pub u128 {
        // Reject self-recipient: the router never legitimately collects
        // interface fees. A frontend that passes `fee_recipient = router`
        // would otherwise no-op the transfer (self-transfer of `fee_amount`)
        // while still subtracting `fee_amount` from the user's output, leaving
        // the difference as router public balance drainable by anyone via
        // `skim_to`. Bounded at 5% by `validate_interface_fee_bips`, so this
        // is a footgun rather than a fund-loss path, but the assert closes
        // it cleanly at the boundary.
        assert(fee_recipient != self.address, "FEE_RECIPIENT_IS_ROUTER");
        if (fee_bips > 0) & !fee_recipient.is_zero() {
            let fee_amount = (amount * fee_bips as u128) / 10000;
            if fee_amount > 0 as u128 {
                Token::at(token)
                    .transfer_in_public(self.address, fee_recipient, fee_amount, 0)
                    .call(self.context);
                let net = amount - fee_amount;
                // Defense-in-depth: unreachable under MAX_INTERFACE_FEE_BIPS
                // = 500 cap (would require fee_bips >= 10000 to make
                // fee_amount == amount). Kept against a future cap-loosening
                // refactor that would otherwise let a 100% fee silently zero
                // the user's output.
                assert(net > 0 as u128, "FEE_EXCEEDS_OUTPUT");
                net
            } else {
                amount
            }
        } else {
            amount
        }
    }

    // ================================================================
    // Single-Pair Operations (SDK resolves pair address)
    // ================================================================

    /// Add liquidity via the router. The router pulls `amount_i_max` of
    /// each token from the user into its own public balance, then in the
    /// public continuation reads the pair's live reserves, computes the
    /// optimal pair-ratio match, transfers exactly that to the pair, and
    /// refunds the unused remainder back to the user (via partial notes
    /// completed in the same tx). This is the V2-router-equivalent pattern
    /// adapted for Aztec's amount-bound authwits: the user's authwit
    /// authorizes up to `amount_i_max`, but only the pair-ratio-matched
    /// portion actually leaves the router for the pair. Donations to the
    /// pair pre-existing this call are absorbed into reserves by the pair's
    /// V2-strict mint -- they cannot be extracted via this entry.
    #[external("private")]
    fn add_liquidity(
        pair: AztecAddress,
        token0: AztecAddress,
        token1: AztecAddress,
        liquidity_token: AztecAddress,
        amount0_max: u128,
        amount1_max: u128,
        amount0_min: u128,
        amount1_min: u128,
        deadline: u64,
        authwit_nonce: Field,
    ) {
        // Boundary zero-amount rejection: fail fast on a no-op input before
        // doing any work. A 0-amount input would otherwise proceed through the
        // transfer_to_public_and_prepare_private_balance_increase call below
        // and revert deeper at the pair's INSUFFICIENT_LIQUIDITY_MINTED. The
        // authwit is preserved either way -- a failed tx commits no nullifier
        // regardless of where it reverts (see docs/aztec-subtleties.md); this
        // fast-fail just saves the wasted proving/gas and gives a clean,
        // specific revert (ZERO_INPUT_AMOUNT) instead of a deep pair revert.
        assert(amount0_max > 0 as u128, "ZERO_INPUT_AMOUNT");
        assert(amount1_max > 0 as u128, "ZERO_INPUT_AMOUNT");

        let sender = self.msg_sender();

        // Pull both tokens from user into the router's own public balance.
        // Each call also prepares a partial note for refunding the unused
        // portion (amount_max - optimal) back to the user's private balance
        // in the public continuation.
        let refund0_note = self.call(
            Token::at(token0).transfer_to_public_and_prepare_private_balance_increase(
                sender, self.address, amount0_max, authwit_nonce,
            ),
        );
        let refund1_note = self.call(
            Token::at(token1).transfer_to_public_and_prepare_private_balance_increase(
                sender, self.address, amount1_max, authwit_nonce,
            ),
        );

        // Prepare LP token partial note for user
        let lp_note = self.call(
            Token::at(liquidity_token).prepare_private_balance_increase(sender),
        );

        self.emit(RouterMintEvent { token0, token1, amount0_max, amount1_max })
            .deliver_to(sender, MessageDelivery.ONCHAIN_UNCONSTRAINED);

        self.enqueue_self._add_liquidity_single(
            pair, token0, token1, liquidity_token,
            refund0_note, refund1_note, lp_note,
            amount0_max, amount1_max,
            amount0_min, amount1_min, deadline,
        );
    }

    /// Remove liquidity via the router. Transfers LP tokens from user to
    /// pair, then calls the pair's public remove_liquidity_public.
    #[external("private")]
    fn remove_liquidity(
        pair: AztecAddress,
        token0: AztecAddress,
        token1: AztecAddress,
        liquidity_token: AztecAddress,
        liquidity: u128,
        amount0_min: u128,
        amount1_min: u128,
        deadline: u64,
        authwit_nonce: Field,
    ) {
        // Boundary zero-amount rejection: fail fast on a no-op call before
        // doing any work. The pair's INSUFFICIENT_0_AMOUNT would otherwise
        // catch this in the public continuation. The authwit and partial
        // notes are not burned by that deeper revert -- a failed tx commits no
        // nullifier regardless of where it reverts (see docs/aztec-subtleties.md);
        // failing fast just saves the wasted proving/gas and gives a clean,
        // specific revert, the convention established by the sibling
        // ZERO_INPUT_AMOUNT / ZERO_OUTPUT_AMOUNT asserts on the swap entries.
        assert(liquidity > 0 as u128, "ZERO_LIQUIDITY");
        let sender = self.msg_sender();

        // Transfer LP tokens from user to pair's public balance
        self.call(Token::at(liquidity_token).transfer_to_public(
            sender, pair, liquidity, authwit_nonce,
        ));

        // Prepare partial notes for returned token0 and token1
        let token0_note = self.call(
            Token::at(token0).prepare_private_balance_increase(sender),
        );
        let token1_note = self.call(
            Token::at(token1).prepare_private_balance_increase(sender),
        );

        self.emit(RouterBurnEvent { token0, token1, liquidity })
            .deliver_to(sender, MessageDelivery.ONCHAIN_UNCONSTRAINED);

        self.enqueue_self._remove_liquidity_single(
            pair, token0, token1, liquidity_token,
            liquidity, token0_note, token1_note,
            amount0_min, amount1_min, deadline,
        );
    }

    /// Swap exact input for maximum output (single hop).
    /// The router transfers tokens from user to its own public balance,
    /// then delegates to `_swap_exact_in` which uses the shared hop helper
    /// and applies the configured interface fee before the user's
    /// post-fee `amount_out_min` check.
    #[external("private")]
    fn swap_exact_in(
        pair: AztecAddress,
        token_in: AztecAddress,
        token_out: AztecAddress,
        amount_in: u128,
        amount_out_min: u128,
        deadline: u64,
        authwit_nonce: Field,
        fee_recipient: AztecAddress,
        fee_bips: u32,
    ) {
        validate_interface_fee_bips(fee_bips, fee_recipient);
        // Boundary zero-amount rejection: fail fast on a no-op call before any
        // work. The authwit is preserved on any failed tx regardless of where
        // it reverts; this just saves proving/gas and gives a clean revert.
        assert(amount_in > 0 as u128, "ZERO_INPUT_AMOUNT");
        // Reject self-recipient at the boundary (fail-fast). The router
        // never legitimately collects interface fees; a frontend that passes
        // `fee_recipient = router_address` would otherwise no-op the fee
        // transfer in `_deduct_interface_fee` while still subtracting from
        // the user's output, leaking the difference into router public
        // balance. `_deduct_interface_fee` keeps a defense-in-depth assert.
        assert(fee_recipient != self.address, "FEE_RECIPIENT_IS_ROUTER");

        let sender = self.msg_sender();

        self.call(Token::at(token_in).transfer_to_public(
            sender, self.address, amount_in, authwit_nonce,
        ));

        let output_note = self.call(
            Token::at(token_out).prepare_private_balance_increase(sender),
        );

        self.emit(RouterSwapExactInEvent { token_in, token_out, amount_in, amount_out_min })
            .deliver_to(sender, MessageDelivery.ONCHAIN_UNCONSTRAINED);

        self.enqueue_self._swap_exact_in(
            pair, token_in, token_out, amount_in, amount_out_min,
            deadline, output_note, fee_recipient, fee_bips,
        );
    }

    /// Swap tokens for exact output (single hop).
    /// The user deposits amount_in_max; the public continuation grosses up
    /// `amount_out` by the interface-fee factor on-chain to get the pair-level
    /// target, calls the pair, deducts the fee from the received output, and
    /// refunds any unspent input. `amount_out` is the user's post-fee minimum.
    #[external("private")]
    fn swap_exact_out(
        pair: AztecAddress,
        token_in: AztecAddress,
        token_out: AztecAddress,
        amount_out: u128,
        amount_in_max: u128,
        deadline: u64,
        authwit_nonce: Field,
        fee_recipient: AztecAddress,
        fee_bips: u32,
    ) {
        validate_interface_fee_bips(fee_bips, fee_recipient);
        // Boundary zero-amount rejection: fail fast on a no-op call before any
        // work. The authwit is preserved on any failed tx regardless of where
        // it reverts; this just saves proving/gas and gives a clean revert.
        assert(amount_in_max > 0 as u128, "ZERO_INPUT_AMOUNT");
        assert(amount_out > 0 as u128, "ZERO_OUTPUT_AMOUNT");
        // Reject self-recipient at the boundary; see swap_exact_in for rationale.
        assert(fee_recipient != self.address, "FEE_RECIPIENT_IS_ROUTER");

        let sender = self.msg_sender();

        let change_partial_note = self.call(
            Token::at(token_in).transfer_to_public_and_prepare_private_balance_increase(
                sender, self.address, amount_in_max, authwit_nonce,
            ),
        );

        let output_note = self.call(
            Token::at(token_out).prepare_private_balance_increase(sender),
        );

        self.emit(RouterSwapExactOutEvent { token_in, token_out, amount_in_max, amount_out })
            .deliver_to(sender, MessageDelivery.ONCHAIN_UNCONSTRAINED);

        self.enqueue_self._swap_exact_out(
            pair, token_in, token_out, amount_out, amount_in_max,
            deadline, output_note, change_partial_note,
            fee_recipient, fee_bips,
        );
    }

    // ================================================================
    // Multi-Hop Swap
    // ================================================================

    /// Multi-hop swap: exact input routed through up to MAX_HOPS pairs.
    ///
    /// The private entry transfers input tokens from the user to the router's
    /// public balance, prepares a partial note for the final output, then
    /// enqueues a public function that chains swaps across pairs using
    /// swap_exact_in_public (synchronous public-to-public calls).
    ///
    /// Individual hop amounts are visible. User identity stays private.
    ///
    /// IMPORTANT: The `pairs` array is user-supplied. The contract cannot verify
    /// on-chain that these are legitimate SigalSwap pairs (the factory's get_pair
    /// is a utility function, not callable from public context). The SDK resolves
    /// pair addresses from the factory. A user who supplies malicious pair addresses
    /// in this array would only harm themselves.
    /// fee_recipient: address to receive the interface fee (zero = no fee).
    /// fee_bips: interface fee in basis points, capped at MAX_INTERFACE_FEE_BIPS
    /// = 500 (5%) by validate_interface_fee_bips. 0 = no fee.
    #[external("private")]
    fn swap_exact_in_multi_hop(
        path: [AztecAddress; MAX_HOPS + 1],
        pairs: [AztecAddress; MAX_HOPS],
        path_length: u32,
        amount_in: u128,
        amount_out_min: u128,
        deadline: u64,
        authwit_nonce: Field,
        fee_recipient: AztecAddress,
        fee_bips: u32,
    ) {
        validate_path_length(path_length);
        validate_interface_fee_bips(fee_bips, fee_recipient);
        // Boundary zero-amount rejection: fail fast on a no-op call before any
        // work. The authwit is preserved on any failed tx regardless of where
        // it reverts; this just saves proving/gas and gives a clean revert.
        assert(amount_in > 0 as u128, "ZERO_INPUT_AMOUNT");
        // Reject self-recipient at the boundary; see swap_exact_in for rationale.
        assert(fee_recipient != self.address, "FEE_RECIPIENT_IS_ROUTER");

        let sender = self.msg_sender();
        let token_in = path[0];
        let final_token_out = path[path_length - 1];

        // Transfer input tokens from user to router's public balance
        self.call(Token::at(token_in).transfer_to_public(
            sender,
            self.address,
            amount_in,
            authwit_nonce,
        ));

        // Prepare partial note for final output (returned to user privately)
        let output_partial_note =
            self.call(Token::at(final_token_out).prepare_private_balance_increase(sender));

        // Encrypted wallet history. Logs path endpoints only (full path visible in public hop execution).
        self.emit(RouterSwapExactInEvent { token_in, token_out: final_token_out, amount_in, amount_out_min })
            .deliver_to(sender, MessageDelivery.ONCHAIN_UNCONSTRAINED);

        self.enqueue_self._swap_exact_in_multi_hop(
            path,
            pairs,
            path_length,
            amount_in,
            amount_out_min,
            deadline,
            output_partial_note,
            fee_recipient,
            fee_bips,
        );
    }

    /// Public multi-hop: chain exact-input swaps synchronously across pairs.
    ///
    /// Each hop delegates the V3 callback + balance-measurement work to
    /// `_execute_one_hop_exact_in`. Interface fee deducted from the final
    /// output before the user's post-fee `amount_out_min` check.
    ///
    /// Verifies every `pairs[i]` against the factory registry before any
    /// hop executes, so a single fake-pair address anywhere in the path
    /// reverts the whole tx before the V3 callback machinery wakes up.
    /// Cyclic input paths (e.g. `[A, B, A]` triangular arbitrage) repeat
    /// the same pair address across slots; the redundant factory view per
    /// repeat is a marginal cost on a small fixed-size loop.
    #[external("public")]
    #[only_self]
    fn _swap_exact_in_multi_hop(
        path: [AztecAddress; MAX_HOPS + 1],
        pairs: [AztecAddress; MAX_HOPS],
        path_length: u32,
        amount_in: u128,
        amount_out_min: u128,
        deadline: u64,
        output_partial_note: PartialUintNote,
        fee_recipient: AztecAddress,
        fee_bips: u32,
    ) {
        assert(self.context.timestamp() as u64 <= deadline, "EXPIRED");

        let factory = self.storage.factory.read();
        for i in 0..MAX_HOPS {
            if i < path_length - 1 {
                let pair_config = self.view(SigalSwapPair::at(pairs[i]).get_config());
                let registered = self.view(SigalSwapFactory::at(factory).get_pair_versioned_public(
                    pair_config.token0, pair_config.token1, pair_config.fee_tier_bps, pair_config.version,
                ));
                assert(registered == pairs[i], "PAIR_NOT_REGISTERED");
                // Verify the path tokens actually trade through this pair.
                // Without this, a mismatched (path, pairs) tuple where every
                // pair is independently registered passes the factory check
                // and reverts deeper at the pair's TOKEN_IN_IS_INVALID. The
                // boundary-side assert produces a clearer error and avoids a
                // wasted hop dispatch.
                assert(
                    (path[i] == pair_config.token0) | (path[i] == pair_config.token1),
                    "PATH_TOKEN_MISMATCH",
                );
                assert(
                    (path[i + 1] == pair_config.token0) | (path[i + 1] == pair_config.token1),
                    "PATH_TOKEN_MISMATCH",
                );
            }
        }

        self.storage.hop_active.write(true);

        let mut current_amount = amount_in;
        for i in 0..MAX_HOPS {
            if i < path_length - 1 {
                current_amount = self.internal._execute_one_hop_exact_in(
                    pairs[i], path[i], path[i + 1], current_amount,
                );
                assert(current_amount > 0 as u128, "ZERO_HOP_OUTPUT");
            }
        }

        let final_token = path[path_length - 1];
        let final_amount = self.internal._deduct_interface_fee(
            final_token, current_amount, fee_recipient, fee_bips,
        );
        assert(final_amount >= amount_out_min, "INSUFFICIENT_OUTPUT_AMOUNT");

        Token::at(final_token)
            .finalize_transfer_to_private(final_amount, output_partial_note)
            .call(self.context);

        self.internal._clear_callback_expectations();
        self.storage.hop_active.write(false);
    }

    /// Callback invoked by pair contracts during swap_exact_in_public to collect payment.
    ///
    /// The pair address is msg_sender (verified to match the pair Field argument
    /// to prevent spoofing). The router transfers the requested tokens to the pair.
    ///
    /// Security: this function can only move tokens that the router already holds
    /// in its public balance. Between transactions the router's balance is zero.
    /// During multi-hop execution, only the pair that swap_exact_in_public called back
    /// can trigger this, and msg_sender verification prevents spoofing.
    #[external("public")]
    fn swap_payment_callback(
        pair: Field,
        token: Field,
        amount: Field,
    ) {
        // Only callable during an active multi-hop swap
        assert(self.storage.hop_active.read(), "NO_ACTIVE_HOP");

        // Verify the caller IS the pair requesting payment
        let pair_addr = AztecAddress::from_field(pair);
        assert(self.msg_sender() == pair_addr, "UNAUTHORIZED_CALLBACK");

        // Verify Field fits in u128 (prevents silent truncation)
        assert(amount as u128 as Field == amount, "AMOUNT_OVERFLOW");

        let token_addr = AztecAddress::from_field(token);
        let amount_u128 = amount as u128;

        // Verify token matches and amount is within the authorized upper bound.
        // Exact-input flows set expected_amount to the precise input, so the pair
        // will request exactly that (its own balance_after check enforces the
        // match). Exact-output flows set expected_amount to amount_in_max; the
        // pair requests the true computed amount_in (<= amount_in_max) and the
        // router refunds the unspent remainder after the swap returns.
        assert(token_addr == self.storage.expected_callback_token.read(), "UNEXPECTED_TOKEN");
        assert(amount_u128 <= self.storage.expected_callback_amount.read(), "EXCESSIVE_CALLBACK_AMOUNT");

        Token::at(token_addr)
            .transfer_in_public(self.address, pair_addr, amount_u128, 0)
            .call(self.context);
    }

    // ================================================================
    // Multi-Hop Swap (Exact Output)
    // ================================================================

    /// Multi-hop swap: exact output routed through up to MAX_HOPS pairs.
    ///
    /// The user specifies the desired final output and maximum input. The
    /// router derives per-hop input ceilings on-chain by walking backward
    /// through the pairs (reading each pair's reserves via
    /// `quote_amount_in_public`). The SDK supplies only the path and
    /// user-visible bounds.
    ///
    /// Compute-and-execute happen atomically in the public continuation, so
    /// the derived per-hop ceilings reflect reserves at tx-time rather than
    /// at quote-time.
    #[external("private")]
    fn swap_exact_out_multi_hop(
        path: [AztecAddress; MAX_HOPS + 1],
        pairs: [AztecAddress; MAX_HOPS],
        path_length: u32,
        amount_out: u128,
        amount_in_max: u128,
        deadline: u64,
        authwit_nonce: Field,
        fee_recipient: AztecAddress,
        fee_bips: u32,
    ) {
        validate_path_length(path_length);
        validate_interface_fee_bips(fee_bips, fee_recipient);
        validate_path_no_cycle_to_final(path, path_length);
        // Boundary zero-amount rejection: fail fast on a no-op call before any
        // work. The authwit is preserved on any failed tx regardless of where
        // it reverts; this just saves proving/gas and gives a clean revert.
        assert(amount_in_max > 0 as u128, "ZERO_INPUT_AMOUNT");
        assert(amount_out > 0 as u128, "ZERO_OUTPUT_AMOUNT");
        // Reject self-recipient at the boundary; see swap_exact_in for rationale.
        assert(fee_recipient != self.address, "FEE_RECIPIENT_IS_ROUTER");

        let sender = self.msg_sender();
        let token_in = path[0];
        let final_token_idx = path_length - 1;
        let final_token_out = path[final_token_idx];

        // Transfer amount_in_max from user to router's public balance and
        // prepare a change partial note so any unused input can be refunded
        // privately. The public continuation computes the actual required
        // input on-chain and refunds the unused remainder.
        let change_partial_note = self.call(
            Token::at(token_in).transfer_to_public_and_prepare_private_balance_increase(
                sender, self.address, amount_in_max, authwit_nonce,
            ),
        );

        // Prepare partial note for final output (returned to user privately)
        let output_partial_note =
            self.call(Token::at(final_token_out).prepare_private_balance_increase(sender));

        // Prepare refund partial notes for each intermediate token (path[1..N-1]).
        // If a hop consumes less than the derived ceiling for its input, the
        // leftover of that intermediate token stays in the router's public
        // balance; the public executor finalizes these notes with the actual
        // leftover so no dust persists and the user gets their tokens back.
        //
        // This loop unconditionally prepares `MAX_HOPS - 1` partial notes
        // regardless of the real `path_length`. Slots that aren't real
        // intermediates (i + 1 >= final_token_idx) are prepared against the
        // final output token as placeholders; they're never finalized in
        // public and uncompleted partial notes are harmless in Aztec.
        //
        // **Privacy design (do not "optimize" this away):** each
        // `prepare_private_balance_increase` emits a note-hash commitment
        // that an on-chain observer can count per tx (the contents are
        // encrypted but the count is public). Always preparing the full
        // `MAX_HOPS - 1` set gives every exact-out multi-hop the same
        // private-side note footprint, so clean swaps (no dust, no
        // fee-on-transfer) are indistinguishable between `path_length`
        // 2 / 3 / 4 from an outside observer. Conditionally skipping
        // placeholders would leak `path_length` exactly via note-count
        // for the common clean-swap case. We accept the fixed proving-cost
        // overhead of the placeholder prepares in exchange for that
        // indistinguishability.
        //
        // (Dusty swaps already leak `path_length` via public
        // `finalize_transfer_to_private` count in the public continuation;
        // that leak is intrinsic to refunding dust and is orthogonal to
        // the private-side placeholder decision.)
        let note0_target_idx =
            if 1 < final_token_idx { 1 } else { final_token_idx };
        let intermediate_note_0 =
            self.call(Token::at(path[note0_target_idx]).prepare_private_balance_increase(sender));
        let note1_target_idx =
            if 2 < final_token_idx { 2 } else { final_token_idx };
        let intermediate_note_1 =
            self.call(Token::at(path[note1_target_idx]).prepare_private_balance_increase(sender));
        let intermediate_notes: [PartialUintNote; MAX_HOPS - 1] =
            [intermediate_note_0, intermediate_note_1];

        // Encrypted wallet history. Logs path endpoints + user's bounds.
        self.emit(RouterSwapExactOutEvent { token_in, token_out: final_token_out, amount_in_max, amount_out })
            .deliver_to(sender, MessageDelivery.ONCHAIN_UNCONSTRAINED);

        // Enqueue the public execution
        self.enqueue_self._swap_exact_out_multi_hop(
            path,
            pairs,
            path_length,
            amount_out,
            amount_in_max,
            deadline,
            output_partial_note,
            change_partial_note,
            intermediate_notes,
            fee_recipient,
            fee_bips,
        );
    }

    /// Public exact-output multi-hop: chain swaps synchronously across pairs
    /// using per-hop exact-output semantics.
    ///
    /// Each hop calls the pair's swap_exact_out_public:
    ///   - amount_out     = amounts[i + 1]  (exact output target for the hop)
    ///   - amount_in_max  = amounts[i]      (upper bound on input the pair may consume)
    /// The pair computes the precise amount_in needed for amount_out and
    /// callbacks the router for exactly that amount (bounded by the `<=` guard
    /// in swap_payment_callback). Any unused token[0] (first-hop input) is
    /// refunded to the user via change_partial_note.
    ///
    /// The interface fee is deducted BEFORE the `final_amount >= amount_out`
    /// check, so amount_out represents the user's POST-FEE minimum received.
    /// SDK callers must size amounts[path_length - 1] to cover amount_out + fee.
    ///
    /// Any leftover of an intermediate token (path[1..path_length-1]) is
    /// refunded to the user's private balance via intermediate_notes so no
    /// dust accumulates in the router's public balance across transactions.
    #[external("public")]
    #[only_self]
    fn _swap_exact_out_multi_hop(
        path: [AztecAddress; MAX_HOPS + 1],
        pairs: [AztecAddress; MAX_HOPS],
        path_length: u32,
        amount_out: u128,
        amount_in_max: u128,
        deadline: u64,
        output_partial_note: PartialUintNote,
        change_partial_note: PartialUintNote,
        intermediate_notes: [PartialUintNote; MAX_HOPS - 1],
        fee_recipient: AztecAddress,
        fee_bips: u32,
    ) {
        assert(self.context.timestamp() as u64 <= deadline, "EXPIRED");

        // Verify every pair in the path against the factory registry before
        // calling _compute_amounts_in (which queries each pair's
        // quote_amount_in_public). Without this check, a fake-pair anywhere
        // in `pairs` could lie about the implied input ceiling and the
        // resulting amounts would propagate through the rest of the hop
        // execution. Cyclic same-pair-twice exact-out paths are rejected
        // upstream by validate_path_no_cycle_to_final, but defense-in-depth
        // is cheap on a fixed-size loop.
        let factory = self.storage.factory.read();
        for i in 0..MAX_HOPS {
            if i < path_length - 1 {
                let pair_config = self.view(SigalSwapPair::at(pairs[i]).get_config());
                let registered = self.view(SigalSwapFactory::at(factory).get_pair_versioned_public(
                    pair_config.token0, pair_config.token1, pair_config.fee_tier_bps, pair_config.version,
                ));
                assert(registered == pairs[i], "PAIR_NOT_REGISTERED");
                // Verify the path tokens actually trade through this pair.
                // Without this, a mismatched (path, pairs) tuple where every
                // pair is independently registered passes the factory check
                // and reverts deeper at the pair's TOKEN_IN_IS_INVALID. The
                // boundary-side assert produces a clearer error and avoids a
                // wasted hop dispatch.
                assert(
                    (path[i] == pair_config.token0) | (path[i] == pair_config.token1),
                    "PATH_TOKEN_MISMATCH",
                );
                assert(
                    (path[i + 1] == pair_config.token0) | (path[i + 1] == pair_config.token1),
                    "PATH_TOKEN_MISMATCH",
                );
            }
        }

        self.storage.hop_active.write(true);

        // Derive per-hop input ceilings on-chain. The last hop must produce
        // enough output to cover the user's `amount_out` plus the interface
        // fee; earlier hops' outputs cascade from that target.
        let amounts = self.internal._compute_amounts_in(
            path, pairs, path_length, amount_out, fee_bips,
        );
        assert(amounts[0] <= amount_in_max, "EXCESSIVE_INPUT_AMOUNT");

        // Per-hop input consumption captured directly from each hop. Lets
        // every refund downstream be computed from execution-derived
        // quantities (consumed[i] vs amounts[i]) instead of from total
        // public-balance reads -- so any router pre-existing stuck balance
        // of any path token (donations, cyclic exact-in dust, same-token
        // reuse across non-adjacent positions) stays at the router rather
        // than leaking into the user's refunds. Stuck balances remain
        // drainable via the documented `skim_to` path.
        let mut consumed: [u128; MAX_HOPS] = [0 as u128; MAX_HOPS];

        for i in 0..MAX_HOPS {
            if i < path_length - 1 {
                consumed[i] = self.internal._execute_one_hop_exact_out(
                    pairs[i], path[i], path[i + 1], amounts[i + 1], amounts[i],
                );
            }
        }

        // Refund unused token[0]: the private entry transferred `amount_in_max`
        // in, hop 0 consumed `consumed[0]`. Difference goes back to user.
        // The `<=` guard converts a Noir bytecode-level underflow panic
        // into a labeled revert. Reachable today only via a pair callback
        // that exceeds `expected_callback_amount` -- the router's own
        // `swap_payment_callback` upper-bound check (`amount_u128 <=
        // expected`) caps a single callback at amount_in_max but does
        // not reject repeat invocations. Defense-in-depth.
        assert(consumed[0] <= amount_in_max, "CONSUMED_EXCEEDS_REQUESTED");
        let change = amount_in_max - consumed[0];
        if change > 0 as u128 {
            Token::at(path[0])
                .finalize_transfer_to_private(change, change_partial_note)
                .call(self.context);
        }

        // Refund intermediate-token dust: hop j-1 delivered exactly
        // `amounts[j]` of `path[j]` (V3 exact-output guarantee), hop j
        // consumed `consumed[j]` (<= `amounts[j]`). The leftover landed
        // transiently at the router and is forwarded to the user's private
        // balance. Slots beyond path_length - 2 aren't real intermediates;
        // their partial notes (placeholders prepared against the final
        // token) are abandoned here.
        for i in 0..MAX_HOPS - 1 {
            let intermediate_idx = i + 1;
            if intermediate_idx < path_length - 1 {
                // Same guard as the first-hop refund above; mirrors the
                // CONSUMED_EXCEEDS_REQUESTED defense for intermediate hops.
                assert(
                    consumed[intermediate_idx] <= amounts[intermediate_idx],
                    "CONSUMED_EXCEEDS_REQUESTED",
                );
                let dust = amounts[intermediate_idx] - consumed[intermediate_idx];
                if dust > 0 as u128 {
                    Token::at(path[intermediate_idx])
                        .finalize_transfer_to_private(dust, intermediate_notes[i])
                        .call(self.context);
                }
            }
        }

        // Final hop produced exactly `amounts[path_length - 1]` (V3
        // exact-output guarantee). Trust that promise here; if the final
        // pair under-delivered, `finalize_transfer_to_private` below would
        // revert on insufficient balance anyway.
        let final_token = path[path_length - 1];
        let received = amounts[path_length - 1];
        let final_amount = self.internal._deduct_interface_fee(
            final_token, received, fee_recipient, fee_bips,
        );
        assert(final_amount >= amount_out, "INSUFFICIENT_OUTPUT_AMOUNT");

        Token::at(final_token)
            .finalize_transfer_to_private(final_amount, output_partial_note)
            .call(self.context);

        self.internal._clear_callback_expectations();
        self.storage.hop_active.write(false);
    }

    /// Walk backward through the pairs and derive per-hop input ceilings.
    /// Final-hop output target is `amount_out` grossed up for the interface
    /// fee (so the user receives at least `amount_out` after fee deduction).
    /// Each earlier hop's output target is the next hop's derived input,
    /// and each hop's input is computed via `pair.quote_amount_in_public`
    /// using the pair's current reserves and fee tier.
    #[internal("public")]
    fn _compute_amounts_in(
        path: [AztecAddress; MAX_HOPS + 1],
        pairs: [AztecAddress; MAX_HOPS],
        path_length: u32,
        amount_out: u128,
        fee_bips: u32,
    ) -> pub [u128; MAX_HOPS + 1] {
        let scale: u128 = 10000;
        // Gross up the final-hop output for the interface fee: the router
        // charges a fee on what the pair delivers, so the pair must deliver
        // `ceil(amount_out * scale / (scale - fee_bips))` for the user to
        // receive at least `amount_out` after the deduction. When fee_bips
        // = 0, this is just `amount_out`.
        let pair_target_out = if fee_bips == 0 {
            amount_out
        } else {
            let fb = fee_bips as u128;
            let denom = scale - fb;
            let num = amount_out * scale;
            let q = num / denom;
            let r = num % denom;
            if r > 0 { q + 1 } else { q }
        };

        let mut amounts: [u128; MAX_HOPS + 1] = [0 as u128; MAX_HOPS + 1];
        amounts[path_length - 1] = pair_target_out;

        // Walk backward: fill amounts[path_length-2..=0] by asking each pair
        // how much input it needs to produce the next hop's requirement.
        for i in 0..MAX_HOPS {
            if i < path_length - 1 {
                let idx = path_length - 1 - i;
                let required = self.view(
                    SigalSwapPair::at(pairs[idx - 1])
                        .quote_amount_in_public(amounts[idx], path[idx]),
                );
                amounts[idx - 1] = required;
            }
        }

        amounts
    }

    /// Public: single-hop exact-input swap. Routes through
    /// `_execute_one_hop_exact_in` and applies the same interface-fee
    /// deduction + `amount_out_min` check as the multi-hop path.
    ///
    /// Verifies `pair` against the factory registry before initiating any
    /// hop work so a caller-supplied fake-pair address cannot reach the
    /// V3 callback machinery.
    #[external("public")]
    #[only_self]
    fn _swap_exact_in(
        pair: AztecAddress,
        token_in: AztecAddress,
        token_out: AztecAddress,
        amount_in: u128,
        amount_out_min: u128,
        deadline: u64,
        output_partial_note: PartialUintNote,
        fee_recipient: AztecAddress,
        fee_bips: u32,
    ) {
        assert(self.context.timestamp() as u64 <= deadline, "EXPIRED");

        let pair_config = self.view(SigalSwapPair::at(pair).get_config());
        let factory = self.storage.factory.read();
        let registered = self.view(SigalSwapFactory::at(factory).get_pair_versioned_public(
            pair_config.token0, pair_config.token1, pair_config.fee_tier_bps, pair_config.version,
        ));
        assert(registered == pair, "PAIR_NOT_REGISTERED");
        // Symmetric to multi-hop's per-hop check: refuse to dispatch a hop
        // when the supplied (token_in, token_out) aren't this pair's
        // tokens. Without this, the request reaches the pair's
        // TOKEN_IN_IS_INVALID assert after the hop_active write, the
        // expectation-slot writes, and the pair call -- a wasted dispatch
        // and a less-clear revert site for an off-chain-detectable error.
        assert(
            (token_in == pair_config.token0) | (token_in == pair_config.token1),
            "PATH_TOKEN_MISMATCH",
        );
        assert(
            (token_out == pair_config.token0) | (token_out == pair_config.token1),
            "PATH_TOKEN_MISMATCH",
        );

        self.storage.hop_active.write(true);

        let received = self.internal._execute_one_hop_exact_in(
            pair, token_in, token_out, amount_in,
        );
        assert(received > 0 as u128, "ZERO_OUTPUT");

        let final_amount = self.internal._deduct_interface_fee(
            token_out, received, fee_recipient, fee_bips,
        );
        assert(final_amount >= amount_out_min, "INSUFFICIENT_OUTPUT_AMOUNT");

        Token::at(token_out)
            .finalize_transfer_to_private(final_amount, output_partial_note)
            .call(self.context);

        self.internal._clear_callback_expectations();
        self.storage.hop_active.write(false);
    }

    /// Public: single-hop exact-output swap. Routes through
    /// `_execute_one_hop_exact_out` and applies the same interface-fee
    /// deduction + `amount_out >= user_amount_out` check as the multi-hop
    /// path. The pair-level target is computed on-chain from `amount_out`
    /// and `fee_bips` (gross up so the user receives at least `amount_out`
    /// after the interface fee is deducted).
    ///
    /// Verifies `pair` against the factory registry before initiating any
    /// hop work so a caller-supplied fake-pair address cannot reach the
    /// V3 callback machinery.
    #[external("public")]
    #[only_self]
    fn _swap_exact_out(
        pair: AztecAddress,
        token_in: AztecAddress,
        token_out: AztecAddress,
        amount_out: u128,
        amount_in_max: u128,
        deadline: u64,
        output_partial_note: PartialUintNote,
        change_partial_note: PartialUintNote,
        fee_recipient: AztecAddress,
        fee_bips: u32,
    ) {
        assert(self.context.timestamp() as u64 <= deadline, "EXPIRED");

        let pair_config = self.view(SigalSwapPair::at(pair).get_config());
        let factory = self.storage.factory.read();
        let registered = self.view(SigalSwapFactory::at(factory).get_pair_versioned_public(
            pair_config.token0, pair_config.token1, pair_config.fee_tier_bps, pair_config.version,
        ));
        assert(registered == pair, "PAIR_NOT_REGISTERED");
        // Symmetric to multi-hop's per-hop check: refuse to dispatch a hop
        // when the supplied (token_in, token_out) aren't this pair's
        // tokens. See the matching block in `_swap_exact_in` for context.
        assert(
            (token_in == pair_config.token0) | (token_in == pair_config.token1),
            "PATH_TOKEN_MISMATCH",
        );
        assert(
            (token_out == pair_config.token0) | (token_out == pair_config.token1),
            "PATH_TOKEN_MISMATCH",
        );

        self.storage.hop_active.write(true);

        // Gross up amount_out by the interface-fee factor on-chain to get the
        // pair-level target. When fee_bips = 0 this equals amount_out.
        let scale: u128 = 10000;
        let pair_target_out = if fee_bips == 0 {
            amount_out
        } else {
            let fb = fee_bips as u128;
            let denom = scale - fb;
            let num = amount_out * scale;
            let q = num / denom;
            let r = num % denom;
            if r > 0 { q + 1 } else { q }
        };

        let consumed = self.internal._execute_one_hop_exact_out(
            pair, token_in, token_out, pair_target_out, amount_in_max,
        );

        // Refund unspent input. `consumed` is the precise per-hop delta;
        // the router's pre-existing public balance of `token_in` (donations,
        // cyclic dust from earlier exact-in paths) is not reachable through
        // this refund -- it stays at the router and remains drainable via
        // the documented `skim_to` recovery path.
        // Same CONSUMED_EXCEEDS_REQUESTED guard as the multi-hop refund;
        // converts a bytecode-level underflow into a labeled revert.
        assert(consumed <= amount_in_max, "CONSUMED_EXCEEDS_REQUESTED");
        let change = amount_in_max - consumed;
        if change > 0 as u128 {
            Token::at(token_in)
                .finalize_transfer_to_private(change, change_partial_note)
                .call(self.context);
        }

        // Output side: the pair contract's exact-output semantic delivers
        // exactly `pair_target_out` of `token_out`. Trust that promise here
        // and rely on the `finalize_transfer_to_private` below to revert
        // (insufficient balance) if the pair under-delivered.
        let received = pair_target_out;
        let final_amount = self.internal._deduct_interface_fee(
            token_out, received, fee_recipient, fee_bips,
        );
        assert(final_amount >= amount_out, "INSUFFICIENT_OUTPUT_AMOUNT");

        Token::at(token_out)
            .finalize_transfer_to_private(final_amount, output_partial_note)
            .call(self.context);

        self.internal._clear_callback_expectations();
        self.storage.hop_active.write(false);
    }

    /// Public: add liquidity via router (V2-router pattern). The user's
    /// `amount_i_max` is sitting in the router's public balance from the
    /// private entry. We read the pair's live reserves, compute the
    /// optimal pair-ratio deposit, transfer exactly that to the pair,
    /// then refund the unused remainder to the user's private balance.
    ///
    /// Slippage check happens here (`get_amounts_to_add` asserts
    /// `amount_i >= amount_i_min`) before any tokens move to the pair.
    /// The pair's slippage check is redundant for this caller but stays
    /// in place as a safety net for direct callers (non-router) of
    /// `add_liquidity_public`.
    ///
    /// Address verification: the caller-supplied `pair` is checked against
    /// the factory's registry, then `token0` / `token1` / `liquidity_token`
    /// are asserted against the pair's authoritative `PairConfig` before
    /// any balance measurement or partial-note finalization. Together
    /// these close two distinct attack lanes: the factory check refutes
    /// a fully-fabricated pair whose `get_config()` returns
    /// internally-consistent lies, and the per-field check refutes a
    /// real-but-wrong-pair-for-these-tokens substitution.
    #[external("public")]
    #[only_self]
    fn _add_liquidity_single(
        pair: AztecAddress,
        token0: AztecAddress,
        token1: AztecAddress,
        liquidity_token: AztecAddress,
        refund0_note: PartialUintNote,
        refund1_note: PartialUintNote,
        lp_note: PartialUintNote,
        amount0_max: u128,
        amount1_max: u128,
        amount0_min: u128,
        amount1_min: u128,
        deadline: u64,
    ) {
        assert(self.context.timestamp() as u64 <= deadline, "EXPIRED");

        let pair_config = self.view(SigalSwapPair::at(pair).get_config());
        let factory = self.storage.factory.read();
        let registered = self.view(SigalSwapFactory::at(factory).get_pair_versioned_public(
            pair_config.token0, pair_config.token1, pair_config.fee_tier_bps, pair_config.version,
        ));
        assert(registered == pair, "PAIR_NOT_REGISTERED");
        assert(token0 == pair_config.token0, "TOKEN0_MISMATCH");
        assert(token1 == pair_config.token1, "TOKEN1_MISMATCH");
        assert(liquidity_token == pair_config.lp_token, "LP_TOKEN_MISMATCH");

        // Reentrancy lock (defense-in-depth, mirroring the swap continuations):
        // held across every token call below so a malicious token's
        // transfer_in_public / finalize callback cannot re-enter skim_to
        // mid-continuation. The net-zero balance invariant already makes this
        // safe, but the lock makes the guarantee explicit and uniform.
        self.storage.hop_active.write(true);

        // Read live reserves and compute the optimal pair-ratio deposit
        // bounded by what the user authorized via authwit. Slippage check
        // (`amount_i >= amount_i_min`) is enforced inside `get_amounts_to_add`.
        let (reserve0, reserve1, _ts) = self.view(SigalSwapPair::at(pair).get_reserves());
        let (optimal0, optimal1) = get_amounts_to_add(
            amount0_max, amount1_max,
            amount0_min, amount1_min,
            reserve0, reserve1,
        );

        // Snapshot LP balance before the mint so we can size the partial-note
        // completion exactly. Token0/token1 deltas don't need snapshotting:
        // we're transferring exactly `optimal_i` out, so the refund to the
        // user is mechanically `amount_i_max - optimal_i`.
        let lp_before = self.view(Token::at(liquidity_token).balance_of_public(self.address));

        // Push the optimal portion to the pair so the pair sees `balance - reserve == optimal`.
        Token::at(token0).transfer_in_public(self.address, pair, optimal0, 0).call(self.context);
        Token::at(token1).transfer_in_public(self.address, pair, optimal1, 0).call(self.context);

        // Pair mints LP for the matched optimal. Pre-existing pair-side
        // donations are absorbed into reserves by the pair's V2-strict mint.
        SigalSwapPair::at(pair)
            .add_liquidity_public(self.address, amount0_min, amount1_min)
            .call(self.context);

        let lp_after = self.view(Token::at(liquidity_token).balance_of_public(self.address));
        let lp_minted = lp_after - lp_before;
        assert(lp_minted > 0 as u128, "NO_LP_MINTED");

        // Finalize partial notes -- refund `amount_max - optimal` to the
        // user's private balance, plus the LP they minted. Skip refund
        // finalization when the optimal exactly matched the authorized
        // max (no leftover); Aztec's PartialUintNote rejects zero-value
        // completion and uncompleted partial notes are harmless.
        let refund0 = amount0_max - optimal0;
        let refund1 = amount1_max - optimal1;
        if refund0 > 0 as u128 {
            Token::at(token0).finalize_transfer_to_private(refund0, refund0_note).call(self.context);
        }
        if refund1 > 0 as u128 {
            Token::at(token1).finalize_transfer_to_private(refund1, refund1_note).call(self.context);
        }
        // Use finalize_transfer_to_private (not mint) -- LP tokens were minted to
        // router's public balance by the pair, now transfer to user's private balance
        Token::at(liquidity_token).finalize_transfer_to_private(lp_minted, lp_note).call(self.context);

        self.storage.hop_active.write(false);
    }

    /// Public: remove liquidity via router. LP tokens pre-deposited in pair.
    /// Pair sends token0/token1 to router's public balance. Router finalizes
    /// partial notes with actual amounts.
    ///
    /// Address verification: same shape as `_add_liquidity_single` -- the
    /// factory check refutes a fully-fabricated pair, and the
    /// token0/token1/liquidity_token field checks refute a
    /// real-but-wrong-pair-for-these-tokens substitution. The pair's burn
    /// also reverts if LP wasn't actually deposited (the FAKE-lp variant on
    /// this side), but a `LP_TOKEN_MISMATCH` at the router boundary is a
    /// clearer error than an indirect insufficient-balance revert from the
    /// LP Token.
    #[external("public")]
    #[only_self]
    fn _remove_liquidity_single(
        pair: AztecAddress,
        token0: AztecAddress,
        token1: AztecAddress,
        liquidity_token: AztecAddress,
        liquidity: u128,
        token0_note: PartialUintNote,
        token1_note: PartialUintNote,
        amount0_min: u128,
        amount1_min: u128,
        deadline: u64,
    ) {
        assert(self.context.timestamp() as u64 <= deadline, "EXPIRED");

        let pair_config = self.view(SigalSwapPair::at(pair).get_config());
        let factory = self.storage.factory.read();
        let registered = self.view(SigalSwapFactory::at(factory).get_pair_versioned_public(
            pair_config.token0, pair_config.token1, pair_config.fee_tier_bps, pair_config.version,
        ));
        assert(registered == pair, "PAIR_NOT_REGISTERED");
        assert(token0 == pair_config.token0, "TOKEN0_MISMATCH");
        assert(token1 == pair_config.token1, "TOKEN1_MISMATCH");
        assert(liquidity_token == pair_config.lp_token, "LP_TOKEN_MISMATCH");

        // Reentrancy lock (defense-in-depth, see _add_liquidity_single): held
        // across the pair call + token finalizes so a malicious token cannot
        // re-enter skim_to mid-continuation.
        self.storage.hop_active.write(true);

        // Record balances before
        let t0_before = self.view(Token::at(token0).balance_of_public(self.address));
        let t1_before = self.view(Token::at(token1).balance_of_public(self.address));

        // Pair does math, sends tokens to this router
        SigalSwapPair::at(pair)
            .remove_liquidity_public(self.address, liquidity, amount0_min, amount1_min)
            .call(self.context);

        // Measure what we received
        let amount0 = self.view(Token::at(token0).balance_of_public(self.address)) - t0_before;
        let amount1 = self.view(Token::at(token1).balance_of_public(self.address)) - t1_before;

        // Finalize partial notes -- send tokens to user's private balance
        assert(amount0 > 0 as u128, "NO_TOKEN0_RECEIVED");
        assert(amount1 > 0 as u128, "NO_TOKEN1_RECEIVED");
        Token::at(token0).finalize_transfer_to_private(amount0, token0_note).call(self.context);
        Token::at(token1).finalize_transfer_to_private(amount1, token1_note).call(self.context);

        self.storage.hop_active.write(false);
    }

    // ================================================================
    // Stuck-balance recovery
    // ================================================================

    /// Sweep the router's full public balance of `token` to `recipient`.
    ///
    /// Permissionless on purpose: the router is designed to hold zero token
    /// balances between transactions, but two scenarios can leave dust:
    ///   1. Cyclic exact-in paths (e.g. `[A, B, A]`) preserve any pre-existing
    ///      router balance of `A` because per-hop delta accounting only
    ///      touches the deltas, not the absolute balance.
    ///   2. Anyone can transfer tokens directly to the router via
    ///      `transfer_in_public(_, router, amount, 0)`. Those tokens have no
    ///      owner record on the router side; without this function they
    ///      would be permanently locked.
    ///
    /// Anyone can call. Donations to the router are a known footgun (sending
    /// to a contract with no withdraw method); permissionless skim just lets
    /// any party reclaim dust before someone else does. The pair has the
    /// same permissionless semantics for the same reason.
    ///
    /// `hop_active == false` is enforced so this can't extract tokens that
    /// the router currently holds for an in-flight multi-hop swap. The
    /// reentrancy lock + atomic tx rollback would already protect the swap
    /// proper; this is defense-in-depth against a future refactor that
    /// might leave hop_active set across a sub-call.
    #[external("public")]
    fn skim_to(token: AztecAddress, recipient: AztecAddress) {
        assert(!self.storage.hop_active.read(), "HOP_ACTIVE");
        assert(!recipient.is_zero(), "ZERO_RECIPIENT");

        let token_contract = Token::at(token);
        let amount = self.view(token_contract.balance_of_public(self.address));
        assert(amount > 0 as u128, "NO_BALANCE");

        token_contract.transfer_in_public(self.address, recipient, amount, 0).call(
            self.context,
        );

        self.emit(RouterSkimEvent { token, recipient, amount });
    }

    // ================================================================
    // View
    // ================================================================

    /// Get the factory address (SDK uses this to look up pairs).
    #[external("utility")]
    unconstrained fn get_factory() -> pub AztecAddress {
        self.storage.factory.read()
    }

    /// Off-chain helper: compute the final output of a multi-hop exact-input
    /// swap without executing it. Walks `path[0..path_length-1]`, applying each
    /// pair's `quote_amount_out` utility with the running amount. Returns the
    /// expected amount of `path[path_length-1]`. Does NOT account for interface
    /// fee or final-output authwit; subtract those caller-side.
    ///
    /// One simulate call replaces N pair-level quote calls the SDK would have
    /// otherwise had to chain. Pre-launch utility for the UI's swap widget.
    /// Reverts on path_length out of [2, MAX_HOPS+1] (same boundary as
    /// `swap_exact_in_multi_hop`). Each per-hop call surfaces pair-side reverts
    /// (TOKEN_IN_IS_INVALID, ZERO_INPUT, etc.) so a quote that wouldn't execute
    /// also won't return a misleading number.
    #[external("utility")]
    unconstrained fn quote_exact_in_multi_hop(
        path: [AztecAddress; MAX_HOPS + 1],
        pairs: [AztecAddress; MAX_HOPS],
        path_length: u32,
        amount_in: u128,
    ) -> u128 {
        validate_path_length(path_length);
        assert(amount_in > 0 as u128, "ZERO_INPUT_AMOUNT");
        let mut current_amount = amount_in;
        for i in 0..MAX_HOPS {
            if i < path_length - 1 {
                current_amount = self.call(SigalSwapPair::at(pairs[i]).quote_amount_out(
                    current_amount, path[i],
                ));
            }
        }
        current_amount
    }

    /// Off-chain helper: compute the input amount needed to receive a given
    /// output through a multi-hop exact-output swap. Walks the path backwards,
    /// applying each pair's `quote_amount_in` utility. Returns the required
    /// amount of `path[0]`.
    ///
    /// Backward walk: at hop i (handling the path[i] -> path[i+1] swap), the
    /// running amount represents the desired amount of path[i+1]; we ask the
    /// pair for the corresponding amount of path[i] (= token_in). Continues
    /// until i = 0, leaving the running amount as needed input at path[0].
    #[external("utility")]
    unconstrained fn quote_exact_out_multi_hop(
        path: [AztecAddress; MAX_HOPS + 1],
        pairs: [AztecAddress; MAX_HOPS],
        path_length: u32,
        amount_out: u128,
    ) -> u128 {
        validate_path_length(path_length);
        assert(amount_out > 0 as u128, "ZERO_OUTPUT_AMOUNT");
        let mut current_amount = amount_out;
        for i_rev in 0..MAX_HOPS {
            if i_rev < path_length - 1 {
                let i = path_length - 2 - i_rev;
                current_amount = self.call(SigalSwapPair::at(pairs[i]).quote_amount_in(
                    current_amount, path[i + 1],
                ));
            }
        }
        current_amount
    }
}
