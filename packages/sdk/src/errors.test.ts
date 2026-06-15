import { describe, it, expect } from 'vitest';
import { AztecAddress } from '@aztec/aztec.js/addresses';
import {
  SigalSwapError,
  SigalSwapValidationError,
  SigalSwapConfigurationError,
  SigalSwapDeploymentError,
  SigalSwapContractRevertError,
  wrapContractRevert,
} from './errors.js';

describe('SigalSwap typed error hierarchy', () => {
  it('every subclass is an instanceof SigalSwapError', () => {
    expect(new SigalSwapValidationError('x')).toBeInstanceOf(SigalSwapError);
    expect(new SigalSwapConfigurationError('x')).toBeInstanceOf(SigalSwapError);
    expect(new SigalSwapDeploymentError('x')).toBeInstanceOf(SigalSwapError);
    expect(new SigalSwapContractRevertError('x', { context: 'c' })).toBeInstanceOf(SigalSwapError);
  });

  it('every subclass is also instanceof Error (Error chain preserved)', () => {
    expect(new SigalSwapValidationError('x')).toBeInstanceOf(Error);
    expect(new SigalSwapDeploymentError('x')).toBeInstanceOf(Error);
  });

  it('subclasses are distinguishable from each other (no cross-instanceof)', () => {
    const v = new SigalSwapValidationError('x');
    expect(v instanceof SigalSwapConfigurationError).toBe(false);
    expect(v instanceof SigalSwapDeploymentError).toBe(false);
    expect(v instanceof SigalSwapContractRevertError).toBe(false);
  });

  it('error.name matches the subclass for stack-trace clarity', () => {
    expect(new SigalSwapValidationError('x').name).toBe('SigalSwapValidationError');
    expect(new SigalSwapConfigurationError('x').name).toBe('SigalSwapConfigurationError');
    expect(new SigalSwapDeploymentError('x').name).toBe('SigalSwapDeploymentError');
    expect(new SigalSwapContractRevertError('x', { context: 'c' }).name).toBe('SigalSwapContractRevertError');
  });

  it('SigalSwapDeploymentError carries pairAddress / lpTokenAddress / cause', () => {
    const pairAddr = AztecAddress.fromBigInt(1n);
    const lpAddr = AztecAddress.fromBigInt(2n);
    const cause = new Error('underlying');
    const err = new SigalSwapDeploymentError('msg', {
      pairAddress: pairAddr,
      lpTokenAddress: lpAddr,
      cause,
    });
    expect(err.pairAddress).toBe(pairAddr);
    expect(err.lpTokenAddress).toBe(lpAddr);
    expect(err.cause).toBe(cause);
  });

  it('SigalSwapContractRevertError carries revertReason / context / cause', () => {
    const cause = new Error('underlying');
    const err = new SigalSwapContractRevertError('msg', {
      revertReason: 'INSUFFICIENT_OUTPUT',
      context: 'router.swapExactIn',
      cause,
    });
    expect(err.revertReason).toBe('INSUFFICIENT_OUTPUT');
    expect(err.context).toBe('router.swapExactIn');
    expect(err.cause).toBe(cause);
  });
});

describe('wrapContractRevert', () => {
  it('passes through the resolved value when the inner promise resolves', async () => {
    const result = await wrapContractRevert('test', async () => 42);
    expect(result).toBe(42);
  });

  it('extracts "Public execution reverted: <reason>" pattern', async () => {
    await expect(
      wrapContractRevert('test.op', async () => {
        throw new Error('Public execution reverted: SOME_REASON\n  at frame');
      }),
    ).rejects.toMatchObject({
      revertReason: 'SOME_REASON',
      context: 'test.op',
    });
  });

  it('extracts "Assertion failed: <reason>" pattern', async () => {
    await expect(
      wrapContractRevert('test.op', async () => {
        throw new Error('Assertion failed: ANOTHER_REASON');
      }),
    ).rejects.toMatchObject({ revertReason: 'ANOTHER_REASON' });
  });

  it('extracts quoted reason pattern', async () => {
    await expect(
      wrapContractRevert('test.op', async () => {
        throw new Error('execution reverted with reason: "QUOTED_REASON"');
      }),
    ).rejects.toMatchObject({ revertReason: 'QUOTED_REASON' });
  });

  it('leaves revertReason undefined when no pattern matches', async () => {
    await expect(
      wrapContractRevert('test.op', async () => {
        throw new Error('something completely unstructured');
      }),
    ).rejects.toMatchObject({ revertReason: undefined, context: 'test.op' });
  });

  it('retains the original error as cause', async () => {
    const cause = new Error('Public execution reverted: X');
    try {
      await wrapContractRevert('ctx', async () => { throw cause; });
    } catch (err) {
      expect((err as SigalSwapContractRevertError).cause).toBe(cause);
    }
  });
});
