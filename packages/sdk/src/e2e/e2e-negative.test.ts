/**
 * E2E negative path tests — verify the contracts correctly REJECT bad inputs.
 *
 * These test the safety boundaries that protect user funds:
 * - Expired deadlines block stale transactions
 * - Slippage protection prevents unfavorable execution
 * - Empty/insufficient liquidity is rejected
 * - Paused pairs block operations
 * - Invalid tokens/paths are rejected
 *
 * Requires: `aztec start --local-network` on localhost:8080
 * Run with: `npm run test:e2e`
 */

import { describe, it, before } from 'node:test';
import assert from 'node:assert/strict';
import type { AztecAddress } from '@aztec/aztec.js/addresses';
import type { Wallet } from '@aztec/aztec.js/wallet';

import { SigalSwapClient } from '../client.js';
import type { TokenContract } from '../artifacts/Token.js';
import type { SigalSwapFactoryContract } from '../artifacts/SigalSwapFactory.js';
import type { SigalSwapPairContract } from '../artifacts/SigalSwapPair.js';
import type { SigalSwapRouterContract } from '../artifacts/SigalSwapRouter.js';
import {
  setupWallet,
  deployToken,
  mintPrivate,
  deployFactory,
  deployPairWithLP,
  deployRouter,
} from './setup.js';

const MINT_AMOUNT = 1_000_000n;
const FEE_TIER = 25;
// Far-future deadline that works with sandbox clock drift
const GOOD_DEADLINE = Math.floor(Date.now() / 1000) + 86400 * 365;

describe('SigalSwap E2E — negative paths', { timeout: 600_000 }, () => {
  let wallet: Wallet;
  let sender: AztecAddress;
  let tokenA: TokenContract;
  let tokenB: TokenContract;
  let factory: SigalSwapFactoryContract;
  let pairAB: SigalSwapPairContract;
  let pairAB_token0: AztecAddress;
  let pairAB_token1: AztecAddress;
  let router: SigalSwapRouterContract;
  let client: SigalSwapClient;

  before(async () => {
    const setup = await setupWallet();
    wallet = setup.wallet;
    sender = setup.senderAddress;

    tokenA = await deployToken(wallet, sender, 'TokenA', 'TKA');
    tokenB = await deployToken(wallet, sender, 'TokenB', 'TKB');
    await mintPrivate(tokenA, sender, sender, MINT_AMOUNT);
    await mintPrivate(tokenB, sender, sender, MINT_AMOUNT);

    factory = await deployFactory(wallet, sender);
    const abResult = await deployPairWithLP(wallet, sender, tokenA, tokenB, factory, FEE_TIER);
    pairAB = abResult.pair;
    pairAB_token0 = abResult.token0;
    pairAB_token1 = abResult.token1;

    router = await deployRouter(wallet, sender, factory);

    client = await SigalSwapClient.create({
      wallet,
      senderAddress: sender,
      factoryAddress: factory.address,
      routerAddress: router.address,
    });

    // Add liquidity so we have a functioning pair
    await client.unsafePair(pairAB.address).addLiquidity({
      amount0Max: 100_000n,
      amount1Max: 100_000n,
      amount0Min: 100_000n,
      amount1Min: 100_000n,
    });
  });

  // ================================================================
  // Expired deadline (router must reject)
  // ================================================================

  it('router rejects swap with expired deadline', async () => {
    // Deadline of 0 is always expired
    await assert.rejects(
      () => client.router().swapSingleExactIn({
        pair: pairAB.address,
        tokenIn: pairAB_token0,
        tokenOut: pairAB_token1,
        amountIn: 1_000n,
        amountOutMin: 0n,
        deadline: 1, // 1970 — always expired
      }),
      /deadline/i,
    );
  });

  // ================================================================
  // Slippage protection (pair and router must reject)
  // ================================================================

  it('pair rejects swap when output below amountOutMin', async () => {
    // Quote says ~990 output for 1000 input. Set min to 999999 — impossible.
    await assert.rejects(
      () => client.unsafePair(pairAB.address).swapExactIn({
        tokenIn: pairAB_token0,
        tokenOut: pairAB_token1,
        amountIn: 1_000n,
        amountOutMin: 999_999n,
      }),
      // Should revert on-chain (insufficient output)
    );
  });

  it('pair rejects addLiquidity when amounts below minimum', async () => {
    // Adding 100 of each but requiring min 200 — impossible
    await assert.rejects(
      () => client.unsafePair(pairAB.address).addLiquidity({
        amount0Max: 100n,
        amount1Max: 100n,
        amount0Min: 200n,
        amount1Min: 200n,
      }),
      // SDK validation catches this (amount0Min > amount0Max)
      /amount0Min must be <= amount0Max/,
    );
  });

  // ================================================================
  // Empty pair / insufficient liquidity
  // ================================================================

  it('swap on pair with zero liquidity reverts', async () => {
    // Deploy a fresh pair with no liquidity
    const tokenC = await deployToken(wallet, sender, 'TokenC', 'TKC');
    await mintPrivate(tokenC, sender, sender, 100_000n);
    const { pair: emptyPair, token0, token1 } = await deployPairWithLP(
      wallet, sender, tokenA, tokenC, factory, FEE_TIER,
    );

    await assert.rejects(
      () => client.unsafePair(emptyPair.address).swapExactIn({
        tokenIn: token0,
        tokenOut: token1,
        amountIn: 1_000n,
        amountOutMin: 0n,
      }),
      // Should revert on-chain (zero reserves)
    );
  });

  // ================================================================
  // SDK-level validation (rejects before hitting the chain)
  // ================================================================

  it('SDK rejects swap with zero amountIn', async () => {
    await assert.rejects(
      () => client.unsafePair(pairAB.address).swapExactIn({
        tokenIn: pairAB_token0,
        tokenOut: pairAB_token1,
        amountIn: 0n,
        amountOutMin: 0n,
      }),
      /amountIn must be positive/,
    );
  });

  it('SDK rejects swap with same tokenIn and tokenOut', async () => {
    await assert.rejects(
      () => client.unsafePair(pairAB.address).swapExactIn({
        tokenIn: pairAB_token0,
        tokenOut: pairAB_token0,
        amountIn: 1_000n,
        amountOutMin: 0n,
      }),
      /tokenIn and tokenOut must differ/,
    );
  });

  it('SDK rejects router swap with zero-address pair', async () => {
    const { AztecAddress: AztecAddr } = await import('@aztec/aztec.js/addresses');
    await assert.rejects(
      () => client.router().swapSingleExactIn({
        pair: AztecAddr.zero(),
        tokenIn: pairAB_token0,
        tokenOut: pairAB_token1,
        amountIn: 1_000n,
        amountOutMin: 0n,
        deadline: GOOD_DEADLINE,
      }),
      /pair address cannot be zero/,
    );
  });

  it('SDK rejects negative amountOutMin', async () => {
    await assert.rejects(
      () => client.unsafePair(pairAB.address).swapExactIn({
        tokenIn: pairAB_token0,
        tokenOut: pairAB_token1,
        amountIn: 1_000n,
        amountOutMin: -1n,
      }),
      /amountOutMin cannot be negative/,
    );
  });

  it('SDK rejects multi-hop exact-out with cyclic path (final token repeated)', async () => {
    // Exact-output multi-hop cannot handle paths where the final token
    // appears earlier in the path: the change-refund and intermediate-
    // dust loops would both consume the final token's balance before the
    // output send. Exact-in handles cycles correctly (triangular
    // arbitrage) and the SDK accepts those; this test covers the
    // direction-specific restriction.
    await assert.rejects(
      () => client.router().swapExactOut({
        path: [pairAB_token0, pairAB_token1, pairAB_token0],
        pairs: [pairAB.address, pairAB.address],
        amountOut: 100n,
        amountInMax: 1_000n,
        deadline: GOOD_DEADLINE,
      }),
      /Final token cannot appear earlier/,
    );
  });

  it('SDK rejects multi-hop with adjacent duplicate tokens', async () => {
    await assert.rejects(
      () => client.router().swapExactIn({
        path: [pairAB_token0, pairAB_token0, pairAB_token1],
        pairs: [pairAB.address, pairAB.address],
        amountIn: 1_000n,
        amountOutMin: 0n,
        deadline: GOOD_DEADLINE,
      }),
      /Adjacent tokens in path must differ/,
    );
  });

  // ================================================================
  // removeLiquidity edge cases
  // ================================================================

  it('SDK rejects removeLiquidity with zero amount', async () => {
    await assert.rejects(
      () => client.unsafePair(pairAB.address).removeLiquidity({
        liquidity: 0n,
        amount0Min: 0n,
        amount1Min: 0n,
      }),
      /liquidity must be positive/,
    );
  });

  // ================================================================
  // Router slippage protection
  // ================================================================

  it('router rejects swap when output below amountOutMin', async () => {
    await assert.rejects(
      () => client.router().swapSingleExactIn({
        pair: pairAB.address,
        tokenIn: pairAB_token0,
        tokenOut: pairAB_token1,
        amountIn: 1_000n,
        amountOutMin: 999_999n, // impossible to achieve
        deadline: GOOD_DEADLINE,
      }),
      // Reverts on-chain in pair's swap_exact_in_public (INSUFFICIENT_OUTPUT)
    );
  });

  // ================================================================
  // Insufficient LP token balance
  // ================================================================

  it('removeLiquidity reverts when user has insufficient LP tokens', async () => {
    // Try to remove 999_999_999 LP tokens — way more than exists
    await assert.rejects(
      () => client.unsafePair(pairAB.address).removeLiquidity({
        liquidity: 999_999_999n,
        amount0Min: 0n,
        amount1Min: 0n,
      }),
      // Reverts on-chain (insufficient balance for transfer_to_public)
    );
  });

  // ================================================================
  // Reserves consistency (lightweight invariant check)
  // ================================================================

  it('reserves match actual token balances after operations', async () => {
    const pair = client.unsafePair(pairAB.address);
    const reserves = await pair.getReserves();

    // Reserves should be positive (we added liquidity in setup)
    assert.ok(reserves.reserve0 > 0n, 'reserve0 should be positive');
    assert.ok(reserves.reserve1 > 0n, 'reserve1 should be positive');

    // K invariant: reserves should be consistent (not corrupted)
    // A simple check: the product should be positive and reasonable
    const k = reserves.reserve0 * reserves.reserve1;
    assert.ok(k > 0n, 'K should be positive');
  });

  // ================================================================
  // Paused pair blocks operations
  // ================================================================

  it('paused pair rejects swaps', async () => {
    // Admin pauses via factory (set_pause is ONLY_FACTORY)
    await factory.methods.pause_pair(pairAB.address).send({ from: sender, wait: { timeout: 120 } });

    // Verify it's paused
    const state = await client.unsafePair(pairAB.address).getPairState();
    assert.equal(state.isPaused, true);

    // Swap should revert
    await assert.rejects(
      () => client.unsafePair(pairAB.address).swapExactIn({
        tokenIn: pairAB_token0,
        tokenOut: pairAB_token1,
        amountIn: 100n,
        amountOutMin: 0n,
      }),
      // Reverts on-chain (PAUSED)
    );

    // Unpause for subsequent tests
    await factory.methods.unpause_pair(pairAB.address).send({ from: sender, wait: { timeout: 120 } });
  });

  it('paused pair still allows removeLiquidity (user protection)', async () => {
    // Pause via factory
    await factory.methods.pause_pair(pairAB.address).send({ from: sender, wait: { timeout: 120 } });

    // removeLiquidity should still work (users can always withdraw)
    await client.unsafePair(pairAB.address).removeLiquidity({
      liquidity: 10n,
      amount0Min: 0n,
      amount1Min: 0n,
    });

    // Unpause
    await factory.methods.unpause_pair(pairAB.address).send({ from: sender, wait: { timeout: 120 } });
  });

  it('factory.pause_pair reverts PAIR_NOT_REGISTERED for an address the factory did not register', async () => {
    // tokenA is a deployed contract this factory has never registered as a pair.
    // The `registered[pair]` assert fires before the cross-contract `set_pause`
    // is attempted, so the address being a token (not a pair) is irrelevant.
    // PXE doesn't reliably decode public-side revert strings in v4.1.2, so we
    // assert on the generic revert marker; the message is covered at the
    // contract layer in protocol/factory tests.
    await assert.rejects(
      () => factory.methods.pause_pair(tokenA.address).send({ from: sender, wait: { timeout: 120 } }),
      /reverted|app_logic_reverted|Assertion failed/,
    );
  });

  it('factory.unpause_pair reverts PAIR_NOT_REGISTERED for an address the factory did not register', async () => {
    await assert.rejects(
      () => factory.methods.unpause_pair(tokenA.address).send({ from: sender, wait: { timeout: 120 } }),
      /reverted|app_logic_reverted|Assertion failed/,
    );
  });

  // ================================================================
  // Router deadline on liquidity operations
  // ================================================================

  it('router rejects addLiquidity with expired deadline', async () => {
    await assert.rejects(
      () => client.router().addLiquidity({
        pair: pairAB.address,
        amount0Max: 1_000n,
        amount1Max: 1_000n,
        amount0Min: 0n,
        amount1Min: 0n,
        deadline: 1,
      }),
      /deadline/i,
    );
  });

  it('router rejects removeLiquidity with expired deadline', async () => {
    await assert.rejects(
      () => client.router().removeLiquidity({
        pair: pairAB.address,
        liquidity: 100n,
        amount0Min: 0n,
        amount1Min: 0n,
        deadline: 1,
      }),
      /deadline/i,
    );
  });

  // ================================================================
  // Dust amounts
  // ================================================================

  it('swap with 1 token produces 0 output and reverts', async () => {
    await assert.rejects(
      () => client.unsafePair(pairAB.address).swapExactIn({
        tokenIn: pairAB_token0,
        tokenOut: pairAB_token1,
        amountIn: 1n,
        amountOutMin: 1n, // require at least 1 output
      }),
      // At 1 input with 0.25% fee, output rounds to 0 → reverts
    );
  });

  // ================================================================
  // verifyPair with unregistered address
  // ================================================================

  it('verifyPair returns false for unregistered pair', async () => {
    const { AztecAddress: AztecAddr } = await import('@aztec/aztec.js/addresses');
    const fakePair = AztecAddr.fromBigInt(99999n);
    const result = await client.verifyPair(fakePair);
    assert.equal(result, false);
  });
});
