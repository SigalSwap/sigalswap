/**
 * E2E tests for indexer- and wallet-facing event surface:
 *
 * - Factory initial events: constructor emits AdminChangedEvent +
 *   three FeeTierAddedEvents so an indexer can reconstruct state from block 1.
 * - Directional private swap events: PrivateSwapExactInEvent /
 *   PrivateSwapExactOutEvent and RouterSwapExactIn/OutEvent queryable via
 *   wallet.getPrivateEvents scoped to the trader.
 * - sync_protocol_fee rejects pairs not in the factory's
 *   `registered` membership set (PAIR_NOT_REGISTERED).
 * - SDK ActionType + decodeActionValue: queued governance actions'
 *   on-chain event data round-trips through the decoder into typed variants.
 *
 * Requires a running Aztec sandbox: `aztec start --local-network`.
 */

import { describe, it, before } from 'node:test';
import assert from 'node:assert/strict';
import type { AztecAddress } from '@aztec/aztec.js/addresses';
import type { Wallet } from '@aztec/aztec.js/wallet';
import type { AztecNode } from '@aztec/aztec.js/node';
import { getPublicEvents } from '@aztec/aztec.js/events';
import { Fr } from '@aztec/foundation/curves/bn254';

import { SigalSwapClient } from '../client.js';
import {
  SigalSwapEvents,
  type AdminChangedEventData,
  type FeeTierAddedEventData,
  type ActionQueuedEventData,
  type PrivateSwapExactInEventData,
  type PrivateSwapExactOutEventData,
  type RouterSwapExactInEventData,
  type RouterSwapExactOutEventData,
} from '../events.js';
import { ActionType, decodeActionValue, CANONICAL_DEPLOY_SALT, SigalSwapFactory } from '../factory.js';
import type { TokenContract } from '../artifacts/Token.js';
import type { SigalSwapFactoryContract } from '../artifacts/SigalSwapFactory.js';
import { SigalSwapPairContract, SigalSwapPairContractArtifact } from '../artifacts/SigalSwapPair.js';
import type { SigalSwapLPTokenContract } from '../artifacts/SigalSwapLPToken.js';
import { SigalSwapLPTokenContract as SigalSwapLPTokenContractValue } from '../artifacts/SigalSwapLPToken.js';
import type { SigalSwapRouterContract } from '../artifacts/SigalSwapRouter.js';

import {
  setupWallet, deployToken, mintPrivate, deployFactory, deployPairWithLP, deployRouter,
} from './setup.js';

const FEE_TIER = 25;
const MINT_AMOUNT = 10_000_000n;
const DEADLINE = () => Math.floor(Date.now() / 1000) + 86400 * 365;
const TX_OPTS = { timeout: 120 };

describe('SigalSwap E2E — events and governance', { timeout: 600_000 }, () => {
  let wallet: Wallet;
  let node: AztecNode;
  let sender: AztecAddress;
  let tokenA: TokenContract;
  let tokenB: TokenContract;
  let factory: SigalSwapFactoryContract;
  let pair: SigalSwapPairContract;
  let pairToken0: AztecAddress;
  let pairToken1: AztecAddress;
  let lpToken: SigalSwapLPTokenContract;
  let router: SigalSwapRouterContract;
  let client: SigalSwapClient;

  before(async () => {
    const setup = await setupWallet();
    wallet = setup.wallet;
    node = setup.node;
    sender = setup.senderAddress;

    tokenA = await deployToken(wallet, sender, 'TokenA', 'TKA');
    tokenB = await deployToken(wallet, sender, 'TokenB', 'TKB');
    await mintPrivate(tokenA, sender, sender, MINT_AMOUNT);
    await mintPrivate(tokenB, sender, sender, MINT_AMOUNT);

    factory = await deployFactory(wallet, sender);

    const pairResult = await deployPairWithLP(wallet, sender, tokenA, tokenB, factory, FEE_TIER);
    pair = pairResult.pair;
    pairToken0 = pairResult.token0;
    pairToken1 = pairResult.token1;
    lpToken = pairResult.lpToken;

    router = await deployRouter(wallet, sender, factory);

    client = await SigalSwapClient.create({
      wallet,
      senderAddress: sender,
      factoryAddress: factory.address,
      routerAddress: router.address,
    });

    // Seed liquidity so we can execute swaps.
    await client.unsafePair(pair.address).addLiquidity({
      amount0Max: 100_000n,
      amount1Max: 100_000n,
      amount0Min: 0n,
      amount1Min: 0n,
    });
  });

  // ================================================================
  // Factory constructor emits initial events
  // ================================================================

  it('factory emits AdminChangedEvent at deployment', async () => {
    const { events } = await getPublicEvents<AdminChangedEventData>(
      node,
      SigalSwapEvents.factory.AdminChangedEvent,
      { contractAddress: factory.address, fromBlock: 1 },
    );
    assert.ok(events.length >= 1, `expected >=1 AdminChangedEvent, got ${events.length}`);
    // The first AdminChangedEvent is the deployment-time one; new_admin is
    // the deployer (sender) since setup's `deployFactory` passes `admin: sender`.
    assert.equal(
      events[0].event.new_admin.toString(),
      sender.toString(),
      'AdminChangedEvent at deploy should name the deployer as new_admin',
    );
  });

  it('factory emits FeeTierAddedEvent for each of 5, 25, 100 bps at deployment', async () => {
    const { events } = await getPublicEvents<FeeTierAddedEventData>(
      node,
      SigalSwapEvents.factory.FeeTierAddedEvent,
      { contractAddress: factory.address, fromBlock: 1 },
    );
    // Factory bootstraps three tiers inline. Same-block ordering within a
    // single tx is stable, so we can check the exact set (order-independent).
    const tiers = new Set(events.map((e) => Number(e.event.tier_bps)));
    assert.ok(tiers.has(5), `missing 5 bps tier event; got ${[...tiers].join(',')}`);
    assert.ok(tiers.has(25), `missing 25 bps tier event; got ${[...tiers].join(',')}`);
    assert.ok(tiers.has(100), `missing 100 bps tier event; got ${[...tiers].join(',')}`);
  });

  // ================================================================
  // Directional private swap events
  // ================================================================

  it('pair.swap_exact_in emits PrivateSwapExactInEvent with actual amount_in', async () => {
    // Record baseline count of events before this swap.
    const metadata = SigalSwapEvents.pair.PrivateSwapExactInEvent;
    const before = await wallet.getPrivateEvents<PrivateSwapExactInEventData>(
      metadata,
      { contractAddress: pair.address, scopes: [sender] },
    );

    const amountIn = 1_000n;
    const minOut = 1n;
    await client.unsafePair(pair.address).swapExactIn({
      tokenIn: pairToken0,
      tokenOut: pairToken1,
      amountIn,
      amountOutMin: minOut,
    });

    const after = await wallet.getPrivateEvents<PrivateSwapExactInEventData>(
      metadata,
      { contractAddress: pair.address, scopes: [sender] },
    );
    assert.equal(after.length, before.length + 1, 'expected exactly one new PrivateSwapExactInEvent');

    const evt = after[after.length - 1].event;
    assert.equal(evt.token_in.toString(), pairToken0.toString());
    assert.equal(evt.token_out.toString(), pairToken1.toString());
    assert.equal(evt.amount_in, amountIn, 'amount_in should equal the declared input');
    assert.equal(evt.amount_out_min, minOut, 'amount_out_min should equal the slippage floor');
  });

  it('pair.swap_exact_out emits PrivateSwapExactOutEvent with amount_in_max upper bound', async () => {
    const metadata = SigalSwapEvents.pair.PrivateSwapExactOutEvent;
    const before = await wallet.getPrivateEvents<PrivateSwapExactOutEventData>(
      metadata,
      { contractAddress: pair.address, scopes: [sender] },
    );

    const amountOut = 500n;
    const amountInMax = 2_000n;
    await client.unsafePair(pair.address).swapExactOut({
      tokenIn: pairToken0,
      tokenOut: pairToken1,
      amountOut,
      amountInMax,
    });

    const after = await wallet.getPrivateEvents<PrivateSwapExactOutEventData>(
      metadata,
      { contractAddress: pair.address, scopes: [sender] },
    );
    assert.equal(after.length, before.length + 1, 'expected exactly one new PrivateSwapExactOutEvent');

    const evt = after[after.length - 1].event;
    assert.equal(evt.token_in.toString(), pairToken0.toString());
    assert.equal(evt.token_out.toString(), pairToken1.toString());
    // Contract logs the authorized upper bound, not the actual input consumed.
    // The actual input is recoverable via the refund partial note in the same
    // tx; this event intentionally doesn't claim a figure it can't know at
    // private-emission time.
    assert.equal(evt.amount_in_max, amountInMax);
    assert.equal(evt.amount_out, amountOut);
  });

  it('router single-hop swap emits RouterSwapExactInEvent', async () => {
    const metadata = SigalSwapEvents.router.RouterSwapExactInEvent;
    const before = await wallet.getPrivateEvents<RouterSwapExactInEventData>(
      metadata,
      { contractAddress: router.address, scopes: [sender] },
    );

    const amountIn = 750n;
    const minOut = 1n;
    await client.router().swapSingleExactIn({
      pair: pair.address,
      tokenIn: pairToken0,
      tokenOut: pairToken1,
      amountIn,
      amountOutMin: minOut,
      deadline: DEADLINE(),
    });

    const after = await wallet.getPrivateEvents<RouterSwapExactInEventData>(
      metadata,
      { contractAddress: router.address, scopes: [sender] },
    );
    assert.equal(after.length, before.length + 1);

    const evt = after[after.length - 1].event;
    assert.equal(evt.token_in.toString(), pairToken0.toString());
    assert.equal(evt.token_out.toString(), pairToken1.toString());
    assert.equal(evt.amount_in, amountIn);
    assert.equal(evt.amount_out_min, minOut);
  });

  it('router single-hop exact-out emits RouterSwapExactOutEvent', async () => {
    const metadata = SigalSwapEvents.router.RouterSwapExactOutEvent;
    const before = await wallet.getPrivateEvents<RouterSwapExactOutEventData>(
      metadata,
      { contractAddress: router.address, scopes: [sender] },
    );

    const amountOut = 250n;
    const amountInMax = 1_500n;
    await client.router().swapSingleExactOut({
      pair: pair.address,
      tokenIn: pairToken1,
      tokenOut: pairToken0,
      amountOut,
      amountInMax,
      deadline: DEADLINE(),
    });

    const after = await wallet.getPrivateEvents<RouterSwapExactOutEventData>(
      metadata,
      { contractAddress: router.address, scopes: [sender] },
    );
    assert.equal(after.length, before.length + 1);

    const evt = after[after.length - 1].event;
    assert.equal(evt.token_in.toString(), pairToken1.toString());
    assert.equal(evt.token_out.toString(), pairToken0.toString());
    assert.equal(evt.amount_in_max, amountInMax);
    assert.equal(evt.amount_out, amountOut);
  });

  // ================================================================
  // sync_protocol_fee rejects unregistered pair
  // ================================================================

  it('factory.sync_protocol_fee reverts PAIR_NOT_REGISTERED for a pair the factory did not register', async () => {
    // Deploy a fresh pair bypassing register_pair. The constructor runs
    // locally but nothing writes to factory.registered, so the factory
    // considers the pair unknown and sync_protocol_fee must reject.
    const { contract: rougePair } = await SigalSwapPairContract.deploy(
      wallet, pairToken0, pairToken1, factory.address, FEE_TIER,
    ).send({
      from: sender,
      universalDeploy: true,
      contractAddressSalt: new Fr(42n), // Distinct salt so the address differs from the registered pair.
      wait: TX_OPTS,
    });

    // Deploy the LP Token at the derived address so the pair could accept
    // mint calls -- not strictly required for sync_protocol_fee (which
    // doesn't touch LP) but keeps the rogue pair in a sane state.
    const { result: lpAddr } = await rougePair.methods
      .get_lp_token().simulate({ from: sender });
    await SigalSwapLPTokenContractValue.deploy(wallet, rougePair.address).send({
      from: sender,
      universalDeploy: true,
      contractAddressSalt: new Fr(42n),
      wait: TX_OPTS,
    });
    assert.ok(lpAddr);

    // Attempt factory sync -- must revert. The factory's
    // `assert(registered[pair], "PAIR_NOT_REGISTERED")` fires; aztec.js
    // surfaces this as `Error: Assertion failed: PAIR_NOT_REGISTERED ...`.
    // We accept any of the framework's revert markers OR the bare assertion
    // text so the canary survives future SDK error-surface changes. The
    // corresponding Noir test in `protocol/factory/src/test/admin.nr`
    // covers the exact assertion message.
    await assert.rejects(
      factory.methods.sync_protocol_fee(rougePair.address)
        .send({ from: sender, wait: TX_OPTS }),
      /reverted|app_logic_reverted|Assertion failed/,
    );
  });

  it('factory.sync_protocol_fee succeeds for a registered pair', async () => {
    // Counterpart to the rejection test: the pair we registered in `before`
    // should pass the membership check and actually sync.
    await factory.methods.sync_protocol_fee(pair.address)
      .send({ from: sender, wait: TX_OPTS });
  });

  // ================================================================
  // ActionQueuedEvent + decodeActionValue roundtrip
  // ================================================================

  it('queued governance action emits ActionQueuedEvent that decodes via decodeActionValue', async () => {
    // `queue_set_fee_to` requires `fee_to` to already be initialized
    // (the first set is immediate via `set_fee_to`; subsequent changes
    // go through the timelock). Bootstrap with `sender`, then queue a
    // change to a different address so the ActionQueuedEvent we're
    // asserting against carries a specific, findable value.
    await factory.methods.set_fee_to(sender)
      .send({ from: sender, wait: TX_OPTS });

    const newFeeTo = tokenA.address; // any non-zero address distinct from `sender`
    await factory.methods.queue_set_fee_to(newFeeTo)
      .send({ from: sender, wait: TX_OPTS });

    const { events } = await getPublicEvents<ActionQueuedEventData>(
      node,
      SigalSwapEvents.factory.ActionQueuedEvent,
      { contractAddress: factory.address, fromBlock: 1 },
    );

    // Find the SET_FEE_TO queue we just did.
    const match = events.find(
      (e) => e.event.action_type === ActionType.SET_FEE_TO
        && e.event.value === newFeeTo.toBigInt(),
    );
    assert.ok(match, `expected ActionQueuedEvent for SET_FEE_TO(${newFeeTo.toString()})`);

    const decoded = decodeActionValue(match.event.action_type, match.event.value);
    assert.equal(decoded.type, 'set_fee_to');
    if (decoded.type === 'set_fee_to') {
      assert.equal(
        decoded.newFeeTo.toString(),
        newFeeTo.toString(),
        'decoder should return the queued address as an AztecAddress',
      );
    }
  });

  it('decodeActionValue handles a set_protocol_fee_percent event end-to-end', async () => {
    await factory.methods.queue_set_protocol_fee_percent(50)
      .send({ from: sender, wait: TX_OPTS });

    const { events } = await getPublicEvents<ActionQueuedEventData>(
      node,
      SigalSwapEvents.factory.ActionQueuedEvent,
      { contractAddress: factory.address, fromBlock: 1 },
    );
    const match = events.find(
      (e) => e.event.action_type === ActionType.SET_PROTOCOL_FEE_PERCENT,
    );
    assert.ok(match, 'expected ActionQueuedEvent for SET_PROTOCOL_FEE_PERCENT');

    const decoded = decodeActionValue(match.event.action_type, match.event.value);
    assert.deepEqual(decoded, {
      type: 'set_protocol_fee_percent',
      newPercent: 50,
    });
  });

  // ================================================================
  // canonical deploy salt
  // ================================================================

  it('CANONICAL_DEPLOY_SALT from SDK matches the pair deployment salt (Fr(1))', () => {
    // Trip-wire: the pair's compile-time LP_TOKEN_SALT is 1 and the
    // factory's register_pair cross-checks `pair_salt` against the
    // address-match computation. If SDK's CANONICAL_DEPLOY_SALT ever
    // drifts from Fr(1), every createPair call via the SDK will land
    // pair and LP at non-canonical addresses and register_pair will
    // revert with ADDRESS_MISMATCH. This test is cheap insurance.
    assert.equal(CANONICAL_DEPLOY_SALT.toBigInt(), 1n);
  });

  // ================================================================
  // factory.createPair idempotency + inspection helpers
  // ================================================================

  it('createPair is idempotent: calling twice with same inputs returns same handles and sends no duplicate deploys', async () => {
    // The before() block already deployed pair + LP and registered. Calling
    // createPair again with identical inputs must detect the prior state:
    //   - pair exists at canonical address -> skip deploy, fetch handle
    //   - LP exists at derived address -> skip deploy, fetch handle
    //   - factory.get_pair returns our pair -> skip register
    // and return addresses matching the original deployment.
    const result = await deployPairWithLP(wallet, sender, tokenA, tokenB, factory, FEE_TIER);
    assert.equal(result.pair.address.toString(), pair.address.toString());
    assert.equal(result.lpToken.address.toString(), lpToken.address.toString());
    assert.equal(result.token0.toString(), pairToken0.toString());
    assert.equal(result.token1.toString(), pairToken1.toString());
  });

  it('deriveCanonicalPairAddress returns the address of the deployed pair without sending a tx', async () => {
    // Computes the canonical address off-chain (via DeployMethod.getInstance)
    // without issuing a deploy tx. For an already-deployed pair this must
    // match the live pair's address -- confirms the SDK's canonical-input
    // derivation matches the runtime deploy path.
    const sdkFactory = new SigalSwapFactory(factory, sender);
    const derived = await sdkFactory.deriveCanonicalPairAddress(
      wallet, tokenA.address, tokenB.address, FEE_TIER,
    );
    assert.equal(derived.toString(), pair.address.toString());
  });

  it('deriveCanonicalPairAddress is order-independent for the input token pair', async () => {
    // Tokens are sorted internally; caller passing either (A, B) or (B, A)
    // must resolve to the same canonical address.
    const sdkFactory = new SigalSwapFactory(factory, sender);
    const ab = await sdkFactory.deriveCanonicalPairAddress(
      wallet, tokenA.address, tokenB.address, FEE_TIER,
    );
    const ba = await sdkFactory.deriveCanonicalPairAddress(
      wallet, tokenB.address, tokenA.address, FEE_TIER,
    );
    assert.equal(ab.toString(), ba.toString());
  });

  it('isPairRegistered returns true for the deployed pair and false for a different address', async () => {
    const sdkFactory = new SigalSwapFactory(factory, sender);

    const registered = await sdkFactory.isPairRegistered(
      pair.address, tokenA.address, tokenB.address, FEE_TIER,
    );
    assert.equal(registered, true);

    // A non-pair address (using tokenA here as a convenient non-pair
    // address) must return false -- the factory's get_pair returns the
    // actual pair, not this random input.
    const notRegistered = await sdkFactory.isPairRegistered(
      tokenA.address, tokenA.address, tokenB.address, FEE_TIER,
    );
    assert.equal(notRegistered, false);
  });

  // ================================================================
  // Router exact-out donation preservation
  //
  // The router's exact-out swap entries refund the unspent input and
  // any leftover output via execution-derived per-hop deltas. They do
  // NOT consume `balance_of_public(self)` totals -- so a donation
  // (or stuck-balance dust from earlier cyclic exact-in swaps) sitting
  // at the router pre-swap stays at the router post-swap, recoverable
  // only via the documented permissionless `skim_to` path.
  //
  // These tests pre-fund the router with public-balance donations of
  // both `token_in` and `token_out`, run an exact-out swap, and assert
  // the router still holds exactly the donation amounts. Each test is
  // self-contained: snapshot pre-swap, donate, swap, assert.
  //
  // Single-pair entry vs multi-hop entry both touch the same
  // accounting (`_swap_exact_out` uses the returned `consumed` for
  // change; `_swap_exact_out_multi_hop` uses per-hop `consumed[]` for
  // change + intermediate dust + final amount). The path_length=2
  // multi-hop case skips the dust loop (no real intermediates), so a
  // dedicated path_length>=3 canary covering intermediate-token
  // preservation lives in a follow-up multi-pair E2E suite.
  // ================================================================

  it('router.swapSingleExactOut preserves pre-existing router donations of token_in and token_out', async () => {
    const donationIn = 7_777n;
    const donationOut = 3_333n;

    // Donate to the router publicly. Token contract's admin (sender) can mint.
    await tokenA.methods.mint_to_public(router.address, donationIn)
      .send({ from: sender, wait: TX_OPTS });
    await tokenB.methods.mint_to_public(router.address, donationOut)
      .send({ from: sender, wait: TX_OPTS });

    // Sanity: donations landed.
    const { result: inBefore } = await tokenA.methods.balance_of_public(router.address)
      .simulate({ from: sender });
    const { result: outBefore } = await tokenB.methods.balance_of_public(router.address)
      .simulate({ from: sender });
    assert.equal(inBefore, donationIn, 'donation of token_in should land at router');
    assert.equal(outBefore, donationOut, 'donation of token_out should land at router');

    await client.router().swapSingleExactOut({
      pair: pair.address,
      tokenIn: pairToken0,
      tokenOut: pairToken1,
      amountOut: 100n,
      amountInMax: 2_000n,
      deadline: DEADLINE(),
    });

    // Router's public balance of each token must equal the donation amount
    // exactly. The change refund derives from the per-hop `consumed` return
    // value (not from a router-side balance-delta read), and `received` is
    // taken from the V3 exact-output guarantee (`pair_target_out`), so
    // donations are never aggregated into the user's refund.
    const { result: inAfter } = await tokenA.methods.balance_of_public(router.address)
      .simulate({ from: sender });
    const { result: outAfter } = await tokenB.methods.balance_of_public(router.address)
      .simulate({ from: sender });
    assert.equal(inAfter, donationIn, 'router token_in donation must be preserved across exact-out swap');
    assert.equal(outAfter, donationOut, 'router token_out donation must be preserved across exact-out swap');
  });

  it('router.swapExactOut (multi-hop entry, path_length=2) preserves router donations of token_in and token_out', async () => {
    // Snapshot router balances first -- earlier tests may have left dust.
    // Assertion is "post-tx == pre-tx + this-test-donation," not "post-tx == this-test-donation."
    const { result: inBaseline } = await tokenA.methods.balance_of_public(router.address)
      .simulate({ from: sender });
    const { result: outBaseline } = await tokenB.methods.balance_of_public(router.address)
      .simulate({ from: sender });

    const donationIn = 4_321n;
    const donationOut = 1_234n;
    await tokenA.methods.mint_to_public(router.address, donationIn)
      .send({ from: sender, wait: TX_OPTS });
    await tokenB.methods.mint_to_public(router.address, donationOut)
      .send({ from: sender, wait: TX_OPTS });

    const inExpected = inBaseline + donationIn;
    const outExpected = outBaseline + donationOut;

    await client.router().swapExactOut({
      path: [pairToken0, pairToken1],
      pairs: [pair.address],
      amountOut: 100n,
      amountInMax: 2_000n,
      deadline: DEADLINE(),
    });

    const { result: inAfter } = await tokenA.methods.balance_of_public(router.address)
      .simulate({ from: sender });
    const { result: outAfter } = await tokenB.methods.balance_of_public(router.address)
      .simulate({ from: sender });
    assert.equal(inAfter, inExpected, 'router token_in donation+baseline must be preserved across multi-hop entry exact-out swap');
    assert.equal(outAfter, outExpected, 'router token_out donation+baseline must be preserved across multi-hop entry exact-out swap');
  });
});

// ================================================================
// Multi-hop exact-out: intermediate-token donation preservation
//
// Separate `describe` block because it needs an extra token (C) and
// a second pair (B/C) so that path = [A, B, C] traverses a real
// intermediate. Path_length=2 cases above don't reach the dust loop
// (no real intermediates), so this is the canary that specifically
// exercises the per-hop `amounts[j] - consumed[j]` refund branch.
// ================================================================

describe('SigalSwap E2E — exact-out multi-hop intermediate donation preservation', { timeout: 600_000 }, () => {
  let wallet: Wallet;
  let sender: AztecAddress;
  let tokenA: TokenContract;
  let tokenB: TokenContract;
  let tokenC: TokenContract;
  let factory: SigalSwapFactoryContract;
  let pairAB: SigalSwapPairContract;
  let pairBC: SigalSwapPairContract;
  let router: SigalSwapRouterContract;
  let client: SigalSwapClient;

  before(async () => {
    const setup = await setupWallet();
    wallet = setup.wallet;
    sender = setup.senderAddress;

    tokenA = await deployToken(wallet, sender, 'TokenA', 'TKA');
    tokenB = await deployToken(wallet, sender, 'TokenB', 'TKB');
    tokenC = await deployToken(wallet, sender, 'TokenC', 'TKC');
    await mintPrivate(tokenA, sender, sender, MINT_AMOUNT);
    await mintPrivate(tokenB, sender, sender, MINT_AMOUNT);
    await mintPrivate(tokenC, sender, sender, MINT_AMOUNT);

    factory = await deployFactory(wallet, sender);
    const ab = await deployPairWithLP(wallet, sender, tokenA, tokenB, factory, FEE_TIER);
    const bc = await deployPairWithLP(wallet, sender, tokenB, tokenC, factory, FEE_TIER);
    pairAB = ab.pair;
    pairBC = bc.pair;

    router = await deployRouter(wallet, sender, factory);
    client = await SigalSwapClient.create({
      wallet,
      senderAddress: sender,
      factoryAddress: factory.address,
      routerAddress: router.address,
    });

    await client.unsafePair(pairAB.address).addLiquidity({
      amount0Max: 100_000n, amount1Max: 100_000n, amount0Min: 0n, amount1Min: 0n,
    });
    await client.unsafePair(pairBC.address).addLiquidity({
      amount0Max: 100_000n, amount1Max: 100_000n, amount0Min: 0n, amount1Min: 0n,
    });
  });

  it('multi-hop exact-out [A, B, C] preserves a pre-existing intermediate-B donation', async () => {
    const donationB = 5_555n;
    const donationC = 2_222n;
    await tokenB.methods.mint_to_public(router.address, donationB)
      .send({ from: sender, wait: TX_OPTS });
    await tokenC.methods.mint_to_public(router.address, donationC)
      .send({ from: sender, wait: TX_OPTS });

    const { result: bBefore } = await tokenB.methods.balance_of_public(router.address)
      .simulate({ from: sender });
    const { result: cBefore } = await tokenC.methods.balance_of_public(router.address)
      .simulate({ from: sender });
    assert.equal(bBefore, donationB);
    assert.equal(cBefore, donationC);

    await client.router().swapExactOut({
      path: [tokenA.address, tokenB.address, tokenC.address],
      pairs: [pairAB.address, pairBC.address],
      amountOut: 100n,
      amountInMax: 5_000n,
      deadline: DEADLINE(),
    });

    // Intermediate-B and final-C donations stay at the router and remain
    // recoverable via skim_to. The dust-refund branch uses `amounts[j] -
    // consumed[j]` (per-hop execution-derived delta) so it cannot reach
    // the donation, and the final-amount calculation uses
    // `amounts[path_length - 1]` (the V3 exact-output guarantee) rather
    // than the router's full final-token balance.
    const { result: bAfter } = await tokenB.methods.balance_of_public(router.address)
      .simulate({ from: sender });
    const { result: cAfter } = await tokenC.methods.balance_of_public(router.address)
      .simulate({ from: sender });
    assert.equal(bAfter, donationB, 'intermediate B donation must be preserved across multi-hop exact-out swap');
    assert.equal(cAfter, donationC, 'final C donation must be preserved across multi-hop exact-out swap');
  });
});
