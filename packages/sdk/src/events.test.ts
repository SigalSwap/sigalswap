import { describe, it, expect } from 'vitest';
import { SigalSwapEvents } from './events.js';

describe('SigalSwapEvents', () => {
  // ================================================================
  // Pair events (16 total: 12 public + 4 private)
  // ================================================================

  describe('pair', () => {
    const pair = SigalSwapEvents.pair;

    it('exposes all 16 pair events', () => {
      const names = Object.keys(pair);
      expect(names).toHaveLength(16);
      expect(names).toContain('SwapEvent');
      expect(names).toContain('SwapPublicEvent');
      expect(names).toContain('MintEvent');
      expect(names).toContain('MintPublicEvent');
      expect(names).toContain('BurnEvent');
      expect(names).toContain('BurnPublicEvent');
      expect(names).toContain('SyncEvent');
      expect(names).toContain('FlashSwapEvent');
      expect(names).toContain('ProtocolFeeMintedEvent');
      expect(names).toContain('ProtocolFeeConfigChangedEvent');
      expect(names).toContain('PairPausedEvent');
      expect(names).toContain('PairUnpausedEvent');
      expect(names).toContain('PrivateSwapExactInEvent');
      expect(names).toContain('PrivateSwapExactOutEvent');
      expect(names).toContain('PrivateMintEvent');
      expect(names).toContain('PrivateBurnEvent');
    });

    it('PairPausedEvent and PairUnpausedEvent are empty (pair address implicit)', () => {
      // Pair-side pause events carry no fields -- the emitter address (the
      // pair) IS the pair identity. Distinct from the factory's same-named
      // events which carry `pair: AztecAddress` because the factory emits
      // about multiple pairs.
      expect(pair.PairPausedEvent.fieldNames).toEqual([]);
      expect(pair.PairUnpausedEvent.fieldNames).toEqual([]);
    });

    it('each event has eventSelector, abiType, and fieldNames', () => {
      for (const [name, meta] of Object.entries(pair)) {
        expect(meta, `${name} missing eventSelector`).toHaveProperty('eventSelector');
        expect(meta, `${name} missing abiType`).toHaveProperty('abiType');
        expect(meta, `${name} missing fieldNames`).toHaveProperty('fieldNames');
        expect(Array.isArray((meta as any).fieldNames), `${name} fieldNames is not array`).toBe(true);
      }
    });

    it('SwapEvent has correct fields', () => {
      expect(pair.SwapEvent.fieldNames).toEqual(['token_in', 'token_out', 'amount_in', 'amount_out']);
    });

    it('SwapPublicEvent includes sender and recipient', () => {
      expect(pair.SwapPublicEvent.fieldNames).toEqual([
        'sender', 'token_in', 'token_out', 'amount_in', 'amount_out', 'recipient',
      ]);
    });

    it('MintEvent has correct fields', () => {
      expect(pair.MintEvent.fieldNames).toEqual(['amount0', 'amount1', 'liquidity']);
    });

    it('MintPublicEvent includes sender', () => {
      expect(pair.MintPublicEvent.fieldNames).toEqual([
        'sender', 'amount0', 'amount1', 'liquidity',
      ]);
    });

    it('BurnEvent has correct fields', () => {
      expect(pair.BurnEvent.fieldNames).toEqual(['amount0', 'amount1', 'liquidity']);
    });

    it('BurnPublicEvent includes sender and recipient', () => {
      expect(pair.BurnPublicEvent.fieldNames).toEqual([
        'sender', 'amount0', 'amount1', 'liquidity', 'recipient',
      ]);
    });

    it('ProtocolFeeConfigChangedEvent has correct fields', () => {
      expect(pair.ProtocolFeeConfigChangedEvent.fieldNames).toEqual([
        'fee_to', 'percent', 'active',
      ]);
    });

    it('SyncEvent has reserve0 and reserve1', () => {
      expect(pair.SyncEvent.fieldNames).toEqual(['reserve0', 'reserve1']);
    });

    it('FlashSwapEvent has correct fields', () => {
      expect(pair.FlashSwapEvent.fieldNames).toEqual(['borrower', 'amount0_in', 'amount1_in', 'amount0_out', 'amount1_out']);
    });

    it('ProtocolFeeMintedEvent has correct fields', () => {
      expect(pair.ProtocolFeeMintedEvent.fieldNames).toEqual(['fee_to', 'amount']);
    });

    it('PrivateSwapExactInEvent has correct fields', () => {
      expect(pair.PrivateSwapExactInEvent.fieldNames).toEqual([
        'token_in', 'token_out', 'amount_in', 'amount_out_min',
      ]);
    });

    it('PrivateSwapExactOutEvent has correct fields', () => {
      expect(pair.PrivateSwapExactOutEvent.fieldNames).toEqual([
        'token_in', 'token_out', 'amount_in_max', 'amount_out',
      ]);
    });

    it('PrivateMintEvent has correct fields', () => {
      expect(pair.PrivateMintEvent.fieldNames).toEqual([
        'token0', 'token1', 'amount0_max', 'amount1_max',
      ]);
    });

    it('PrivateBurnEvent has correct fields', () => {
      expect(pair.PrivateBurnEvent.fieldNames).toEqual(['token0', 'token1', 'liquidity']);
    });
  });

  // ================================================================
  // Router events (5 total: 4 private + 1 public)
  // ================================================================

  describe('router', () => {
    const router = SigalSwapEvents.router;

    it('exposes all 5 router events', () => {
      const names = Object.keys(router);
      expect(names).toHaveLength(5);
      expect(names).toContain('RouterSwapExactInEvent');
      expect(names).toContain('RouterSwapExactOutEvent');
      expect(names).toContain('RouterMintEvent');
      expect(names).toContain('RouterBurnEvent');
      expect(names).toContain('RouterSkimEvent');
    });

    it('RouterSwapExactInEvent matches PrivateSwapExactInEvent fields', () => {
      expect(router.RouterSwapExactInEvent.fieldNames).toEqual([
        'token_in', 'token_out', 'amount_in', 'amount_out_min',
      ]);
    });

    it('RouterSwapExactOutEvent matches PrivateSwapExactOutEvent fields', () => {
      expect(router.RouterSwapExactOutEvent.fieldNames).toEqual([
        'token_in', 'token_out', 'amount_in_max', 'amount_out',
      ]);
    });

    it('RouterMintEvent matches PrivateMintEvent fields', () => {
      expect(router.RouterMintEvent.fieldNames).toEqual([
        'token0', 'token1', 'amount0_max', 'amount1_max',
      ]);
    });

    it('RouterBurnEvent matches PrivateBurnEvent fields', () => {
      expect(router.RouterBurnEvent.fieldNames).toEqual(['token0', 'token1', 'liquidity']);
    });

    it('RouterSkimEvent has token / recipient / amount fields', () => {
      expect(router.RouterSkimEvent.fieldNames).toEqual(['token', 'recipient', 'amount']);
    });
  });

  // ================================================================
  // LP Token events (1 private: LPTransfer, encrypted to recipient)
  // ================================================================

  describe('lpToken', () => {
    const lpToken = SigalSwapEvents.lpToken;

    it('exposes the LPTransfer event', () => {
      const names = Object.keys(lpToken);
      expect(names).toHaveLength(1);
      expect(names).toContain('LPTransfer');
    });

    it('LPTransfer has from / to / amount fields', () => {
      // Distinct from Aztec Token's `Transfer` event -- the LP Token uses
      // a different name to avoid selector collision when both contracts
      // are imported by the same consumer.
      expect(lpToken.LPTransfer.fieldNames).toEqual(['from', 'to', 'amount']);
    });

    it('LPTransfer has valid metadata', () => {
      expect(lpToken.LPTransfer).toHaveProperty('eventSelector');
      expect(lpToken.LPTransfer).toHaveProperty('abiType');
      expect(lpToken.LPTransfer).toHaveProperty('fieldNames');
    });
  });

  // ================================================================
  // Factory events (17 public)
  // ================================================================

  describe('factory', () => {
    const factory = SigalSwapEvents.factory;

    it('exposes all 17 factory events', () => {
      const names = Object.keys(factory);
      expect(names).toHaveLength(17);
      expect(names).toContain('PairCreatedEvent');
      expect(names).toContain('PairSlotClearedEvent');
      expect(names).toContain('RegistrationPausedEvent');
      expect(names).toContain('RegistrationUnpausedEvent');
      expect(names).toContain('PairPausedEvent');
      expect(names).toContain('PairUnpausedEvent');
      expect(names).toContain('ProtocolFeeSyncedEvent');
      expect(names).toContain('ActionQueuedEvent');
      expect(names).toContain('ActionExecutedEvent');
      expect(names).toContain('ActionCancelledEvent');
      expect(names).toContain('AdminChangedEvent');
      expect(names).toContain('FeeToChangedEvent');
      expect(names).toContain('FeeTierAddedEvent');
      expect(names).toContain('FeeTierRemovedEvent');
      expect(names).toContain('ProtocolFeePercentChangedEvent');
      expect(names).toContain('ProtocolFeeEnabledChangedEvent');
      expect(names).toContain('PairClassIdChangedEvent');
    });

    it('PairCreatedEvent has correct fields', () => {
      expect(factory.PairCreatedEvent.fieldNames).toEqual([
        'token0', 'token1', 'pair', 'lp_token', 'fee_tier_bps', 'version', 'pair_count',
      ]);
    });

    it('ActionQueuedEvent has correct fields', () => {
      expect(factory.ActionQueuedEvent.fieldNames).toEqual([
        'action_type', 'value', 'execute_after',
      ]);
    });

    it('ActionCancelledEvent has correct fields', () => {
      expect(factory.ActionCancelledEvent.fieldNames).toEqual([
        'action_type', 'value',
      ]);
    });

    it('ActionExecutedEvent has correct fields', () => {
      expect(factory.ActionExecutedEvent.fieldNames).toEqual([
        'action_type', 'value',
      ]);
    });

    it('AdminChangedEvent has correct fields', () => {
      expect(factory.AdminChangedEvent.fieldNames).toEqual(['new_admin']);
    });

    it('FeeToChangedEvent has correct fields', () => {
      expect(factory.FeeToChangedEvent.fieldNames).toEqual(['new_fee_to']);
    });

    it('FeeTierAddedEvent has correct fields', () => {
      expect(factory.FeeTierAddedEvent.fieldNames).toEqual(['tier_bps']);
    });

    it('FeeTierRemovedEvent has correct fields', () => {
      expect(factory.FeeTierRemovedEvent.fieldNames).toEqual(['tier_bps']);
    });

    it('ProtocolFeePercentChangedEvent has correct fields', () => {
      expect(factory.ProtocolFeePercentChangedEvent.fieldNames).toEqual(['new_percent']);
    });

    it('ProtocolFeeEnabledChangedEvent has correct fields', () => {
      expect(factory.ProtocolFeeEnabledChangedEvent.fieldNames).toEqual(['enabled']);
    });

    it('PairClassIdChangedEvent has correct fields', () => {
      expect(factory.PairClassIdChangedEvent.fieldNames).toEqual(['class_id', 'version']);
    });

    it('ProtocolFeeSyncedEvent has correct fields', () => {
      expect(factory.ProtocolFeeSyncedEvent.fieldNames).toEqual(['pair']);
    });

    it('PairSlotClearedEvent has correct fields', () => {
      // Plaintext base identity (token0, token1, fee_tier_bps) so indexers
      // don't need a global base_key lookup table; new_latest_pair carries
      // the rolled-back-to address (zero on full clear).
      expect(factory.PairSlotClearedEvent.fieldNames).toEqual([
        'pair', 'token0', 'token1', 'fee_tier_bps',
        'cleared_version', 'new_latest_version', 'new_latest_pair',
      ]);
    });

    it('RegistrationPausedEvent and RegistrationUnpausedEvent are field-less', () => {
      expect(factory.RegistrationPausedEvent.fieldNames).toEqual([]);
      expect(factory.RegistrationUnpausedEvent.fieldNames).toEqual([]);
    });

    it('PairPausedEvent and PairUnpausedEvent carry the pair address', () => {
      expect(factory.PairPausedEvent.fieldNames).toEqual(['pair']);
      expect(factory.PairUnpausedEvent.fieldNames).toEqual(['pair']);
    });

    it('all factory events have valid metadata', () => {
      for (const [name, meta] of Object.entries(factory)) {
        expect(meta, `${name} missing eventSelector`).toHaveProperty('eventSelector');
        expect(meta, `${name} missing abiType`).toHaveProperty('abiType');
        expect(meta, `${name} missing fieldNames`).toHaveProperty('fieldNames');
      }
    });
  });

  // ================================================================
  // Field-type drift canary
  // ================================================================
  //
  // The Aztec ABI decoder returns `bigint` for any field whose ABI kind is
  // `integer` or `field` (verified at @aztec/stdlib/dest/abi/decoder.js).
  // Our `events.ts` interfaces declare these fields as `bigint` to match.
  // If a contract-side type ever changes from u32 to a struct (or any
  // non-integer kind), the SDK interface becomes wrong and the runtime
  // shape diverges silently. These assertions trip when that happens, so
  // the type interface gets updated in lock-step.
  //
  // Adding a new u32/Field to a contract event? Add it here too.
  describe('integer/Field event fields decode as bigint (drift canary)', () => {
    function fieldKindOf(meta: { abiType: any }, fieldName: string): string {
      const f = meta.abiType.fields.find((x: any) => x.name === fieldName);
      if (!f) throw new Error(`field ${fieldName} not found on event abi`);
      return f.type.kind;
    }

    function expectIntegerOrField(meta: { abiType: any }, fieldName: string) {
      const kind = fieldKindOf(meta, fieldName);
      expect(['integer', 'field'], `${fieldName} must decode as bigint (kind=integer|field, got ${kind})`).toContain(kind);
    }

    it('pair.ProtocolFeeConfigChangedEvent.percent decodes as bigint', () => {
      expectIntegerOrField(SigalSwapEvents.pair.ProtocolFeeConfigChangedEvent, 'percent');
    });

    it('factory.PairCreatedEvent u32 fields decode as bigint', () => {
      const meta = SigalSwapEvents.factory.PairCreatedEvent;
      expectIntegerOrField(meta, 'fee_tier_bps');
      expectIntegerOrField(meta, 'version');
      expectIntegerOrField(meta, 'pair_count');
    });

    it('factory.PairSlotClearedEvent u32 fields decode as bigint', () => {
      const meta = SigalSwapEvents.factory.PairSlotClearedEvent;
      expectIntegerOrField(meta, 'fee_tier_bps');
      expectIntegerOrField(meta, 'cleared_version');
      expectIntegerOrField(meta, 'new_latest_version');
    });

    it('factory.FeeTierAddedEvent.tier_bps decodes as bigint', () => {
      expectIntegerOrField(SigalSwapEvents.factory.FeeTierAddedEvent, 'tier_bps');
    });

    it('factory.FeeTierRemovedEvent.tier_bps decodes as bigint', () => {
      expectIntegerOrField(SigalSwapEvents.factory.FeeTierRemovedEvent, 'tier_bps');
    });

    it('factory.ProtocolFeePercentChangedEvent.new_percent decodes as bigint', () => {
      expectIntegerOrField(SigalSwapEvents.factory.ProtocolFeePercentChangedEvent, 'new_percent');
    });

    it('factory.PairClassIdChangedEvent.version decodes as bigint', () => {
      expectIntegerOrField(SigalSwapEvents.factory.PairClassIdChangedEvent, 'version');
    });

    // -- Pair u128 amount fields --

    it('pair.SwapEvent u128 fields decode as bigint', () => {
      const meta = SigalSwapEvents.pair.SwapEvent;
      expectIntegerOrField(meta, 'amount_in');
      expectIntegerOrField(meta, 'amount_out');
    });

    it('pair.SwapPublicEvent u128 fields decode as bigint', () => {
      const meta = SigalSwapEvents.pair.SwapPublicEvent;
      expectIntegerOrField(meta, 'amount_in');
      expectIntegerOrField(meta, 'amount_out');
    });

    it('pair.MintEvent u128 fields decode as bigint', () => {
      const meta = SigalSwapEvents.pair.MintEvent;
      expectIntegerOrField(meta, 'amount0');
      expectIntegerOrField(meta, 'amount1');
      expectIntegerOrField(meta, 'liquidity');
    });

    it('pair.MintPublicEvent u128 fields decode as bigint', () => {
      const meta = SigalSwapEvents.pair.MintPublicEvent;
      expectIntegerOrField(meta, 'amount0');
      expectIntegerOrField(meta, 'amount1');
      expectIntegerOrField(meta, 'liquidity');
    });

    it('pair.BurnEvent u128 fields decode as bigint', () => {
      const meta = SigalSwapEvents.pair.BurnEvent;
      expectIntegerOrField(meta, 'amount0');
      expectIntegerOrField(meta, 'amount1');
      expectIntegerOrField(meta, 'liquidity');
    });

    it('pair.BurnPublicEvent u128 fields decode as bigint', () => {
      const meta = SigalSwapEvents.pair.BurnPublicEvent;
      expectIntegerOrField(meta, 'amount0');
      expectIntegerOrField(meta, 'amount1');
      expectIntegerOrField(meta, 'liquidity');
    });

    it('pair.SyncEvent u128 fields decode as bigint', () => {
      const meta = SigalSwapEvents.pair.SyncEvent;
      expectIntegerOrField(meta, 'reserve0');
      expectIntegerOrField(meta, 'reserve1');
    });

    it('pair.FlashSwapEvent u128 fields decode as bigint', () => {
      const meta = SigalSwapEvents.pair.FlashSwapEvent;
      expectIntegerOrField(meta, 'amount0_in');
      expectIntegerOrField(meta, 'amount1_in');
      expectIntegerOrField(meta, 'amount0_out');
      expectIntegerOrField(meta, 'amount1_out');
    });

    it('pair.ProtocolFeeMintedEvent.amount decodes as bigint', () => {
      expectIntegerOrField(SigalSwapEvents.pair.ProtocolFeeMintedEvent, 'amount');
    });

    it('pair.PrivateSwapExactInEvent u128 fields decode as bigint', () => {
      const meta = SigalSwapEvents.pair.PrivateSwapExactInEvent;
      expectIntegerOrField(meta, 'amount_in');
      expectIntegerOrField(meta, 'amount_out_min');
    });

    it('pair.PrivateSwapExactOutEvent u128 fields decode as bigint', () => {
      const meta = SigalSwapEvents.pair.PrivateSwapExactOutEvent;
      expectIntegerOrField(meta, 'amount_in_max');
      expectIntegerOrField(meta, 'amount_out');
    });

    it('pair.PrivateMintEvent u128 fields decode as bigint', () => {
      const meta = SigalSwapEvents.pair.PrivateMintEvent;
      expectIntegerOrField(meta, 'amount0_max');
      expectIntegerOrField(meta, 'amount1_max');
    });

    it('pair.PrivateBurnEvent.liquidity decodes as bigint', () => {
      expectIntegerOrField(SigalSwapEvents.pair.PrivateBurnEvent, 'liquidity');
    });

    // -- Router u128 amount fields --

    it('router.RouterSwapExactInEvent u128 fields decode as bigint', () => {
      const meta = SigalSwapEvents.router.RouterSwapExactInEvent;
      expectIntegerOrField(meta, 'amount_in');
      expectIntegerOrField(meta, 'amount_out_min');
    });

    it('router.RouterSwapExactOutEvent u128 fields decode as bigint', () => {
      const meta = SigalSwapEvents.router.RouterSwapExactOutEvent;
      expectIntegerOrField(meta, 'amount_in_max');
      expectIntegerOrField(meta, 'amount_out');
    });

    it('router.RouterMintEvent u128 fields decode as bigint', () => {
      const meta = SigalSwapEvents.router.RouterMintEvent;
      expectIntegerOrField(meta, 'amount0_max');
      expectIntegerOrField(meta, 'amount1_max');
    });

    it('router.RouterBurnEvent.liquidity decodes as bigint', () => {
      expectIntegerOrField(SigalSwapEvents.router.RouterBurnEvent, 'liquidity');
    });

    it('router.RouterSkimEvent.amount decodes as bigint', () => {
      expectIntegerOrField(SigalSwapEvents.router.RouterSkimEvent, 'amount');
    });

    // -- Factory action / class id Field & integer fields --

    it('factory.ActionQueuedEvent fields decode as bigint', () => {
      const meta = SigalSwapEvents.factory.ActionQueuedEvent;
      expectIntegerOrField(meta, 'action_type');
      expectIntegerOrField(meta, 'value');
      expectIntegerOrField(meta, 'execute_after');
    });

    it('factory.ActionExecutedEvent fields decode as bigint', () => {
      const meta = SigalSwapEvents.factory.ActionExecutedEvent;
      expectIntegerOrField(meta, 'action_type');
      expectIntegerOrField(meta, 'value');
    });

    it('factory.ActionCancelledEvent fields decode as bigint', () => {
      const meta = SigalSwapEvents.factory.ActionCancelledEvent;
      expectIntegerOrField(meta, 'action_type');
      expectIntegerOrField(meta, 'value');
    });

    it('factory.PairClassIdChangedEvent.class_id decodes as bigint', () => {
      expectIntegerOrField(SigalSwapEvents.factory.PairClassIdChangedEvent, 'class_id');
    });

    // -- LP Token --

    it('lpToken.LPTransfer.amount decodes as bigint', () => {
      expectIntegerOrField(SigalSwapEvents.lpToken.LPTransfer, 'amount');
    });
  });

  // ================================================================
  // Meta-canary: every integer/field on every event has a drift line
  // ================================================================
  //
  // A reviewer can forget to add an `expectIntegerOrField` call when a new
  // u128/Field/u64 field is added to an event interface. This meta-test
  // closes that loop: walk every event across all four namespaces, find
  // each `integer`/`field` ABI field, and assert there's a corresponding
  // canary line in this file. If a new field lands in the contract +
  // events.ts but the canary is missing, this trips.
  describe('meta-canary: every integer/Field has a drift assertion', () => {
    function collectIntegerFields(): { namespace: string; eventName: string; fieldName: string }[] {
      const out: { namespace: string; eventName: string; fieldName: string }[] = [];
      for (const [ns, eventBag] of Object.entries(SigalSwapEvents)) {
        for (const [eventName, meta] of Object.entries(eventBag)) {
          const abiFields = (meta as any).abiType?.fields ?? [];
          for (const f of abiFields) {
            const kind = f.type?.kind;
            if (kind === 'integer' || kind === 'field') {
              out.push({ namespace: ns, eventName, fieldName: f.name });
            }
          }
        }
      }
      return out;
    }

    it('every integer/field field has an expectIntegerOrField call in this file', async () => {
      const fs = await import('node:fs');
      const path = await import('node:path');
      const url = await import('node:url');
      const __dirname = path.dirname(url.fileURLToPath(import.meta.url));
      const source = fs.readFileSync(path.resolve(__dirname, 'events.test.ts'), 'utf-8');

      // Match `expectIntegerOrField(<expr>, '<field>')` -- the <expr> can
      // be either `SigalSwapEvents.<ns>.<event>` directly OR `meta` (with
      // a preceding `const meta = SigalSwapEvents.<ns>.<event>`). Build
      // (namespace.eventName.fieldName) keys for every match, accounting
      // for the per-it `meta` aliasing pattern.
      const directRe = /expectIntegerOrField\(\s*SigalSwapEvents\.(\w+)\.(\w+)\s*,\s*['"](\w+)['"]/g;
      const metaAliasRe = /const meta = SigalSwapEvents\.(\w+)\.(\w+);[\s\S]*?(?=\n\s*it\(|\n\s*\/\/ --|\n  \}\);)/g;
      const metaFieldRe = /expectIntegerOrField\(\s*meta\s*,\s*['"](\w+)['"]/g;

      const covered = new Set<string>();
      for (const m of source.matchAll(directRe)) {
        covered.add(`${m[1]}.${m[2]}.${m[3]}`);
      }
      for (const block of source.matchAll(metaAliasRe)) {
        const ns = block[1];
        const ev = block[2];
        const blockText = block[0];
        for (const fm of blockText.matchAll(metaFieldRe)) {
          covered.add(`${ns}.${ev}.${fm[1]}`);
        }
      }

      const required = collectIntegerFields();
      const missing = required.filter(
        (r) => !covered.has(`${r.namespace}.${r.eventName}.${r.fieldName}`),
      );
      expect(
        missing,
        missing.length === 0
          ? 'all covered'
          : `missing canary lines for: ${missing
              .map((m) => `SigalSwapEvents.${m.namespace}.${m.eventName}.${m.fieldName}`)
              .join(', ')}`,
      ).toEqual([]);
    });
  });
});
