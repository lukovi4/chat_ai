// Private GCS replay store (ADR 0006, SERVER-CONTRACT §6/§10, task §10). Thin
// functions over the INJECTED bucket — no repository abstraction, no second
// cache. The object holds only normalised SSE frames (never keepalive comments);
// its byte count and SHA-256 are the replay-verification contract.
//
// Object path: chat-replays/{uid}/{attemptKey}/{runId}.sse
// Create-only with generation precondition 0, so a stale-cleanup of an old
// runId can never clobber a newer run of the same key.

import { sha256Hex, storageSafeUid } from './canonical';
import type { ReplayBucket } from './dependencies';

/** Exact replay object path for one run of one attempt (task §10). */
export function replayObjectPath(uid: string, attemptKey: string, runId: string): string {
  return `chat-replays/${storageSafeUid(uid)}/${attemptKey}/${runId}.sse`;
}

/** The verified byte facts stored on the Firestore terminal record. */
export interface ReplayObjectFacts {
  path: string;
  bytes: number;
  sha256: string;
}

/** Thrown when a just-written object does not read back byte/SHA-exact. */
export class ReplayVerificationError extends Error {
  constructor() {
    super('replay object verification failed');
    this.name = 'ReplayVerificationError';
  }
}

/**
 * Create-only save of the concatenated frame bytes, then finalize + read-back
 * verification of the exact stored bytes and SHA-256 (task §10 steps 3–4). The
 * custom metadata pins `outcomeKind` and the SHA-256. Returns the verified
 * facts; throws {@link ReplayVerificationError} if the store does not match.
 */
export async function writeAndVerifyOutcome(
  bucket: ReplayBucket,
  path: string,
  body: Buffer,
  outcomeKind: 'success' | 'release',
): Promise<ReplayObjectFacts> {
  const sha = sha256Hex(body);
  await bucket.file(path).save(body, {
    resumable: false,
    contentType: 'text/event-stream',
    preconditionOpts: { ifGenerationMatch: 0 },
    metadata: { metadata: { outcomeKind, sha256: sha } },
  });

  const [stored] = await bucket.file(path).download();
  if (stored.length !== body.length || sha256Hex(stored) !== sha) {
    throw new ReplayVerificationError();
  }
  return { path, bytes: stored.length, sha256: sha };
}

/**
 * Reads a stored terminal object and verifies it against the Firestore pointer
 * (path/bytes/SHA-256). Returns the exact bytes for replay, or `null` when the
 * object is permanently missing or corrupt (→ repair `complete → aborted`).
 */
export async function readVerifiedOutcome(
  bucket: ReplayBucket,
  facts: ReplayObjectFacts,
): Promise<Buffer | null> {
  let stored: Buffer;
  try {
    [stored] = await bucket.file(facts.path).download();
  } catch {
    return null;
  }
  if (stored.length !== facts.bytes || sha256Hex(stored) !== facts.sha256) {
    return null;
  }
  return stored;
}

/**
 * Reads a captured run's release object for a cross-instance joiner and verifies
 * it is a genuine release outcome: the custom metadata must declare
 * `outcomeKind: "release"` and its stored SHA-256 must match the body bytes. A
 * missing, foreign-kind or corrupt object returns `null` (the joiner must not
 * replay it).
 */
export async function readVerifiedReleaseObject(
  bucket: ReplayBucket,
  path: string,
): Promise<Buffer | null> {
  try {
    const file = bucket.file(path);
    const [stored] = await file.download();
    const [metadata] = await file.getMetadata();
    const custom = (metadata.metadata ?? {}) as Record<string, unknown>;
    if (custom.outcomeKind !== 'release') return null;
    if (typeof custom.sha256 !== 'string' || sha256Hex(stored) !== custom.sha256) return null;
    return stored;
  } catch {
    return null;
  }
}

/** Best-effort cleanup of exactly one old run's object (task §6/§10). */
export async function deleteObject(bucket: ReplayBucket, path: string): Promise<void> {
  try {
    await bucket.file(path).delete({ ignoreNotFound: true });
  } catch {
    // Cleanup is best-effort; bucket lifecycle removes any orphan later.
  }
}
