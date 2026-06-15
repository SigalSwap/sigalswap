// Verifies that `self.address` is available and correct inside a contract's
// constructor. The LP Token derived-address design depends on the pair's
// constructor being able to read its own address to compute the LP Token's
// derived address. If `self.address` is unavailable or incorrect in a
// constructor context, the design needs adjustment.

use aztec::macros::aztec;

#[aztec]
pub contract SelfAddressTest {
    use aztec::{
        macros::{
            functions::{external, initializer},
            storage::storage,
        },
        protocol::address::AztecAddress,
        state_vars::PublicImmutable,
    };

    #[storage]
    struct Storage<Context> {
        stored_address: PublicImmutable<AztecAddress, Context>,
    }

    #[initializer]
    #[external("public")]
    fn constructor() {
        self.storage.stored_address.initialize(self.address);
    }

    #[external("utility")]
    unconstrained fn get_stored_address() -> pub AztecAddress {
        self.storage.stored_address.read()
    }
}
