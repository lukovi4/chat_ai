// The package-owned request handler and its factory (SERVER-CONTRACT §1–§10,
// docs/server-template.md, task §3–§11). This is the mandatory runtime
// orchestration: HTTP/auth/wire validation → idempotency claim → admission →
// OpenAI dispatch → normalised SSE → strict terminal commit → settlement →
// cancellation. All dependencies are injected; no global Firebase/default state,
// no API key, no provider client construction here.
//
// Failure discipline: every pre-provider exit is provably unbilled (safe
// release), every ambiguous exit is `aborted` + settlement `unknown`, and no
// body/token/provider/user content ever reaches a client detail, an SSE error
// or a log (task §4 leakage rule).

import { randomUUID } from 'node:crypto';

import type { DocumentReference } from 'firebase-admin/firestore';

import { buildOpenAIResponsesRequest } from '../providers/openai/request';
import { translateOpenAIStream } from '../providers/openai/stream';
import { encodeSseFrame } from '../core/sse';
import type { ChatRequest, NormalizedEvent, NormalizedUsage } from '../core/wire';

import { paramsHash, requestHash } from './canonical';
import type { ChatServerDependencies } from './dependencies';
import type { ChatServerHooks, QuotaReservation, ReserveQuotaResult, Tier } from './hooks';
import { classifyOpenAIError, hasZeroRetries } from './openai';
import {
  deleteObject,
  readVerifiedOutcome,
  readVerifiedReleaseObject,
  replayObjectPath,
  ReplayVerificationError,
  writeAndVerifyOutcome,
} from './replay';
import {
  claimAttempt,
  commitAborted,
  commitComplete,
  deleteClaim,
  getRecord,
  idempotencyDocRef,
  repairToAborted,
  resolveProvider,
  type IdempotencyRecord,
} from './firestore';
import {
  header,
  MAX_PAYLOAD_BYTES,
  parseBearer,
  sendPreStreamError,
  SseWriter,
  type ChatHandlerRequest,
  type ChatHandlerResponse,
  type ChatHttpHandler,
  type PreStreamError,
} from './transport';
import { validateChatRequest, isUuidV4 } from './validation';

/** Poll interval for a joiner waiting on the owner's terminal state (ms). */
const JOIN_POLL_MS = 200;

/** Thrown by the factory when a mandatory dependency/config is missing/invalid. */
export class ChatServerConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ChatServerConfigError';
  }
}

/** Fixed, payload-free accounting-fault log (SERVER-CONTRACT §9; task §H). */
function logAccountingFault(): void {
  // eslint-disable-next-line no-console
  console.error('chat_ai: quota settlement failed');
}

function isFunction(value: unknown): value is (...args: never[]) => unknown {
  return typeof value === 'function';
}

/** Fail-closed construction checks (task §3). */
function validateDependencies(deps: ChatServerDependencies): void {
  const hooks = deps.hooks;
  if (
    hooks === undefined ||
    !isFunction(hooks.checkEntitlement) ||
    !isFunction(hooks.checkRateLimit) ||
    !isFunction(hooks.reserveQuota) ||
    !isFunction(hooks.settleQuota)
  ) {
    throw new ChatServerConfigError('all four business hooks are required');
  }
  if (deps.auth === undefined || deps.appCheck === undefined) {
    throw new ChatServerConfigError('auth and appCheck instances are required');
  }
  if (deps.firestore === undefined || deps.bucket === undefined) {
    throw new ChatServerConfigError('firestore and replay bucket are required');
  }
  if (deps.openAIClients === undefined || deps.openAIClients.size === 0) {
    throw new ChatServerConfigError('at least one configured provider client is required');
  }
  for (const client of deps.openAIClients.values()) {
    if (!hasZeroRetries(client)) {
      throw new ChatServerConfigError('every provider client must be constructed with maxRetries: 0');
    }
  }
  if (!Number.isInteger(deps.functionTimeoutSeconds) || deps.functionTimeoutSeconds <= 0) {
    throw new ChatServerConfigError('functionTimeoutSeconds must be a positive integer');
  }
  if (!Number.isInteger(deps.replayTtlSeconds) || deps.replayTtlSeconds < 30) {
    throw new ChatServerConfigError('replayTtlSeconds must be an integer >= 30');
  }
}

// --- settlement helpers (idempotent by attemptKey; never leak) ---------------

/** Settles `unbilled`; reports whether the hook actually succeeded. */
async function settleUnbilled(hooks: ChatServerHooks, reservation: QuotaReservation): Promise<boolean> {
  try {
    await hooks.settleQuota(reservation, { kind: 'unbilled' });
    return true;
  } catch {
    logAccountingFault();
    return false;
  }
}

async function settleUnknown(hooks: ChatServerHooks, reservation: QuotaReservation): Promise<void> {
  try {
    await hooks.settleQuota(reservation, { kind: 'unknown' });
  } catch {
    logAccountingFault();
  }
}

/**
 * Settles a proven-successful leg `billed` with exact usage. Reports success; a
 * failed billed settlement records `unknown` (accounting fault) and returns
 * false — a successful billed is never later downgraded by a caller.
 */
async function settleBilled(
  hooks: ChatServerHooks,
  reservation: QuotaReservation,
  usage: NormalizedUsage | undefined,
): Promise<boolean> {
  const billed = {
    kind: 'billed' as const,
    usage: {
      inputTokens: usage?.inputTokens ?? null,
      outputTokens: usage?.outputTokens ?? null,
    },
  };
  try {
    await hooks.settleQuota(reservation, billed);
    return true;
  } catch {
    // Settlement failure records `unknown`; the verified/replayable result stays.
    await settleUnknown(hooks, reservation);
    return false;
  }
}

/**
 * Best-effort `running → aborted`; swallows its own failure so it can never
 * propagate into the streaming catch and re-settle an already-settled attempt.
 */
async function commitAbortedBestEffort(
  deps: ChatServerDependencies,
  ref: DocumentReference,
  runId: string,
  replayTtlMs: number,
): Promise<void> {
  try {
    await commitAborted(deps.firestore, ref, runId, Date.now(), replayTtlMs);
  } catch {
    // The verified/settled outcome must not be disturbed by a cleanup failure.
  }
}

// --- shared exits ------------------------------------------------------------

/** Builds one normalised release `error` event (release object / owner reply). */
function releaseEvent(error: PreStreamError): NormalizedEvent {
  const event: Extract<NormalizedEvent, { kind: 'error' }> = { kind: 'error', cause: error.cause };
  if (error.retryAfterMs !== undefined) event.retryAfterMs = error.retryAfterMs;
  return event;
}

/**
 * Durable safe release of a still-`running` owner claim before any provider
 * work: write the run's release object (one normalised `error`), settle any
 * reservation `unbilled`, then delete the claim. Returns `true` when released;
 * `false` when the release object could not be finalised (then the attempt is
 * left `aborted`, reservation `unknown`) so the caller returns upstream.
 */
async function safeRelease(
  deps: ChatServerDependencies,
  uid: string,
  attemptKey: string,
  runId: string,
  error: PreStreamError,
  reservation: QuotaReservation | null,
  replayTtlMs: number,
): Promise<boolean> {
  const ref = idempotencyDocRef(deps.firestore, uid, attemptKey);
  const path = replayObjectPath(uid, attemptKey, runId);
  const frame = Buffer.from(encodeSseFrame(releaseEvent(error)), 'utf8');

  // 1. Durable release object first.
  try {
    await writeAndVerifyOutcome(deps.bucket, path, frame, 'release');
  } catch {
    await commitAborted(deps.firestore, ref, runId, Date.now(), replayTtlMs);
    if (reservation !== null) await settleUnknown(deps.hooks, reservation);
    return false;
  }

  // 2. Release the reservation `unbilled`. A failed unbilled settlement must not
  // be reported as a safe release: fall back to `unknown` and keep the claim
  // (aborted), never delete it.
  if (reservation !== null) {
    const settled = await settleUnbilled(deps.hooks, reservation);
    if (!settled) {
      await settleUnknown(deps.hooks, reservation);
      await commitAborted(deps.firestore, ref, runId, Date.now(), replayTtlMs);
      return false;
    }
  }

  // 3. Only a successful claim deletion counts as a safe release; a `false`
  // result or a throw leaves the attempt aborted (a retained tombstone), never a
  // phantom-released key.
  let deleted = false;
  try {
    deleted = await deleteClaim(deps.firestore, ref, runId);
  } catch {
    deleted = false;
  }
  if (!deleted) {
    await commitAborted(deps.firestore, ref, runId, Date.now(), replayTtlMs);
    return false;
  }
  return true;
}

/**
 * Owner pre-provider admission exit: safe-release then reply. On a release the
 * owner returns the mapped status (+ Retry-After); a non-finalisable release
 * object leaves the attempt aborted and returns upstream.
 */
async function ownerAdmissionExit(
  deps: ChatServerDependencies,
  res: ChatHandlerResponse,
  uid: string,
  attemptKey: string,
  runId: string,
  error: PreStreamError,
  reservation: QuotaReservation | null,
  replayTtlMs: number,
): Promise<void> {
  const released = await safeRelease(deps, uid, attemptKey, runId, error, reservation, replayTtlMs);
  sendPreStreamError(res, released ? error : { status: 502, cause: 'upstream' });
}

/** Stale-owner recovery bookkeeping: recover the ledger, settle `unknown`, clean up. */
async function staleSettleAndCleanup(
  deps: ChatServerDependencies,
  uid: string,
  attemptKey: string,
  oldRunId: string,
): Promise<void> {
  try {
    const recovered = await deps.hooks.reserveQuota({ kind: 'getExisting', uid, attemptKey });
    if (recovered.kind === 'reserved') await settleUnknown(deps.hooks, recovered.reservation);
  } catch {
    logAccountingFault();
  }
  await deleteObject(deps.bucket, replayObjectPath(uid, attemptKey, oldRunId));
}

// --- the factory -------------------------------------------------------------

/**
 * Builds the package-owned chat handler from the concrete per-deployment
 * dependencies. The returned handler matches the Firebase Functions gen2 HTTP
 * signature and is wrapped by the app-owned `onRequest` (a later increment).
 */
export function createChatHandler(deps: ChatServerDependencies): ChatHttpHandler {
  validateDependencies(deps);
  const ownerWindowMs = deps.functionTimeoutSeconds * 1000;
  const replayTtlMs = deps.replayTtlSeconds * 1000;

  return async (req: ChatHandlerRequest, res: ChatHandlerResponse): Promise<void> => {
    try {
      await handleRequest(deps, ownerWindowMs, replayTtlMs, req, res);
    } catch {
      // Last-resort guard: never leak; best-effort minimal failure.
      if (!res.headersSent && !res.writableEnded) {
        sendPreStreamError(res, { status: 502, cause: 'upstream' });
      } else if (!res.writableEnded) {
        try {
          res.end();
        } catch {
          /* connection already gone */
        }
      }
    }
  };
}

async function handleRequest(
  deps: ChatServerDependencies,
  ownerWindowMs: number,
  replayTtlMs: number,
  req: ChatHandlerRequest,
  res: ChatHandlerResponse,
): Promise<void> {
  // 1. POST only.
  if (req.method !== 'POST') {
    sendPreStreamError(res, { status: 405, cause: 'upstream', detail: 'method-not-allowed' });
    return;
  }

  // 2. Firebase Auth id-token.
  const bearer = parseBearer(header(req, 'authorization'));
  if (bearer === null) {
    sendPreStreamError(res, { status: 401, cause: 'auth', detail: 'id-token' });
    return;
  }
  let uid: string;
  try {
    const decoded = await deps.auth.verifyIdToken(bearer);
    uid = decoded.uid;
  } catch {
    sendPreStreamError(res, { status: 401, cause: 'auth', detail: 'id-token' });
    return;
  }

  // 3. App Check.
  const appCheckToken = header(req, 'x-firebase-appcheck');
  if (appCheckToken === undefined) {
    sendPreStreamError(res, { status: 401, cause: 'auth', detail: 'app-check' });
    return;
  }
  try {
    await deps.appCheck.verifyToken(appCheckToken);
  } catch {
    sendPreStreamError(res, { status: 401, cause: 'auth', detail: 'app-check' });
    return;
  }

  // 4. Raw payload: size → JSON → wireVersion → key → exact shape/toolset.
  const rawBody = req.rawBody ?? Buffer.alloc(0);
  if (rawBody.length > MAX_PAYLOAD_BYTES) {
    sendPreStreamError(res, { status: 413, cause: 'context-too-long' });
    return;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(rawBody.toString('utf8'));
  } catch {
    sendPreStreamError(res, { status: 400, cause: 'upstream', detail: 'malformed-json' });
    return;
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    sendPreStreamError(res, { status: 400, cause: 'upstream', detail: 'invalid-request' });
    return;
  }
  if ((parsed as Record<string, unknown>).wireVersion !== 1) {
    sendPreStreamError(res, { status: 426, cause: 'upstream', detail: 'unsupported-wire-version' });
    return;
  }
  const attemptKey = header(req, 'idempotency-key');
  if (!isUuidV4(attemptKey)) {
    sendPreStreamError(res, { status: 400, cause: 'upstream', detail: 'invalid-idempotency-key' });
    return;
  }
  const validation = validateChatRequest(parsed);
  if (!validation.ok) {
    if (validation.reason === 'unsupported-wire-version') {
      sendPreStreamError(res, { status: 426, cause: 'upstream', detail: 'unsupported-wire-version' });
    } else if (validation.reason === 'invalid-tool-schema') {
      sendPreStreamError(res, { status: 400, cause: 'upstream', detail: 'invalid-tool-schema' });
    } else {
      sendPreStreamError(res, { status: 400, cause: 'upstream', detail: 'invalid-request' });
    }
    return;
  }
  const request = validation.request;

  // 5. Firestore claim (the money boundary; nothing above touched it).
  const ref = idempotencyDocRef(deps.firestore, uid, attemptKey);
  const reqHash = requestHash(request);
  const claim = await claimAttempt(deps.firestore, ref, {
    requestHash: reqHash,
    paramsHashFor: (provider) => paramsHash(request, provider),
    nowMs: Date.now(),
    ownerWindowMs,
    replayTtlMs,
    mintRunId: () => randomUUID(),
  });

  switch (claim.kind) {
    case 'conflict':
      sendPreStreamError(res, { status: 409, cause: 'upstream', detail: 'idempotency-conflict' });
      return;
    case 'aborted':
      sendPreStreamError(res, { status: 410, cause: 'upstream', detail: 'aborted' });
      return;
    case 'stale':
      await staleSettleAndCleanup(deps, uid, attemptKey, claim.record.runId);
      sendPreStreamError(res, { status: 410, cause: 'upstream', detail: 'stale' });
      return;
    case 'complete':
      await replayComplete(deps, uid, attemptKey, claim.record, res, replayTtlMs);
      return;
    case 'join':
      await joinRun(deps, uid, attemptKey, claim.capturedRunId, req, res, ownerWindowMs, replayTtlMs);
      return;
    case 'owner':
      if (claim.cleanupPath !== null) await deleteObject(deps.bucket, claim.cleanupPath);
      await runOwner(deps, uid, attemptKey, claim.runId, request, req, res, replayTtlMs);
      return;
  }
}

/** Verifies and replays a `complete` outcome; repairs a missing/corrupt object. */
async function replayComplete(
  deps: ChatServerDependencies,
  uid: string,
  attemptKey: string,
  record: IdempotencyRecord,
  res: ChatHandlerResponse,
  replayTtlMs: number,
): Promise<void> {
  const ref = idempotencyDocRef(deps.firestore, uid, attemptKey);
  // Canonical path guard: the stored pointer MUST equal the exact object path of
  // this run. A mismatched path is never downloaded — repair, then 410.
  const canonicalPath = replayObjectPath(uid, attemptKey, record.runId);
  if (record.outcomeObjectPath !== canonicalPath) {
    await repairToAborted(deps.firestore, ref, record.runId, Date.now(), replayTtlMs);
    sendPreStreamError(res, { status: 410, cause: 'upstream', detail: 'replay-path' });
    return;
  }
  const bytes = await readVerifiedOutcome(deps.bucket, {
    path: canonicalPath,
    bytes: record.outcomeBytes!,
    sha256: record.outcomeSha256!,
  });
  if (bytes === null) {
    await repairToAborted(deps.firestore, ref, record.runId, Date.now(), replayTtlMs);
    sendPreStreamError(res, { status: 410, cause: 'upstream', detail: 'replay-missing' });
    return;
  }
  const writer = new SseWriter(res);
  writer.openHeaders();
  writer.writeFrame(bytes.toString('utf8'));
  writer.end();
}

/** A joiner: open SSE, keepalive, and replay the captured run's outcome. */
async function joinRun(
  deps: ChatServerDependencies,
  uid: string,
  attemptKey: string,
  capturedRunId: string,
  req: ChatHandlerRequest,
  res: ChatHandlerResponse,
  ownerWindowMs: number,
  replayTtlMs: number,
): Promise<void> {
  const ref = idempotencyDocRef(deps.firestore, uid, attemptKey);
  const writer = new SseWriter(res);
  const onClose = (): void => writer.markDisconnected();
  req.on('close', onClose);
  res.on('close', onClose);
  res.on('error', onClose);
  writer.openHeaders();

  const emitUpstream = (): void => {
    writer.writeFrame(encodeSseFrame({ kind: 'error', cause: 'upstream' }));
    writer.end();
  };
  // Replays the captured run's verified release object, or a bare upstream error
  // when it is absent/foreign/corrupt (never replay an unverified object).
  const replayCapturedRelease = async (): Promise<void> => {
    const bytes = await readVerifiedReleaseObject(
      deps.bucket,
      replayObjectPath(uid, attemptKey, capturedRunId),
    );
    if (bytes !== null) {
      writer.writeFrame(bytes.toString('utf8'));
      writer.end();
    } else {
      emitUpstream();
    }
  };

  try {
    for (;;) {
      if (writer.disconnected) return;
      const record = await getRecord(ref);

      if (record === null || record.runId !== capturedRunId) {
        // Claim gone (safe release) or a newer run replaced the key: the only
        // valid outcome for the captured run is its verified release object.
        await replayCapturedRelease();
        return;
      }
      if (record.status === 'complete') {
        // Canonical path guard first: a mismatched pointer is never downloaded.
        const canonicalPath = replayObjectPath(uid, attemptKey, capturedRunId);
        const bytes =
          record.outcomeObjectPath === canonicalPath
            ? await readVerifiedOutcome(deps.bucket, {
                path: canonicalPath,
                bytes: record.outcomeBytes!,
                sha256: record.outcomeSha256!,
              })
            : null;
        if (bytes !== null) {
          writer.writeFrame(bytes.toString('utf8'));
          writer.end();
        } else {
          // A wrong-path / corrupt / missing complete object is repaired before
          // the terminal error(upstream).
          await repairToAborted(deps.firestore, ref, capturedRunId, Date.now(), replayTtlMs);
          emitUpstream();
        }
        return;
      }
      if (record.status === 'aborted') {
        emitUpstream();
        return;
      }
      // running: if the owner window elapsed, THIS joiner may recover it — but
      // only the transition it actually wins may settle/clean up. If the owner
      // finished first, re-read and handle complete/release without downgrading.
      if (Date.now() > record.createdAt.toMillis() + ownerWindowMs) {
        const won = await commitAborted(deps.firestore, ref, capturedRunId, Date.now(), replayTtlMs);
        if (won) {
          await staleSettleAndCleanup(deps, uid, attemptKey, capturedRunId);
          emitUpstream();
          return;
        }
        continue; // owner reached a terminal first; re-read.
      }
      await delay(JOIN_POLL_MS);
    }
  } finally {
    req.removeListener('close', onClose);
    res.removeListener('close', onClose);
    res.removeListener('error', onClose);
    writer.end();
  }
}

/** The newly claimed owner: admission → OpenAI dispatch → SSE → settlement. */
async function runOwner(
  deps: ChatServerDependencies,
  uid: string,
  attemptKey: string,
  runId: string,
  request: ChatRequest,
  req: ChatHandlerRequest,
  res: ChatHandlerResponse,
  replayTtlMs: number,
): Promise<void> {
  const ref = idempotencyDocRef(deps.firestore, uid, attemptKey);
  const botId = request.botId;

  // 1. Entitlement.
  let tier: Tier;
  try {
    const entitlement = await deps.hooks.checkEntitlement(uid, botId);
    if (entitlement.kind === 'denied') {
      await ownerAdmissionExit(deps, res, uid, attemptKey, runId, { status: 403, cause: 'entitlement' }, null, replayTtlMs);
      return;
    }
    tier = entitlement.tier;
  } catch {
    await ownerAdmissionExit(deps, res, uid, attemptKey, runId, { status: 502, cause: 'upstream' }, null, replayTtlMs);
    return;
  }

  // This increment dispatches only openai; an anthropic tier fails closed.
  if (tier.provider !== 'openai') {
    await ownerAdmissionExit(deps, res, uid, attemptKey, runId, { status: 502, cause: 'upstream' }, null, replayTtlMs);
    return;
  }

  // 2. Freeze the resolved provider + paramsHash before rate/quota/dispatch.
  const pHash = paramsHash(request, 'openai');
  const resolved = await resolveProvider(deps.firestore, ref, runId, 'openai', pHash);
  if (!resolved) {
    // Ownership was lost (e.g. concurrently aborted) — fail closed, no claim ours.
    sendPreStreamError(res, { status: 502, cause: 'upstream' });
    return;
  }

  // 3. Rate limit.
  try {
    const rate = await deps.hooks.checkRateLimit(uid, botId);
    if (rate.kind === 'denied') {
      const error: PreStreamError = { status: 429, cause: 'rate', retryAfterMs: rate.retryAfterMs };
      await ownerAdmissionExit(deps, res, uid, attemptKey, runId, error, null, replayTtlMs);
      return;
    }
  } catch {
    await ownerAdmissionExit(deps, res, uid, attemptKey, runId, { status: 502, cause: 'upstream' }, null, replayTtlMs);
    return;
  }

  // 4. Quota reservation. The try/catch guards ONLY the hook call; result
  // handling (denied / terminal / reserved) runs OUTSIDE it, so an error while
  // emitting the terminal 410 (e.g. a failed response.end) can never fall through
  // to the reserveQuota catch and trigger a safe release — which would make a
  // durable-terminal key runnable again.
  let reserve: ReserveQuotaResult;
  try {
    reserve = await deps.hooks.reserveQuota({ kind: 'createOrGet', uid, attemptKey, botId, tier });
  } catch {
    await ownerAdmissionExit(deps, res, uid, attemptKey, runId, { status: 502, cause: 'upstream' }, null, replayTtlMs);
    return;
  }
  if (reserve.kind === 'denied') {
    await ownerAdmissionExit(deps, res, uid, attemptKey, runId, { status: 429, cause: 'quota' }, null, replayTtlMs);
    return;
  }
  if (reserve.kind === 'terminal') {
    // Durable terminal (billed/estimated/unknown) accounting for this key: NEVER
    // re-dispatch, even though idempotency/replay metadata expiry minted a
    // provisional owner claim. No provider call, no settlement (accounting is
    // already terminal), and NO safe release/claim delete — that would make the
    // key runnable again. Turn the provisional claim into an aborted tombstone
    // (best-effort) and return a stable pre-stream 410; the client recovers with a
    // fresh key. Even if the tombstone write or the 410 emit fails, dispatch stays
    // forbidden and no safe release runs.
    await commitAbortedBestEffort(deps, ref, runId, replayTtlMs);
    sendPreStreamError(res, { status: 410, cause: 'upstream', detail: 'attempt-terminal' });
    return;
  }
  const reservation: QuotaReservation = reserve.reservation;

  // 5. Build the exact typed provider request (local validation is pre-provider).
  let providerRequest;
  try {
    providerRequest = buildOpenAIResponsesRequest(request, {
      model: tier.model,
      maxOutputTokens: tier.maxOutputTokens,
      reasoningEffort: tier.reasoningEffort,
      compactThreshold: tier.compactThreshold,
    });
  } catch {
    await ownerAdmissionExit(deps, res, uid, attemptKey, runId, { status: 502, cause: 'upstream' }, reservation, replayTtlMs);
    return;
  }

  const client = deps.openAIClients.get(tier.id);
  if (client === undefined) {
    await ownerAdmissionExit(deps, res, uid, attemptKey, runId, { status: 502, cause: 'upstream' }, reservation, replayTtlMs);
    return;
  }

  // 6. Dispatch with cancellation wiring. A single idempotent callback handles
  // every observed-disconnect source — request aborted/close, response
  // close/error, and a failed normal-frame OR keepalive write (via
  // writer.onDisconnect); it sets `disconnected` once and aborts upstream.
  const controller = new AbortController();
  const writer = new SseWriter(res);
  let disconnected = false;
  const disconnect = (): void => {
    if (disconnected) return;
    disconnected = true;
    writer.markDisconnected();
    controller.abort();
  };
  writer.onDisconnect = disconnect;
  req.on('aborted', disconnect);
  req.on('close', disconnect);
  res.on('close', disconnect);
  res.on('error', disconnect);

  const finish = (): void => {
    req.removeListener('aborted', disconnect);
    req.removeListener('close', disconnect);
    res.removeListener('close', disconnect);
    res.removeListener('error', disconnect);
    writer.end();
  };

  let stream;
  try {
    stream = await client.responses.create(providerRequest, { signal: controller.signal });
  } catch (error) {
    if (disconnected) {
      // Cancelled before the stream opened: ambiguous → aborted + unknown.
      await commitAborted(deps.firestore, ref, runId, Date.now(), replayTtlMs);
      await settleUnknown(deps.hooks, reservation);
      finish();
      return;
    }
    const classified = classifyOpenAIError(error);
    if (classified.disposition === 'release') {
      const mapped: PreStreamError = { status: 429, cause: classified.cause, retryAfterMs: classified.retryAfterMs };
      const released = await safeRelease(deps, uid, attemptKey, runId, mapped, reservation, replayTtlMs);
      sendPreStreamError(res, released ? mapped : { status: 502, cause: 'upstream' });
    } else {
      await commitAborted(deps.firestore, ref, runId, Date.now(), replayTtlMs);
      await settleUnknown(deps.hooks, reservation);
      const status = classified.cause === 'context-too-long' ? 413 : 502;
      sendPreStreamError(res, { status, cause: classified.cause });
    }
    finish();
    return;
  }

  // 7. Stream normalised events; strict terminal commit order for success.
  writer.openHeaders();
  const replayFrames: Buffer[] = [];

  try {
    for await (const event of translateOpenAIStream(stream)) {
      if (disconnected) break;

      if (event.kind === 'delta' || event.kind === 'provider_state') {
        const frame = encodeSseFrame(event);
        replayFrames.push(Buffer.from(frame, 'utf8'));
        // A failed write means the connection is gone: stop consuming upstream.
        if (!writer.writeFrame(frame)) {
          disconnect();
          break;
        }
        continue;
      }

      if (event.kind === 'error') {
        // Mid-stream failure → aborted. Exact provider usage on the error is a
        // real (partial) spend → `billed`; without exact usage → `unknown`.
        await commitAborted(deps.firestore, ref, runId, Date.now(), replayTtlMs);
        if (event.usage !== undefined) {
          await settleBilled(deps.hooks, reservation, event.usage);
        } else {
          await settleUnknown(deps.hooks, reservation);
        }
        writer.writeFrame(encodeSseFrame(event));
        finish();
        return;
      }

      // Success terminal (done | tool_call): object → verify → settle → complete → emit.
      const terminalFrame = encodeSseFrame(event);
      replayFrames.push(Buffer.from(terminalFrame, 'utf8'));
      const path = replayObjectPath(uid, attemptKey, runId);
      const body = Buffer.concat(replayFrames);

      let facts;
      try {
        facts = await writeAndVerifyOutcome(deps.bucket, path, body, 'success');
      } catch (objectError) {
        // Object finalise/verify failed → no terminal; aborted + unknown.
        void (objectError instanceof ReplayVerificationError);
        await commitAborted(deps.firestore, ref, runId, Date.now(), replayTtlMs);
        await settleUnknown(deps.hooks, reservation);
        writer.writeFrame(encodeSseFrame({ kind: 'error', cause: 'upstream' }));
        finish();
        return;
      }

      // Settle BEFORE the complete commit (SERVER-CONTRACT §6). A settlement
      // fault already records `unknown` inside settleBilled; a successful billed
      // is never downgraded by the single post-billed failure path below.
      await settleBilled(deps.hooks, reservation, event.usage);

      // commitComplete returning false OR throwing is ONE post-billed failure
      // path: no re-settlement, best-effort abort, no success terminal.
      let committed = false;
      try {
        committed = await commitComplete(
          deps.firestore,
          ref,
          runId,
          { outcomeObjectPath: facts.path, outcomeBytes: facts.bytes, outcomeSha256: facts.sha256 },
          Date.now(),
          replayTtlMs,
        );
      } catch {
        committed = false;
      }
      if (!committed) {
        await commitAbortedBestEffort(deps, ref, runId, replayTtlMs);
        writer.writeFrame(encodeSseFrame({ kind: 'error', cause: 'upstream' }));
        finish();
        return;
      }

      writer.writeFrame(terminalFrame);
      finish();
      return;
    }

    // Loop ended without a terminal: cancellation, or a broken stream.
    await commitAborted(deps.firestore, ref, runId, Date.now(), replayTtlMs);
    await settleUnknown(deps.hooks, reservation);
    if (!disconnected) writer.writeFrame(encodeSseFrame({ kind: 'error', cause: 'upstream' }));
    finish();
  } catch {
    // Defensive backstop; the translator already turns iterator throws into data.
    await commitAborted(deps.firestore, ref, runId, Date.now(), replayTtlMs);
    await settleUnknown(deps.hooks, reservation);
    if (!disconnected) writer.writeFrame(encodeSseFrame({ kind: 'error', cause: 'upstream' }));
    finish();
  }
}

/** A real-timer delay used by the joiner poll loop (join tests use real timers). */
function delay(ms: number): Promise<void> {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, ms);
    timer.unref?.();
  });
}
