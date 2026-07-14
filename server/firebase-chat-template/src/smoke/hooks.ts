// App-owned business hooks for the DEDICATED OpenAI-only smoke project — NOT
// server-runtime API and NOT a universal quota engine. It implements exactly the
// four required `ChatServerHooks` against real Firestore, so a physical-device
// smoke exercises entitlement, a fixed-window rate limit and a per-UTC-day
// attempt quota end to end. Pricing/quotas of a real product remain app logic.
//
// The usage/quota ledger matches the approved schema (docs/server-template.md,
// SERVER-CONTRACT §9): status is `running | terminal` and the Attempt lifecycle
// field `aborted` is NOT duplicated here — the idempotency record is the sole
// authority for `running | complete | aborted`. This ledger is authoritative
// only for reservation, usage and quota outcome.
//
// The storage-safe uid segment (the existing `storageSafeUid`, never a second
// encoder) is used for every Firestore path. Because `settleQuota` receives only
// `{attemptKey, reservationId}` (no uid), the app encodes that segment into its
// OWN opaque `reservationId` (`<seg>.<uuid>`) so settlement can locate the
// normative ledger `usage/{seg}/attempts/{attemptKey}`.

import { randomUUID } from 'node:crypto';

import { Timestamp } from 'firebase-admin/firestore';
import type { DocumentReference, Firestore } from 'firebase-admin/firestore';

import { storageSafeUid } from '../server/canonical';
import type {
  ChatServerHooks,
  EntitlementResult,
  QuotaOutcome,
  QuotaReservation,
  RateLimitResult,
  ReserveQuotaRequest,
  ReserveQuotaResult,
  Tier,
} from '../server/hooks';

/** App-supplied smoke policy values (all validated positive by the composition root). */
export interface SmokeConfig {
  botId: string;
  model: string;
  maxOutputTokens: number;
  rateMaxRequests: number;
  rateWindowSeconds: number;
  dailyAttemptQuota: number;
}

/** The approved usage ledger row — no `aborted`; lifecycle is the idempotency record's. */
interface LedgerDoc {
  uid: string;
  attemptKey: string;
  botId: string;
  provider: 'openai' | 'anthropic';
  model: string;
  reservationId: string;
  status: 'running' | 'terminal';
  inputTokens: number | null;
  outputTokens: number | null;
  quotaOutcome: 'billed' | 'unbilled' | 'estimated' | 'unknown' | null;
  createdAt: Timestamp;
  terminalAt: Timestamp | null;
  /** Internal only: the UTC day whose quota unit this ledger currently holds. */
  day: string;
}

/**
 * Stable internal error for a settlement whose ledger is missing or whose stored
 * identity does not match the passed reservation. Carries NO uid/attemptKey/
 * reservationId/wire values — a silent success/no-op is forbidden.
 */
export class SmokeLedgerIdentityError extends Error {
  constructor() {
    super('smoke usage ledger identity check failed');
    this.name = 'SmokeLedgerIdentityError';
  }
}

/** The storage-safe uid segment carried at the front of the opaque reservationId. */
function segmentOf(reservationId: string): string {
  return reservationId.split('.', 1)[0]!;
}

/** UTC calendar day (YYYY-MM-DD) that scopes the attempt quota. */
function utcDay(nowMs: number): string {
  return new Date(nowMs).toISOString().slice(0, 10);
}

/**
 * Builds the four smoke hooks over `firestore`. `now` is an injectable clock
 * (default wall clock) so the fixed-window/day logic is testable without real
 * Firebase; the Firestore transactions and paths are exactly the deployed ones.
 */
export function createSmokeHooks(
  firestore: Firestore,
  config: SmokeConfig,
  now: () => number = () => Date.now(),
): ChatServerHooks {
  const tier: Tier = {
    id: config.botId,
    provider: 'openai',
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
  };

  const attemptRef = (seg: string, attemptKey: string): DocumentReference =>
    firestore.doc(`usage/${seg}/attempts/${attemptKey}`);
  const dayRef = (seg: string, day: string): DocumentReference =>
    firestore.doc(`usage/${seg}/quota/${day}`);
  const readCount = (data: unknown): number => {
    const count = (data as { count?: unknown } | undefined)?.count;
    return typeof count === 'number' ? count : 0;
  };

  async function checkEntitlement(_uid: string, botId: string): Promise<EntitlementResult> {
    // Only the one configured smoke bot is allowed; it maps to the one OpenAI tier.
    if (botId !== config.botId) return { kind: 'denied', detail: 'unknown-bot' };
    return { kind: 'allowed', tier };
  }

  async function checkRateLimit(uid: string, _botId: string): Promise<RateLimitResult> {
    const windowMs = config.rateWindowSeconds * 1000;
    const nowMs = now();
    const windowStart = Math.floor(nowMs / windowMs) * windowMs;
    const seg = storageSafeUid(uid);
    const ref = firestore.doc(`rate/${seg}/windows/${windowStart}`);
    return firestore.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const count = readCount(snap.exists ? snap.data() : undefined);
      if (count >= config.rateMaxRequests) {
        return { kind: 'denied', retryAfterMs: windowStart + windowMs - nowMs };
      }
      tx.set(ref, { count: count + 1, windowStart: Timestamp.fromMillis(windowStart) });
      return { kind: 'allowed' };
    });
  }

  async function reserveQuota(request: ReserveQuotaRequest): Promise<ReserveQuotaResult> {
    const seg = storageSafeUid(request.uid);
    const aRef = attemptRef(seg, request.attemptKey);

    if (request.kind === 'getExisting') {
      // Stale-recovery read ONLY: never creates a ledger.
      const snap = await aRef.get();
      if (!snap.exists) return { kind: 'denied', detail: 'no-ledger' };
      const data = snap.data() as LedgerDoc;
      return { kind: 'reserved', reservation: { attemptKey: request.attemptKey, reservationId: data.reservationId } };
    }

    const nowMs = now();
    const day = utcDay(nowMs);
    const dRef = dayRef(seg, day);
    return firestore.runTransaction(async (tx) => {
      const aSnap = await tx.get(aRef);

      if (aSnap.exists) {
        const data = aSnap.data() as LedgerDoc;

        // Idempotent running: same reservation, no new row, no counter change.
        if (data.status === 'running') {
          return { kind: 'reserved', reservation: { attemptKey: request.attemptKey, reservationId: data.reservationId } };
        }

        // The ONLY reopen: a terminal ledger settled `unbilled` → running. Any
        // other terminal outcome is a no-op idempotent return.
        if (data.status === 'terminal' && data.quotaOutcome === 'unbilled') {
          // Reopen re-consumes a day unit and MUST re-check the quota — the
          // released slot may already be taken by another attempt.
          const dSnap = await tx.get(dRef);
          const count = readCount(dSnap.exists ? dSnap.data() : undefined);
          if (count >= config.dailyAttemptQuota) {
            return { kind: 'denied', detail: 'daily-quota' };
          }
          // Reset only the terminal fields; keep identity/provider/model/createdAt.
          tx.update(aRef, {
            status: 'running',
            quotaOutcome: null,
            inputTokens: null,
            outputTokens: null,
            terminalAt: null,
            day,
          });
          tx.set(dRef, { count: count + 1 });
          return { kind: 'reserved', reservation: { attemptKey: request.attemptKey, reservationId: data.reservationId } };
        }

        // terminal + billed/estimated/unknown: a durable, non-unbilled accounting
        // outcome. The attempt must NEVER re-dispatch under this key (even after
        // idempotency/replay metadata expiry). Change nothing, touch no counter,
        // and never hand back the old reservation as `reserved`.
        return { kind: 'terminal' };
      }

      // New attempt: enforce the per-UTC-day attempt quota, then create one row.
      const dSnap = await tx.get(dRef);
      const count = readCount(dSnap.exists ? dSnap.data() : undefined);
      if (count >= config.dailyAttemptQuota) {
        return { kind: 'denied', detail: 'daily-quota' };
      }
      const reservationId = `${seg}.${randomUUID()}`;
      const ledger: LedgerDoc = {
        uid: request.uid,
        attemptKey: request.attemptKey,
        botId: request.botId,
        provider: request.tier.provider,
        model: request.tier.model,
        reservationId,
        status: 'running',
        inputTokens: null,
        outputTokens: null,
        quotaOutcome: null,
        createdAt: Timestamp.fromMillis(nowMs),
        terminalAt: null,
        day,
      };
      tx.set(aRef, ledger);
      tx.set(dRef, { count: count + 1 });
      return { kind: 'reserved', reservation: { attemptKey: request.attemptKey, reservationId } };
    });
  }

  async function settleQuota(reservation: QuotaReservation, outcome: QuotaOutcome): Promise<void> {
    const seg = segmentOf(reservation.reservationId);
    const aRef = attemptRef(seg, reservation.attemptKey);
    await firestore.runTransaction(async (tx) => {
      const snap = await tx.get(aRef);
      // Missing ledger or identity mismatch is a hard failure — never a silent
      // no-op. The handler wraps settlement, so this surfaces as an accounting
      // fault, not a leaked/lost settlement.
      if (!snap.exists) throw new SmokeLedgerIdentityError();
      const data = snap.data() as LedgerDoc;
      if (data.attemptKey !== reservation.attemptKey || data.reservationId !== reservation.reservationId) {
        throw new SmokeLedgerIdentityError();
      }

      // Already terminal: the first outcome is frozen — no overwrite, no re-release.
      if (data.status === 'terminal') return;

      if (outcome.kind === 'unbilled') {
        // running → terminal(unbilled): release exactly one day attempt-unit.
        const dRef = dayRef(seg, data.day);
        const dSnap = await tx.get(dRef);
        const count = readCount(dSnap.exists ? dSnap.data() : undefined);
        tx.update(aRef, {
          status: 'terminal',
          quotaOutcome: 'unbilled',
          inputTokens: null,
          outputTokens: null,
          terminalAt: Timestamp.fromMillis(now()),
        });
        tx.set(dRef, { count: Math.max(0, count - 1) });
        return;
      }

      // billed | estimated | unknown: running → terminal, keep the day-unit.
      const usage = 'usage' in outcome ? outcome.usage : { inputTokens: null, outputTokens: null };
      tx.update(aRef, {
        status: 'terminal',
        quotaOutcome: outcome.kind,
        inputTokens: usage.inputTokens,
        outputTokens: usage.outputTokens,
        terminalAt: Timestamp.fromMillis(now()),
      });
    });
  }

  return { checkEntitlement, checkRateLimit, reserveQuota, settleQuota };
}
