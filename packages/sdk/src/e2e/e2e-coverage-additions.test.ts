/**
 * E2E coverage for SDK methods against a live sandbox. Each test below pins
 * behavior end-to-end:
 *
 * - `getSwapHistory` / `getLiquidityHistory`: live event decoding across
 *   pair-direct + router-mediated paths with all four `(source, direction)`
 *   tags asserted; auto-enumerate path covered.
 * - `swapExactInPublic` / `swapExactOutPublic`: V3-style public callback
 *   swaps with a `FlashBorrower` callback fixture funded to pay exactly
 *   the requested amount.
 * - `flashSwap`: optimistic borrow + repay-with-fee via the same fixture.
 * - `skimTo`: dust-recovery happy path + `NO_BALANCE` revert.
 * - `getPairPauseStates` + `getProtocolFeeDriftStates`: multi-pair admin
 *   views against a live registry, including pagination and pause toggles.
 *
 * Requires a running Aztec sandbox: `aztec start --local-network`.
 */

import { describe, it, before } from 'node:test';
import assert from 'node:assert/strict';
import type { AztecAddress } from '@aztec/aztec.js/addresses';
import type { Wallet } from '@aztec/aztec.js/wallet';
import type { AztecNode } from '@aztec/aztec.js/node';
import { FunctionSelector } from '@aztec/aztec.js/abi';
import { Fr } from '@aztec/foundation/curves/bn254';

import { SigalSwapClient } from '../client.js';
import type { TokenContract } from '../artifacts/Token.js';
import { TokenContract as TokenContractValue } from '../artifacts/Token.js';
import type { SigalSwapFactoryContract } from '../artifacts/SigalSwapFactory.js';
import type { SigalSwapPairContract } from '../artifacts/SigalSwapPair.js';
import type { SigalSwapLPTokenContract } from '../artifacts/SigalSwapLPToken.js';
import type { SigalSwapRouterContract } from '../artifacts/SigalSwapRouter.js';
import { FlashBorrowerContract } from '../artifacts/FlashBorrower.js';
import {
  setupWallet,
  deployToken,
  mintPrivate,
  deployFactory,
  deployPairWithLP,
  deployRouter,
} from './setup.js';

const FEE_TIER = 25;
const MINT_AMOUNT = 10_000_000n;
const TX_OPTS = { timeout: 120 };
const DEADLINE = () => Math.floor(Date.now() / 1000) + 86400 * 365;

/** Read a public token balance for `account` via the wallet. */
async function publicBalance(
  token: TokenContract,
  account: AztecAddress,
  from: AztecAddress,
): Promise<bigint> {
  const { result } = await token.methods.balance_of_public(account).simulate({ from });
  return result as bigint;
}

describe('SigalSwap E2E — Group R coverage additions', { timeout: 600_000 }, () => {
  let wallet: Wallet;
  let node: AztecNode;
  let sender: AztecAddress;
  let tokenA: TokenContract;
  let tokenB: TokenContract;
  let tokenC: TokenContract;
  let factory: SigalSwapFactoryContract;
  let pairAB: SigalSwapPairContract;
  let pairAB_token0: AztecAddress;
  let pairAB_token1: AztecAddress;
  let lpTokenAB: SigalSwapLPTokenContract;
  let pairBC: SigalSwapPairContract;
  let pairBC_token0: AztecAddress;
  let pairBC_token1: AztecAddress;
  let router: SigalSwapRouterContract;
  let client: SigalSwapClient;
  let borrower: FlashBorrowerContract;
  // Token handles aligned to pairAB's sorted (token0, token1) ordering.
  let pairAB_t0: TokenContract;
  let pairAB_t1: TokenContract;
  let swapPaymentSelector: FunctionSelector;
  let flashCallbackSelector: FunctionSelector;

  before(async () => {
    const setup = await setupWallet();
    wallet = setup.wallet;
    node = setup.node;
    sender = setup.senderAddress;

    tokenA = await deployToken(wallet, sender, 'TokenA', 'TKA');
    tokenB = await deployToken(wallet, sender, 'TokenB', 'TKB');
    tokenC = await deployToken(wallet, sender, 'TokenC', 'TKC');
    await mintPrivate(tokenA, sender, sender, MINT_AMOUNT);
    await mintPrivate(tokenB, sender, sender, MINT_AMOUNT);
    await mintPrivate(tokenC, sender, sender, MINT_AMOUNT);

    factory = await deployFactory(wallet, sender);

    const ab = await deployPairWithLP(wallet, sender, tokenA, tokenB, factory, FEE_TIER);
    pairAB = ab.pair;
    pairAB_token0 = ab.token0;
    pairAB_token1 = ab.token1;
    lpTokenAB = ab.lpToken;

    const bc = await deployPairWithLP(wallet, sender, tokenB, tokenC, factory, FEE_TIER);
    pairBC = bc.pair;
    pairBC_token0 = bc.token0;
    pairBC_token1 = bc.token1;

    router = await deployRouter(wallet, sender, factory);

    // Resolve token contract handles aligned to the pair's sorted order so
    // tests can mint the right token without guessing whether tokenA or
    // tokenB sorted lower.
    pairAB_t0 = await TokenContractValue.at(pairAB_token0, wallet);
    pairAB_t1 = await TokenContractValue.at(pairAB_token1, wallet);

    // Deploy the FlashBorrower fixture with universalDeploy so the pair can
    // dispatch to it from a public context.
    const { contract: borrowerContract } = await FlashBorrowerContract.deploy(wallet)
      .send({ from: sender, universalDeploy: true, wait: TX_OPTS });
    borrower = borrowerContract;

    // Selectors must hash the same signature string the Noir-side
    // `from_signature` macro expansion uses (uppercase `Field`).
    swapPaymentSelector = await FunctionSelector.fromSignature(
      'swap_payment_callback(Field,Field,Field)',
    );
    flashCallbackSelector = await FunctionSelector.fromSignature(
      'flash_callback(Field,Field,Field,Field,Field,Field)',
    );

    client = await SigalSwapClient.create({
      wallet,
      senderAddress: sender,
      factoryAddress: factory.address,
      routerAddress: router.address,
    });

    // Seed liquidity in both pairs so swap flows have reserves to work with.
    await client.unsafePair(pairAB.address).addLiquidity({
      amount0Max: 200_000n, amount1Max: 200_000n,
      amount0Min: 0n, amount1Min: 0n,
    });
    await client.unsafePair(pairBC.address).addLiquidity({
      amount0Max: 200_000n, amount1Max: 200_000n,
      amount0Min: 0n, amount1Min: 0n,
    });
  });

  // ================================================================
  // history & recovery
  // ================================================================

  describe('history & recovery', () => {
    it('getSwapHistory captures all four (source, direction) tags after pair-direct + router-mediated swaps', async () => {
      const baselineSwap = (await client.getSwapHistory({ pair: pairAB.address })).length;

      await client.unsafePair(pairAB.address).swapExactIn({
        tokenIn: pairAB_token0, tokenOut: pairAB_token1,
        amountIn: 1_000n, amountOutMin: 1n,
      });
      await client.unsafePair(pairAB.address).swapExactOut({
        tokenIn: pairAB_token0, tokenOut: pairAB_token1,
        amountOut: 500n, amountInMax: 2_000n,
      });
      await client.router().swapSingleExactIn({
        pair: pairAB.address,
        tokenIn: pairAB_token0, tokenOut: pairAB_token1,
        amountIn: 500n, amountOutMin: 1n,
        deadline: DEADLINE(),
      });
      await client.router().swapSingleExactOut({
        pair: pairAB.address,
        tokenIn: pairAB_token0, tokenOut: pairAB_token1,
        amountOut: 200n, amountInMax: 1_000n,
        deadline: DEADLINE(),
      });

      const history = await client.getSwapHistory({ pair: pairAB.address });
      assert.equal(history.length, baselineSwap + 4, 'expected 4 new history entries');

      const tags = new Set(history.map((e) => `${e.source}/${e.direction}`));
      assert.ok(tags.has('pair/exactIn'), `missing pair/exactIn; got ${[...tags]}`);
      assert.ok(tags.has('pair/exactOut'), `missing pair/exactOut; got ${[...tags]}`);
      assert.ok(tags.has('router/exactIn'), `missing router/exactIn; got ${[...tags]}`);
      assert.ok(tags.has('router/exactOut'), `missing router/exactOut; got ${[...tags]}`);

      for (let i = 1; i < history.length; i++) {
        assert.ok(history[i].blockNumber >= history[i - 1].blockNumber);
      }
    });

    it('getLiquidityHistory captures pair-direct and router-mediated mints + burns', async () => {
      const baselineLiq = (await client.getLiquidityHistory({ pair: pairAB.address })).length;

      await client.unsafePair(pairAB.address).addLiquidity({
        amount0Max: 5_000n, amount1Max: 5_000n,
        amount0Min: 0n, amount1Min: 0n,
      });
      await client.router().addLiquidity({
        pair: pairAB.address,
        amount0Max: 5_000n, amount1Max: 5_000n,
        amount0Min: 0n, amount1Min: 0n,
        deadline: DEADLINE(),
      });
      await client.unsafePair(pairAB.address).removeLiquidity({
        liquidity: 1_000n, amount0Min: 0n, amount1Min: 0n,
      });
      await client.router().removeLiquidity({
        pair: pairAB.address,
        liquidity: 500n, amount0Min: 0n, amount1Min: 0n,
        deadline: DEADLINE(),
      });

      const history = await client.getLiquidityHistory({ pair: pairAB.address });
      assert.equal(history.length, baselineLiq + 4);

      const tags = new Set(history.map((e) => `${e.source}/${e.kind}`));
      assert.ok(tags.has('pair/mint'));
      assert.ok(tags.has('router/mint'));
      assert.ok(tags.has('pair/burn'));
      assert.ok(tags.has('router/burn'));
    });

    it('getSwapHistory auto-enumerates pairs when neither pair nor pairs is supplied', async () => {
      const before = await client.getSwapHistory();

      // Trigger a swap on pairBC so auto-enumeration must include it to
      // surface this entry. Without auto-enumerate, the result would be
      // capped at router events + (no pair-side) and miss pair-direct
      // pairBC entries.
      await client.unsafePair(pairBC.address).swapExactIn({
        tokenIn: pairBC_token0, tokenOut: pairBC_token1,
        amountIn: 200n, amountOutMin: 1n,
      });

      const after = await client.getSwapHistory();
      assert.ok(after.length > before.length,
        `auto-enumerated history should grow after pairBC swap; before=${before.length}, after=${after.length}`);
    });
  });

  // ================================================================
  // public callback swaps
  // ================================================================

  describe('public callback swaps', () => {
    it('swapExactInPublic: callback pays amountIn, recipient receives at least amountOutMin', async () => {
      // Pre-fund borrower with token0 (pair's `tokenIn`). Mint to public
      // balance so the callback's `transfer_in_public` path can debit it.
      const amountIn = 1_000n;
      await pairAB_t0.methods.mint_to_public(borrower.address, amountIn)
        .send({ from: sender, wait: TX_OPTS });

      const recipient = sender;
      const expectedOut = await client.unsafePair(pairAB.address).quoteAmountOut(amountIn, pairAB_token0);
      const recipBefore = await publicBalance(pairAB_t1, recipient, sender);

      await client.unsafePair(pairAB.address).swapExactInPublic({
        tokenIn: pairAB_token0, tokenOut: pairAB_token1,
        amountIn,
        amountOutMin: expectedOut > 5n ? expectedOut - 5n : 1n,
        recipient,
        callbackContract: borrower.address,
        callbackSelector: swapPaymentSelector,
      });

      const recipAfter = await publicBalance(pairAB_t1, recipient, sender);
      assert.ok(recipAfter - recipBefore >= (expectedOut > 5n ? expectedOut - 5n : 1n),
        `recipient should receive >= amountOutMin; delta=${recipAfter - recipBefore}`);

      // Borrower should have transferred amountIn to the pair, draining its
      // public balance (the callback transfers exactly `amount` of token).
      const borrowerBal = await publicBalance(pairAB_t0, borrower.address, sender);
      assert.equal(borrowerBal, 0n, 'borrower should have transferred amountIn to pair');
    });

    it('swapExactOutPublic: callback pays formula-derived amountIn, recipient receives exactly amountOut', async () => {
      const amountOut = 500n;
      const recipient = sender;
      const expectedIn = await client.unsafePair(pairAB.address).quoteAmountIn(amountOut, pairAB_token1);

      // Over-fund so the callback transfers exactly `expectedIn` and leaves
      // the cushion at the borrower (the callback transfers exactly the
      // pair-supplied `amount` argument, not the full balance).
      const cushion = 200n;
      await pairAB_t0.methods.mint_to_public(borrower.address, expectedIn + cushion)
        .send({ from: sender, wait: TX_OPTS });

      const recipBefore = await publicBalance(pairAB_t1, recipient, sender);

      await client.unsafePair(pairAB.address).swapExactOutPublic({
        tokenIn: pairAB_token0, tokenOut: pairAB_token1,
        amountOut,
        amountInMax: expectedIn + 50n,
        recipient,
        callbackContract: borrower.address,
        callbackSelector: swapPaymentSelector,
      });

      const recipAfter = await publicBalance(pairAB_t1, recipient, sender);
      assert.equal(recipAfter - recipBefore, amountOut,
        'public swap_exact_out is exact: recipient gets exactly amountOut');

      // Borrower retains the cushion (the callback transferred only
      // `amount` = expectedIn, not the full pre-funded balance).
      const borrowerBal = await publicBalance(pairAB_t0, borrower.address, sender);
      assert.ok(borrowerBal > 0n,
        `borrower should retain unused cushion; got ${borrowerBal}`);
    });
  });

  // ================================================================
  // flash swap
  // ================================================================

  describe('flash swap', () => {
    it('flashSwap: borrow + repay-with-fee via FlashBorrower.flash_callback', async () => {
      // Borrow `borrowAmount` of token0. Pre-fund borrower with the loan
      // amount + cushion so the callback can repay loan + K-invariant fee.
      // The borrower's `flash_callback` transfers ITS FULL balance back to
      // the pair, so over-funding becomes the LP fee captured into reserves.
      const borrowAmount = 100n;
      const repayCushion = 500n;
      await pairAB_t0.methods.mint_to_public(borrower.address, borrowAmount + repayCushion)
        .send({ from: sender, wait: TX_OPTS });

      const reservesBefore = await client.unsafePair(pairAB.address).getReserves();

      await client.unsafePair(pairAB.address).flashSwap({
        amount0Out: borrowAmount,
        amount1Out: 0n,
        borrower: borrower.address,
        callbackSelector: flashCallbackSelector,
        data: new Fr(0n),
      });

      const reservesAfter = await client.unsafePair(pairAB.address).getReserves();
      // Reserves grew (or stayed) because the callback returned the full
      // pre-funded balance (= borrow + cushion). Net delta on token0 is
      // +cushion (the K-fee absorbed into reserves).
      assert.ok(reservesAfter.reserve0 >= reservesBefore.reserve0,
        `reserve0 should not shrink after flash; got ${reservesAfter.reserve0} vs ${reservesBefore.reserve0}`);

      const borrowerBal = await publicBalance(pairAB_t0, borrower.address, sender);
      assert.equal(borrowerBal, 0n, 'borrower should have transferred full balance to pair');
    });
  });

  // ================================================================
  // skim recovery
  // ================================================================

  describe('skim recovery', () => {
    it('skimTo: dust at router transferred to recipient', async () => {
      const dust = 4_242n;
      await tokenA.methods.mint_to_public(router.address, dust)
        .send({ from: sender, wait: TX_OPTS });

      const routerBalBefore = await publicBalance(tokenA, router.address, sender);
      assert.ok(routerBalBefore >= dust);

      const recipient = sender;
      const recipBefore = await publicBalance(tokenA, recipient, sender);

      await client.router().skimTo(tokenA.address, recipient);

      const routerBalAfter = await publicBalance(tokenA, router.address, sender);
      const recipAfter = await publicBalance(tokenA, recipient, sender);
      assert.equal(routerBalAfter, 0n, 'router public balance should be drained');
      assert.equal(recipAfter - recipBefore, routerBalBefore,
        'recipient should receive the full skim amount');
    });

    it('skimTo: NO_BALANCE when router has no balance of the requested token', async () => {
      const routerBal = await publicBalance(tokenC, router.address, sender);
      assert.equal(routerBal, 0n, 'precondition: router has no tokenC');

      // The SDK pre-checks router balance and throws SigalSwapValidationError
      // before submitting; the contract-side NO_BALANCE assert is
      // defense-in-depth and remains covered by the regex.
      await assert.rejects(
        client.router().skimTo(tokenC.address, sender),
        /holds no balance|NO_BALANCE|reverted|app_logic_reverted|Assertion failed/,
      );
    });
  });

  // ================================================================
  // getPairPauseStates + getProtocolFeeDriftStates
  // ================================================================

  describe('admin views (multi-pair)', () => {
    it('getPairPauseStates returns flags for each live pair and reflects pause toggles', async () => {
      const f = client.factory();

      const initial = await f.getPairPauseStates();
      assert.ok(initial.length >= 2, 'at least pairAB and pairBC should be enumerable');
      for (const entry of initial) {
        assert.equal(entry.isPaused, false, `pair ${entry.pair.toString()} unexpectedly paused`);
      }

      await factory.methods.pause_pair(pairAB.address)
        .send({ from: sender, wait: TX_OPTS });

      const afterPause = await f.getPairPauseStates();
      const pairABEntry = afterPause.find((e) => e.pair.equals(pairAB.address));
      assert.ok(pairABEntry, 'pairAB should still appear in enumeration');
      assert.equal(pairABEntry.isPaused, true, 'pairAB should report paused');

      const pairBCEntry = afterPause.find((e) => e.pair.equals(pairBC.address));
      assert.ok(pairBCEntry);
      assert.equal(pairBCEntry.isPaused, false);

      await factory.methods.unpause_pair(pairAB.address)
        .send({ from: sender, wait: TX_OPTS });
      const afterUnpause = await f.getPairPauseStates();
      const pairABAfter = afterUnpause.find((e) => e.pair.equals(pairAB.address));
      assert.ok(pairABAfter);
      assert.equal(pairABAfter.isPaused, false);
    });

    it('getPairPauseStates honors pagination via (start, end)', async () => {
      const f = client.factory();
      const all = await f.getPairPauseStates();
      assert.ok(all.length >= 2);
      const page = await f.getPairPauseStates({ start: 0, end: 1 });
      assert.equal(page.length, 1);
      assert.ok(page[0].pair.equals(all[0].pair));
    });

    it('getProtocolFeeDriftStates baseline: no drift after register_pair pushed factory defaults', async () => {
      // After register_pair, every pair holds the factory's
      // (fee_to=zero, percent=20, enabled=false) defaults. The drift view
      // compares pair-side cached config to factory globals; baseline must
      // report drifted=false everywhere.
      //
      // The post-execute drift case (factory percent changes between sync
      // calls so pairs lag) requires advancing past the 48h timelock,
      // which the sandbox doesn't expose a cheat for at this test's
      // granularity. The contract unit tests in factory/src/test/admin.nr
      // cover the drift-after-execute flow on the cross-contract side.
      const f = client.factory();
      const baseline = await f.getProtocolFeeDriftStates();
      assert.ok(baseline.length >= 2, 'expected >= 2 live pairs');
      for (const entry of baseline) {
        assert.equal(entry.drifted, false,
          `pair ${entry.pair.toString()} unexpectedly drifted at baseline`);
      }
    });
  });

  // ================================================================
  // Pair verification (verifyPair / client.pair() factory cross-check)
  //
  // Drift probes for the production "verified pair wrapper" path. The
  // SDK exposes three layers: `verifyPair(addr) -> boolean`, async
  // `pair(addr) -> SigalSwapPair` (verified at construction), and
  // `unsafePair(addr)` (sync, no check). This block exercises all three
  // against a live registry — the unit tests cover the mocked path.
  // ================================================================

  describe('pair verification', () => {
    it('verifyPair returns true for a registered pair', async () => {
      const result = await client.verifyPair(pairAB.address);
      assert.equal(result, true);
    });

    it('verifyPair returns false for an unregistered address', async () => {
      // The router was deployed (so it has bytecode) but is not registered
      // as a pair in the factory — perfect stand-in for "address that
      // exists but isn't a pair."
      const result = await client.verifyPair(router.address);
      assert.equal(result, false);
    });

    it('client.pair() returns a working wrapper for a registered pair', async () => {
      const verified = await client.pair(pairAB.address);
      assert.equal(verified.address.toString(), pairAB.address.toString());
      // The wrapper is fully functional: query passes through.
      const reserves = await verified.getReserves();
      assert.ok(reserves.reserve0 >= 0n);
    });

    it('client.pair() rejects an unregistered address', async () => {
      await assert.rejects(
        () => client.pair(router.address),
        (err: Error) =>
          /not a registered SigalSwap pair|phishing/.test(err.message),
      );
    });

    it('client.unsafePair() returns a wrapper without a factory query', () => {
      // No await: unsafePair is synchronous. The wrapper is returned
      // even if the address is bogus; the caller is opting out of the
      // factory cross-check.
      const wrapper = client.unsafePair(pairAB.address);
      assert.equal(wrapper.address.toString(), pairAB.address.toString());
    });
  });
});
