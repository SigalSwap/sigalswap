// SPDX-License-Identifier: MIT
// Copyright (c) 2026 SigalSwap LLC

import type { AztecAddress } from '@aztec/aztec.js/addresses';

/**
 * Base class for every error originating in the SigalSwap SDK.
 *
 * Lets integrators write `catch (err) { if (err instanceof SigalSwapError)
 * ... }` to filter SDK-side failures from unrelated Aztec / network /
 * runtime errors. Specific subclasses below tag the *category* of failure
 * so handlers don't have to pattern-match on error message text.
 *
 * The hierarchy is closed -- new failure categories should be added as new
 * subclasses, not as ad-hoc fields on the base.
 */
export class SigalSwapError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'SigalSwapError';
    // Preserve the prototype chain through the ES5 `Error` quirk (otherwise
    // `instanceof` is unreliable on TS-compiled output).
    Object.setPrototypeOf(this, new.target.prototype);
  }
}

/**
 * Caller passed an argument that fails the SDK's pre-flight input checks --
 * e.g., `amountIn <= 0`, `tokenIn == tokenOut`, deadline in the past,
 * `path.length < 2`, recipient is the zero address. The contract would
 * revert too, but the SDK fails fast off-chain so the user doesn't waste a
 * tx. Surface to end users as "invalid input" with the embedded message.
 */
export class SigalSwapValidationError extends SigalSwapError {
  constructor(message: string) {
    super(message);
    this.name = 'SigalSwapValidationError';
    Object.setPrototypeOf(this, new.target.prototype);
  }
}

/**
 * The SDK was constructed or wired up incorrectly -- e.g., `feeBips` outside
 * `[0, 500]`, `feeBips > 0` without a `feeRecipient`, factory/router
 * address missing for a flow that needs it. Distinguish from validation
 * because validation errors are user-input-driven (recoverable by re-asking
 * the user) while configuration errors are dev-driven (need a code/config
 * fix at the integration layer).
 */
export class SigalSwapConfigurationError extends SigalSwapError {
  constructor(message: string) {
    super(message);
    this.name = 'SigalSwapConfigurationError';
    Object.setPrototypeOf(this, new.target.prototype);
  }
}

/**
 * `createPair` (or a related deploy flow) failed mid-way. Carries the
 * already-deployed addresses so the caller can either retry idempotently
 * (createPair handles partial-state recovery) or surface the addresses to
 * the user for manual inspection.
 *
 * `pairAddress` / `lpTokenAddress` are the canonically-derived addresses --
 * present whenever derivation succeeded, even if the deploy step itself
 * later threw. `cause` (if set) is the underlying error from Aztec.
 */
export class SigalSwapDeploymentError extends SigalSwapError {
  readonly pairAddress?: AztecAddress;
  readonly lpTokenAddress?: AztecAddress;
  readonly cause?: unknown;

  constructor(
    message: string,
    opts: {
      pairAddress?: AztecAddress;
      lpTokenAddress?: AztecAddress;
      cause?: unknown;
    } = {},
  ) {
    super(message);
    this.name = 'SigalSwapDeploymentError';
    this.pairAddress = opts.pairAddress;
    this.lpTokenAddress = opts.lpTokenAddress;
    this.cause = opts.cause;
    Object.setPrototypeOf(this, new.target.prototype);
  }
}

/**
 * A contract call reverted on-chain. `revertReason` is the contract-side
 * assertion message (e.g., `"INSUFFICIENT_OUTPUT_AMOUNT"`) when the SDK was
 * able to extract it from Aztec's error surface; `undefined` when the
 * underlying error is unstructured.
 *
 * `cause` retains the original error for callers that want to drop down to
 * Aztec-specific diagnostics. `context` is a short SDK-side label
 * identifying which operation failed (e.g., `"router.swapExactIn"`,
 * `"factory.register_pair"`) -- useful when the same revert reason can
 * arise from multiple call sites.
 */
export class SigalSwapContractRevertError extends SigalSwapError {
  readonly revertReason?: string;
  readonly context: string;
  readonly cause?: unknown;

  constructor(
    message: string,
    opts: {
      revertReason?: string;
      context: string;
      cause?: unknown;
    },
  ) {
    super(message);
    this.name = 'SigalSwapContractRevertError';
    this.revertReason = opts.revertReason;
    this.context = opts.context;
    this.cause = opts.cause;
    Object.setPrototypeOf(this, new.target.prototype);
  }
}

/**
 * Run a contract-call promise and wrap any revert as
 * `SigalSwapContractRevertError`. Best-effort: extracts the embedded
 * assertion message from the Aztec error string when present, otherwise
 * leaves `revertReason` undefined. Always retains the original error as
 * `.cause` so callers can drop down to Aztec diagnostics.
 */
export async function wrapContractRevert<T>(
  context: string,
  fn: () => Promise<T>,
): Promise<T> {
  try {
    return await fn();
  } catch (err) {
    const reason = extractRevertReason(err);
    const reasonSuffix = reason ? `: ${reason}` : '';
    throw new SigalSwapContractRevertError(
      `${context} reverted${reasonSuffix}`,
      { revertReason: reason, context, cause: err },
    );
  }
}

/**
 * Extract a contract-side assertion message from an Aztec error. Aztec
 * surfaces revert reasons in a few shapes -- `"...Reason: <msg>..."`,
 * `"Assertion failed: <msg>"`, or simply embedded in the error message --
 * so this is a best-effort regex pass. Returns undefined when no shape
 * matches.
 */
function extractRevertReason(err: unknown): string | undefined {
  const msg = err instanceof Error ? err.message : String(err ?? '');
  // Aztec public-execution failure: 'Public execution reverted: <msg>'
  const pub = msg.match(/Public execution reverted:\s*(.+?)(?:\n|$)/);
  if (pub) return pub[1].trim();
  // Noir assertion: 'Assertion failed: <msg>'
  const ass = msg.match(/Assertion failed:\s*(.+?)(?:\n|$)/);
  if (ass) return ass[1].trim();
  // Quoted reason: '... reverted with reason: "<msg>"'
  const quoted = msg.match(/reverted with reason:\s*"([^"]+)"/);
  if (quoted) return quoted[1];
  return undefined;
}
