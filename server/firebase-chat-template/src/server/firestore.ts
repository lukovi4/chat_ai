// Firestore idempotency lifecycle (SERVER-CONTRACT §6/§9, docs/server-template.md,
// ADR 0004/0006, task §6). Thin transaction helpers over the INJECTED Firestore
// — no distributed-lock framework, no repository abstraction. Every atomic
// state transition runs inside a Firestore transaction; the owner window and
// logical `expiresAt` are enforced here.
//
// Path: idempotency/{uid}/keys/{attemptKey}   (uid in the path = security boundary)

import { Timestamp } from 'firebase-admin/firestore';
import type { DocumentReference, Firestore } from 'firebase-admin/firestore';

import { storageSafeUid } from './canonical';

export type IdempotencyStatus = 'running' | 'complete' | 'aborted';

/** Exact stored record (docs/server-template.md «Firestore»). */
export interface IdempotencyRecord {
  status: IdempotencyStatus;
  runId: string;
  requestHash: string;
  provider: 'openai' | 'anthropic' | null;
  paramsHash: string | null;
  outcomeObjectPath: string | null;
  outcomeSha256: string | null;
  outcomeBytes: number | null;
  createdAt: Timestamp;
  terminalAt: Timestamp | null;
  expiresAt: Timestamp | null;
}

/** The verified terminal object facts written on `complete`. */
export interface OutcomeFacts {
  outcomeObjectPath: string;
  outcomeBytes: number;
  outcomeSha256: string;
}

export function idempotencyDocRef(
  firestore: Firestore,
  uid: string,
  attemptKey: string,
): DocumentReference {
  return firestore.doc(`idempotency/${storageSafeUid(uid)}/keys/${attemptKey}`);
}

/** The atomic result of an initial key claim (task §6). */
export type ClaimOutcome =
  | { kind: 'owner'; runId: string; cleanupPath: string | null }
  | { kind: 'join'; capturedRunId: string }
  | { kind: 'stale'; record: IdempotencyRecord }
  | { kind: 'complete'; record: IdempotencyRecord }
  | { kind: 'aborted' }
  | { kind: 'conflict' };

interface ClaimParams {
  requestHash: string;
  paramsHashFor: (provider: 'openai' | 'anthropic') => string;
  nowMs: number;
  ownerWindowMs: number;
  replayTtlMs: number;
  mintRunId: () => string;
}

function readRecord(data: unknown): IdempotencyRecord {
  return data as IdempotencyRecord;
}

/**
 * Atomically claims the key: mint a fresh `running` for an unknown or logically
 * expired-terminal key, join a live `running`, recover a stale `running` to
 * `aborted`, or surface `complete`/`aborted`/`conflict`. Pre-resolution repeats
 * compare `requestHash`; resolved repeats compare `paramsHash` under the stored
 * provider.
 */
export function claimAttempt(
  firestore: Firestore,
  ref: DocumentReference,
  params: ClaimParams,
): Promise<ClaimOutcome> {
  const { nowMs, ownerWindowMs, replayTtlMs } = params;
  return firestore.runTransaction<ClaimOutcome>(async (tx) => {
    const snap = await tx.get(ref);
    const record = snap.exists ? readRecord(snap.data()) : null;

    const isExpiredTerminal =
      record !== null &&
      record.status !== 'running' &&
      record.expiresAt !== null &&
      record.expiresAt.toMillis() <= nowMs;

    if (record === null || isExpiredTerminal) {
      const runId = params.mintRunId();
      const fresh: IdempotencyRecord = {
        status: 'running',
        runId,
        requestHash: params.requestHash,
        provider: null,
        paramsHash: null,
        outcomeObjectPath: null,
        outcomeSha256: null,
        outcomeBytes: null,
        createdAt: Timestamp.fromMillis(nowMs),
        terminalAt: null,
        expiresAt: null,
      };
      tx.set(ref, fresh);
      return {
        kind: 'owner',
        runId,
        cleanupPath: isExpiredTerminal ? record!.outcomeObjectPath : null,
      };
    }

    // A stale `running` owner window is recovered BEFORE any mismatch check: a
    // dead owner must never trap the key as a permanent 409, and stale recovery
    // is defined regardless of the incoming hash.
    if (record.status === 'running' && nowMs > record.createdAt.toMillis() + ownerWindowMs) {
      tx.update(ref, {
        status: 'aborted',
        terminalAt: Timestamp.fromMillis(nowMs),
        expiresAt: Timestamp.fromMillis(nowMs + replayTtlMs),
      });
      return { kind: 'stale', record };
    }

    // Mismatch is a protocol signal: pre-resolution compares the provisional
    // requestHash, a resolved record compares paramsHash under its own frozen
    // provider so a server config change cannot corrupt it.
    const storedHash = record.provider === null ? record.requestHash : record.paramsHash;
    const incomingHash =
      record.provider === null ? params.requestHash : params.paramsHashFor(record.provider);
    if (storedHash !== incomingHash) {
      return { kind: 'conflict' };
    }

    if (record.status === 'complete') return { kind: 'complete', record };
    if (record.status === 'aborted') return { kind: 'aborted' };

    // running & live: join.
    return { kind: 'join', capturedRunId: record.runId };
  });
}

/** Freezes the resolved provider + paramsHash on the still-`running` record. */
export function resolveProvider(
  firestore: Firestore,
  ref: DocumentReference,
  runId: string,
  provider: 'openai' | 'anthropic',
  paramsHash: string,
): Promise<boolean> {
  return firestore.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) return false;
    const record = readRecord(snap.data());
    if (record.status !== 'running' || record.runId !== runId) return false;
    tx.update(ref, { provider, paramsHash });
    return true;
  });
}

/** Atomic `running → complete` with the verified object facts. */
export function commitComplete(
  firestore: Firestore,
  ref: DocumentReference,
  runId: string,
  facts: OutcomeFacts,
  nowMs: number,
  replayTtlMs: number,
): Promise<boolean> {
  return firestore.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) return false;
    const record = readRecord(snap.data());
    if (record.status !== 'running' || record.runId !== runId) return false;
    tx.update(ref, {
      status: 'complete',
      outcomeObjectPath: facts.outcomeObjectPath,
      outcomeBytes: facts.outcomeBytes,
      outcomeSha256: facts.outcomeSha256,
      terminalAt: Timestamp.fromMillis(nowMs),
      expiresAt: Timestamp.fromMillis(nowMs + replayTtlMs),
    });
    return true;
  });
}

/** Atomic `running → aborted` (mid-stream, finalise failure, cancellation). */
export function commitAborted(
  firestore: Firestore,
  ref: DocumentReference,
  runId: string,
  nowMs: number,
  replayTtlMs: number,
): Promise<boolean> {
  return firestore.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) return false;
    const record = readRecord(snap.data());
    if (record.status !== 'running' || record.runId !== runId) return false;
    tx.update(ref, {
      status: 'aborted',
      terminalAt: Timestamp.fromMillis(nowMs),
      expiresAt: Timestamp.fromMillis(nowMs + replayTtlMs),
    });
    return true;
  });
}

/** Permanent repair of a `complete` record with a missing/corrupt object. */
export function repairToAborted(
  firestore: Firestore,
  ref: DocumentReference,
  runId: string,
  nowMs: number,
  replayTtlMs: number,
): Promise<boolean> {
  return firestore.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) return false;
    const record = readRecord(snap.data());
    if (record.status !== 'complete' || record.runId !== runId) return false;
    tx.update(ref, {
      status: 'aborted',
      outcomeObjectPath: null,
      outcomeBytes: null,
      outcomeSha256: null,
      terminalAt: Timestamp.fromMillis(nowMs),
      expiresAt: Timestamp.fromMillis(nowMs + replayTtlMs),
    });
    return true;
  });
}

/** Safe-release: deletes the still-`running` claim owned by `runId`. */
export function deleteClaim(
  firestore: Firestore,
  ref: DocumentReference,
  runId: string,
): Promise<boolean> {
  return firestore.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) return false;
    const record = readRecord(snap.data());
    if (record.status !== 'running' || record.runId !== runId) return false;
    tx.delete(ref);
    return true;
  });
}

/** Non-transactional read for a joiner polling the record's terminal state. */
export async function getRecord(
  ref: DocumentReference,
): Promise<IdempotencyRecord | null> {
  const snap = await ref.get();
  return snap.exists ? readRecord(snap.data()) : null;
}
