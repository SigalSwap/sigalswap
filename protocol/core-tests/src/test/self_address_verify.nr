// Verifies that `self.address` inside a contract's constructor returns the
// contract's own deployed address. The LP Token derived-address design in
// SigalSwap depends on the pair being able to compute its LP Token's
// address at construction time using `self.address` as one of the inputs.
// If this assumption is wrong, the design has to change before we build it.

use aztec::{protocol::address::AztecAddress, test::helpers::test_environment::TestEnvironment};
use self_address_test::SelfAddressTest;

#[test]
unconstrained fn self_address_in_constructor_matches_deployed_address() {
    let mut env = TestEnvironment::new();
    let deployer = env.create_contract_account();

    let init = SelfAddressTest::interface().constructor();
    let deployed_address = env
        .deploy("@self_address_test/SelfAddressTest")
        .with_public_initializer(deployer, init);

    let stored: AztecAddress =
        env.execute_utility(SelfAddressTest::at(deployed_address).get_stored_address());

    assert_eq(stored, deployed_address);
}
