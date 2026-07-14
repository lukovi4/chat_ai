import { describe, expect, it } from 'vitest';

import { createSmokeHooks, SmokeLedgerIdentityError, type SmokeConfig } from '../src/smoke/hooks';
import { storageSafeUid } from '../src/server/canonical';
import type { QuotaOutcome, QuotaReservation, Tier } from '../src/server/hooks';
import { asFirestore, FakeFirestore } from './fixtures/server-fakes';

// Smoke business hooks over a real Firestore transaction model (the shared
// FakeFirestore test seam; no network, no emulator). Entitlement, the
// fixed-window rate limit, and the per-UTC-day attempt quota / usage ledger —
// which follows the approved `running | terminal` schema (no `aborted`).

const UID = 'user-1';
const SEG = storageSafeUid(UID);
const CONFIG: SmokeConfig = {
  botId: 'smoke-bot',
  model: 'gpt-5',
  maxOutputTokens: 1024,
  rateMaxRequests: 2,
  rateWindowSeconds: 60,
  dailyAttemptQuota: 2,
};
const TIER: Tier = { id: CONFIG.botId, provider: 'openai', model: CONFIG.model, maxOutputTokens: CONFIG.maxOutputTokens };
const FIXED_MS = Date.UTC(2026, 6, 14, 12, 0, 0);
const DAY = new Date(FIXED_MS).toISOString().slice(0, 10);

function setup(nowMs = FIXED_MS, config = CONFIG) {
  const fake = new FakeFirestore();
  let clock = nowMs;
  const hooks = createSmokeHooks(asFirestore(fake), config, () => clock);
  return { fake, hooks, setNow: (ms: number) => (clock = ms) };
}

const createOrGet = (attemptKey: string) => ({
  kind: 'createOrGet' as const,
  uid: UID,
  attemptKey,
  botId: CONFIG.botId,
  tier: TIER,
});

const dayCount = (fake: FakeFirestore, day = DAY): number =>
  ((fake.store.get(`usage/${SEG}/quota/${day}`) as { count?: number } | undefined)?.count ?? 0);
const ledger = (fake: FakeFirestore, key: string): Record<string, unknown> =>
  fake.store.get(`usage/${SEG}/attempts/${key}`) as Record<string, unknown>;

async function reserve(hooks: ReturnType<typeof setup>['hooks'], key: string): Promise<QuotaReservation> {
  const r = await hooks.reserveQuota(createOrGet(key));
  if (r.kind !== 'reserved') throw new Error(`expected reserved, got ${r.kind}`);
  return r.reservation;
}

describe('smoke checkEntitlement', () => {
  it('allows only the configured bot and maps it to the one OpenAI tier', async () => {
    const { hooks } = setup();
    expect(await hooks.checkEntitlement(UID, 'smoke-bot')).toEqual({ kind: 'allowed', tier: TIER });
  });

  it('denies any other bot', async () => {
    const { hooks } = setup();
    expect((await hooks.checkEntitlement(UID, 'other-bot')).kind).toBe('denied');
  });
});

describe('smoke checkRateLimit — fixed window', () => {
  it('allows up to the limit, then denies with retryAfter, and resets next window', async () => {
    const { hooks, setNow } = setup();
    expect((await hooks.checkRateLimit(UID, 'smoke-bot')).kind).toBe('allowed');
    expect((await hooks.checkRateLimit(UID, 'smoke-bot')).kind).toBe('allowed');
    const denied = await hooks.checkRateLimit(UID, 'smoke-bot');
    expect(denied.kind).toBe('denied');
    if (denied.kind === 'denied') {
      expect(denied.retryAfterMs).toBeGreaterThan(0);
      expect(denied.retryAfterMs).toBeLessThanOrEqual(60_000);
    }
    setNow(FIXED_MS + 60_000);
    expect((await hooks.checkRateLimit(UID, 'smoke-bot')).kind).toBe('allowed');
  });
});

describe('smoke usage ledger — schema & new row', () => {
  it('a new ledger carries every normative field, status running, and NO aborted', async () => {
    const { fake, hooks } = setup();
    await reserve(hooks, 'k1');
    const row = ledger(fake, 'k1');
    expect(Object.keys(row).sort()).toEqual(
      [
        'attemptKey',
        'botId',
        'createdAt',
        'day',
        'inputTokens',
        'model',
        'outputTokens',
        'provider',
        'quotaOutcome',
        'reservationId',
        'status',
        'terminalAt',
        'uid',
      ].sort(),
    );
    expect(row).toMatchObject({
      uid: UID,
      attemptKey: 'k1',
      botId: CONFIG.botId,
      provider: 'openai',
      model: CONFIG.model,
      status: 'running',
      inputTokens: null,
      outputTokens: null,
      quotaOutcome: null,
      terminalAt: null,
    });
    expect('aborted' in row).toBe(false);
    expect(dayCount(fake)).toBe(1);
  });

  it('a repeat createOrGet on a running ledger is idempotent (same reservation, no counter change)', async () => {
    const { fake, hooks } = setup();
    const a = await reserve(hooks, 'k1');
    const b = await reserve(hooks, 'k1');
    expect(b).toEqual(a);
    expect(dayCount(fake)).toBe(1);
  });

  it('getExisting on a missing ledger is denied and creates nothing', async () => {
    const { fake, hooks } = setup();
    const result = await hooks.reserveQuota({ kind: 'getExisting', uid: UID, attemptKey: 'missing' });
    expect(result.kind).toBe('denied');
    expect(fake.store.size).toBe(0);
  });

  it('enforces the per-day attempt quota for new attempts', async () => {
    const { hooks } = setup();
    expect((await hooks.reserveQuota(createOrGet('k1'))).kind).toBe('reserved');
    expect((await hooks.reserveQuota(createOrGet('k2'))).kind).toBe('reserved');
    expect((await hooks.reserveQuota(createOrGet('k3'))).kind).toBe('denied');
  });
});

describe('smoke usage ledger — settlement identity & lifecycle', () => {
  it('settlement of a missing ledger throws a sanitized identity error', async () => {
    const { hooks } = setup();
    await expect(
      hooks.settleQuota({ attemptKey: 'nope', reservationId: `${SEG}.deadbeef` }, { kind: 'unbilled' }),
    ).rejects.toBeInstanceOf(SmokeLedgerIdentityError);
  });

  it('settlement with a foreign reservationId is rejected and leaves the ledger unchanged', async () => {
    const { fake, hooks } = setup();
    await reserve(hooks, 'k1');
    await expect(
      hooks.settleQuota({ attemptKey: 'k1', reservationId: `${SEG}.not-the-real-one` }, { kind: 'billed', usage: { inputTokens: 1, outputTokens: 1 } }),
    ).rejects.toBeInstanceOf(SmokeLedgerIdentityError);
    const row = ledger(fake, 'k1');
    expect(row.status).toBe('running');
    expect(row.quotaOutcome).toBeNull();
    expect(dayCount(fake)).toBe(1);
  });

  it('the identity error message leaks no uid/attemptKey/reservationId', async () => {
    const { hooks } = setup();
    try {
      await hooks.settleQuota({ attemptKey: 'k1', reservationId: `${SEG}.secret-res` }, { kind: 'unbilled' });
      throw new Error('should have thrown');
    } catch (error) {
      const message = (error as Error).message;
      expect(message).not.toContain('k1');
      expect(message).not.toContain('secret-res');
      expect(message).not.toContain(SEG);
    }
  });

  it('first settlement moves running → terminal and sets terminalAt', async () => {
    const { fake, hooks } = setup();
    const res = await reserve(hooks, 'k1');
    const createdAt = ledger(fake, 'k1').createdAt;
    await hooks.settleQuota(res, { kind: 'billed', usage: { inputTokens: 7, outputTokens: 3 } });
    const row = ledger(fake, 'k1');
    expect(row.status).toBe('terminal');
    expect(row.quotaOutcome).toBe('billed');
    expect(row.inputTokens).toBe(7);
    expect(row.outputTokens).toBe(3);
    expect(row.terminalAt).not.toBeNull();
    expect(row.createdAt).toBe(createdAt); // identity/createdAt unchanged
  });

  it('billed, estimated and unknown never release the day attempt-unit', async () => {
    const { fake, hooks } = setup(FIXED_MS, { ...CONFIG, dailyAttemptQuota: 3 });
    await hooks.settleQuota(await reserve(hooks, 'k1'), { kind: 'billed', usage: { inputTokens: 1, outputTokens: 1 } });
    await hooks.settleQuota(await reserve(hooks, 'k2'), { kind: 'estimated', usage: { inputTokens: 1, outputTokens: 1 } });
    await hooks.settleQuota(await reserve(hooks, 'k3'), { kind: 'unknown' });
    expect(dayCount(fake)).toBe(3);
  });

  it('the first terminal outcome cannot be overwritten by a later settlement', async () => {
    const { fake, hooks } = setup();
    const res = await reserve(hooks, 'k1');
    await hooks.settleQuota(res, { kind: 'billed', usage: { inputTokens: 3, outputTokens: 2 } });
    await hooks.settleQuota(res, { kind: 'unknown' }); // late, must not override
    expect(ledger(fake, 'k1').quotaOutcome).toBe('billed');
    expect(dayCount(fake)).toBe(1);
  });

  it('unbilled releases one unit; a duplicate unbilled does not release twice', async () => {
    const { fake, hooks } = setup();
    const res = await reserve(hooks, 'k1');
    expect(dayCount(fake)).toBe(1);
    await hooks.settleQuota(res, { kind: 'unbilled' });
    expect(dayCount(fake)).toBe(0);
    expect(ledger(fake, 'k1').status).toBe('terminal');
    expect(ledger(fake, 'k1').quotaOutcome).toBe('unbilled');
    await hooks.settleQuota(res, { kind: 'unbilled' });
    expect(dayCount(fake)).toBe(0); // not released twice
  });
});

describe('smoke usage ledger — terminal non-unbilled forbids re-dispatch [P1]', () => {
  const terminalCases: Array<[string, QuotaOutcome]> = [
    ['billed', { kind: 'billed', usage: { inputTokens: 5, outputTokens: 2 } }],
    ['estimated', { kind: 'estimated', usage: { inputTokens: 5, outputTokens: 2 } }],
    ['unknown', { kind: 'unknown' }],
  ];

  for (const [name, outcome] of terminalCases) {
    it(`createOrGet on a terminal ${name} ledger returns {kind:'terminal'} and changes nothing`, async () => {
      const { fake, hooks } = setup();
      const res = await reserve(hooks, 'k1');
      await hooks.settleQuota(res, outcome);
      const ledgerBefore = { ...ledger(fake, 'k1') };
      const countBefore = dayCount(fake);

      const result = await hooks.reserveQuota(createOrGet('k1'));

      expect(result).toEqual({ kind: 'terminal' });
      expect(ledger(fake, 'k1')).toEqual(ledgerBefore); // ledger untouched
      expect(dayCount(fake)).toBe(countBefore); // no counter change
    });
  }
});

describe('smoke usage ledger — the single reopen (unbilled → running)', () => {
  it('reopen reuses the same ledger/reservationId and resets only the terminal fields', async () => {
    const { fake, hooks } = setup();
    const first = await reserve(hooks, 'k1');
    const createdAt = ledger(fake, 'k1').createdAt;
    await hooks.settleQuota(first, { kind: 'unbilled' });

    const reopened = await hooks.reserveQuota(createOrGet('k1'));
    expect(reopened.kind).toBe('reserved');
    if (reopened.kind === 'reserved') expect(reopened.reservation.reservationId).toBe(first.reservationId);
    const row = ledger(fake, 'k1');
    expect(row.status).toBe('running');
    expect(row.quotaOutcome).toBeNull();
    expect(row.terminalAt).toBeNull();
    // Identity + createdAt survive the reopen.
    expect(row.uid).toBe(UID);
    expect(row.botId).toBe(CONFIG.botId);
    expect(row.provider).toBe('openai');
    expect(row.model).toBe(CONFIG.model);
    expect(row.createdAt).toBe(createdAt);
    expect(dayCount(fake)).toBe(1); // re-consumed
  });

  it('reopen is denied when the freed slot was already taken (counter never exceeds the limit)', async () => {
    const { fake, hooks } = setup(FIXED_MS, { ...CONFIG, dailyAttemptQuota: 1 });
    const first = await reserve(hooks, 'k1'); // count 1
    await hooks.settleQuota(first, { kind: 'unbilled' }); // count 0
    await reserve(hooks, 'k2'); // another attempt fills the slot → count 1
    const reopen = await hooks.reserveQuota(createOrGet('k1'));
    expect(reopen.kind).toBe('denied');
    if (reopen.kind === 'denied') expect(reopen.detail).toBe('daily-quota');
    expect(dayCount(fake)).toBe(1); // never exceeds the limit
    // k1 stays terminal/unbilled; k2 holds the unit.
    expect(ledger(fake, 'k1').status).toBe('terminal');
    expect(ledger(fake, 'k1').quotaOutcome).toBe('unbilled');
  });
});
