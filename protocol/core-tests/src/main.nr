// Test-harness crate for sigalswap_core. Hosts the TXE integration tests so the
// test-fixture contracts stay out of the production core build graph (see
// Nargo.toml). This crate is never deployed.
use aztec::macros::aztec;

mod test;

#[aztec]
pub contract SigalSwapCoreTests {
    // Minimal dummy contract so this crate is type = "contract" (which the TXE
    // test runner expects). All real content is in `mod test`.
    use aztec::macros::functions::{external, initializer};

    #[external("public")]
    #[initializer]
    fn constructor() {}
}
