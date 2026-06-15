// Test-harness crate for sigalswap_periphery. Hosts the TXE integration tests so
// the abusive_pair / mock_factory fixtures stay out of the production periphery
// build graph (see Nargo.toml). This crate is never deployed.
use aztec::macros::aztec;

mod test;

#[aztec]
pub contract SigalSwapPeripheryTests {
    use aztec::macros::functions::{external, initializer};

    #[external("public")]
    #[initializer]
    fn constructor() {}
}
