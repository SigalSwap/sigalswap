// Test-harness crate for sigalswap_factory. Hosts the TXE integration tests so
// the mock_pair_v2 fixture stays out of the production factory build graph (see
// Nargo.toml). This crate is never deployed.
use aztec::macros::aztec;

mod test;

#[aztec]
pub contract SigalSwapFactoryTests {
    use aztec::macros::functions::{external, initializer};

    #[external("public")]
    #[initializer]
    fn constructor() {}
}
