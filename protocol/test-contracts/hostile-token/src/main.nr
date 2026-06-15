// Mock token with multi-mode dispatch for fuzzing the pair's
// token-interaction assumptions. Implements a selector-compatible subset
// of the standard Aztec Token interface -- only the public-side methods
// the pair actually calls on public-direct entry points
// (`add_liquidity_public`, `swap_exact_in_public`, `swap_exact_out_public`,
// `remove_liquidity_public`).
//
// Each test scenario flips `mode` (or calls `force_rebase`) to swap in a
// distinct misbehavior, then exercises a pair entry and asserts the
// observed defense. Mocks for any additional weird-token category go
// here as new mode constants -- adding modes is cheaper than adding
// contracts.

use aztec::macros::aztec;

#[aztec]
pub contract HostileToken {
    use aztec::{
        macros::{
            functions::{authorize_once, external, initializer, view},
            storage::storage,
        },
        protocol::address::AztecAddress,
        state_vars::{Map, PublicMutable},
    };

    // Mode selectors. Kept as `u32` (not `enum`) so test code can pass a
    // plain integer literal and the storage write/read is straightforward.
    //   0 = HONEST              canonical Token behavior; baseline.
    //   1 = NOOP_TRANSFER       transfer_in_public accepts the call but does
    //                           not move state. Pair must detect via balance
    //                           delta and revert.
    //   2 = UNDER_DELIVERY      moves (amount * under_factor / 100) to `to`
    //                           with `under_factor < 100`. Models a
    //                           fee-on-transfer / burn-on-transfer token.
    //                           Pair-direct entries absorb the undershoot;
    //                           router-mediated calls reject it.
    //   3 = OVER_DELIVERY       credits (amount * over_factor / 100) to `to`
    //                           with `over_factor > 100`; from-balance only
    //                           debited by `amount`, surplus minted out of
    //                           thin air. Pair should cap usable deposit and
    //                           leave the surplus skim-claimable.
    //   4 = HOSTILE_BALANCE     balance_of_public returns `hostile_balance_value`
    //                           when queried for `hostile_balance_target`,
    //                           otherwise honest. Tests whether pair logic
    //                           is fooled by a token mis-reporting its own
    //                           state -- it is, with all the downstream
    //                           consequences. Defense lives at the
    //                           token-whitelisting layer, not in the pair.
    //   5 = REVERT_ON_RECIPIENT transfer_in_public asserts the recipient is
    //                           not `hostile_recipient`. Pair must surface
    //                           the underlying revert cleanly without
    //                           half-state.
    global MODE_HONEST: u32 = 0;
    global MODE_NOOP_TRANSFER: u32 = 1;
    global MODE_UNDER_DELIVERY: u32 = 2;
    global MODE_OVER_DELIVERY: u32 = 3;
    global MODE_HOSTILE_BALANCE: u32 = 4;
    global MODE_REVERT_ON_RECIPIENT: u32 = 5;

    #[storage]
    struct Storage<Context> {
        public_balances: Map<AztecAddress, PublicMutable<u128, Context>, Context>,
        total_supply: PublicMutable<u128, Context>,
        mode: PublicMutable<u32, Context>,
        // Per-mode parameters. Default to harmless values; tests set the
        // ones they need before flipping the mode.
        under_factor: PublicMutable<u128, Context>,
        over_factor: PublicMutable<u128, Context>,
        hostile_balance_target: PublicMutable<AztecAddress, Context>,
        hostile_balance_value: PublicMutable<u128, Context>,
        hostile_recipient: PublicMutable<AztecAddress, Context>,
    }

    #[external("public")]
    #[initializer]
    fn constructor() {
        // Default to HONEST; tests flip the mode before exercising attacks.
        self.storage.mode.write(MODE_HONEST);
    }

    // ----- Mode control (test-only setters) ----------------------------

    #[external("public")]
    fn set_mode(new_mode: u32) {
        self.storage.mode.write(new_mode);
    }

    #[external("public")]
    fn set_under_factor(factor: u128) {
        self.storage.under_factor.write(factor);
    }

    #[external("public")]
    fn set_over_factor(factor: u128) {
        self.storage.over_factor.write(factor);
    }

    #[external("public")]
    fn set_hostile_balance(target: AztecAddress, value: u128) {
        self.storage.hostile_balance_target.write(target);
        self.storage.hostile_balance_value.write(value);
    }

    #[external("public")]
    fn set_hostile_recipient(recipient: AztecAddress) {
        self.storage.hostile_recipient.write(recipient);
    }

    /// Direct balance adjustment that bypasses transfer flow entirely.
    /// Models a rebasing token whose admin can spontaneously change
    /// balances out from under the pair. Recovery path is the pair's
    /// `skim()` / `sync()`.
    #[external("public")]
    fn force_rebase(account: AztecAddress, new_balance: u128) {
        let old = self.storage.public_balances.at(account).read();
        self.storage.public_balances.at(account).write(new_balance);
        let supply = self.storage.total_supply.read();
        let new_supply = if new_balance >= old {
            supply + (new_balance - old)
        } else {
            supply - (old - new_balance)
        };
        self.storage.total_supply.write(new_supply);
    }

    // ----- Selector-compatible Token interface (public-side only) -----

    #[external("public")]
    fn mint_to_public(to: AztecAddress, amount: u128) {
        let new_balance = self.storage.public_balances.at(to).read() + amount;
        let supply = self.storage.total_supply.read() + amount;
        self.storage.public_balances.at(to).write(new_balance);
        self.storage.total_supply.write(supply);
    }

    #[external("public")]
    #[view]
    fn balance_of_public(owner: AztecAddress) -> u128 {
        let mode = self.storage.mode.read();
        if mode == MODE_HOSTILE_BALANCE {
            let target = self.storage.hostile_balance_target.read();
            if owner == target {
                self.storage.hostile_balance_value.read()
            } else {
                self.storage.public_balances.at(owner).read()
            }
        } else {
            self.storage.public_balances.at(owner).read()
        }
    }

    #[external("public")]
    #[view]
    fn total_supply() -> u128 {
        self.storage.total_supply.read()
    }

    #[authorize_once("from", "authwit_nonce")]
    #[external("public")]
    fn transfer_in_public(
        from: AztecAddress,
        to: AztecAddress,
        amount: u128,
        authwit_nonce: Field,
    ) {
        let mode = self.storage.mode.read();
        if mode == MODE_NOOP_TRANSFER {
            // Accept, do nothing. Pair detects via balance delta.
        } else if mode == MODE_UNDER_DELIVERY {
            let factor = self.storage.under_factor.read();
            let delivered = amount * factor / 100;
            // Debit `from` by the full requested amount; only `delivered`
            // lands at `to`. The undelivered remainder is burned (total
            // supply shrinks).
            let from_balance = self.storage.public_balances.at(from).read() - amount;
            self.storage.public_balances.at(from).write(from_balance);
            let to_balance = self.storage.public_balances.at(to).read() + delivered;
            self.storage.public_balances.at(to).write(to_balance);
            let supply = self.storage.total_supply.read() - (amount - delivered);
            self.storage.total_supply.write(supply);
        } else if mode == MODE_OVER_DELIVERY {
            let factor = self.storage.over_factor.read();
            let delivered = amount * factor / 100;
            // Debit `from` by `amount`; credit `to` with the inflated
            // `delivered`. Total supply grows by the surplus.
            let from_balance = self.storage.public_balances.at(from).read() - amount;
            self.storage.public_balances.at(from).write(from_balance);
            let to_balance = self.storage.public_balances.at(to).read() + delivered;
            self.storage.public_balances.at(to).write(to_balance);
            let supply = self.storage.total_supply.read() + (delivered - amount);
            self.storage.total_supply.write(supply);
        } else if mode == MODE_REVERT_ON_RECIPIENT {
            assert(
                to != self.storage.hostile_recipient.read(),
                "HOSTILE_TOKEN_REVERT",
            );
            let from_balance = self.storage.public_balances.at(from).read() - amount;
            self.storage.public_balances.at(from).write(from_balance);
            let to_balance = self.storage.public_balances.at(to).read() + amount;
            self.storage.public_balances.at(to).write(to_balance);
        } else {
            // MODE_HONEST and MODE_HOSTILE_BALANCE (which only affects the
            // read path, not transfer) fall through to canonical behavior.
            let from_balance = self.storage.public_balances.at(from).read() - amount;
            self.storage.public_balances.at(from).write(from_balance);
            let to_balance = self.storage.public_balances.at(to).read() + amount;
            self.storage.public_balances.at(to).write(to_balance);
        }
    }
}
