import { describe, it, expect } from 'vitest';
import {
  validateConfig,
  LOCAL_CONFIG,
  TESTNET_CONFIG,
  PRODUCTION_CONFIG,
  type SigalSwapConfig,
} from './index.js';
import { ADDR_FEE_RECIPIENT } from '../__test__/addresses.js';

function validConfig(overrides: Partial<SigalSwapConfig> = {}): SigalSwapConfig {
  return { nodeUrl: 'http://localhost:8080', environment: 'local', ...overrides };
}

describe('validateConfig', () => {
  describe('nodeUrl', () => {
    it('throws when nodeUrl is empty', () => {
      expect(() => validateConfig(validConfig({ nodeUrl: '' }))).toThrow('nodeUrl is required');
    });

    it('accepts a valid nodeUrl', () => {
      expect(() => validateConfig(validConfig())).not.toThrow();
    });
  });

  describe('feeBips', () => {
    it('accepts feeBips = 0', () => {
      expect(() => validateConfig(validConfig({ feeBips: 0 }))).not.toThrow();
    });

    it('accepts feeBips at the 500 bps cap with valid recipient', () => {
      expect(() => validateConfig(validConfig({
        feeBips: 500,
        feeRecipient: ADDR_FEE_RECIPIENT.toString(),
      }))).not.toThrow();
    });

    it('throws when feeBips is negative', () => {
      expect(() => validateConfig(validConfig({ feeBips: -1 }))).toThrow('feeBips must be an integer');
    });

    it('throws when feeBips exceeds the 5% cap', () => {
      expect(() => validateConfig(validConfig({ feeBips: 501 }))).toThrow('feeBips must be an integer');
    });

    it('throws when feeBips is fractional', () => {
      expect(() => validateConfig(validConfig({ feeBips: 1.5 }))).toThrow('feeBips must be an integer');
    });
  });

  describe('feeRecipient', () => {
    it('throws when feeBips > 0 but no feeRecipient', () => {
      expect(() => validateConfig(validConfig({ feeBips: 50 }))).toThrow('requires a feeRecipient');
    });

    it('throws when feeRecipient is not a valid address', () => {
      expect(() => validateConfig(validConfig({
        feeBips: 50,
        feeRecipient: 'not-an-address',
      }))).toThrow('not a valid Aztec address');
    });

    it('accepts valid feeBips + feeRecipient', () => {
      expect(() => validateConfig(validConfig({
        feeBips: 50,
        feeRecipient: ADDR_FEE_RECIPIENT.toString(),
      }))).not.toThrow();
    });

    it('does not require feeRecipient when feeBips is 0', () => {
      expect(() => validateConfig(validConfig({ feeBips: 0 }))).not.toThrow();
    });
  });
});

describe('preset configs', () => {
  it('LOCAL_CONFIG is frozen and passes validation', () => {
    expect(Object.isFrozen(LOCAL_CONFIG)).toBe(true);
    expect(() => validateConfig(LOCAL_CONFIG)).not.toThrow();
  });

  it('TESTNET_CONFIG is frozen and fails validation (empty nodeUrl)', () => {
    expect(Object.isFrozen(TESTNET_CONFIG)).toBe(true);
    expect(() => validateConfig(TESTNET_CONFIG)).toThrow('nodeUrl is required');
  });

  it('PRODUCTION_CONFIG is frozen and fails validation (empty nodeUrl)', () => {
    expect(Object.isFrozen(PRODUCTION_CONFIG)).toBe(true);
    expect(() => validateConfig(PRODUCTION_CONFIG)).toThrow('nodeUrl is required');
  });
});
