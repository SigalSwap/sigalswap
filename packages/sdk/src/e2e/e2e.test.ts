/**
 * E2E tests for the SigalSwap SDK.
 *
 * Requires a running Aztec sandbox: `aztec start --local-network`
 * Run with: `npm run test:e2e`
 *
 * Uses Node's built-in test runner (not vitest) because Vite strips
 * import attributes required by @aztec/accounts for JSON modules.
 */

import { describe, it, before } from 'node:test';
import assert from 'node:assert/strict';
import type { AztecAddress } from '@aztec/aztec.js/addresses';
import type { Wallet } from '@aztec/aztec.js/wallet';
import type { AztecNode } from '@aztec/aztec.js/node';
import { getPublicEvents } from '@aztec/aztec.js/events';

import { SigalSwapClient } from '../client.js';
import { SigalSwapEvents, type PairCreatedEventData } from '../events.js';
import type { TokenContract } from '../artifacts/Token.js';
import type { SigalSwapFactoryContract } from '../artifacts/SigalSwapFactory.js';
import type { SigalSwapPairContract } from '../artifacts/SigalSwapPair.js';
import type { SigalSwapLPTokenContract } from '../artifacts/SigalSwapLPToken.js';
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
const FEE_TIER = 25; // 0.25%

describe('SigalSwap E2E', { timeout: 600_000 }, () => {
  let wallet: Wallet;
  let node: AztecNode;
  let sender: AztecAddress;
  let tokenA: TokenContract;
  let tokenB: TokenContract;
  let tokenC: TokenContract;
  let factory: SigalSwapFactoryContract;
  let pairAB: SigalSwapPairContract;
  let lpTokenAB: SigalSwapLPTokenContract;
  let pairAB_token0: AztecAddress;
  let pairAB_token1: AztecAddress;
  let pairBC: SigalSwapPairContract;
  let router: SigalSwapRouterContract;
  let client: SigalSwapClient;

  before(async () => {
    try {
    console.log('Setting up wallet...');
    const setup = await setupWallet();
    wallet = setup.wallet;
    node = setup.node;
    sender = setup.senderAddress;

    console.log('Deploying tokens...');
    tokenA = await deployToken(wallet, sender, 'TokenA', 'TKA');
    tokenB = await deployToken(wallet, sender, 'TokenB', 'TKB');
    tokenC = await deployToken(wallet, sender, 'TokenC', 'TKC');

    console.log('Minting tokenA...');
    await mintPrivate(tokenA, sender, sender, MINT_AMOUNT);
    console.log('Minting tokenB...');
    await mintPrivate(tokenB, sender, sender, MINT_AMOUNT);
    console.log('Minting tokenC...');
    await mintPrivate(tokenC, sender, sender, MINT_AMOUNT);

    console.log('Deploying factory...');
    factory = await deployFactory(wallet, sender);

    console.log('Deploying pairAB...');
    const abResult = await deployPairWithLP(wallet, sender, tokenA, tokenB, factory, FEE_TIER);
    pairAB = abResult.pair;
    lpTokenAB = abResult.lpToken;
    pairAB_token0 = abResult.token0;
    pairAB_token1 = abResult.token1;
    console.log('PairAB deployed and registered');

    console.log('Deploying pairBC...');
    const bcResult = await deployPairWithLP(wallet, sender, tokenB, tokenC, factory, FEE_TIER);
    pairBC = bcResult.pair;
    console.log('PairBC deployed and registered');

    console.log('Deploying router...');
    router = await deployRouter(wallet, sender, factory);

    console.log('Creating SDK client...');
    client = await SigalSwapClient.create({
      wallet,
      senderAddress: sender,
      factoryAddress: factory.address,
      routerAddress: router.address,
    });

    console.log('Setup complete.');
    } catch (e: any) {
      console.error('SETUP FAILED:', e.message?.slice(0, 300));
      console.error('Stack:', e.stack?.split('\n').slice(0, 5).join('\n'));
      throw e;
    }
  });

  // ================================================================
  // Factory queries
  // ================================================================

  it('factory reports correct pair count', async () => {
    const count = await client.factory().getPairCount();
    assert.equal(count, 2);
  });

  it('factory reports fee tier 25 as allowed', async () => {
    const allowed = await client.factory().isFeeTierAllowed(FEE_TIER);
    assert.equal(allowed, true);
  });

  it('factory looks up pairAB by token addresses', async () => {
    const found = await client.factory().getPair(pairAB_token0, pairAB_token1, FEE_TIER);
    assert.ok(found.equals(pairAB.address));
  });

  // ================================================================
  // Factory versioning & enumeration (new surface added in versioning pass)
  // ================================================================

  it('factory pair_class_version is 1 after deployment', async () => {
    const v = await client.factory().getPairClassVersion();
    assert.equal(v, 1);
  });

  it('getLatestVersion returns 1 at each registered base', async () => {
    const vAB = await client.factory().getLatestVersion(pairAB_token0, pairAB_token1, FEE_TIER);
    assert.equal(vAB, 1);
  });

  it('getPairVersioned(..., 1) matches getPair; version 2 returns zero', async () => {
    const v1 = await client.factory().getPairVersioned(pairAB_token0, pairAB_token1, FEE_TIER, 1);
    assert.ok(v1.equals(pairAB.address));
    const v2 = await client.factory().getPairVersioned(pairAB_token0, pairAB_token1, FEE_TIER, 2);
    assert.ok(v2.isZero());
  });

  it('getIndexedBaseCount equals distinct bases (2)', async () => {
    const baseCount = await client.factory().getIndexedBaseCount();
    assert.equal(baseCount, 2);
  });

  it('getActivePairCount equals live bases (2 -- none cleared)', async () => {
    const active = await client.factory().getActivePairCount();
    assert.equal(active, 2);
  });

  it('getLatestPairAtIndex resolves each base to its live pair', async () => {
    const pair0 = await client.factory().getLatestPairAtIndex(0);
    const pair1 = await client.factory().getLatestPairAtIndex(1);
    const set = new Set([pair0.toString(), pair1.toString()]);
    assert.ok(set.has(pairAB.address.toString()));
    assert.ok(set.has(pairBC.address.toString()));
  });

  it('getPairAt historical enumeration resolves same addresses as latest', async () => {
    const pair0 = await client.factory().getPairAt(0);
    const pair1 = await client.factory().getPairAt(1);
    const set = new Set([pair0.toString(), pair1.toString()]);
    assert.ok(set.has(pairAB.address.toString()));
    assert.ok(set.has(pairBC.address.toString()));
  });

  it('pair.getVersion returns 1 (compile-time global)', async () => {
    const v = await client.unsafePair(pairAB.address).getVersion();
    assert.equal(v, 1);
  });

  it('PairCreatedEvent decodes with version=1 via getPublicEvents', async () => {
    // The factory emits one PairCreatedEvent per register_pair call. Setup
    // registered pairAB and pairBC, so we expect at least two events from
    // the factory contract. Query from block 1 (covers full sandbox history)
    // and verify shape, including the version field added this pass.
    const { events } = await getPublicEvents<PairCreatedEventData>(
      node,
      SigalSwapEvents.factory.PairCreatedEvent,
      { contractAddress: factory.address, fromBlock: 1 },
    );

    assert.ok(events.length >= 2, `expected >=2 PairCreatedEvents, got ${events.length}`);

    // Every event from this factory should advertise version 1 (the only
    // blessed pair class version in this test's lifecycle).
    for (const e of events) {
      assert.equal(Number(e.event.version), 1, `event version should be 1, got ${e.event.version}`);
      assert.equal(Number(e.event.fee_tier_bps), FEE_TIER);
      assert.ok(typeof e.event.pair_count === 'bigint' || typeof e.event.pair_count === 'number');
    }

    // At least one event should point at pairAB.
    const pairABString = pairAB.address.toString();
    const matchingPairAB = events.find((e) => e.event.pair.toString() === pairABString);
    assert.ok(matchingPairAB, 'no PairCreatedEvent matched pairAB address');
  });

  // ================================================================
  // Pair verification
  // ================================================================

  it('verifyPair returns true for registered pair', async () => {
    assert.equal(await client.verifyPair(pairAB.address), true);
  });

  // ================================================================
  // Initial pair state
  // ================================================================

  it('pair has zero reserves initially', async () => {
    const reserves = await client.unsafePair(pairAB.address).getReserves();
    assert.equal(reserves.reserve0, 0n);
    assert.equal(reserves.reserve1, 0n);
  });

  it('pair config matches deployment', async () => {
    const config = await client.unsafePair(pairAB.address).getConfig();
    assert.ok(config.token0.equals(pairAB_token0));
    assert.ok(config.token1.equals(pairAB_token1));
    assert.ok(config.lpToken.equals(lpTokenAB.address));
    assert.ok(config.factory.equals(factory.address));
    assert.equal(config.feeTierBps, 25n);
    assert.equal(config.version, 1n);
  });

  it('pair is not paused', async () => {
    const state = await client.unsafePair(pairAB.address).getPairState();
    assert.equal(state.isPaused, false);
  });

  // ================================================================
  // Add liquidity
  // ================================================================

  it('adds initial liquidity to pairAB', async () => {
    await client.unsafePair(pairAB.address).addLiquidity({
      amount0Max: 100_000n,
      amount1Max: 200_000n,
      amount0Min: 100_000n,
      amount1Min: 200_000n,
    });

    const reserves = await client.unsafePair(pairAB.address).getReserves();
    assert.equal(reserves.reserve0, 100_000n);
    assert.equal(reserves.reserve1, 200_000n);
  });

  it('adds initial liquidity to pairBC', async () => {
    await client.unsafePair(pairBC.address).addLiquidity({
      amount0Max: 100_000n,
      amount1Max: 100_000n,
      amount0Min: 100_000n,
      amount1Min: 100_000n,
    });

    const reserves = await client.unsafePair(pairBC.address).getReserves();
    assert.equal(reserves.reserve0, 100_000n);
    assert.equal(reserves.reserve1, 100_000n);
  });

  // ================================================================
  // Quotes
  // ================================================================

  it('quoteAmountOut returns positive value', async () => {
    const quoted = await client.unsafePair(pairAB.address).quoteAmountOut(1000n, pairAB_token0);
    assert.ok(quoted > 0n);
    assert.ok(quoted < 2000n);
  });

  it('quoteAmountIn returns positive value', async () => {
    const quoted = await client.unsafePair(pairAB.address).quoteAmountIn(1000n, pairAB_token1);
    assert.ok(quoted > 0n);
  });

  // ================================================================
  // Swaps via router (single-hop)
  // ================================================================

  it('swapSingleExactIn: swaps token0 for token1', async () => {
    const pair = client.unsafePair(pairAB.address);
    const reservesBefore = await pair.getReserves();
    const quotedOut = await pair.quoteAmountOut(1_000n, pairAB_token0);

    await client.router().swapSingleExactIn({
      pair: pairAB.address,
      tokenIn: pairAB_token0,
      tokenOut: pairAB_token1,
      amountIn: 1_000n,
      amountOutMin: quotedOut - 1n,
      deadline: Math.floor(Date.now() / 1000) + 86400 * 365,
    });

    const reservesAfter = await pair.getReserves();
    assert.ok(reservesAfter.reserve0 > reservesBefore.reserve0);
    assert.ok(reservesAfter.reserve1 < reservesBefore.reserve1);
  });

  it('swapSingleExactOut: gets exact token0 output', async () => {
    const pair = client.unsafePair(pairAB.address);
    const reservesBefore = await pair.getReserves();
    const quotedIn = await pair.quoteAmountIn(500n, pairAB_token0);

    await client.router().swapSingleExactOut({
      pair: pairAB.address,
      tokenIn: pairAB_token1,
      tokenOut: pairAB_token0,
      amountOut: 500n,
      amountInMax: quotedIn + 10n,
      deadline: Math.floor(Date.now() / 1000) + 86400 * 365,
    });

    const reservesAfter = await pair.getReserves();
    assert.ok(reservesAfter.reserve0 < reservesBefore.reserve0);
    assert.ok(reservesAfter.reserve1 > reservesBefore.reserve1);
  });

  // ================================================================
  // Multi-hop swap
  // ================================================================

  it('multi-hop swap A->B->C via router', async () => {
    const reservesBCBefore = await client.unsafePair(pairBC.address).getReserves();

    // Path must use actual token addresses (not pair-sorted order).
    // tokenA -> tokenB -> tokenC: tokenB is the intermediate in both pairs.
    await client.router().swapExactIn({
      path: [tokenA.address, tokenB.address, tokenC.address],
      pairs: [pairAB.address, pairBC.address],
      amountIn: 500n,
      amountOutMin: 1n,
      deadline: Math.floor(Date.now() / 1000) + 86400 * 365,
    });

    const reservesBCAfter = await client.unsafePair(pairBC.address).getReserves();
    assert.ok(
      reservesBCAfter.reserve0 !== reservesBCBefore.reserve0 ||
      reservesBCAfter.reserve1 !== reservesBCBefore.reserve1,
    );
  });

  // ================================================================
  // Remove liquidity
  // ================================================================

  it('removes liquidity via pair', async () => {
    const pair = client.unsafePair(pairAB.address);
    const reservesBefore = await pair.getReserves();

    await pair.removeLiquidity({
      liquidity: 1000n,
      amount0Min: 0n,
      amount1Min: 0n,
    });

    const reservesAfter = await pair.getReserves();
    assert.ok(reservesAfter.reserve0 < reservesBefore.reserve0);
    assert.ok(reservesAfter.reserve1 < reservesBefore.reserve1);
  });

  it('removes liquidity via router with deadline', async () => {
    const reservesBefore = await client.unsafePair(pairAB.address).getReserves();

    await client.router().removeLiquidity({
      pair: pairAB.address,
      liquidity: 500n,
      amount0Min: 0n,
      amount1Min: 0n,
      deadline: Math.floor(Date.now() / 1000) + 86400 * 365,
    });

    const reservesAfter = await client.unsafePair(pairAB.address).getReserves();
    assert.ok(reservesAfter.reserve0 < reservesBefore.reserve0);
  });

  // ================================================================
  // Analytics queries (post-swap)
  // ================================================================

  it('spot prices reflect reserves', async () => {
    const pair = client.unsafePair(pairAB.address);
    const reserves = await pair.getReserves();
    const prices = await pair.getSpotPrices();
    assert.equal(prices.price0Num, reserves.reserve1);
    assert.equal(prices.price0Den, reserves.reserve0);
  });

  it('cumulative prices have been updated', async () => {
    const prices = await client.unsafePair(pairAB.address).getCumulativePrices();
    assert.ok(prices.blockTimestampLast > 0n);
  });

  it('getPositionValue returns proportional amounts', async () => {
    const pair = client.unsafePair(pairAB.address);
    const reserves = await pair.getReserves();
    const value = await pair.getPositionValue(100n, 10000n);
    assert.equal(value.amount0, reserves.reserve0 * 100n / 10000n);
    assert.equal(value.amount1, reserves.reserve1 * 100n / 10000n);
  });

  // ================================================================
  // Router add liquidity with deadline
  // ================================================================

  it('adds liquidity via router with deadline', async () => {
    const reservesBefore = await client.unsafePair(pairAB.address).getReserves();

    await client.router().addLiquidity({
      pair: pairAB.address,
      amount0Max: 10_000n,
      amount1Max: 20_000n,
      amount0Min: 0n,
      amount1Min: 0n,
      deadline: Math.floor(Date.now() / 1000) + 86400 * 365,
    });

    const reservesAfter = await client.unsafePair(pairAB.address).getReserves();
    assert.ok(reservesAfter.reserve0 > reservesBefore.reserve0);
    assert.ok(reservesAfter.reserve1 > reservesBefore.reserve1);
  });
});
