import { describe, it, expect, vi, beforeEach } from 'vitest';
import { AztecAddress } from '@aztec/aztec.js/addresses';
import { Fr } from '@aztec/aztec.js/fields';
import { FunctionSelector } from '@aztec/aztec.js/abi';
import { SigalSwapPair } from './pair.js';
import { ADDR_A, ADDR_B, ADDR_PAIR, ADDR_SENDER, ADDR_LP_TOKEN, ADDR_FACTORY } from './__test__/addresses.js';
import { mockPairContract, mockWallet, mockInteraction, mockTokenContract, DEFAULT_PAIR_CONFIG } from './__test__/mocks.js';

// Mock artifact modules so the real JSON/WASM isn't loaded
vi.mock('./artifacts/SigalSwapPair.js', () => ({
  SigalSwapPairContract: { at: vi.fn() },
}));
vi.mock('./artifacts/SigalSwapLPToken.js', () => ({
  SigalSwapLPTokenContract: { at: vi.fn() },
}));
vi.mock('./artifacts/Token.js', () => ({
  TokenContract: { at: vi.fn() },
}));

import { TokenContract } from './artifacts/Token.js';
import { SigalSwapLPTokenContract } from './artifacts/SigalSwapLPToken.js';

const LOCAL_CONFIG = { nodeUrl: 'http://localhost:8080', environment: 'local' as const, feeBips: 0 };

describe('SigalSwapPair', () => {
  let pair: SigalSwapPair;
  let contract: ReturnType<typeof mockPairContract>;
  let wallet: ReturnType<typeof mockWallet>;
  let tokenMock: ReturnType<typeof mockTokenContract>;

  beforeEach(() => {
    contract = mockPairContract(ADDR_PAIR);
    wallet = mockWallet(ADDR_SENDER);
    tokenMock = mockTokenContract();
    vi.mocked(TokenContract.at).mockReturnValue(tokenMock as any);

    // LP Token mock for the new getLpBalance / getLpTotalSupply / getMyPositionValue methods.
    const lpTokenMock = {
      address: ADDR_LP_TOKEN,
      methods: {
        balance_of_private: vi.fn().mockReturnValue(mockInteraction(700n)),
        balance_of_public: vi.fn().mockReturnValue(mockInteraction(0n)),
        total_supply: vi.fn().mockReturnValue(mockInteraction(10000n)),
      },
    };
    vi.mocked(SigalSwapLPTokenContract.at).mockReturnValue(lpTokenMock as any);

    pair = new SigalSwapPair(contract as any, wallet, ADDR_SENDER, LOCAL_CONFIG);
  });

  // ================================================================
  // Query result mapping
  // ================================================================

  describe('query methods', () => {
    it('getReserves maps tuple correctly', async () => {
      contract.methods.get_reserves.mockReturnValue(mockInteraction([100n, 200n, 300n]));
      expect(await pair.getReserves()).toEqual({
        reserve0: 100n, reserve1: 200n, blockTimestampLast: 300n,
      });
    });

    it('getPairState maps tuple correctly', async () => {
      contract.methods.get_pair_state.mockReturnValue(
        mockInteraction([100n, 200n, 300n, true, 20n, false]),
      );
      const state = await pair.getPairState();
      expect(state).toEqual({
        reserve0: 100n, reserve1: 200n, blockTimestampLast: 300n,
        isPaused: true, protocolFeePercent: 20, protocolFeeActive: false,
      });
    });

    it('getCumulativePrices maps 5-tuple', async () => {
      contract.methods.get_cumulative_prices.mockReturnValue(
        mockInteraction([1n, 2n, 3n, 4n, 5n]),
      );
      expect(await pair.getCumulativePrices()).toEqual({
        price0CumulInt: 1n, price0CumulFrac: 2n,
        price1CumulInt: 3n, price1CumulFrac: 4n,
        blockTimestampLast: 5n,
      });
    });

    it('getSpotPrices maps 4-tuple', async () => {
      contract.methods.get_spot_prices.mockReturnValue(mockInteraction([10n, 20n, 30n, 40n]));
      expect(await pair.getSpotPrices()).toEqual({
        price0Num: 10n, price0Den: 20n, price1Num: 30n, price1Den: 40n,
      });
    });

    it('getPositionValue maps 2-tuple', async () => {
      contract.methods.get_position_value.mockReturnValue(mockInteraction([50n, 100n]));
      expect(await pair.getPositionValue(10n, 1000n)).toEqual({ amount0: 50n, amount1: 100n });
    });

    it('address returns contract address', () => {
      expect(pair.address).toBe(ADDR_PAIR);
    });
  });

  // ================================================================
  // getConfig caching
  // ================================================================

  describe('getConfig', () => {
    it('queries contract on first call', async () => {
      const config = await pair.getConfig();
      expect(config.token0).toBe(ADDR_A);
      expect(config.token1).toBe(ADDR_B);
      expect(config.lpToken).toBe(ADDR_LP_TOKEN);
      expect(config.version).toBe(1n);
      expect(contract.methods.get_config).toHaveBeenCalledOnce();
    });

    it('returns cached result on second call', async () => {
      await pair.getConfig();
      await pair.getConfig();
      expect(contract.methods.get_config).toHaveBeenCalledOnce();
    });
  });

  describe('getVersion', () => {
    it('returns the version as a number', async () => {
      contract.methods.get_version.mockReturnValue(mockInteraction(1n));
      expect(await pair.getVersion()).toBe(1);
    });
  });

  // ================================================================
  // swapExactIn validation
  // ================================================================

  describe('swapExactIn', () => {
    const validOpts = { tokenIn: ADDR_A, tokenOut: ADDR_B, amountIn: 100n, amountOutMin: 90n };

    it('throws when amountIn is 0', async () => {
      await expect(pair.swapExactIn({ ...validOpts, amountIn: 0n })).rejects.toThrow('amountIn must be positive');
    });

    it('throws when amountOutMin is negative', async () => {
      await expect(pair.swapExactIn({ ...validOpts, amountOutMin: -1n })).rejects.toThrow('amountOutMin cannot be negative');
    });

    it('accepts amountOutMin = 0 (zero is valid: any output amount accepted)', async () => {
      await expect(pair.swapExactIn({ ...validOpts, amountOutMin: 0n })).resolves.toBeDefined();
    });

    it('throws when tokenIn equals tokenOut', async () => {
      await expect(pair.swapExactIn({ ...validOpts, tokenIn: ADDR_A, tokenOut: ADDR_A })).rejects.toThrow('tokenIn and tokenOut must differ');
    });

    it('creates authwit with transfer_to_public and sends', async () => {
      await pair.swapExactIn(validOpts);
      expect(tokenMock.methods.transfer_to_public).toHaveBeenCalled();
      expect(wallet.createAuthWit).toHaveBeenCalled();
      expect(contract.methods.swap_exact_in).toHaveBeenCalled();
    });
  });

  // ================================================================
  // swapExactOut validation
  // ================================================================

  describe('swapExactOut', () => {
    const validOpts = { tokenIn: ADDR_A, tokenOut: ADDR_B, amountOut: 100n, amountInMax: 110n };

    it('throws when amountOut is 0', async () => {
      await expect(pair.swapExactOut({ ...validOpts, amountOut: 0n })).rejects.toThrow('amountOut must be positive');
    });

    it('throws when amountInMax is 0', async () => {
      await expect(pair.swapExactOut({ ...validOpts, amountInMax: 0n })).rejects.toThrow('amountInMax must be positive');
    });

    it('throws when tokenIn equals tokenOut', async () => {
      await expect(pair.swapExactOut({ ...validOpts, tokenIn: ADDR_A, tokenOut: ADDR_A })).rejects.toThrow('tokenIn and tokenOut must differ');
    });

    it('creates authwit with transfer_to_public_and_prepare_private_balance_increase', async () => {
      await pair.swapExactOut(validOpts);
      expect(tokenMock.methods.transfer_to_public_and_prepare_private_balance_increase).toHaveBeenCalled();
    });
  });

  // ================================================================
  // addLiquidity validation
  // ================================================================

  describe('addLiquidity', () => {
    const validOpts = { amount0Max: 100n, amount1Max: 200n, amount0Min: 90n, amount1Min: 180n };

    it('throws when amount0Max is 0', async () => {
      await expect(pair.addLiquidity({ ...validOpts, amount0Max: 0n })).rejects.toThrow('amount0Max must be positive');
    });

    it('throws when amount1Max is 0', async () => {
      await expect(pair.addLiquidity({ ...validOpts, amount1Max: 0n })).rejects.toThrow('amount1Max must be positive');
    });

    it('throws when amount0Min is negative', async () => {
      await expect(pair.addLiquidity({ ...validOpts, amount0Min: -1n })).rejects.toThrow('amount0Min cannot be negative');
    });

    it('throws when amount1Min is negative', async () => {
      await expect(pair.addLiquidity({ ...validOpts, amount1Min: -1n })).rejects.toThrow('amount1Min cannot be negative');
    });

    it('throws when amount0Min > amount0Max', async () => {
      await expect(pair.addLiquidity({ ...validOpts, amount0Min: 200n, amount0Max: 100n })).rejects.toThrow('amount0Min must be <= amount0Max');
    });

    it('throws when amount1Min > amount1Max', async () => {
      await expect(pair.addLiquidity({ ...validOpts, amount1Min: 300n, amount1Max: 200n })).rejects.toThrow('amount1Min must be <= amount1Max');
    });

    it('accepts amount0Min = 0 (zero slippage tolerance is valid)', async () => {
      await expect(pair.addLiquidity({ ...validOpts, amount0Min: 0n })).resolves.toBeDefined();
    });

    it('accepts amount1Min = 0 (zero slippage tolerance is valid)', async () => {
      await expect(pair.addLiquidity({ ...validOpts, amount1Min: 0n })).resolves.toBeDefined();
    });

    it('accepts amount0Min == amount0Max (boundary: exact-amount deposit)', async () => {
      await expect(pair.addLiquidity({ ...validOpts, amount0Min: 100n, amount0Max: 100n })).resolves.toBeDefined();
    });

    it('accepts amount1Min == amount1Max (boundary: exact-amount deposit)', async () => {
      await expect(pair.addLiquidity({ ...validOpts, amount1Min: 200n, amount1Max: 200n })).resolves.toBeDefined();
    });

    it('throws when pair reports token0 == token1', async () => {
      const badConfig = { token0: ADDR_A, token1: ADDR_A, factory: ADDR_FACTORY, fee_tier_bps: 25n, version: 1n, lp_token: ADDR_LP_TOKEN };
      contract.methods.get_config.mockReturnValue(mockInteraction(badConfig));
      // Reset cached config by creating a new pair
      const badPair = new SigalSwapPair(contract as any, wallet, ADDR_SENDER, LOCAL_CONFIG);
      await expect(badPair.addLiquidity(validOpts)).rejects.toThrow('identical token0 and token1');
    });

    it('creates two authwits for token0 and token1', async () => {
      await pair.addLiquidity(validOpts);
      expect(wallet.createAuthWit).toHaveBeenCalledTimes(2);
      expect(contract.methods.add_liquidity).toHaveBeenCalled();
    });
  });

  // ================================================================
  // removeLiquidity validation
  // ================================================================

  describe('removeLiquidity', () => {
    const validOpts = { liquidity: 100n, amount0Min: 50n, amount1Min: 50n };

    it('throws when liquidity is 0', async () => {
      await expect(pair.removeLiquidity({ ...validOpts, liquidity: 0n })).rejects.toThrow('liquidity must be positive');
    });

    it('throws when amount0Min is negative', async () => {
      await expect(pair.removeLiquidity({ ...validOpts, amount0Min: -1n })).rejects.toThrow('amount0Min cannot be negative');
    });

    it('throws when amount1Min is negative', async () => {
      await expect(pair.removeLiquidity({ ...validOpts, amount1Min: -1n })).rejects.toThrow('amount1Min cannot be negative');
    });

    it('accepts amount0Min = 0 (zero slippage tolerance is valid)', async () => {
      await expect(pair.removeLiquidity({ ...validOpts, amount0Min: 0n })).resolves.toBeDefined();
    });

    it('accepts amount1Min = 0 (zero slippage tolerance is valid)', async () => {
      await expect(pair.removeLiquidity({ ...validOpts, amount1Min: 0n })).resolves.toBeDefined();
    });

    it('creates authwit for LP token with transfer_to_public', async () => {
      await pair.removeLiquidity(validOpts);
      expect(tokenMock.methods.transfer_to_public).toHaveBeenCalled();
      expect(wallet.createAuthWit).toHaveBeenCalledOnce();
    });
  });

  // ================================================================
  // skim and sync
  // ================================================================

  describe('skim and sync', () => {
    it('skim calls contract with target address', async () => {
      await pair.skim(ADDR_A);
      expect(contract.methods.skim).toHaveBeenCalledWith(ADDR_A);
    });

    it('skim rejects the zero address', async () => {
      await expect(pair.skim(AztecAddress.zero())).rejects.toThrow(/zero/i);
    });

    it('sync calls contract with no args', async () => {
      await pair.sync();
      expect(contract.methods.sync).toHaveBeenCalled();
    });
  });

  // ================================================================
  // V3-callback public swaps + flash_swap
  // ================================================================

  describe('public-callback swaps and flash_swap', () => {
    const callbackContract = AztecAddress.fromBigInt(0xcafe0001n);
    const callbackSelector = FunctionSelector.fromField(new Fr(0xdeadn));

    it('swapExactInPublic forwards args to swap_exact_in_public', async () => {
      await pair.swapExactInPublic({
        tokenIn: ADDR_A, tokenOut: ADDR_B,
        amountIn: 1000n, amountOutMin: 900n,
        recipient: ADDR_SENDER,
        callbackContract, callbackSelector,
      });
      expect(contract.methods.swap_exact_in_public).toHaveBeenCalledWith(
        ADDR_A, ADDR_B, 1000n, 900n, ADDR_SENDER, callbackContract, callbackSelector,
      );
    });

    it('swapExactOutPublic forwards args', async () => {
      await pair.swapExactOutPublic({
        tokenIn: ADDR_A, tokenOut: ADDR_B,
        amountOut: 100n, amountInMax: 200n,
        recipient: ADDR_SENDER,
        callbackContract, callbackSelector,
      });
      expect(contract.methods.swap_exact_out_public).toHaveBeenCalledWith(
        ADDR_A, ADDR_B, 100n, 200n, ADDR_SENDER, callbackContract, callbackSelector,
      );
    });

    it('swapExactInPublic throws when amountIn is 0', async () => {
      await expect(pair.swapExactInPublic({
        tokenIn: ADDR_A, tokenOut: ADDR_B,
        amountIn: 0n, amountOutMin: 0n,
        recipient: ADDR_SENDER,
        callbackContract, callbackSelector,
      })).rejects.toThrow('amountIn must be positive');
    });

    it('swapExactInPublic accepts amountOutMin = 0', async () => {
      await expect(pair.swapExactInPublic({
        tokenIn: ADDR_A, tokenOut: ADDR_B,
        amountIn: 1000n, amountOutMin: 0n,
        recipient: ADDR_SENDER,
        callbackContract, callbackSelector,
      })).resolves.toBeDefined();
    });

    it('swapExactInPublic throws when amountOutMin is negative', async () => {
      await expect(pair.swapExactInPublic({
        tokenIn: ADDR_A, tokenOut: ADDR_B,
        amountIn: 1000n, amountOutMin: -1n,
        recipient: ADDR_SENDER,
        callbackContract, callbackSelector,
      })).rejects.toThrow('amountOutMin cannot be negative');
    });

    it('swapExactInPublic throws when tokenIn equals tokenOut', async () => {
      await expect(pair.swapExactInPublic({
        tokenIn: ADDR_A, tokenOut: ADDR_A,
        amountIn: 1000n, amountOutMin: 0n,
        recipient: ADDR_SENDER,
        callbackContract, callbackSelector,
      })).rejects.toThrow('tokenIn and tokenOut must differ');
    });

    it('swapExactOutPublic throws when tokenIn equals tokenOut', async () => {
      await expect(pair.swapExactOutPublic({
        tokenIn: ADDR_A, tokenOut: ADDR_A,
        amountOut: 100n, amountInMax: 200n,
        recipient: ADDR_SENDER,
        callbackContract, callbackSelector,
      })).rejects.toThrow('tokenIn and tokenOut must differ');
    });

    it('flashSwap accepts amount0Out=0, amount1Out=positive (single-sided flash, token1 only)', async () => {
      // Exercises the OTHER side of the
      // `amount0Out === 0n && amount1Out === 0n` guard (amount0Out=0,
      // amount1Out positive); the sibling test covers amount1Out=0.
      const data = new Fr(0xfeen);
      await pair.flashSwap({
        amount0Out: 0n, amount1Out: 500n,
        borrower: ADDR_SENDER,
        callbackSelector, data,
      });
      expect(contract.methods.flash_swap).toHaveBeenCalledWith(
        0n, 500n, ADDR_SENDER, callbackSelector, data,
      );
    });

    it('flashSwap throws when amount0Out is negative', async () => {
      const data = new Fr(0xfeen);
      await expect(pair.flashSwap({
        amount0Out: -1n, amount1Out: 0n,
        borrower: ADDR_SENDER,
        callbackSelector, data,
      })).rejects.toThrow('amount0Out cannot be negative');
    });

    it('flashSwap throws when amount1Out is negative', async () => {
      const data = new Fr(0xfeen);
      await expect(pair.flashSwap({
        amount0Out: 100n, amount1Out: -1n,
        borrower: ADDR_SENDER,
        callbackSelector, data,
      })).rejects.toThrow('amount1Out cannot be negative');
    });

    it('swapExactOutPublic throws when amountOut is 0', async () => {
      await expect(pair.swapExactOutPublic({
        tokenIn: ADDR_A, tokenOut: ADDR_B,
        amountOut: 0n, amountInMax: 100n,
        recipient: ADDR_SENDER,
        callbackContract, callbackSelector,
      })).rejects.toThrow('amountOut must be positive');
    });

    it('swapExactOutPublic throws when amountInMax is 0', async () => {
      await expect(pair.swapExactOutPublic({
        tokenIn: ADDR_A, tokenOut: ADDR_B,
        amountOut: 100n, amountInMax: 0n,
        recipient: ADDR_SENDER,
        callbackContract, callbackSelector,
      })).rejects.toThrow('amountInMax must be positive');
    });

    it('flashSwap forwards args to flash_swap', async () => {
      const data = new Fr(0xfeen);
      await pair.flashSwap({
        amount0Out: 500n, amount1Out: 0n,
        borrower: ADDR_SENDER,
        callbackSelector, data,
      });
      expect(contract.methods.flash_swap).toHaveBeenCalledWith(
        500n, 0n, ADDR_SENDER, callbackSelector, data,
      );
    });

    it('flashSwap rejects when both output amounts are zero', async () => {
      await expect(pair.flashSwap({
        amount0Out: 0n, amount1Out: 0n,
        borrower: ADDR_SENDER,
        callbackSelector, data: new Fr(0n),
      })).rejects.toThrow(/at least one of amount0Out/);
    });

    it('flashSwap rejects zero borrower', async () => {
      await expect(pair.flashSwap({
        amount0Out: 100n, amount1Out: 0n,
        borrower: AztecAddress.zero(),
        callbackSelector, data: new Fr(0n),
      })).rejects.toThrow(/borrower/);
    });

    // Callback / borrower / recipient blocklist coverage.
    //
    // The contract enforces an identical 6-element blocklist (zero, self,
    // token0, token1, lp_token, factory) across three roles:
    //   - `INVALID_CALLBACK_TARGET` on swap_exact_{in,out}_public
    //   - `INVALID_BORROWER` on flash_swap
    //   - `INVALID_RECIPIENT` on swap_exact_{in,out}_public
    // The SDK mirrors all three through a single `assertCallbackTargetValid`
    // helper. Iterating the same blocklist for every role keeps the SDK in
    // lockstep with the contract — a future contract-side blocklist
    // expansion that misses the SDK side would surface here as a
    // canary-pass-but-still-fails-on-chain mismatch.

    for (const [label, addr] of [
      ['self (pair)', ADDR_PAIR] as const,
      ['token0', ADDR_A] as const,
      ['token1', ADDR_B] as const,
      ['lp_token', ADDR_LP_TOKEN] as const,
      ['factory', ADDR_FACTORY] as const,
    ]) {
      it(`swapExactInPublic rejects callbackContract = ${label}`, async () => {
        await expect(pair.swapExactInPublic({
          tokenIn: ADDR_A, tokenOut: ADDR_B,
          amountIn: 1000n, amountOutMin: 900n,
          recipient: ADDR_SENDER,
          callbackContract: addr, callbackSelector,
        })).rejects.toThrow(/callbackContract/);
      });

      it(`swapExactOutPublic rejects callbackContract = ${label}`, async () => {
        await expect(pair.swapExactOutPublic({
          tokenIn: ADDR_A, tokenOut: ADDR_B,
          amountOut: 100n, amountInMax: 200n,
          recipient: ADDR_SENDER,
          callbackContract: addr, callbackSelector,
        })).rejects.toThrow(/callbackContract/);
      });

      it(`flashSwap rejects borrower = ${label}`, async () => {
        await expect(pair.flashSwap({
          amount0Out: 100n, amount1Out: 0n,
          borrower: addr,
          callbackSelector, data: new Fr(0n),
        })).rejects.toThrow(/borrower/);
      });

      it(`swapExactInPublic rejects recipient = ${label}`, async () => {
        await expect(pair.swapExactInPublic({
          tokenIn: ADDR_A, tokenOut: ADDR_B,
          amountIn: 1000n, amountOutMin: 900n,
          recipient: addr,
          callbackContract: AztecAddress.fromBigInt(0xc0de0001n),
          callbackSelector,
        })).rejects.toThrow(/recipient/);
      });

      it(`swapExactOutPublic rejects recipient = ${label}`, async () => {
        await expect(pair.swapExactOutPublic({
          tokenIn: ADDR_A, tokenOut: ADDR_B,
          amountOut: 100n, amountInMax: 200n,
          recipient: addr,
          callbackContract: AztecAddress.fromBigInt(0xc0de0001n),
          callbackSelector,
        })).rejects.toThrow(/recipient/);
      });
    }

    // Zero is the 6th blocklist element; covered separately so the error
    // string is asserted explicitly (the helper's zero branch fires first).
    it('swapExactInPublic rejects recipient = zero', async () => {
      await expect(pair.swapExactInPublic({
        tokenIn: ADDR_A, tokenOut: ADDR_B,
        amountIn: 1000n, amountOutMin: 900n,
        recipient: AztecAddress.zero(),
        callbackContract: AztecAddress.fromBigInt(0xc0de0001n), callbackSelector,
      })).rejects.toThrow(/recipient/);
    });

    it('swapExactOutPublic rejects recipient = zero', async () => {
      await expect(pair.swapExactOutPublic({
        tokenIn: ADDR_A, tokenOut: ADDR_B,
        amountOut: 100n, amountInMax: 200n,
        recipient: AztecAddress.zero(),
        callbackContract: AztecAddress.fromBigInt(0xc0de0001n), callbackSelector,
      })).rejects.toThrow(/recipient/);
    });
  });

  // ================================================================
  // Q6: pair/token consistency boundary asserts
  // ================================================================

  describe('pair/token consistency', () => {
    const ADDR_OTHER = AztecAddress.fromBigInt(0xfeed0001n);

    it('swapExactIn rejects mismatched tokenIn', async () => {
      await expect(pair.swapExactIn({
        tokenIn: ADDR_OTHER, tokenOut: ADDR_B,
        amountIn: 1000n, amountOutMin: 900n,
      })).rejects.toThrow(/do not match/);
    });

    it('swapExactOut rejects mismatched tokenOut', async () => {
      await expect(pair.swapExactOut({
        tokenIn: ADDR_A, tokenOut: ADDR_OTHER,
        amountOut: 100n, amountInMax: 200n,
      })).rejects.toThrow(/do not match/);
    });

    it('swapExactInPublic rejects mismatched pair tokens', async () => {
      await expect(pair.swapExactInPublic({
        tokenIn: ADDR_OTHER, tokenOut: ADDR_B,
        amountIn: 1000n, amountOutMin: 900n,
        recipient: ADDR_SENDER,
        callbackContract: AztecAddress.fromBigInt(0xc0de0001n),
        callbackSelector: FunctionSelector.fromField(new Fr(0xdeadn)),
      })).rejects.toThrow(/do not match/);
    });

    it('rejects partial-match where only tokenIn equals token1 (matchesReverse must require BOTH)', async () => {
      // Pair config is (A, B). Call with tokenIn=B (matches token1), tokenOut=OTHER (matches neither).
      // matchesForward = A==B && B==OTHER → false.
      // matchesReverse with `&&` = A==OTHER && B==B → false (correctly throws).
      // matchesReverse with `||` would = A==OTHER || B==B → true (incorrectly accepts).
      // The throw confirms the check uses `&&`.
      await expect(pair.swapExactIn({
        tokenIn: ADDR_B, tokenOut: ADDR_OTHER,
        amountIn: 1000n, amountOutMin: 900n,
      })).rejects.toThrow(/do not match/);
    });

    it('rejects partial-match where only tokenOut equals token0 (matchesReverse must require BOTH)', async () => {
      // Pair config is (A, B). Call with tokenIn=OTHER, tokenOut=A.
      // matchesForward = A==OTHER && B==A → false.
      // matchesReverse with `&&` = A==A && B==OTHER → false (correctly throws).
      // matchesReverse with `||` would = A==A || B==OTHER → true (incorrectly accepts).
      await expect(pair.swapExactIn({
        tokenIn: ADDR_OTHER, tokenOut: ADDR_A,
        amountIn: 1000n, amountOutMin: 900n,
      })).rejects.toThrow(/do not match/);
    });

    it('accepts tokens in either order (token0=B, token1=A)', async () => {
      // Reversed order is a valid pair pairing -- the helper accepts
      // (tokenIn=B, tokenOut=A) the same as (tokenIn=A, tokenOut=B).
      await expect(pair.swapExactIn({
        tokenIn: ADDR_B, tokenOut: ADDR_A,
        amountIn: 1000n, amountOutMin: 900n,
      })).resolves.toBeDefined();
    });
  });

  // ================================================================
  // LP balance helpers
  // ================================================================

  describe('LP balance helpers', () => {
    it('getLpBalance returns private and public balances in parallel', async () => {
      const result = await pair.getLpBalance();
      expect(result).toEqual({ private: 700n, public: 0n });
    });

    it('getLpTotalSupply returns the LP total supply', async () => {
      const result = await pair.getLpTotalSupply();
      expect(result).toBe(10000n);
    });

    it('caches the LP token wrapper across multiple LP-touching calls', async () => {
      // First LP-touching call resolves the LP token via SigalSwapLPTokenContract.at.
      // Subsequent calls must reuse the cached wrapper without re-resolving.
      // If the cache check is elided (always re-resolve), .at() gets called
      // multiple times.
      const callsBefore = vi.mocked(SigalSwapLPTokenContract.at).mock.calls.length;
      await pair.getLpBalance();
      await pair.getLpTotalSupply();
      await pair.getMyPositionValue();
      const newCalls = vi.mocked(SigalSwapLPTokenContract.at).mock.calls.length - callsBefore;
      // First call resolves; subsequent calls use cache → exactly 1 new resolution.
      expect(newCalls).toBe(1);
    });

    it('getMyPositionValue computes share against current pair balances', async () => {
      // 700 / 10000 LP * (balance0=20000, balance1=20000) -> (1400, 1400)
      tokenMock.methods.balance_of_public.mockReturnValue(mockInteraction(20000n));
      const result = await pair.getMyPositionValue();
      expect(result).toEqual({ amount0: 1400n, amount1: 1400n });
    });

    it('getMyPositionValue sums private and public LP balances (not difference)', async () => {
      // Default mock has balance.private=700, balance.public=0; the sum and
      // difference are identical. Override to put balance in BOTH so the
      // formula `private + public` produces a different result than `private - public`.
      // private=400, public=300 -> sum=700, diff=100.
      const splitLpMock = {
        address: ADDR_LP_TOKEN,
        methods: {
          balance_of_private: vi.fn().mockReturnValue(mockInteraction(400n)),
          balance_of_public: vi.fn().mockReturnValue(mockInteraction(300n)),
          total_supply: vi.fn().mockReturnValue(mockInteraction(10000n)),
        },
      };
      vi.mocked(SigalSwapLPTokenContract.at).mockReturnValueOnce(splitLpMock as any);
      const freshPair = new SigalSwapPair(contract as any, wallet, ADDR_SENDER, LOCAL_CONFIG);
      tokenMock.methods.balance_of_public.mockReturnValue(mockInteraction(20000n));
      const result = await freshPair.getMyPositionValue();
      // sum=700, 700/10000 * 20000 = 1400. diff=100, 100/10000 * 20000 = 200.
      expect(result).toEqual({ amount0: 1400n, amount1: 1400n });
    });

    it('getMyPositionValue returns zero when user has no LP', async () => {
      // Override LP balance mock for this test only
      const zeroLpMock = {
        address: ADDR_LP_TOKEN,
        methods: {
          balance_of_private: vi.fn().mockReturnValue(mockInteraction(0n)),
          balance_of_public: vi.fn().mockReturnValue(mockInteraction(0n)),
          total_supply: vi.fn().mockReturnValue(mockInteraction(10000n)),
        },
      };
      vi.mocked(SigalSwapLPTokenContract.at).mockReturnValueOnce(zeroLpMock as any);
      const freshPair = new SigalSwapPair(contract as any, wallet, ADDR_SENDER, LOCAL_CONFIG);
      tokenMock.methods.balance_of_public.mockReturnValue(mockInteraction(20000n));
      const result = await freshPair.getMyPositionValue();
      expect(result).toEqual({ amount0: 0n, amount1: 0n });
    });

    it('getMyPositionValue absorbs donations into the LP claim (balance > reserve)', async () => {
      // Reserves (stored) = 20000/20000 but actual token balance is 25000/30000
      // due to donations. Burn settles against balances; the helper must
      // reflect that, not the reserve snapshot.
      tokenMock.methods.balance_of_public
        .mockReturnValueOnce(mockInteraction(25000n))   // token0 balance
        .mockReturnValueOnce(mockInteraction(30000n));  // token1 balance
      const result = await pair.getMyPositionValue();
      // 700/10000 * 25000 = 1750, 700/10000 * 30000 = 2100
      expect(result).toEqual({ amount0: 1750n, amount1: 2100n });
    });

    it('getMyPositionValue dilutes by pending protocol-fee mint', async () => {
      // Protocol fee active with K growth: previewProtocolFeeMint returns
      // a non-zero pendingFee, which inflates the divisor at burn.
      // Set up a state where compute_mint_fee returns a known value:
      //   reserves now 20000/20000 (K = 4e8), reserves_last 10000/10000
      //   (K_last = 1e8), totalSupply 10000, percent 20.
      //   sqrt(K) = 20000, sqrt(K_last) = 10000.
      //   fee = totalSupply * percent * (sqrt(K) - sqrt(K_last))
      //         / (sqrt(K) * 100 + sqrt(K_last) * percent)
      //       = 10000 * 20 * 10000 / (20000 * 100 + 10000 * 20)
      //       = 2_000_000_000 / 2_200_000 = 909
      // effectiveSupply = 10000 + 909 = 10909
      // amount0 = 700 * 20000 / 10909 = 1283 (floor)
      contract.methods.get_pair_state.mockReturnValue(
        mockInteraction([20000n, 20000n, 0n, false, 20n, true]),
      );
      contract.methods.get_reserves_last.mockReturnValue(
        mockInteraction([10000n, 10000n]),
      );
      tokenMock.methods.balance_of_public.mockReturnValue(mockInteraction(20000n));
      const result = await pair.getMyPositionValue();
      expect(result).toEqual({ amount0: 1283n, amount1: 1283n });
    });
  });

  // ================================================================
  // quote methods
  // ================================================================

  describe('quote methods', () => {
    it('quoteAmountOut passes amountIn and tokenIn', async () => {
      contract.methods.quote_amount_out.mockReturnValue(mockInteraction(500n));
      const result = await pair.quoteAmountOut(1000n, ADDR_A);
      expect(result).toBe(500n);
      expect(contract.methods.quote_amount_out).toHaveBeenCalledWith(1000n, ADDR_A);
    });

    it('quoteAmountIn passes amountOut and tokenOut', async () => {
      contract.methods.quote_amount_in.mockReturnValue(mockInteraction(600n));
      const result = await pair.quoteAmountIn(500n, ADDR_B);
      expect(result).toBe(600n);
      expect(contract.methods.quote_amount_in).toHaveBeenCalledWith(500n, ADDR_B);
    });
  });

  // ================================================================
  // Single-field view wrappers
  // ================================================================

  describe('single-field views', () => {
    it('isPaused returns the pair-side pause flag', async () => {
      contract.methods.is_paused_view.mockReturnValue(mockInteraction(true));
      expect(await pair.isPaused()).toBe(true);
    });

    it('getFeeTo returns the pair-side fee_to recipient', async () => {
      contract.methods.get_fee_to.mockReturnValue(mockInteraction(ADDR_A));
      expect(await pair.getFeeTo()).toBe(ADDR_A);
    });

    it('getReservesLast maps the (u128, u128) tuple', async () => {
      contract.methods.get_reserves_last.mockReturnValue(mockInteraction([7000n, 9000n]));
      expect(await pair.getReservesLast()).toEqual({
        reserve0Last: 7000n,
        reserve1Last: 9000n,
      });
    });
  });

  // ================================================================
  // previewProtocolFeeMint composite
  // ================================================================

  describe('previewProtocolFeeMint', () => {
    it('returns 0 when the pair-side fee is inactive', async () => {
      contract.methods.get_pair_state.mockReturnValue(
        mockInteraction([11000n, 11000n, 0n, false, 20n, false]),
      );
      contract.methods.get_reserves_last.mockReturnValue(mockInteraction([10000n, 10000n]));
      expect(await pair.previewProtocolFeeMint()).toBe(0n);
    });

    it('matches the Noir compute_mint_fee fixture when fee is active', async () => {
      // Noir: compute_mint_fee(11000, 11000, 10000, 10000, 5000, 20) == 76
      contract.methods.get_pair_state.mockReturnValue(
        mockInteraction([11000n, 11000n, 0n, false, 20n, true]),
      );
      contract.methods.get_reserves_last.mockReturnValue(mockInteraction([10000n, 10000n]));
      const lpTokenMock = {
        address: ADDR_LP_TOKEN,
        methods: {
          balance_of_private: vi.fn().mockReturnValue(mockInteraction(0n)),
          balance_of_public: vi.fn().mockReturnValue(mockInteraction(0n)),
          total_supply: vi.fn().mockReturnValue(mockInteraction(5000n)),
        },
      };
      vi.mocked(SigalSwapLPTokenContract.at).mockReturnValueOnce(lpTokenMock as any);
      const freshPair = new SigalSwapPair(contract as any, wallet, ADDR_SENDER, LOCAL_CONFIG);
      expect(await freshPair.previewProtocolFeeMint()).toBe(76n);
    });
  });
});

describe('SigalSwapPair.twapBetween', () => {
  const Q112 = 1n << 112n;
  const FIELD_MODULUS =
    21888242871839275222246405745257275088548364400416034343698204186575808495617n;

  const sample = (
    p0i: bigint, p0f: bigint, p1i: bigint, p1f: bigint, ts: bigint,
  ) => ({
    price0CumulInt: p0i, price0CumulFrac: p0f,
    price1CumulInt: p1i, price1CumulFrac: p1f,
    blockTimestampLast: ts,
  });

  it('captures a fraction-only signal that the integer-only recipe would read as zero', () => {
    // Decimal-mismatched pair: price0 ratio < 1, so the integer accumulator
    // stays 0 and the entire signal lives in the fraction. dt = 100.
    const earlier = sample(0n, 1000n, 0n, 0n, 100n);
    const later = sample(0n, 1000n + 5_000_000n, 0n, 0n, 200n);
    const r = SigalSwapPair.twapBetween(earlier, later);
    expect(r.secondsElapsed).toBe(100n);
    // (5_000_000) / 100 = 50000 in UQ112x112 units -- nonzero.
    expect(r.price0Scaled).toBe(50_000n);
    // The naive `(int2 - int1) / dt` recipe would return 0 here; the floored
    // plain ratio is also 0, but the scaled value preserves the real signal.
    expect(r.price0).toBe(0n);
  });

  it('computes a whole-number ratio for the large-price direction', () => {
    // price1 integer accumulator advances by 3000 over 100s => mean price1 = 30.
    const earlier = sample(0n, 0n, 0n, 0n, 0n);
    const later = sample(0n, 0n, 3000n, 0n, 100n);
    const r = SigalSwapPair.twapBetween(earlier, later);
    expect(r.price1Scaled).toBe(30n * Q112);
    expect(r.price1).toBe(30n);
  });

  it('reconstructs across the integer/fraction carry boundary', () => {
    // earlier just below a whole unit in the fraction; later carried into the
    // integer. The full reconstruction must net to a 15-unit scaled advance.
    const earlier = sample(5n, Q112 - 10n, 0n, 0n, 0n);
    const later = sample(6n, 5n, 0n, 0n, 1n);
    const r = SigalSwapPair.twapBetween(earlier, later);
    expect(r.price0Scaled).toBe(15n);
  });

  it('corrects for a BN254 field wrap of the integer accumulator', () => {
    // Integer accumulator wraps from (p-1) to 5: true advance is 6 units.
    const earlier = sample(FIELD_MODULUS - 1n, 0n, 0n, 0n, 0n);
    const later = sample(5n, 0n, 0n, 0n, 1n);
    const r = SigalSwapPair.twapBetween(earlier, later);
    expect(r.price0Scaled).toBe(6n * Q112);
    expect(r.price0).toBe(6n);
  });

  it('throws when the later sample is not strictly after the earlier', () => {
    const a = sample(0n, 0n, 0n, 0n, 100n);
    const b = sample(0n, 0n, 0n, 0n, 200n);
    expect(() => SigalSwapPair.twapBetween(b, a)).toThrow();
    expect(() => SigalSwapPair.twapBetween(a, a)).toThrow();
  });
});
