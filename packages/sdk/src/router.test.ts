import { describe, it, expect, vi, beforeEach } from 'vitest';
import { SigalSwapRouter } from './router.js';
import {
  ADDR_A, ADDR_B, ADDR_C, ADDR_D, ADDR_PAIR, ADDR_PAIR_BC, ADDR_ROUTER,
  ADDR_SENDER, ADDR_ZERO, ADDR_FACTORY, ADDR_FEE_RECIPIENT, ADDR_LP_TOKEN,
} from './__test__/addresses.js';
import { AztecAddress } from '@aztec/aztec.js/addresses';
import {
  mockRouterContract, mockWallet, mockInteraction,
  mockTokenContract, mockPairContract, futureDeadline,
  DEFAULT_PAIR_CONFIG,
} from './__test__/mocks.js';
import type { SigalSwapConfig } from './config/index.js';

vi.mock('./artifacts/SigalSwapRouter.js', () => ({
  SigalSwapRouterContract: { at: vi.fn() },
}));
vi.mock('./artifacts/SigalSwapPair.js', () => ({
  SigalSwapPairContract: { at: vi.fn() },
}));
vi.mock('./artifacts/SigalSwapFactory.js', () => ({
  SigalSwapFactoryContract: { at: vi.fn() },
}));
vi.mock('./artifacts/Token.js', () => ({
  TokenContract: { at: vi.fn() },
}));

import { SigalSwapPairContract } from './artifacts/SigalSwapPair.js';
import { SigalSwapFactoryContract } from './artifacts/SigalSwapFactory.js';
import { TokenContract } from './artifacts/Token.js';

/**
 * Smart factory mock for the router's `assertPairVerified` cross-check.
 * `get_pair_versioned(token0, token1, feeTier, version)` returns the
 * registered pair address per (tokens) tuple. Two known pairs in the
 * test fixture: (A,B) → ADDR_PAIR, (B,C) → ADDR_PAIR_BC. Any other
 * combination returns the zero address (the contract's "no pair
 * registered" sentinel), which the verifier reads as "not verified."
 */
function makeFactoryMock(address: AztecAddress = ADDR_FACTORY) {
  return {
    address,
    methods: {
      get_pair_versioned: vi.fn().mockImplementation(
        (t0: AztecAddress, t1: AztecAddress, _fee: number, _version: number) => {
          if (t0.equals(ADDR_A) && t1.equals(ADDR_B)) return mockInteraction(ADDR_PAIR);
          if (t0.equals(ADDR_B) && t1.equals(ADDR_C)) return mockInteraction(ADDR_PAIR_BC);
          return mockInteraction(ADDR_ZERO);
        },
      ),
    },
  };
}

function makeRouter(configOverrides: Partial<SigalSwapConfig> = {}) {
  const config: SigalSwapConfig = {
    nodeUrl: 'http://localhost:8080',
    environment: 'local',
    feeBips: 0,
    ...configOverrides,
  };
  const contract = mockRouterContract(ADDR_ROUTER);
  const wallet = mockWallet(ADDR_SENDER);
  const tokenMock = mockTokenContract();
  vi.mocked(TokenContract.at).mockReturnValue(tokenMock as any);

  // Per-address pair mocks. Single-hop tests + add/remove liquidity use
  // ADDR_PAIR which holds (token0=A, token1=B). Multi-hop tests that walk
  // [A, B, C] need a second pair on (B, C); ADDR_PAIR_BC covers that.
  const pairContract = mockPairContract(ADDR_PAIR);
  const pairContractBC = mockPairContract(ADDR_PAIR_BC, {
    token0: ADDR_B, token1: ADDR_C, factory: ADDR_FACTORY, fee_tier_bps: 25n, version: 1n,
    lp_token: ADDR_LP_TOKEN,
  });
  vi.mocked(SigalSwapPairContract.at).mockImplementation((address: AztecAddress) => {
    if (address.equals(ADDR_PAIR_BC)) return pairContractBC as any;
    return pairContract as any;
  });

  const factoryContract = makeFactoryMock();
  vi.mocked(SigalSwapFactoryContract.at).mockReturnValue(factoryContract as any);

  const router = new SigalSwapRouter(
    contract as any, wallet, ADDR_SENDER, config, factoryContract as any,
  );
  return { router, contract, wallet, tokenMock, pairContract, pairContractBC, factoryContract };
}

// ================================================================
// Deadline validation (tested via swapSingleExactIn)
// ================================================================

describe('deadline validation', () => {
  it('throws when deadline is 0', async () => {
    const { router } = makeRouter();
    await expect(router.swapSingleExactIn({
      pair: ADDR_PAIR, tokenIn: ADDR_A, tokenOut: ADDR_B,
      amountIn: 100n, amountOutMin: 90n, deadline: 0,
    })).rejects.toThrow('deadline must be a positive integer');
  });

  it('throws when deadline is negative', async () => {
    const { router } = makeRouter();
    await expect(router.swapSingleExactIn({
      pair: ADDR_PAIR, tokenIn: ADDR_A, tokenOut: ADDR_B,
      amountIn: 100n, amountOutMin: 90n, deadline: -1,
    })).rejects.toThrow('deadline must be a positive integer');
  });

  it('throws when deadline is fractional', async () => {
    const { router } = makeRouter();
    await expect(router.swapSingleExactIn({
      pair: ADDR_PAIR, tokenIn: ADDR_A, tokenOut: ADDR_B,
      amountIn: 100n, amountOutMin: 90n, deadline: 1.5,
    })).rejects.toThrow('deadline must be a positive integer');
  });

  it('accepts deadline == current second (boundary: not yet past)', async () => {
    // The check is `deadline < Math.floor(Date.now() / 1000)`. A deadline
    // equal to the current second is NOT past — it's the inclusive lower
    // bound. Uses fake timers so Date.now() is deterministic and
    // doesn't tick between deadline construction and validation.
    vi.useFakeTimers();
    try {
      vi.setSystemTime(new Date('2026-05-09T12:00:00Z'));
      const now = Math.floor(Date.now() / 1000);
      const { router } = makeRouter();
      await router.swapSingleExactIn({
        pair: ADDR_PAIR, tokenIn: ADDR_A, tokenOut: ADDR_B,
        amountIn: 100n, amountOutMin: 90n, deadline: now,
      });
    } finally {
      vi.useRealTimers();
    }
  });

  it('throws when deadline is in the past', async () => {
    const { router } = makeRouter();
    const pastDeadline = Math.floor(Date.now() / 1000) - 60;
    await expect(router.swapSingleExactIn({
      pair: ADDR_PAIR, tokenIn: ADDR_A, tokenOut: ADDR_B,
      amountIn: 100n, amountOutMin: 90n, deadline: pastDeadline,
    })).rejects.toThrow('deadline is in the past');
  });
});

// ================================================================
// swapSingleExactIn
// ================================================================

describe('swapSingleExactIn', () => {
  it('throws when pair is zero address', async () => {
    const { router } = makeRouter();
    await expect(router.swapSingleExactIn({
      pair: ADDR_ZERO, tokenIn: ADDR_A, tokenOut: ADDR_B,
      amountIn: 100n, amountOutMin: 90n, deadline: futureDeadline(),
    })).rejects.toThrow('pair address cannot be zero');
  });

  it('throws when amountIn is 0', async () => {
    const { router } = makeRouter();
    await expect(router.swapSingleExactIn({
      pair: ADDR_PAIR, tokenIn: ADDR_A, tokenOut: ADDR_B,
      amountIn: 0n, amountOutMin: 90n, deadline: futureDeadline(),
    })).rejects.toThrow('amountIn must be positive');
  });

  it('throws when tokenIn equals tokenOut', async () => {
    const { router } = makeRouter();
    await expect(router.swapSingleExactIn({
      pair: ADDR_PAIR, tokenIn: ADDR_A, tokenOut: ADDR_A,
      amountIn: 100n, amountOutMin: 90n, deadline: futureDeadline(),
    })).rejects.toThrow('tokenIn and tokenOut must differ');
  });

  it('accepts amountOutMin = 0 (zero is valid: any output amount accepted)', async () => {
    const { router } = makeRouter();
    await router.swapSingleExactIn({
      pair: ADDR_PAIR, tokenIn: ADDR_A, tokenOut: ADDR_B,
      amountIn: 100n, amountOutMin: 0n, deadline: futureDeadline(),
    });
  });

  it('throws when amountOutMin is negative', async () => {
    const { router } = makeRouter();
    await expect(router.swapSingleExactIn({
      pair: ADDR_PAIR, tokenIn: ADDR_A, tokenOut: ADDR_B,
      amountIn: 100n, amountOutMin: -1n, deadline: futureDeadline(),
    })).rejects.toThrow('amountOutMin cannot be negative');
  });

  it('accepts reverse-order tokens (tokenIn=token1, tokenOut=token0)', async () => {
    // Pair config is (A, B). User can swap in either direction. The
    // matchesReverse path must succeed when (tokenIn=B, tokenOut=A).
    // If matchesReverse were elided (always false), this swap would be
    // wrongly rejected.
    const { router } = makeRouter();
    await router.swapSingleExactIn({
      pair: ADDR_PAIR, tokenIn: ADDR_B, tokenOut: ADDR_A,
      amountIn: 100n, amountOutMin: 90n, deadline: futureDeadline(),
    });
  });

  it('rejects partial-match where only tokenIn equals pair token1', async () => {
    // Pair config is (A, B). Call with tokenIn=B (matches token1), tokenOut=C (matches neither).
    // matchesReverse must require BOTH cfg.token0==tokenOut AND cfg.token1==tokenIn;
    // an `||` would let this slip through. The throw confirms `&&` is required.
    const { router } = makeRouter();
    await expect(router.swapSingleExactIn({
      pair: ADDR_PAIR, tokenIn: ADDR_B, tokenOut: ADDR_C,
      amountIn: 100n, amountOutMin: 90n, deadline: futureDeadline(),
    })).rejects.toThrow(/does not contain/);
  });

  it('creates authwit with router as caller and sends', async () => {
    const { router, contract, wallet, tokenMock } = makeRouter();
    await router.swapSingleExactIn({
      pair: ADDR_PAIR, tokenIn: ADDR_A, tokenOut: ADDR_B,
      amountIn: 100n, amountOutMin: 90n, deadline: futureDeadline(),
    });
    expect(tokenMock.methods.transfer_to_public).toHaveBeenCalled();
    expect(wallet.createAuthWit).toHaveBeenCalledOnce();
    // Single-hop calls swap_exact_in on the router; the ROUTER pulls
    // tokens from the user, so the authwit's `caller` must be the router
    // address. Mirrors the multi-hop tests below that assert the same.
    const authWitArgs = wallet.createAuthWit.mock.calls[0];
    expect(authWitArgs[1].caller).toEqual(ADDR_ROUTER);
    expect(contract.methods.swap_exact_in).toHaveBeenCalled();
  });

  it('passes configured fee_recipient and fee_bips to the contract', async () => {
    // Single-hop now honors the SDK's configured interface fee, matching
    // multi-hop behavior. amount_out_min maps 1:1 (contract enforces post-fee).
    const { router, contract } = makeRouter({
      feeBips: 50,
      feeRecipient: ADDR_FEE_RECIPIENT.toString(),
    });
    await router.swapSingleExactIn({
      pair: ADDR_PAIR, tokenIn: ADDR_A, tokenOut: ADDR_B,
      amountIn: 100n, amountOutMin: 90n, deadline: futureDeadline(),
    });
    const callArgs = contract.methods.swap_exact_in.mock.calls[0];
    // swap_exact_in(pair, token_in, token_out, amount_in, amount_out_min,
    //               deadline, authwit_nonce, fee_recipient, fee_bips)
    expect(callArgs[4]).toBe(90n);
    expect(callArgs[7]).toEqual(ADDR_FEE_RECIPIENT);
    expect(callArgs[8]).toBe(50);
  });

  it('defaults fee params to zero when the SDK config has no interface fee', async () => {
    const { router, contract } = makeRouter();
    await router.swapSingleExactIn({
      pair: ADDR_PAIR, tokenIn: ADDR_A, tokenOut: ADDR_B,
      amountIn: 100n, amountOutMin: 90n, deadline: futureDeadline(),
    });
    const callArgs = contract.methods.swap_exact_in.mock.calls[0];
    expect(callArgs[7]).toEqual(ADDR_ZERO);
    expect(callArgs[8]).toBe(0);
  });

  it('rejects mismatched (pair, tokenIn, tokenOut)', async () => {
    // ADDR_PAIR holds (token0=A, token1=B); supplying ADDR_C as tokenIn
    // doesn't match. Boundary fail-fast against contract-side
    // TOKEN_IN_IS_INVALID after authwit + proving cost.
    const { router } = makeRouter();
    await expect(router.swapSingleExactIn({
      pair: ADDR_PAIR, tokenIn: ADDR_C, tokenOut: ADDR_B,
      amountIn: 100n, amountOutMin: 90n, deadline: futureDeadline(),
    })).rejects.toThrow(/does not contain/);
  });
});

// ================================================================
// swapSingleExactOut
// ================================================================

describe('swapSingleExactOut', () => {
  it('throws when amountOut is 0', async () => {
    const { router } = makeRouter();
    await expect(router.swapSingleExactOut({
      pair: ADDR_PAIR, tokenIn: ADDR_A, tokenOut: ADDR_B,
      amountOut: 0n, amountInMax: 110n, deadline: futureDeadline(),
    })).rejects.toThrow('amountOut must be positive');
  });

  it('throws when amountInMax is 0', async () => {
    const { router } = makeRouter();
    await expect(router.swapSingleExactOut({
      pair: ADDR_PAIR, tokenIn: ADDR_A, tokenOut: ADDR_B,
      amountOut: 100n, amountInMax: 0n, deadline: futureDeadline(),
    })).rejects.toThrow('amountInMax must be positive');
  });

  it('uses transfer_to_public_and_prepare_private_balance_increase for input tokens', async () => {
    // The router pulls amount_in_max AND prepares a change partial note so any
    // unspent input can be refunded to the user privately after the swap.
    const { router, tokenMock } = makeRouter();
    await router.swapSingleExactOut({
      pair: ADDR_PAIR, tokenIn: ADDR_A, tokenOut: ADDR_B,
      amountOut: 100n, amountInMax: 110n, deadline: futureDeadline(),
    });
    expect(tokenMock.methods.transfer_to_public_and_prepare_private_balance_increase).toHaveBeenCalled();
  });

  it('throws when tokenIn equals tokenOut', async () => {
    const { router } = makeRouter();
    await expect(router.swapSingleExactOut({
      pair: ADDR_PAIR, tokenIn: ADDR_A, tokenOut: ADDR_A,
      amountOut: 100n, amountInMax: 110n, deadline: futureDeadline(),
    })).rejects.toThrow('tokenIn and tokenOut must differ');
  });

  it('throws when pair is zero address', async () => {
    const { router } = makeRouter();
    await expect(router.swapSingleExactOut({
      pair: ADDR_ZERO, tokenIn: ADDR_A, tokenOut: ADDR_B,
      amountOut: 100n, amountInMax: 110n, deadline: futureDeadline(),
    })).rejects.toThrow('pair address cannot be zero');
  });

  it('passes amountOut and fee params when a fee is configured', async () => {
    // The router grosses up the pair-level target on-chain; the SDK only
    // forwards the user-facing values plus fee config.
    const { router, contract } = makeRouter({
      feeBips: 50,
      feeRecipient: ADDR_FEE_RECIPIENT.toString(),
    });
    await router.swapSingleExactOut({
      pair: ADDR_PAIR, tokenIn: ADDR_A, tokenOut: ADDR_B,
      amountOut: 10000n, amountInMax: 11000n, deadline: futureDeadline(),
    });
    const callArgs = contract.methods.swap_exact_out.mock.calls[0];
    // swap_exact_out(pair, token_in, token_out, amount_out, amount_in_max,
    //                deadline, nonce, fee_recipient, fee_bips)
    expect(callArgs[3]).toBe(10000n);
    expect(callArgs[4]).toBe(11000n);
    expect(callArgs[7]).toEqual(ADDR_FEE_RECIPIENT);
    expect(callArgs[8]).toBe(50);
  });

  it('passes zero fee params when no fee is configured', async () => {
    const { router, contract } = makeRouter();
    await router.swapSingleExactOut({
      pair: ADDR_PAIR, tokenIn: ADDR_A, tokenOut: ADDR_B,
      amountOut: 100n, amountInMax: 110n, deadline: futureDeadline(),
    });
    const callArgs = contract.methods.swap_exact_out.mock.calls[0];
    expect(callArgs[3]).toBe(100n);
    expect(callArgs[4]).toBe(110n);
    expect(callArgs[7]).toEqual(ADDR_ZERO);
    expect(callArgs[8]).toBe(0);
  });

  it('rejects mismatched (pair, tokenIn, tokenOut)', async () => {
    const { router } = makeRouter();
    await expect(router.swapSingleExactOut({
      pair: ADDR_PAIR, tokenIn: ADDR_A, tokenOut: ADDR_C,
      amountOut: 100n, amountInMax: 110n, deadline: futureDeadline(),
    })).rejects.toThrow(/does not contain/);
  });
});

// ================================================================
// swapExactIn (multi-hop) — path validation + fee computation
// ================================================================

describe('swapExactIn (multi-hop)', () => {
  const validOpts = () => ({
    path: [ADDR_A, ADDR_B],
    pairs: [ADDR_PAIR],
    amountIn: 100n,
    amountOutMin: 90n,
    deadline: futureDeadline(),
  });

  it('throws when path has < 2 tokens', async () => {
    const { router } = makeRouter();
    await expect(router.swapExactIn({ ...validOpts(), path: [ADDR_A], pairs: [] }))
      .rejects.toThrow('Path must have at least 2 tokens');
  });

  it('throws when path has > MAX_HOPS+1 tokens', async () => {
    const { router } = makeRouter();
    await expect(router.swapExactIn({
      ...validOpts(),
      path: [ADDR_A, ADDR_B, ADDR_C, ADDR_D, ADDR_A],
      pairs: [ADDR_PAIR, ADDR_PAIR, ADDR_PAIR, ADDR_PAIR],
    })).rejects.toThrow('Path too long');
  });

  it('throws when pairs length != path.length - 1', async () => {
    const { router } = makeRouter();
    await expect(router.swapExactIn({
      ...validOpts(), path: [ADDR_A, ADDR_B, ADDR_C], pairs: [ADDR_PAIR],
    })).rejects.toThrow('Pairs array must be one shorter');
  });

  it('throws on adjacent duplicate tokens', async () => {
    const { router } = makeRouter();
    await expect(router.swapExactIn({
      ...validOpts(), path: [ADDR_A, ADDR_A, ADDR_B], pairs: [ADDR_PAIR, ADDR_PAIR],
    })).rejects.toThrow('Adjacent tokens in path must differ');
  });

  it('accepts triangular arbitrage path (start == end)', async () => {
    // Exact-in supports cyclic paths -- the contract consumes the full
    // amount_in on hop 0 and measures the final-token balance cleanly.
    // SDK must not pre-reject this shape. Both hops use ADDR_PAIR which
    // is mocked with config (A, B); pair-consistency check accepts both
    // (path[0]=A,path[1]=B) and (path[1]=B,path[2]=A) (reverse-order match).
    const { router } = makeRouter();
    await router.swapExactIn({
      ...validOpts(), path: [ADDR_A, ADDR_B, ADDR_A], pairs: [ADDR_PAIR, ADDR_PAIR],
    });
  });

  it('accepts path.length == MAX_HOPS+1 (max valid path)', async () => {
    // Boundary: maximum allowed path length. Exercises both the path-length
    // upper bound and the padArray invariant (arr.length == targetLength
    // must not throw).
    const { router } = makeRouter();
    await router.swapExactIn({
      ...validOpts(),
      path: [ADDR_A, ADDR_B, ADDR_A, ADDR_B],
      pairs: [ADDR_PAIR, ADDR_PAIR, ADDR_PAIR],
    });
  });

  it('throws when amountIn is 0', async () => {
    const { router } = makeRouter();
    await expect(router.swapExactIn({ ...validOpts(), amountIn: 0n }))
      .rejects.toThrow('amountIn must be positive');
  });

  it('throws when amountOutMin is negative', async () => {
    const { router } = makeRouter();
    await expect(router.swapExactIn({ ...validOpts(), amountOutMin: -1n }))
      .rejects.toThrow('amountOutMin cannot be negative');
  });

  it('rejects multi-hop path where hop has only partial token match', async () => {
    // Pair config at ADDR_PAIR is (A, B). Use path [B, C] at hop 0.
    // matchesForward: A==B && B==C -> false.
    // matchesReverse with `&&`: A==C && B==B -> false (throws).
    // matchesReverse with `||`: A==C || B==B -> true (would accept).
    // The throw confirms validatePathPairConsistency uses `&&`.
    const { router } = makeRouter();
    await expect(router.swapExactIn({
      ...validOpts(),
      path: [ADDR_B, ADDR_C],
      pairs: [ADDR_PAIR],
    })).rejects.toThrow(/does not contain/);
  });

  it('rejects multi-hop with mismatched pair config (shuffled pairs array)', async () => {
    // path=[A,B,C] but pairs=[ADDR_PAIR_BC, ADDR_PAIR] swaps the order.
    // Hop 0 expects (A,B) but supplied pair holds (B,C). Without this
    // check the contract reverts deeper after authwits are consumed.
    const { router } = makeRouter();
    await expect(router.swapExactIn({
      ...validOpts(),
      path: [ADDR_A, ADDR_B, ADDR_C],
      pairs: [ADDR_PAIR_BC, ADDR_PAIR],
    })).rejects.toThrow(/does not contain/);
  });

  it('passes amountOutMin through unchanged when no fee configured', async () => {
    const { router, contract } = makeRouter({ feeBips: 0 });
    await router.swapExactIn(validOpts());
    const callArgs = contract.methods.swap_exact_in_multi_hop.mock.calls[0];
    expect(callArgs[4]).toBe(90n);
  });

  it('passes amountOutMin through unchanged even when fee is active', async () => {
    // The contract enforces amount_out_min AFTER deducting the fee, so the
    // user's request maps 1:1 -- no SDK-side inflation.
    const { router, contract } = makeRouter({
      feeBips: 50,
      feeRecipient: ADDR_FEE_RECIPIENT.toString(),
    });
    await router.swapExactIn({ ...validOpts(), amountOutMin: 995n });
    const callArgs = contract.methods.swap_exact_in_multi_hop.mock.calls[0];
    expect(callArgs[4]).toBe(995n);
  });

  it('passes amountOutMin through when feeBips > 0 but feeRecipient is empty', async () => {
    const { router, contract } = makeRouter({ feeBips: 50 });
    await router.swapExactIn(validOpts());
    const callArgs = contract.methods.swap_exact_in_multi_hop.mock.calls[0];
    expect(callArgs[4]).toBe(90n);
  });

  it('creates authwit with router as caller for multi-hop', async () => {
    const { router, wallet } = makeRouter();
    await router.swapExactIn(validOpts());
    const authwitCall = vi.mocked(wallet.createAuthWit).mock.calls[0];
    expect(authwitCall[0]).toBe(ADDR_SENDER); // from
    expect(authwitCall[1]).toHaveProperty('caller', ADDR_ROUTER); // router is caller
  });

  it('pads path and pairs to fixed lengths', async () => {
    const { router, contract } = makeRouter();
    await router.swapExactIn(validOpts());
    const callArgs = contract.methods.swap_exact_in_multi_hop.mock.calls[0];
    expect(callArgs[0]).toHaveLength(4); // MAX_HOPS + 1
    expect(callArgs[1]).toHaveLength(3); // MAX_HOPS
    expect(callArgs[2]).toBe(2); // path_length
  });

  it('throws when feeBips exceeds the 5% cap', async () => {
    // Contract caps fee_bips at 500 (5%); SDK mirrors the cap for a clearer
    // client-side error before the tx is built.
    const { router } = makeRouter({ feeBips: 501, feeRecipient: ADDR_FEE_RECIPIENT.toString() });
    await expect(router.swapExactIn(validOpts())).rejects.toThrow('feeBips must be <= 500');
  });

  it('accepts feeBips exactly at the 5% cap', async () => {
    const { router, contract } = makeRouter({ feeBips: 500, feeRecipient: ADDR_FEE_RECIPIENT.toString() });
    await router.swapExactIn({ ...validOpts(), amountOutMin: 100n });
    const callArgs = contract.methods.swap_exact_in_multi_hop.mock.calls[0];
    expect(callArgs[4]).toBe(100n);
    expect(callArgs[8]).toBe(500);
  });

  it('passes amountOutMin through when userAmountOutMin is 0', async () => {
    const { router, contract } = makeRouter({ feeBips: 50, feeRecipient: ADDR_FEE_RECIPIENT.toString() });
    await router.swapExactIn({ ...validOpts(), amountOutMin: 0n });
    const callArgs = contract.methods.swap_exact_in_multi_hop.mock.calls[0];
    expect(callArgs[4]).toBe(0n);
  });
});

// ================================================================
// swapExactOut (multi-hop) — path validation (incl. final-unique),
// fee pass-through, bound arithmetic
// ================================================================

describe('swapExactOut (multi-hop)', () => {
  const validOpts = () => ({
    path: [ADDR_A, ADDR_B, ADDR_C],
    pairs: [ADDR_PAIR, ADDR_PAIR_BC],
    amountOut: 100n,
    amountInMax: 200n,
    deadline: futureDeadline(),
  });

  it('throws when path has < 2 tokens', async () => {
    const { router } = makeRouter();
    await expect(router.swapExactOut({ ...validOpts(), path: [ADDR_A], pairs: [] }))
      .rejects.toThrow('Path must have at least 2 tokens');
  });

  it('throws when path has > MAX_HOPS+1 tokens', async () => {
    const { router } = makeRouter();
    await expect(router.swapExactOut({
      ...validOpts(),
      path: [ADDR_A, ADDR_B, ADDR_C, ADDR_D, ADDR_A],
      pairs: [ADDR_PAIR, ADDR_PAIR, ADDR_PAIR, ADDR_PAIR],
    })).rejects.toThrow('Path too long');
  });

  it('throws when pairs length != path.length - 1', async () => {
    const { router } = makeRouter();
    await expect(router.swapExactOut({
      ...validOpts(), path: [ADDR_A, ADDR_B, ADDR_C], pairs: [ADDR_PAIR],
    })).rejects.toThrow('Pairs array must be one shorter');
  });

  it('accepts path.length == 2 (minimum valid path: single hop)', async () => {
    // Boundary: minimum allowed path length. Path of [tokenIn, tokenOut]
    // with one pair is the smallest valid multi-hop input.
    const { router } = makeRouter();
    await router.swapExactOut({
      ...validOpts(), path: [ADDR_A, ADDR_B], pairs: [ADDR_PAIR],
    });
  });

  it('throws on adjacent duplicate tokens', async () => {
    const { router } = makeRouter();
    await expect(router.swapExactOut({
      ...validOpts(), path: [ADDR_A, ADDR_A, ADDR_B], pairs: [ADDR_PAIR, ADDR_PAIR],
    })).rejects.toThrow('Adjacent tokens in path must differ');
  });

  it('throws on cyclic path (final == initial)', async () => {
    // [A, B, C, A] -- exact-out breaks when the final token also appears
    // earlier because change-refund and final-output measurements race
    // for the same balance. Contract asserts FINAL_TOKEN_REPEATED.
    const { router } = makeRouter();
    await expect(router.swapExactOut({
      ...validOpts(),
      path: [ADDR_A, ADDR_B, ADDR_C, ADDR_A],
      pairs: [ADDR_PAIR, ADDR_PAIR, ADDR_PAIR],
    })).rejects.toThrow('Final token cannot appear earlier');
  });

  it('throws on hub-routing path (final == intermediate)', async () => {
    // [A, B, C, B] -- the intermediate-dust refund loop drains the final
    // token's balance before the final-output send.
    const { router } = makeRouter();
    await expect(router.swapExactOut({
      ...validOpts(),
      path: [ADDR_A, ADDR_B, ADDR_C, ADDR_B],
      pairs: [ADDR_PAIR, ADDR_PAIR, ADDR_PAIR],
    })).rejects.toThrow('Final token cannot appear earlier');
  });

  it('passes amountOut and amountInMax to the contract unchanged', async () => {
    // The contract handles fee gross-up on-chain; SDK passes user's
    // POST-FEE desired amount_out as-is.
    const { router, contract } = makeRouter({ feeBips: 0 });
    await router.swapExactOut(validOpts());
    const callArgs = contract.methods.swap_exact_out_multi_hop.mock.calls[0];
    expect(callArgs[3]).toBe(100n); // amount_out
    expect(callArgs[4]).toBe(200n); // amount_in_max
  });

  it('passes amountOut unchanged when fee is active (contract grosses up internally)', async () => {
    const { router, contract } = makeRouter({
      feeBips: 50,
      feeRecipient: ADDR_FEE_RECIPIENT.toString(),
    });
    await router.swapExactOut(validOpts());
    const callArgs = contract.methods.swap_exact_out_multi_hop.mock.calls[0];
    expect(callArgs[3]).toBe(100n);
  });

  it('injects fee recipient and fee bips from config', async () => {
    const { router, contract } = makeRouter({
      feeBips: 50,
      feeRecipient: ADDR_FEE_RECIPIENT.toString(),
    });
    await router.swapExactOut(validOpts());
    const callArgs = contract.methods.swap_exact_out_multi_hop.mock.calls[0];
    expect(callArgs[7]).toEqual(ADDR_FEE_RECIPIENT); // fee_recipient
    expect(callArgs[8]).toBe(50);                    // fee_bips
  });

  it('creates authwit on token_in with router as caller', async () => {
    const { router, wallet } = makeRouter();
    await router.swapExactOut(validOpts());
    const authwitCall = vi.mocked(wallet.createAuthWit).mock.calls[0];
    expect(authwitCall[0]).toBe(ADDR_SENDER);
    expect(authwitCall[1]).toHaveProperty('caller', ADDR_ROUTER);
  });

  it('pads path and pairs to fixed lengths', async () => {
    const { router, contract } = makeRouter();
    await router.swapExactOut(validOpts());
    const callArgs = contract.methods.swap_exact_out_multi_hop.mock.calls[0];
    expect(callArgs[0]).toHaveLength(4); // MAX_HOPS + 1
    expect(callArgs[1]).toHaveLength(3); // MAX_HOPS
    expect(callArgs[2]).toBe(3);         // path_length
  });

  it('throws when feeBips exceeds the 5% cap', async () => {
    const { router } = makeRouter({ feeBips: 501, feeRecipient: ADDR_FEE_RECIPIENT.toString() });
    await expect(router.swapExactOut(validOpts())).rejects.toThrow('feeBips must be <= 500');
  });

  it('throws on zero amountOut', async () => {
    const { router } = makeRouter();
    await expect(router.swapExactOut({ ...validOpts(), amountOut: 0n }))
      .rejects.toThrow('amountOut must be positive');
  });

  it('throws on zero amountInMax', async () => {
    const { router } = makeRouter();
    await expect(router.swapExactOut({ ...validOpts(), amountInMax: 0n }))
      .rejects.toThrow('amountInMax must be positive');
  });
});

// ================================================================
// addLiquidity
// ================================================================

describe('addLiquidity', () => {
  const validOpts = () => ({
    pair: ADDR_PAIR,
    amount0Max: 100n, amount1Max: 200n,
    amount0Min: 90n, amount1Min: 180n,
    deadline: futureDeadline(),
  });

  it('throws when pair is zero', async () => {
    const { router } = makeRouter();
    await expect(router.addLiquidity({ ...validOpts(), pair: ADDR_ZERO }))
      .rejects.toThrow('pair address cannot be zero');
  });

  it('throws when amount0Min > amount0Max', async () => {
    const { router } = makeRouter();
    await expect(router.addLiquidity({ ...validOpts(), amount0Min: 200n, amount0Max: 100n }))
      .rejects.toThrow('amount0Min must be <= amount0Max');
  });

  it('auto-fetches pair config and creates two authwits', async () => {
    const { router, wallet } = makeRouter();
    await router.addLiquidity(validOpts());
    expect(SigalSwapPairContract.at).toHaveBeenCalledWith(ADDR_PAIR, expect.anything());
    expect(wallet.createAuthWit).toHaveBeenCalledTimes(2);
  });

  it('caches pair config and verification across calls', async () => {
    const { router } = makeRouter();
    const callsBefore = vi.mocked(SigalSwapPairContract.at).mock.calls.length;
    await router.addLiquidity(validOpts());
    await router.addLiquidity(validOpts());
    // First addLiquidity opens the pair contract ONCE: `assertPairVerified`
    // reads the config for the factory cross-check and seeds `pairConfigCache`
    // with it, so the subsequent `fetchPairConfig` is a cache hit rather than a
    // second `get_config` round-trip. The second addLiquidity hits both caches
    // (verified + config), adding zero new `.at()` calls.
    expect(vi.mocked(SigalSwapPairContract.at).mock.calls.length - callsBefore).toBe(1);
  });

  it('throws when amount1Min > amount1Max', async () => {
    const { router } = makeRouter();
    await expect(router.addLiquidity({ ...validOpts(), amount1Min: 300n, amount1Max: 200n }))
      .rejects.toThrow('amount1Min must be <= amount1Max');
  });

  it('throws when amount0Max is 0', async () => {
    const { router } = makeRouter();
    await expect(router.addLiquidity({ ...validOpts(), amount0Max: 0n }))
      .rejects.toThrow('amount0Max must be positive');
  });

  it('throws when amount1Max is 0', async () => {
    const { router } = makeRouter();
    await expect(router.addLiquidity({ ...validOpts(), amount1Max: 0n }))
      .rejects.toThrow('amount1Max must be positive');
  });

  it('accepts amount0Min = 0 (zero slippage tolerance is valid)', async () => {
    const { router } = makeRouter();
    await router.addLiquidity({ ...validOpts(), amount0Min: 0n });
  });

  it('accepts amount1Min = 0 (zero slippage tolerance is valid)', async () => {
    const { router } = makeRouter();
    await router.addLiquidity({ ...validOpts(), amount1Min: 0n });
  });

  it('accepts amount0Min == amount0Max (boundary: exact-amount deposit)', async () => {
    const { router } = makeRouter();
    await router.addLiquidity({ ...validOpts(), amount0Min: 100n, amount0Max: 100n });
  });

  it('throws when amount0Min is negative', async () => {
    const { router } = makeRouter();
    await expect(router.addLiquidity({ ...validOpts(), amount0Min: -1n }))
      .rejects.toThrow('amount0Min cannot be negative');
  });

  it('throws when amount1Min is negative', async () => {
    const { router } = makeRouter();
    await expect(router.addLiquidity({ ...validOpts(), amount1Min: -1n }))
      .rejects.toThrow('amount1Min cannot be negative');
  });

  it('accepts amount1Min == amount1Max (boundary: exact-amount deposit)', async () => {
    const { router } = makeRouter();
    await router.addLiquidity({ ...validOpts(), amount1Min: 200n, amount1Max: 200n });
  });

  it('passes token addresses from pair config to contract', async () => {
    const { router, contract } = makeRouter();
    await router.addLiquidity(validOpts());
    const callArgs = contract.methods.add_liquidity.mock.calls[0];
    // Contract signature: add_liquidity(pair, token0, token1, lpToken, ...)
    // callArgs[0] = pair, callArgs[1] = token0, callArgs[2] = token1, callArgs[3] = lpToken
    expect(callArgs[1]).toBe(ADDR_A); // token0 from DEFAULT_PAIR_CONFIG
    expect(callArgs[2]).toBe(ADDR_B); // token1 from DEFAULT_PAIR_CONFIG
  });

  // V2-router pattern: tokens flow user -> router -> pair (not user -> pair direct).
  // The authwit's `recipient` field MUST be the router so the router can hold
  // the user's amount_max in its own public balance, compute optimal at tx time,
  // and forward only the optimal to the pair. If this regresses to recipient=pair,
  // pre-existing pair-side donations leak as part of the user's "refund" through
  // the pair's old refund logic -- the H1 vector this fix closed.
  it('authwit recipient is the router, not the pair', async () => {
    const { router, tokenMock } = makeRouter();
    await router.addLiquidity(validOpts());
    // First call: token0; second call: token1
    const t0Args = tokenMock.methods.transfer_to_public_and_prepare_private_balance_increase.mock.calls[0];
    const t1Args = tokenMock.methods.transfer_to_public_and_prepare_private_balance_increase.mock.calls[1];
    // Method signature: (sender, recipient, amount, nonce)
    expect(t0Args[1]).toEqual(ADDR_ROUTER);
    expect(t1Args[1]).toEqual(ADDR_ROUTER);
    // And specifically NOT the pair address
    expect(t0Args[1]).not.toEqual(ADDR_PAIR);
    expect(t1Args[1]).not.toEqual(ADDR_PAIR);
  });
});

// ================================================================
// removeLiquidity
// ================================================================

describe('removeLiquidity', () => {
  const validOpts = () => ({
    pair: ADDR_PAIR,
    liquidity: 100n,
    amount0Min: 50n, amount1Min: 50n,
    deadline: futureDeadline(),
  });

  it('throws when pair is zero', async () => {
    const { router } = makeRouter();
    await expect(router.removeLiquidity({ ...validOpts(), pair: ADDR_ZERO }))
      .rejects.toThrow('pair address cannot be zero');
  });

  it('throws when liquidity is 0', async () => {
    const { router } = makeRouter();
    await expect(router.removeLiquidity({ ...validOpts(), liquidity: 0n }))
      .rejects.toThrow('liquidity must be positive');
  });

  it('throws when amount0Min is negative', async () => {
    const { router } = makeRouter();
    await expect(router.removeLiquidity({ ...validOpts(), amount0Min: -1n }))
      .rejects.toThrow('amount0Min cannot be negative');
  });

  it('accepts amount0Min = 0 (zero slippage tolerance is valid)', async () => {
    const { router } = makeRouter();
    await router.removeLiquidity({ ...validOpts(), amount0Min: 0n });
  });

  it('accepts amount1Min = 0 (zero slippage tolerance is valid)', async () => {
    const { router } = makeRouter();
    await router.removeLiquidity({ ...validOpts(), amount1Min: 0n });
  });

  it('throws when amount1Min is negative', async () => {
    const { router } = makeRouter();
    await expect(router.removeLiquidity({ ...validOpts(), amount1Min: -1n }))
      .rejects.toThrow('amount1Min cannot be negative');
  });

  it('auto-fetches LP token from pair config', async () => {
    const { router, tokenMock } = makeRouter();
    await router.removeLiquidity(validOpts());
    // TokenContract.at should be called with the LP token address from DEFAULT_PAIR_CONFIG[2]
    expect(TokenContract.at).toHaveBeenCalled();
    expect(tokenMock.methods.transfer_to_public).toHaveBeenCalled();
  });
});

describe("skimTo", () => {
  it("rejects zero recipient with SigalSwapValidationError before any contract call", async () => {
    const { SigalSwapValidationError } = await import("./errors.js");
    const { router, contract } = makeRouter();
    await expect(router.skimTo(ADDR_A, ADDR_ZERO))
      .rejects.toBeInstanceOf(SigalSwapValidationError);
    // Asserting on the exact message (not just the error class) ensures the
    // recipient-zero check fires here, not a downstream balance/etc check
    // that also throws SigalSwapValidationError. Without this specificity
    // the rejection would pass even if the recipient guard were skipped.
    await expect(router.skimTo(ADDR_A, ADDR_ZERO))
      .rejects.toThrow(/recipient cannot be the zero address/);
    // Crucially: skim_to was never called -- preflight blocked it.
    expect(contract.methods.skim_to).not.toHaveBeenCalled();
  });

  it("rejects with SigalSwapValidationError when router holds zero balance of the token", async () => {
    const { SigalSwapValidationError } = await import("./errors.js");
    const { router, contract, tokenMock } = makeRouter();
    // Default tokenMock returns 0n on balance_of_public; the off-chain
    // pre-check fires before any on-chain call.
    tokenMock.methods.balance_of_public.mockReturnValueOnce(mockInteraction(0n));
    await expect(router.skimTo(ADDR_A, ADDR_SENDER))
      .rejects.toBeInstanceOf(SigalSwapValidationError);
    expect(contract.methods.skim_to).not.toHaveBeenCalled();
  });

  it("forwards (token, recipient) to the contract on the happy path", async () => {
    const { router, contract, tokenMock } = makeRouter();
    tokenMock.methods.balance_of_public.mockReturnValueOnce(mockInteraction(42n));
    await router.skimTo(ADDR_A, ADDR_SENDER);
    expect(contract.methods.skim_to).toHaveBeenCalledWith(ADDR_A, ADDR_SENDER);
  });

  it("wraps a contract revert as SigalSwapContractRevertError with extracted reason", async () => {
    const { SigalSwapContractRevertError } = await import("./errors.js");
    const { router, contract, tokenMock } = makeRouter();
    // Non-zero balance so the off-chain pre-check passes; the on-chain
    // call still reverts because someone else skimmed between sim and send.
    tokenMock.methods.balance_of_public.mockReturnValue(mockInteraction(42n));
    const interaction = mockInteraction();
    interaction.send = vi.fn().mockRejectedValueOnce(
      new Error("Public execution reverted: NO_BALANCE\n  at frame"),
    );
    contract.methods.skim_to.mockReturnValueOnce(interaction);

    await expect(router.skimTo(ADDR_A, ADDR_SENDER))
      .rejects.toBeInstanceOf(SigalSwapContractRevertError);
    contract.methods.skim_to.mockReturnValueOnce(interaction);
    interaction.send = vi.fn().mockRejectedValueOnce(
      new Error("Public execution reverted: NO_BALANCE\n  at frame"),
    );
    await expect(router.skimTo(ADDR_A, ADDR_SENDER))
      .rejects.toMatchObject({ revertReason: "NO_BALANCE", context: "router.skim_to" });
  });
});

describe('getFactory', () => {
  it("returns the factory address the router was constructed against", async () => {
    const { router, contract } = makeRouter();
    contract.methods.get_factory.mockReturnValue(mockInteraction(ADDR_FACTORY));
    expect(await router.getFactory()).toBe(ADDR_FACTORY);
    expect(contract.methods.get_factory).toHaveBeenCalled();
  });
});

// ================================================================
// Pair verification (assertPairVerified) — drift probes
//
// Every fund-moving entry calls `assertPairVerified` before authwit
// construction. The covered surfaces:
//   - swapSingleExactIn / swapSingleExactOut
//   - swapExactIn / swapExactOut (multi-hop)
//   - addLiquidity / removeLiquidity
// These tests exercise the verification helper directly through one
// surface (swapSingleExactIn) and rely on the shared helper to cover the
// others; a failure in one method's wiring would still surface here as a
// missing assert call, since the helper is the same instance.
// ================================================================

describe('feeRecipient configuration', () => {
  it('throws SigalSwapConfigurationError when feeRecipient equals the router address', async () => {
    const { SigalSwapConfigurationError } = await import('./errors.js');
    // Bypass `makeRouter` (which uses ADDR_FEE_RECIPIENT) and construct
    // the router directly with feeRecipient aliased to the router's own
    // address. The constructor surfaces the misconfiguration before any
    // tx is built, mirroring the contract-side FEE_RECIPIENT_IS_ROUTER
    // assert. Same threat model the contract guards against, surfaced
    // off-chain so an integrator catches the typo at SDK-init.
    const config = {
      nodeUrl: 'http://localhost:8080',
      environment: 'local' as const,
      feeBips: 25,
      feeRecipient: ADDR_ROUTER.toString(),
    };
    const contract = mockRouterContract(ADDR_ROUTER);
    const wallet = mockWallet(ADDR_SENDER);
    expect(() => new SigalSwapRouter(contract as any, wallet, ADDR_SENDER, config))
      .toThrow(SigalSwapConfigurationError);
    expect(() => new SigalSwapRouter(contract as any, wallet, ADDR_SENDER, config))
      .toThrow(/cannot equal the router address/);
  });

  it('accepts feeRecipient = zero (no-fee sentinel)', async () => {
    // Sanity probe: zero is the no-interface-fee sentinel and must
    // construct cleanly even though the router's address is non-zero.
    const config = {
      nodeUrl: 'http://localhost:8080',
      environment: 'local' as const,
      feeBips: 0,
    };
    const contract = mockRouterContract(ADDR_ROUTER);
    const wallet = mockWallet(ADDR_SENDER);
    expect(() => new SigalSwapRouter(contract as any, wallet, ADDR_SENDER, config))
      .not.toThrow();
  });
});

describe('pair verification (factory cross-check)', () => {
  it('rejects an unregistered pair address before authwit construction', async () => {
    const { SigalSwapValidationError } = await import('./errors.js');
    const { router, contract, wallet } = makeRouter();
    // ADDR_D is not in the factory mock's registered set; verification
    // returns ADDR_ZERO and the assert throws.
    const unknownPair = ADDR_D;
    await expect(router.swapSingleExactIn({
      pair: unknownPair, tokenIn: ADDR_A, tokenOut: ADDR_B,
      amountIn: 100n, amountOutMin: 90n, deadline: futureDeadline(),
    })).rejects.toBeInstanceOf(SigalSwapValidationError);
    // Authwit not built and contract method not invoked: the verification
    // failure short-circuits before any of those side effects.
    expect(wallet.createAuthWit).not.toHaveBeenCalled();
    expect(contract.methods.swap_exact_in).not.toHaveBeenCalled();
  });

  it('mentions the impersonation framing in the rejection message', async () => {
    const { router } = makeRouter();
    await expect(router.swapSingleExactIn({
      pair: ADDR_D, tokenIn: ADDR_A, tokenOut: ADDR_B,
      amountIn: 100n, amountOutMin: 90n, deadline: futureDeadline(),
    })).rejects.toThrow(/not a registered SigalSwap pair|phishing/);
  });

  it('throws a configuration error when factory is not wired in', async () => {
    const config: SigalSwapConfig = {
      nodeUrl: 'http://localhost:8080', environment: 'local', feeBips: 0,
    };
    const contract = mockRouterContract(ADDR_ROUTER);
    const wallet = mockWallet(ADDR_SENDER);
    // Construct router WITHOUT a factory handle. The constructor accepts
    // null (default) but every fund-moving entry must reject clearly.
    const router = new SigalSwapRouter(contract as any, wallet, ADDR_SENDER, config);
    await expect(router.swapSingleExactIn({
      pair: ADDR_PAIR, tokenIn: ADDR_A, tokenOut: ADDR_B,
      amountIn: 100n, amountOutMin: 90n, deadline: futureDeadline(),
    })).rejects.toThrow(/factory address not configured/);
  });

  it('caches verification across calls on the same pair', async () => {
    const { router, factoryContract } = makeRouter();
    await router.swapSingleExactIn({
      pair: ADDR_PAIR, tokenIn: ADDR_A, tokenOut: ADDR_B,
      amountIn: 100n, amountOutMin: 90n, deadline: futureDeadline(),
    });
    await router.swapSingleExactIn({
      pair: ADDR_PAIR, tokenIn: ADDR_A, tokenOut: ADDR_B,
      amountIn: 200n, amountOutMin: 180n, deadline: futureDeadline(),
    });
    // First call hits the factory once; second call is a cache hit.
    expect(factoryContract.methods.get_pair_versioned).toHaveBeenCalledTimes(1);
  });

  it('verifies every pair in a multi-hop swap', async () => {
    const { router, factoryContract } = makeRouter();
    await router.swapExactIn({
      path: [ADDR_A, ADDR_B, ADDR_C],
      pairs: [ADDR_PAIR, ADDR_PAIR_BC],
      amountIn: 100n, amountOutMin: 90n, deadline: futureDeadline(),
    });
    expect(factoryContract.methods.get_pair_versioned).toHaveBeenCalledTimes(2);
  });

  it('rejects a multi-hop swap when any pair is unregistered', async () => {
    const { SigalSwapValidationError } = await import('./errors.js');
    const { router, contract } = makeRouter();
    await expect(router.swapExactIn({
      path: [ADDR_A, ADDR_B, ADDR_C],
      pairs: [ADDR_PAIR, ADDR_D], // ADDR_D is not registered
      amountIn: 100n, amountOutMin: 90n, deadline: futureDeadline(),
    })).rejects.toBeInstanceOf(SigalSwapValidationError);
    expect(contract.methods.swap_exact_in_multi_hop).not.toHaveBeenCalled();
  });
});
