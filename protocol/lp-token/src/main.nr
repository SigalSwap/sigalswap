// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 SigalSwap LLC
// Licensed under the Apache License, Version 2.0 (the "License"). See LICENSE
// and NOTICE in this directory.
// Portions derived from aztec-packages (noir-projects/noir-contracts/contracts/app/token_contract),
// Copyright Spilsbury Holdings Ltd, licensed under Apache-2.0.
//
// SigalSwap LP Token. A minimal fungible token for representing LP positions
// in a single SigalSwapPair. Exactly one pair can mint; no admin, no minter
// map, no upgrade surface. The paired pair address is fixed at construction
// via the single constructor argument and is bound into the contract's
// address via init_hash (and therefore into the pair's derived LP address).
//
// LOAD-BEARING INVARIANT: this contract MUST NOT include any call to
// Aztec's `ContractInstanceRegistry::update`. That primitive lets a deployed
// contract reschedule its own class_id (bytecode swap at the same address).
// LPs are implicitly trusting that the bytecode they signed up with cannot
// silently change; an `update` call here would break that guarantee. The
// factory's `LP_TOKEN_WRONG_CLASS` check (in factory/src/main.nr `register_pair`) is the
// canary that catches a class swap at registration time, but we maintain
// the invariant here at the source level too: no `update` call, period.

mod test;

use aztec::macros::aztec;

#[aztec]
pub contract SigalSwapLPToken {
    use std::ops::{Add, Sub};

    use compressed_string::FieldCompressedString;

    use aztec::{
        authwit::auth::compute_authwit_nullifier,
        context::{PrivateCall, PrivateContext},
        macros::{
            events::event,
            functions::{authorize_once, external, initializer, internal, only_self, view},
            storage::storage,
        },
        messages::message_delivery::MessageDelivery,
        protocol::{address::AztecAddress, traits::ToField, utils::field::field_from_bytes},
        state_vars::{Map, Owned, PublicImmutable, PublicMutable, StateVariable},
    };

    use uint_note::{PartialUintNote, UintNote};

    use balance_set::BalanceSet;

    global INITIAL_TRANSFER_CALL_MAX_NOTES: u32 = 2;
    global RECURSIVE_TRANSFER_CALL_MAX_NOTES: u32 = 8;

    // Hardcoded token metadata. Identical across every SigalSwap LP Token
    // instance. Wallets distinguish LP positions by contract address; the
    // pool tokens (token0, token1) are readable from the paired pair.
    //
    // Name and symbol are stored as 31-byte arrays with trailing 0x00
    // padding. Null-byte padding (rather than ASCII spaces) means wallets
    // that trim display strings render "SigalSwap LP" and "SSLP" cleanly.
    global LP_TOKEN_DECIMALS: u8 = 18;

    // "SigalSwap LP" + 19 null bytes
    global LP_TOKEN_NAME_BYTES: [u8; 31] = [
        0x53, 0x69, 0x67, 0x61, 0x6c, 0x53, 0x77, 0x61, 0x70, 0x20,
        0x4c, 0x50,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ];

    // "SSLP" + 27 null bytes
    global LP_TOKEN_SYMBOL_BYTES: [u8; 31] = [
        0x53, 0x53, 0x4c, 0x50,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ];

    // Named `LPTransfer` (not `Transfer`) to avoid a selector collision with
    // Aztec's standard Token `Transfer` event -- the pair imports both this
    // contract and the Aztec Token interface (for token0/token1), so a shared
    // `Transfer` name could clash for a consumer decoding both in one tx.
    //
    // `LPTransfer` is a PRIVATE event, emitted only by the private `transfer`
    // entry and delivered ENCRYPTED to `to` (via deliver_to). It carries the
    // sender attribution a received note lacks, readable only by `to`; it is
    // NOT public or indexer-readable. This mirrors the Aztec reference Token,
    // which likewise emits its `Transfer` event only on the `transfer` path
    // (encrypted to the recipient) and emits nothing on mint, burn, the public
    // paths, or the ramps -- those balance changes are already recorded by the
    // notes themselves (private) or the `public_balances` map (public).
    #[event]
    struct LPTransfer {
        from: AztecAddress,
        to: AztecAddress,
        amount: u128,
    }

    #[storage]
    struct Storage<Context> {
        // The single pair that can mint LP tokens for this instance.
        // Immutable; set at construction; never changes.
        pair: PublicImmutable<AztecAddress, Context>,
        balances: Owned<BalanceSet<Context>, Context>,
        total_supply: PublicMutable<u128, Context>,
        public_balances: Map<AztecAddress, PublicMutable<u128, Context>, Context>,
        symbol: PublicImmutable<FieldCompressedString, Context>,
        name: PublicImmutable<FieldCompressedString, Context>,
        decimals: PublicImmutable<u8, Context>,
    }

    #[external("public")]
    #[initializer]
    fn constructor(pair: AztecAddress) {
        assert(!pair.is_zero(), "pair cannot be zero");
        self.storage.pair.initialize(pair);
        self.storage.name.initialize(
            FieldCompressedString::from_field(field_from_bytes(LP_TOKEN_NAME_BYTES, true)),
        );
        self.storage.symbol.initialize(
            FieldCompressedString::from_field(field_from_bytes(LP_TOKEN_SYMBOL_BYTES, true)),
        );
        self.storage.decimals.initialize(LP_TOKEN_DECIMALS);
    }

    #[external("public")]
    #[view]
    fn public_get_name() -> FieldCompressedString {
        self.storage.name.read()
    }

    #[external("private")]
    #[view]
    fn private_get_name() -> FieldCompressedString {
        self.storage.name.read()
    }

    #[external("public")]
    #[view]
    fn public_get_symbol() -> pub FieldCompressedString {
        self.storage.symbol.read()
    }

    #[external("private")]
    #[view]
    fn private_get_symbol() -> pub FieldCompressedString {
        self.storage.symbol.read()
    }

    #[external("public")]
    #[view]
    fn public_get_decimals() -> pub u8 {
        self.storage.decimals.read()
    }

    #[external("private")]
    #[view]
    fn private_get_decimals() -> pub u8 {
        self.storage.decimals.read()
    }

    #[external("public")]
    #[view]
    fn get_pair() -> Field {
        self.storage.pair.read().to_field()
    }

    #[external("public")]
    #[view]
    fn total_supply() -> u128 {
        self.storage.total_supply.read()
    }

    #[external("public")]
    #[view]
    fn balance_of_public(owner: AztecAddress) -> u128 {
        self.storage.public_balances.at(owner).read()
    }

    #[external("public")]
    fn mint_to_public(to: AztecAddress, amount: u128) {
        assert(self.msg_sender() == self.storage.pair.read(), "ONLY_PAIR");
        let new_balance = self.storage.public_balances.at(to).read().add(amount);
        let supply = self.storage.total_supply.read().add(amount);
        self.storage.public_balances.at(to).write(new_balance);
        self.storage.total_supply.write(supply);
    }

    #[authorize_once("from", "authwit_nonce")]
    #[external("public")]
    fn transfer_in_public(
        from: AztecAddress,
        to: AztecAddress,
        amount: u128,
        authwit_nonce: Field,
    ) {
        let from_balance = self.storage.public_balances.at(from).read().sub(amount);
        self.storage.public_balances.at(from).write(from_balance);
        let to_balance = self.storage.public_balances.at(to).read().add(amount);
        self.storage.public_balances.at(to).write(to_balance);
    }

    #[authorize_once("from", "authwit_nonce")]
    #[external("public")]
    fn burn_public(from: AztecAddress, amount: u128, authwit_nonce: Field) {
        let from_balance = self.storage.public_balances.at(from).read().sub(amount);
        self.storage.public_balances.at(from).write(from_balance);
        let new_supply = self.storage.total_supply.read().sub(amount);
        self.storage.total_supply.write(new_supply);
    }

    #[authorize_once("from", "authwit_nonce")]
    #[external("private")]
    fn transfer_to_public(
        from: AztecAddress,
        to: AztecAddress,
        amount: u128,
        authwit_nonce: Field,
    ) {
        self.storage.balances.at(from).sub(amount).deliver(MessageDelivery.ONCHAIN_CONSTRAINED);
        self.enqueue_self._increase_public_balance(to, amount);
    }

    #[authorize_once("from", "authwit_nonce")]
    #[external("private")]
    fn transfer_to_public_and_prepare_private_balance_increase(
        from: AztecAddress,
        to: AztecAddress,
        amount: u128,
        authwit_nonce: Field,
    ) -> PartialUintNote {
        self.storage.balances.at(from).sub(amount).deliver(MessageDelivery.ONCHAIN_CONSTRAINED);
        self.enqueue_self._increase_public_balance(to, amount);
        self.internal._prepare_private_balance_increase(from)
    }

    #[external("private")]
    fn transfer(to: AztecAddress, amount: u128) {
        let from = self.msg_sender();

        let change = self.internal.subtract_balance(from, amount, INITIAL_TRANSFER_CALL_MAX_NOTES);
        self.storage.balances.at(from).add(change).deliver(MessageDelivery.ONCHAIN_UNCONSTRAINED);
        self.storage.balances.at(to).add(amount).deliver(MessageDelivery.ONCHAIN_UNCONSTRAINED);

        self.emit(LPTransfer { from, to, amount }).deliver_to(
            to,
            MessageDelivery.ONCHAIN_UNCONSTRAINED,
        );
    }

    #[internal("private")]
    fn subtract_balance(account: AztecAddress, amount: u128, max_notes: u32) -> u128 {
        let subtracted = self.storage.balances.at(account).try_sub(amount, max_notes);
        assert(subtracted > 0 as u128, "Balance too low");
        if subtracted >= amount {
            subtracted - amount
        } else {
            let remaining = amount - subtracted;
            compute_recurse_subtract_balance_call(*context, account, remaining).call(context)
        }
    }

    #[no_predicates]
    #[contract_library_method]
    fn compute_recurse_subtract_balance_call(
        context: PrivateContext,
        account: AztecAddress,
        remaining: u128,
    ) -> PrivateCall<25, 2, u128> {
        SigalSwapLPToken::at(context.this_address())._recurse_subtract_balance(account, remaining)
    }

    #[only_self]
    #[external("private")]
    fn _recurse_subtract_balance(account: AztecAddress, amount: u128) -> u128 {
        self.internal.subtract_balance(account, amount, RECURSIVE_TRANSFER_CALL_MAX_NOTES)
    }

    #[external("private")]
    fn cancel_authwit(inner_hash: Field) {
        let on_behalf_of = self.msg_sender();
        let nullifier = compute_authwit_nullifier(on_behalf_of, inner_hash);
        self.context.push_nullifier(nullifier);
    }

    #[authorize_once("from", "authwit_nonce")]
    #[external("private")]
    fn transfer_in_private(
        from: AztecAddress,
        to: AztecAddress,
        amount: u128,
        authwit_nonce: Field,
    ) {
        self.storage.balances.at(from).sub(amount).deliver(MessageDelivery.ONCHAIN_CONSTRAINED);
        self.storage.balances.at(to).add(amount).deliver(MessageDelivery.ONCHAIN_CONSTRAINED);
    }

    #[authorize_once("from", "authwit_nonce")]
    #[external("private")]
    fn burn_private(from: AztecAddress, amount: u128, authwit_nonce: Field) {
        self.storage.balances.at(from).sub(amount).deliver(MessageDelivery.ONCHAIN_CONSTRAINED);
        self.enqueue_self._reduce_total_supply(amount);
    }

    #[external("private")]
    fn transfer_to_private(to: AztecAddress, amount: u128) {
        let from = self.msg_sender();
        let partial_note = self.internal._prepare_private_balance_increase(to);
        self.enqueue_self._finalize_transfer_to_private_unsafe(from, amount, partial_note);
    }

    #[external("private")]
    fn prepare_private_balance_increase(to: AztecAddress) -> PartialUintNote {
        self.internal._prepare_private_balance_increase(to)
    }

    #[internal("private")]
    fn _prepare_private_balance_increase(to: AztecAddress) -> PartialUintNote {
        let partial_note = UintNote::partial(
            to,
            self.context,
            to,
            self.msg_sender(),
        );
        partial_note
    }

    #[external("public")]
    fn finalize_transfer_to_private(amount: u128, partial_note: PartialUintNote) {
        let from_and_completer = self.msg_sender();
        self.internal._finalize_transfer_to_private(from_and_completer, amount, partial_note);
    }

    #[authorize_once("from", "authwit_nonce")]
    #[external("private")]
    fn finalize_transfer_to_private_from_private(
        from: AztecAddress,
        partial_note: PartialUintNote,
        amount: u128,
        authwit_nonce: Field,
    ) {
        self.storage.balances.at(from).sub(amount).deliver(MessageDelivery.ONCHAIN_CONSTRAINED);
        partial_note.complete_from_private(self.context, self.msg_sender(), self.storage.balances.get_storage_slot(), amount);
    }

    #[external("public")]
    #[only_self]
    fn _finalize_transfer_to_private_unsafe(
        from_and_completer: AztecAddress,
        amount: u128,
        partial_note: PartialUintNote,
    ) {
        self.internal._finalize_transfer_to_private(from_and_completer, amount, partial_note);
    }

    #[internal("public")]
    fn _finalize_transfer_to_private(
        from_and_completer: AztecAddress,
        amount: u128,
        partial_note: PartialUintNote,
    ) {
        let balance_storage = self.storage.public_balances.at(from_and_completer);
        let from_balance = balance_storage.read().sub(amount);
        balance_storage.write(from_balance);
        partial_note.complete(self.context, from_and_completer, self.storage.balances.get_storage_slot(), amount);
    }

    #[external("public")]
    fn finalize_mint_to_private(amount: u128, partial_note: PartialUintNote) {
        let minter_and_completer = self.msg_sender();
        assert(minter_and_completer == self.storage.pair.read(), "ONLY_PAIR");
        self.internal._finalize_mint_to_private(minter_and_completer, amount, partial_note);
    }

    #[internal("public")]
    fn _finalize_mint_to_private(
        completer: AztecAddress,
        amount: u128,
        partial_note: PartialUintNote,
    ) {
        let supply = self.storage.total_supply.read().add(amount);
        self.storage.total_supply.write(supply);
        partial_note.complete(self.context, completer, self.storage.balances.get_storage_slot(), amount);
    }

    #[external("public")]
    #[only_self]
    fn _increase_public_balance(to: AztecAddress, amount: u128) {
        let to_balance = self.storage.public_balances.at(to);
        let new_balance = to_balance.read().add(amount);
        to_balance.write(new_balance);
    }

    #[external("public")]
    #[only_self]
    fn _reduce_total_supply(amount: u128) {
        let new_supply = self.storage.total_supply.read().sub(amount);
        self.storage.total_supply.write(new_supply);
    }

    #[external("utility")]
    unconstrained fn balance_of_private(owner: AztecAddress) -> u128 {
        self.storage.balances.at(owner).balance_of()
    }
}
