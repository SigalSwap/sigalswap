// Extracts the LP Token's contract_class_id by deploying via the low-level
// TXE oracle and asserting against a sentinel. The assertion fails,
// revealing the real class_id in the error output. Copy the value from
// that output into the pair contract's `LP_TOKEN_CLASS_ID` constant.
//
// This test is expected to fail during class_id extraction and expected to
// pass once the LP Token bytecode is stable (after updating
// EXPECTED_LP_TOKEN_CLASS_ID below). It guards the invariant that pair
// source and LP Token bytecode stay in sync: if someone edits the LP Token,
// its class_id changes, this assertion fails, and they know to update pair
// source and rebuild.

use aztec::{
    protocol::{address::AztecAddress, traits::ToField},
    test::helpers::txe_oracles,
};

// The class_id baked into the pair's source as `LP_TOKEN_CLASS_ID`.
// This constant must match the runtime class_id of SigalSwapLPToken's
// compiled bytecode. If you edit the LP Token source, recompile, and this
// test fails with a new hex value in its println output, update this
// constant AND the pair's matching constant together, then recompile the
// pair. The coupling keeps the pair and its LP Token in sync.
global EXPECTED_LP_TOKEN_CLASS_ID: Field =
    0x18d88f757fa7311208ca30529ea9cd60c78a2823a0e287ec661cbdc7f193f26c;

#[test]
unconstrained fn lp_token_class_id_matches_expected() {
    let args: [Field; 1] = [1];
    let instance = txe_oracles::deploy(
        "@sigalswap_lp_token/SigalSwapLPToken",
        "constructor",
        args,
        0xdead,
        1,
        AztecAddress::zero(),
    );
    let class_id = instance.contract_class_id.to_field();
    std::println(f"LP_TOKEN_CLASS_ID = {class_id}");
    assert_eq(class_id, EXPECTED_LP_TOKEN_CLASS_ID);
}
