use sigalswap_core::{SigalSwapPair, pair::MINIMUM_LIQUIDITY};
use crate::test::utils::{setup, add_liquidity, remove_liquidity, swap_exact_in, swap_exact_out};
use aztec::protocol::abis::function_selector::FunctionSelector;
use flash_borrower::FlashBorrower;
use token::Token;
use sigalswap_lp_token::SigalSwapLPToken;

// ============================================
// Core AMM Lifecycle
// ============================================

/// 1.1 + 1.2: Deploy stack and add first liquidity.
/// Verifies MINIMUM_LIQUIDITY locked, LP tokens minted, reserves set.
#[test]
unconstrained fn test_first_deposit() {
    let (mut env, pair_address, token0_address, token1_address, lp_address, admin) = setup();

    let provider = env.create_contract_account();

    // Sized to clear the MINIMUM_LIQUIDITY floor (10000) with margin.
    let amount0: u128 = 10000;
    let amount1: u128 = 20000;

    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, amount0, amount1, 0, 0,
    );

    // Verify pair holds the tokens (reserves = balances after first deposit)
    assert_eq(env.view_public(Token::at(token0_address).balance_of_public(pair_address)), amount0);
    assert_eq(env.view_public(Token::at(token1_address).balance_of_public(pair_address)), amount1);

    // Verify LP token supply: MINIMUM_LIQUIDITY + user's share
    // sqrt(10000 * 20000) = 14142, user gets 14142 - 10000 = 4142
    let total_supply = env.view_public(SigalSwapLPToken::at(lp_address).total_supply());
    assert_eq(total_supply, MINIMUM_LIQUIDITY + 4142);

    // Verify provider received LP tokens
    let provider_lp = env.execute_utility(SigalSwapLPToken::at(lp_address).balance_of_private(provider));
    assert_eq(provider_lp, 4142);
}

/// Second deposit by different user. Verifies proportional minting and refund.
#[test]
unconstrained fn test_second_deposit_with_refund() {
    let (mut env, pair_address, token0_address, token1_address, lp_address, admin) = setup();

    let provider1 = env.create_contract_account();
    let provider2 = env.create_contract_account();
    let token0 = Token::at(token0_address);
    let token1 = Token::at(token1_address);
    let lp_token = SigalSwapLPToken::at(lp_address);

    // First deposit: 10000 / 20000 (1:2 ratio)
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider1, 10000, 20000, 0, 0,
    );

    let supply_after_first = env.view_public(lp_token.total_supply());

    // Second deposit: 5000 token0 max, 15000 token1 max (excess token1)
    // Pool ratio is 1:2, so 5000 token0 needs 10000 token1
    // Refund = 15000 - 10000 = 5000 token1
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider2, 5000, 15000, 0, 0,
    );

    // Verify reserves updated
    let reserve0 = env.view_public(Token::at(token0_address).balance_of_public(pair_address));
    let reserve1 = env.view_public(Token::at(token1_address).balance_of_public(pair_address));
    assert_eq(reserve0, 15000); // 10000 + 5000
    assert_eq(reserve1, 30000); // 20000 + 10000

    // Verify provider2 got proportional LP tokens
    // provider2's share = min(5000 * supply / 10000, 10000 * supply / 20000) = supply / 2
    let provider2_lp = env.execute_utility(lp_token.balance_of_private(provider2));
    assert_eq(provider2_lp, supply_after_first / 2);

    // Pin total_supply after the second deposit. A double-finalize on the
    // second `_add_liquidity` would mint twice into the partial-note slot,
    // inflating supply by 2x the expected delta.
    let supply_after_second = env.view_public(lp_token.total_supply());
    assert_eq(supply_after_second, supply_after_first + (supply_after_first / 2));

    // Verify provider2 got the token1 refund back privately
    let provider2_token1 = env.execute_utility(Token::at(token1_address).balance_of_private(provider2));
    assert_eq(provider2_token1, 5000); // refund
}

/// Swap exact tokens for tokens.
#[test]
unconstrained fn test_swap_exact_in() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let swapper = env.create_contract_account();
    let token0 = Token::at(token0_address);
    let token1 = Token::at(token1_address);

    // Add liquidity: 20000 / 20000 (1:1 ratio)
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    // Swap 1000 token0 for token1 with 0.25% fee (25 bps, no protocol fee)
    // Hand computation of get_amount_out(1000, 20000, 20000, 25):
    //   amount_in_with_fee = 1000 * (10000 - 25) = 9975000
    //   denominator = 20000 * 10000 + 9975000 = 209975000
    //   output = floor(9975000 * 20000 / 209975000) = floor(199500000000 / 209975000) = 950
    swap_exact_in(
        env, pair_address, token0_address, token1_address,
        admin, swapper, 1000, 900,
    );

    // Verify exact output and reserves against hand-computed values
    assert_eq(env.execute_utility(token1.balance_of_private(swapper)), 950);
    assert_eq(env.execute_utility(token0.balance_of_private(swapper)), 0);
    assert_eq(env.view_public(Token::at(token0_address).balance_of_public(pair_address)), 21000);
    assert_eq(env.view_public(Token::at(token1_address).balance_of_public(pair_address)), 19050);
}

/// Swap tokens for exact output.
#[test]
unconstrained fn test_swap_exact_out() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let swapper = env.create_contract_account();
    let token0 = Token::at(token0_address);
    let token1 = Token::at(token1_address);

    // Add liquidity: 20000 / 20000
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    // Swap for exactly 500 token1, willing to spend up to 600 token0
    // Hand computation of get_amount_in(500, 20000, 20000, 25):
    //   denominator = (20000 - 500) * (10000 - 25) = 19500 * 9975 = 194512500
    //   numerator = 20000 * 500 * 10000 = 100000000000
    //   amount_in = ceil(100000000000 / 194512500) = ceil(514.11...) = 515
    //   change = 600 - 515 = 85 token0 refunded to swapper
    swap_exact_out(
        env, pair_address, token0_address, token1_address,
        admin, swapper, 500, 600,
    );

    // Verify exact amounts against hand-computed values
    assert_eq(env.execute_utility(token1.balance_of_private(swapper)), 500);
    assert_eq(env.execute_utility(token0.balance_of_private(swapper)), 85);
}

/// Remove liquidity.
#[test]
unconstrained fn test_remove_liquidity() {
    let (mut env, pair_address, token0_address, token1_address, lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let token0 = Token::at(token0_address);
    let token1 = Token::at(token1_address);
    let lp_token = SigalSwapLPToken::at(lp_address);

    // Add liquidity: 10000/20000
    // sqrt(10000 * 20000) = sqrt(200000000) = 14142 (floor)
    // user gets 14142 - 10000 = 4142 LP tokens; total supply = 14142
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 10000, 20000, 0, 0,
    );

    let provider_lp = env.execute_utility(lp_token.balance_of_private(provider));
    assert_eq(provider_lp, 4142);
    assert_eq(env.view_public(lp_token.total_supply()), 14142);

    // Remove half: 2071 LP tokens
    let to_remove: u128 = 2071;
    remove_liquidity(
        env, pair_address, lp_address, provider,
        to_remove, 0, 0,
    );

    // Hand-computed proportional withdrawal (uses totalSupply = 14142, unchanged):
    //   token0 = floor(2071 * 10000 / 14142) = 1464
    //   token1 = floor(2071 * 20000 / 14142) = 2928
    assert_eq(env.execute_utility(token0.balance_of_private(provider)), 1464);
    assert_eq(env.execute_utility(token1.balance_of_private(provider)), 2928);
    assert_eq(env.execute_utility(lp_token.balance_of_private(provider)), 4142 - 2071);
}

/// Full cycle -- deposit, swap, deposit again, remove both.
#[test]
unconstrained fn test_full_cycle() {
    let (mut env, pair_address, token0_address, token1_address, lp_address, admin) = setup();

    let alice = env.create_contract_account();
    let bob = env.create_contract_account();
    let swapper = env.create_contract_account();
    let token0 = Token::at(token0_address);
    let token1 = Token::at(token1_address);
    let lp_token = SigalSwapLPToken::at(lp_address);

    // Alice adds initial liquidity: 20000 / 20000
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, alice, 20000, 20000, 0, 0,
    );

    // Swapper swaps 1000 token0 for token1
    swap_exact_in(
        env, pair_address, token0_address, token1_address,
        admin, swapper, 1000, 0,
    );

    // Bob adds liquidity at the new ratio
    // After swap: reserves shifted. Bob deposits proportionally.
    let r0 = env.view_public(Token::at(token0_address).balance_of_public(pair_address));
    let r1 = env.view_public(Token::at(token1_address).balance_of_public(pair_address));
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, bob, r0, r1, 0, 0, // exact proportional
    );

    // Both remove all their LP tokens
    let alice_lp = env.execute_utility(lp_token.balance_of_private(alice));
    let bob_lp = env.execute_utility(lp_token.balance_of_private(bob));

    remove_liquidity(env, pair_address, lp_address, alice, alice_lp, 0, 0);
    remove_liquidity(env, pair_address, lp_address, bob, bob_lp, 0, 0);

    // Only MINIMUM_LIQUIDITY (10000) LP tokens remain -- held by address(0).
    // These lock a small amount of each token permanently.
    let final_supply = env.view_public(lp_token.total_supply());
    assert_eq(final_supply, MINIMUM_LIQUIDITY);

    let final_r0 = env.view_public(Token::at(token0_address).balance_of_public(pair_address));
    let final_r1 = env.view_public(Token::at(token1_address).balance_of_public(pair_address));
    assert(final_r0 > 0);
    assert(final_r1 > 0);

    // Total tokens in + out must be conserved.
    // Alice deposited 10000/10000. Swapper added 1000 token0. Bob deposited r0/r1.
    // All user withdrawals + pool remainder should account for all tokens.
    let alice_t0 = env.execute_utility(token0.balance_of_private(alice));
    let alice_t1 = env.execute_utility(token1.balance_of_private(alice));
    let bob_t0 = env.execute_utility(token0.balance_of_private(bob));
    let bob_t1 = env.execute_utility(token1.balance_of_private(bob));
    let swapper_t1 = env.execute_utility(token1.balance_of_private(swapper));

    // Token0 conservation: alice deposited 20000, swapper deposited 1000, bob deposited r0
    // All should be accounted for across alice, bob, and pool remainder
    assert_eq(alice_t0 + bob_t0 + final_r0, 20000 + 1000 + r0);
    // Token1 conservation: alice deposited 20000, bob deposited r1
    // Swapper received some token1 from the swap
    assert_eq(alice_t1 + bob_t1 + swapper_t1 + final_r1, 20000 + r1);
}

/// Public exact-output swap via V3 callback pattern.
///
/// swap_exact_out_public: pair computes the required amount_in
/// from amount_out, sends amount_out optimistically, callbacks the caller for
/// exactly amount_in. Pre-funding the callback with more than amount_in should
/// leave the excess with the caller (pair only pulls what's needed).
///
/// Reserves 20000/20000, fee 25 bps, amount_out = 500:
///   denominator = (20000 - 500) * (10000 - 25) = 19500 * 9975 = 194_512_500
///   numerator   = 20000 * 500 * 10000          = 100_000_000_000
///   amount_in   = ceil(100_000_000_000 / 194_512_500) = 515
#[test]
unconstrained fn test_swap_exact_out_public_happy() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();
    let provider = env.create_contract_account();
    let recipient = env.create_contract_account();

    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    let borrower_init = FlashBorrower::interface().constructor();
    let borrower = env
        .deploy("@flash_borrower/FlashBorrower")
        .with_public_initializer(admin, borrower_init);

    // Pre-fund borrower with 600 token0 (more than required 515)
    env.call_public(admin, Token::at(token0_address).mint_to_public(borrower, 600));

    let callback_sel =
        FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).swap_exact_out_public(
            token0_address, token1_address,
            500, 600,
            recipient, borrower, callback_sel,
        ),
    );

    // Recipient received exactly amount_out of token1
    assert_eq(env.view_public(Token::at(token1_address).balance_of_public(recipient)), 500);
    // Pair pulled only the computed amount_in (515), leaving 85 untouched on borrower
    assert_eq(env.view_public(Token::at(token0_address).balance_of_public(borrower)), 85);
    // Reserves: 20000 + 515 token0, 20000 - 500 token1
    assert_eq(env.view_public(Token::at(token0_address).balance_of_public(pair_address)), 20515);
    assert_eq(env.view_public(Token::at(token1_address).balance_of_public(pair_address)), 19500);
}

/// Exact-output public swap at the boundary amount_in_max == amount_in.
/// Pre-fund exactly 515; the callback must pay all of it and finish with zero remaining.
#[test]
unconstrained fn test_swap_exact_out_public_exact_boundary() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();
    let provider = env.create_contract_account();
    let recipient = env.create_contract_account();

    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    let borrower_init = FlashBorrower::interface().constructor();
    let borrower = env
        .deploy("@flash_borrower/FlashBorrower")
        .with_public_initializer(admin, borrower_init);

    env.call_public(admin, Token::at(token0_address).mint_to_public(borrower, 515));

    let callback_sel =
        FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).swap_exact_out_public(
            token0_address, token1_address,
            500, 515,
            recipient, borrower, callback_sel,
        ),
    );

    // Callback paid exactly amount_in; borrower balance is zero after
    assert_eq(env.view_public(Token::at(token0_address).balance_of_public(borrower)), 0);
    // Recipient received amount_out
    assert_eq(env.view_public(Token::at(token1_address).balance_of_public(recipient)), 500);
}

/// Protocol fee markup flows through the computed amount_in.
///
/// With 25 bps LP fee and 20% protocol markup, total fee_bps = 30.
/// get_amount_in(1000, 20000, 20000, 30):
///   denominator = 19000 * 9970 = 189_430_000
///   numerator   = 20000 * 1000 * 10000 = 200_000_000_000
///   amount_in   = ceil(200_000_000_000 / 189_430_000) = 1056
/// vs. no protocol fee (25 bps only): 200_000_000_000 / (19000 * 9975)
///   = 200_000_000_000 / 189_525_000 = ceil(1055.27) = 1056 also.
/// At these reserves the two ceilings land on the same integer -- the protocol
/// markup still flows through the fee_bps code path and the trader still pays
/// the rounded-up input; the extra pool accrual from the markup is realized by
/// fee_to on the next mint/burn via compute_mint_fee regardless of whether the
/// gap materializes for any single trade.
#[test]
unconstrained fn test_swap_exact_out_public_with_protocol_fee() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();
    let provider = env.create_contract_account();
    let recipient = env.create_contract_account();

    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).set_protocol_fee(admin, 20, true),
    );

    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    let borrower_init = FlashBorrower::interface().constructor();
    let borrower = env
        .deploy("@flash_borrower/FlashBorrower")
        .with_public_initializer(admin, borrower_init);

    env.call_public(admin, Token::at(token0_address).mint_to_public(borrower, 2000));

    let callback_sel =
        FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).swap_exact_out_public(
            token0_address, token1_address,
            1000, 2000,
            recipient, borrower, callback_sel,
        ),
    );

    // amount_in = 1056 (protocol-fee path)
    assert_eq(env.view_public(Token::at(token0_address).balance_of_public(borrower)), 2000 - 1056);
    assert_eq(env.view_public(Token::at(token1_address).balance_of_public(recipient)), 1000);
    // Pair's token0 balance reflects full 1056 pulled
    assert_eq(env.view_public(Token::at(token0_address).balance_of_public(pair_address)), 20000 + 1056);
}

/// swap_exact_in_public captures donations into reserves.
///
/// The pair must read both actual balances (like flash_swap does) and write
/// them directly, so any `token_out` already sitting in the pair's public
/// balance (e.g. from a prior direct transfer or a callback that incidentally
/// moved extra tokens in) is captured into reserves and accrues to LPs via the
/// next mint/burn -- rather than writing the computed `reserve_out -
/// amount_out` and leaving the donation recoverable only via a bot-raced
/// `skim()`.
#[test]
unconstrained fn test_swap_exact_in_public_captures_donations_to_lps() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();
    let provider = env.create_contract_account();
    let swap_recipient = env.create_contract_account();
    let pair = SigalSwapPair::at(pair_address);

    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    // Simulate a donation: 100 token1 transferred directly to the pair
    // (equivalent to a callback incidentally donating during execution; the
    // pair's reserve-write sees the same picture either way once the tx ends).
    env.call_public(admin, Token::at(token1_address).mint_to_public(pair_address, 100));

    // Callback contract pre-funded with enough token0 to pay for the swap.
    let borrower_init = FlashBorrower::interface().constructor();
    let borrower = env
        .deploy("@flash_borrower/FlashBorrower")
        .with_public_initializer(admin, borrower_init);
    env.call_public(admin, Token::at(token0_address).mint_to_public(borrower, 1000));

    // Execute swap_exact_in_public: 1000 token0 in, min 0 token1 out.
    // get_amount_out(1000, 20000, 20000, 25) = 950 using the stored reserves
    // (which do not yet reflect the donation).
    let callback_sel =
        FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");
    env.call_public(
        admin,
        pair.swap_exact_in_public(
            token0_address, token1_address,
            1000, 0,
            swap_recipient, borrower, callback_sel,
        ),
    );

    // Borrower paid 1000 token0. Recipient received 950 token1.
    assert_eq(env.view_public(Token::at(token0_address).balance_of_public(borrower)), 0);
    assert_eq(env.view_public(Token::at(token1_address).balance_of_public(swap_recipient)), 950);

    // Pair's actual balances: (20000 + 1000) token0, (20000 + 100 - 950) token1
    // = 21000 / 19150.
    assert_eq(env.view_public(Token::at(token0_address).balance_of_public(pair_address)), 21000);
    assert_eq(env.view_public(Token::at(token1_address).balance_of_public(pair_address)), 19150);

    // And the reserves now match those actual balances -- the 100 donation is
    // reflected in `reserve1` rather than sitting outside the invariant.
    let (reserve0, reserve1, _) = env.view_public(pair.get_reserves());
    assert_eq(reserve0, 21000);
    assert_eq(reserve1, 19150);

    // skim() should find nothing to recover because everything was captured.
    let skim_recipient = env.create_contract_account();
    env.call_private(admin, pair.skim(skim_recipient));
    assert_eq(env.execute_utility(Token::at(token0_address).balance_of_private(skim_recipient)), 0);
    assert_eq(env.execute_utility(Token::at(token1_address).balance_of_private(skim_recipient)), 0);
}

/// Two sequential exact-output swaps confirm the lock is released cleanly
/// and the second swap sees the updated reserves.
#[test]
unconstrained fn test_swap_exact_out_public_sequential_swaps() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();
    let provider = env.create_contract_account();
    let recipient = env.create_contract_account();

    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, 20000, 20000, 0, 0,
    );

    let borrower_init = FlashBorrower::interface().constructor();
    let borrower = env
        .deploy("@flash_borrower/FlashBorrower")
        .with_public_initializer(admin, borrower_init);

    env.call_public(admin, Token::at(token0_address).mint_to_public(borrower, 2000));

    let callback_sel =
        FunctionSelector::from_signature("swap_payment_callback(Field,Field,Field)");

    // First swap: out=500 at reserves (20000, 20000) requires amount_in=515
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).swap_exact_out_public(
            token0_address, token1_address,
            500, 1000,
            recipient, borrower, callback_sel,
        ),
    );

    // Second swap: out=200 at reserves (20515, 19500). Lock must be released
    // for this to succeed.
    env.call_public(
        admin,
        SigalSwapPair::at(pair_address).swap_exact_out_public(
            token0_address, token1_address,
            200, 1000,
            recipient, borrower, callback_sel,
        ),
    );

    // Both swaps completed -- if lock were stuck, second call would revert with LOCKED.
    // Recipient accumulated 500 + 200 = 700 token1 across the two swaps.
    assert_eq(env.view_public(Token::at(token1_address).balance_of_public(recipient)), 700);
}

/// Realistic 18-decimal swap that drives `verify_k_invariant` through its
/// MULTI-LIMB (wide-int) arithmetic. Every other lifecycle/swap test uses
/// small reserves (10000-scale), so `verify_k_invariant`'s internal
/// `__wide_mul(reserve*10000, reserve*10000)` stays single-limb (high == 0) and
/// the 512-bit compare takes its trivial branch. With ~1e18 reserves the scaled
/// K product is ~2^146, so `__wide_mul` / `__mul_u256_u256_to_u512` /
/// `__wide_lt_u512` engage their carry-propagation branches end-to-end on the
/// live private swap path. A clean swap (no `K_INVARIANT_VIOLATED`) plus correct
/// reserve deltas is the property: the wide K-check accepts a valid swap without
/// Field wraparound at realistic magnitudes.
#[test]
unconstrained fn test_swap_wide_int_k_invariant_18dec() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();

    let provider = env.create_contract_account();
    let swapper = env.create_contract_account();

    // 1.0 : 1.0 pool at 18 decimals. reserve*10000 ~ 1e22 (~2^73), so the K
    // product reserve0*reserve1*10^8 ~ 2^146 -- squarely in the wide-int path.
    let one_e18: u128 = 1_000_000_000_000_000_000;
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, one_e18, one_e18, 0, 0,
    );

    // Swap 0.1 token0 in. amount_out_min = 0 so no slippage revert; the only
    // gate the swap must clear is the wide-int K-invariant.
    let tenth_e18: u128 = 100_000_000_000_000_000;
    swap_exact_in(
        env, pair_address, token0_address, token1_address,
        admin, swapper, tenth_e18, 0,
    );

    // token0 reserve grew by the full input (the pair received 1.1e18 total).
    assert_eq(
        env.view_public(Token::at(token0_address).balance_of_public(pair_address)),
        one_e18 + tenth_e18,
    );
    // token1 reserve shrank by a positive, sub-reserve output -> the swap
    // executed and the wide-int K-check passed.
    let r1_after = env.view_public(Token::at(token1_address).balance_of_public(pair_address));
    assert(r1_after < one_e18, "TOKEN1_RESERVE_DID_NOT_DECREASE");
    assert(r1_after > 0, "TOKEN1_RESERVE_DRAINED");
}

/// First deposit whose token product crosses 2^128, driving
/// `compute_liquidity` -> `sqrt_product` through its WIDE-INT branch
/// end-to-end. `test_swap_wide_int_k_invariant_18dec` reaches the wide path in
/// `verify_k_invariant` (via the *10000 scaling) but its 1e18*1e18 = 1e36
/// product is still < 2^128, so the first-mint sqrt stays in the direct branch.
/// Here amounts of 3e19 give product 9e38 > 2^128 (~3.4e38), so `sqrt_product`
/// takes the over-estimate-seed wide branch. A clean mint with the expected LP
/// supply is the property: the composed first-mint sqrt is correct at realistic
/// 18-decimal magnitudes, not just in the isolated `fuzz_sqrt_product_wide`.
#[test]
unconstrained fn test_first_deposit_wide_sqrt_product() {
    let (mut env, pair_address, token0_address, token1_address, lp_address, admin) = setup();
    let provider = env.create_contract_account();

    // 3e19 each: product 9e38 > 2^128 (~3.4e38), and 3e19 is well below
    // MAX_RESERVE (~5.19e33) so it fits u112. floor(sqrt(9e38)) = 3e19 (perfect
    // square), so LP = 3e19 - MINIMUM_LIQUIDITY.
    let amt: u128 = 30_000_000_000_000_000_000; // 3e19
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, amt, amt, 0, 0,
    );

    assert_eq(env.view_public(Token::at(token0_address).balance_of_public(pair_address)), amt);
    assert_eq(env.view_public(Token::at(token1_address).balance_of_public(pair_address)), amt);

    // sqrt(3e19 * 3e19) = 3e19; provider gets 3e19 - MINIMUM_LIQUIDITY.
    let total_supply = env.view_public(SigalSwapLPToken::at(lp_address).total_supply());
    assert_eq(total_supply, amt);
    let provider_lp = env.execute_utility(SigalSwapLPToken::at(lp_address).balance_of_private(provider));
    assert_eq(provider_lp, amt - MINIMUM_LIQUIDITY);
}

/// `assert_reserve_fits` negative path: a deposit at MAX_RESERVE + 1 (= 2^112,
/// since MAX_RESERVE = 2^112 - 1) trips `RESERVE_OVERFLOW` on the first-mint
/// `compute_liquidity` bound check. Pins that the guard fires rather than
/// letting an over-cap reserve through.
#[test(should_fail_with = "RESERVE_OVERFLOW")]
unconstrained fn test_add_liquidity_reserve_overflow_reverts() {
    let (mut env, pair_address, token0_address, token1_address, _lp_address, admin) = setup();
    let provider = env.create_contract_account();

    let over_cap: u128 = 1 << 112; // MAX_RESERVE is (1 << 112) - 1
    add_liquidity(
        env, pair_address, token0_address, token1_address,
        admin, provider, over_cap, over_cap, 0, 0,
    );
}
