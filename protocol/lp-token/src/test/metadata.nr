use crate::{SigalSwapLPToken, test::utils::setup};

/// Decimals is hardcoded to 18.
#[test]
unconstrained fn public_decimals_is_18() {
    let (mut env, lp_address, _pair, _outsider) = setup();
    let lp = SigalSwapLPToken::at(lp_address);

    let decimals: u8 = env.view_public( lp.public_get_decimals());
    assert_eq(decimals, 18);
}

/// Name round-trips to the expected byte pattern (SigalSwap LP + 19 null bytes).
#[test]
unconstrained fn public_name_returns_expected_bytes() {
    let (mut env, lp_address, _pair, _outsider) = setup();
    let lp = SigalSwapLPToken::at(lp_address);

    let name = env.view_public( lp.public_get_name());
    let bytes = name.to_bytes();

    // "SigalSwap LP"
    assert_eq(bytes[0], 0x53); // 'S'
    assert_eq(bytes[1], 0x69); // 'i'
    assert_eq(bytes[2], 0x67); // 'g'
    assert_eq(bytes[3], 0x61); // 'a'
    assert_eq(bytes[4], 0x6c); // 'l'
    assert_eq(bytes[5], 0x53); // 'S'
    assert_eq(bytes[6], 0x77); // 'w'
    assert_eq(bytes[7], 0x61); // 'a'
    assert_eq(bytes[8], 0x70); // 'p'
    assert_eq(bytes[9], 0x20); // ' '
    assert_eq(bytes[10], 0x4c); // 'L'
    assert_eq(bytes[11], 0x50); // 'P'
    // Trailing null padding
    assert_eq(bytes[12], 0);
    assert_eq(bytes[30], 0);
}

/// Symbol round-trips to "SSLP" + 27 null bytes.
#[test]
unconstrained fn public_symbol_returns_expected_bytes() {
    let (mut env, lp_address, _pair, _outsider) = setup();
    let lp = SigalSwapLPToken::at(lp_address);

    let symbol = env.view_public( lp.public_get_symbol());
    let bytes = symbol.to_bytes();

    // "SSLP"
    assert_eq(bytes[0], 0x53); // 'S'
    assert_eq(bytes[1], 0x53); // 'S'
    assert_eq(bytes[2], 0x4c); // 'L'
    assert_eq(bytes[3], 0x50); // 'P'
    // Trailing null padding
    assert_eq(bytes[4], 0);
    assert_eq(bytes[30], 0);
}
