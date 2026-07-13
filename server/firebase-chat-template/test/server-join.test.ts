import { describe, expect, it } from 'vitest';

import { createChatHandler } from '../src/server';
import { encodeSseFrame } from '../src/core/sse';
import { paramsHash, sha256Hex } from '../src/server/canonical';
import { validateChatRequest } from '../src/server/validation';
import type { IdempotencyRecord } from '../src/server/firestore';
import type { HookOverrides } from './fixtures/server-fakes';
import {
  asFirestore,
  asReq,
  asRes,
  baseDeps,
  clientRegistry,
  docPath,
  FakeBucket,
  FakeFirestore,
  FakeOpenAIClient,
  FakeRes,
  makeReq,
  objectPath,
  parseSse,
  RecordingHooks,
  Timestamp,
  uuid,
  validBody,
  type StreamBehavior,
} from './fixtures/server-fakes';
import { makeResponse, makeUsage, responseCompleted, textDelta } from './fixtures/openai-events';

// D (concurrency slice): exactly one provider call, live running join, and a
// joiner that receives the exact release outcome after a safe release.

const KEY = uuid('a');

function deferred<T>(): { promise: Promise<T>; resolve: (v: T) => void } {
  let resolve!: (v: T) => void;
  const promise = new Promise<T>((r) => (resolve = r));
  return { promise, resolve };
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

function shared(behavior: StreamBehavior, hookOverrides?: HookOverrides) {
  const firestore = new FakeFirestore();
  const bucket = new FakeBucket();
  const hooks = new RecordingHooks(hookOverrides);
  const client = new FakeOpenAIClient(behavior);
  const handler = createChatHandler(
    baseDeps({ firestore: asFirestore(firestore), bucket, hooks, openAIClients: clientRegistry(client) }),
  );
  const invoke = (): Promise<FakeRes> => {
    const res = new FakeRes();
    return handler(asReq(makeReq({ idempotencyKey: KEY })), asRes(res)).then(() => res);
  };
  return { invoke, firestore, bucket, hooks, client };
}

const OK_STREAM: StreamBehavior = {
  kind: 'events',
  events: [textDelta('hi'), responseCompleted(makeResponse({ usage: makeUsage(1, 1) }))],
};

describe('idempotency — concurrent same-key requests', () => {
  it('make exactly one provider call; the joiner replays the same outcome', async () => {
    const h = shared(OK_STREAM);
    const [a, b] = await Promise.all([h.invoke(), h.invoke()]);
    expect(h.client.callCount).toBe(1);
    // Only the owner ran admission; the joiner bypassed the hooks.
    expect(h.hooks.calls).toEqual(['checkEntitlement', 'checkRateLimit', 'reserveQuota:createOrGet', 'settleQuota:billed']);
    for (const res of [a, b]) {
      expect(res.statusCode).toBe(200);
      expect(parseSse(res.body()).at(-1)!.event).toBe('done');
    }
  });
});

describe('idempotency — live running join', () => {
  it('joins a live owner, waits, then replays the verified outcome byte-exact', async () => {
    const gate = deferred<void>();
    const behavior: StreamBehavior = {
      kind: 'generator',
      make: async function* () {
        yield textDelta('hi');
        await gate.promise;
        yield responseCompleted(makeResponse({ usage: makeUsage(1, 1) }));
      },
    };
    const h = shared(behavior);

    const ownerPromise = h.invoke();
    await sleep(20); // owner claims + starts streaming, then blocks on the gate
    const joinerPromise = h.invoke();
    await sleep(250); // joiner claims (running), polls at least once
    gate.resolve();

    const [owner, joiner] = await Promise.all([ownerPromise, joinerPromise]);
    expect(h.client.callCount).toBe(1);
    // The joiner replays the full stored object (delta + done).
    expect(joiner.body()).toBe(owner.body());
    expect(parseSse(joiner.body()).map((e) => e.event)).toEqual(['delta', 'done']);
  });
});

describe('idempotency — joiner after safe release', () => {
  it('returns the exact release outcome from the captured run and never owns', async () => {
    const gate = deferred<void>();
    const h = shared(OK_STREAM, {
      checkRateLimit: async () => {
        await gate.promise;
        return { kind: 'denied', retryAfterMs: 4321 };
      },
    });

    const ownerPromise = h.invoke();
    await sleep(20); // owner claims, resolves provider, blocks in checkRateLimit
    const joinerPromise = h.invoke();
    await sleep(250); // joiner joins the live running record and polls
    gate.resolve();

    const [owner, joiner] = await Promise.all([ownerPromise, joinerPromise]);
    // Owner: pre-stream rate with Retry-After; claim safe-released.
    expect(owner.statusCode).toBe(429);
    expect(owner.json()).toEqual({ cause: 'rate' });
    expect(owner.headers['retry-after']).toBe('5');
    // Joiner: the identical release outcome as an SSE error with retryAfterMs.
    expect(joiner.statusCode).toBe(200);
    expect(parseSse(joiner.body())).toEqual([{ event: 'error', data: { cause: 'rate', retryAfterMs: 4321 } }]);
    // No provider call at all; the joiner never became owner.
    expect(h.client.callCount).toBe(0);
  });
});

// Deterministic joiner-race regressions (P1-1, P1-3) using the FakeFirestore
// before-transaction / before-get hooks instead of wall-clock races.

const DOC = docPath(KEY);

function matchingParamsHash(): string {
  const v = validateChatRequest(validBody());
  if (!v.ok) throw new Error('fixture body invalid');
  return paramsHash(v.request, 'openai');
}

function seededJoiner(functionTimeoutSeconds = 60) {
  const firestore = new FakeFirestore();
  const bucket = new FakeBucket();
  const hooks = new RecordingHooks();
  const client = new FakeOpenAIClient(OK_STREAM);
  const handler = createChatHandler(
    baseDeps({
      firestore: asFirestore(firestore),
      bucket,
      hooks,
      openAIClients: clientRegistry(client),
      functionTimeoutSeconds,
    }),
  );
  const invoke = (): Promise<FakeRes> => {
    const res = new FakeRes();
    return handler(asReq(makeReq({ idempotencyKey: KEY })), asRes(res)).then(() => res);
  };
  return { firestore, bucket, hooks, client, invoke };
}

/** Seeds a LIVE running record (so the fresh request becomes a joiner). */
function seedLiveRunning(firestore: FakeFirestore, runId: string, createdAtMs: number): void {
  const rec: IdempotencyRecord = {
    status: 'running',
    runId,
    requestHash: 'seed',
    provider: 'openai',
    paramsHash: matchingParamsHash(),
    outcomeObjectPath: null,
    outcomeSha256: null,
    outcomeBytes: null,
    createdAt: Timestamp.fromMillis(createdAtMs),
    terminalAt: null,
    expiresAt: null,
  };
  firestore.seed(DOC, rec);
}

describe('joiner — owner completes between the read and the abort [P1-1]', () => {
  it('re-reads and replays complete; never deletes the replay or downgrades settlement', async () => {
    const h = seededJoiner(1); // 1 s owner window
    // Live at claim (700 ms < 1000 ms), but the window elapses while polling.
    seedLiveRunning(h.firestore, 'run-A', Date.now() - 700);

    const doneBytes = Buffer.from('event: done\ndata: {}\n\n', 'utf8');
    // The 2nd transaction is the joiner's stale commitAborted: the owner has just
    // completed, so that transition must fail and NOT trigger settle/cleanup.
    h.firestore.beforeTransaction = (index): void => {
      if (index !== 2) return;
      const rec = h.firestore.store.get(DOC)!;
      rec.status = 'complete';
      rec.outcomeObjectPath = objectPath(KEY, 'run-A');
      rec.outcomeBytes = doneBytes.length;
      rec.outcomeSha256 = sha256Hex(doneBytes);
      rec.terminalAt = Timestamp.fromMillis(Date.now());
      rec.expiresAt = Timestamp.fromMillis(Date.now() + 30_000);
      h.bucket.objects.set(objectPath(KEY, 'run-A'), {
        data: doneBytes,
        metadata: { outcomeKind: 'success', sha256: sha256Hex(doneBytes) },
      });
    };

    const res = await h.invoke();
    expect(res.body()).toBe(doneBytes.toString('utf8')); // replayed, not aborted
    expect(h.bucket.objects.has(objectPath(KEY, 'run-A'))).toBe(true); // replay NOT deleted
    expect(h.hooks.calls).toEqual([]); // no getExisting / unknown downgrade
    expect((h.firestore.store.get(DOC) as IdempotencyRecord).status).toBe('complete');
  });
});

describe('joiner — captured run replaced or released [P1-3]', () => {
  it('replays the captured run verified release when a newer run took the key', async () => {
    const h = seededJoiner();
    seedLiveRunning(h.firestore, 'run-A', Date.now());
    const releaseFrame = Buffer.from(
      encodeSseFrame({ kind: 'error', cause: 'rate', retryAfterMs: 4321 }),
      'utf8',
    );
    h.bucket.objects.set(objectPath(KEY, 'run-A'), {
      data: releaseFrame,
      metadata: { outcomeKind: 'release', sha256: sha256Hex(releaseFrame) },
    });
    let flipped = false;
    h.firestore.beforeGet = (): void => {
      if (flipped) return;
      flipped = true;
      (h.firestore.store.get(DOC) as IdempotencyRecord).runId = 'run-B';
    };

    const res = await h.invoke();
    expect(parseSse(res.body())).toEqual([{ event: 'error', data: { cause: 'rate', retryAfterMs: 4321 } }]);
    expect(h.client.callCount).toBe(0);
  });

  it('rejects a captured release object with a bad SHA/outcomeKind (never replays it)', async () => {
    const h = seededJoiner();
    seedLiveRunning(h.firestore, 'run-A', Date.now());
    const corrupt = Buffer.from(encodeSseFrame({ kind: 'error', cause: 'rate', retryAfterMs: 9999 }), 'utf8');
    h.bucket.objects.set(objectPath(KEY, 'run-A'), {
      data: corrupt,
      metadata: { outcomeKind: 'release', sha256: 'WRONG-SHA' },
    });
    let deleted = false;
    h.firestore.beforeGet = (): void => {
      if (deleted) return;
      deleted = true;
      h.firestore.store.delete(DOC); // safe-release deletion
    };

    const res = await h.invoke();
    expect(parseSse(res.body())).toEqual([{ event: 'error', data: { cause: 'upstream' } }]);
    expect(res.body()).not.toContain('9999'); // the corrupt object is never replayed
  });

  it('a complete record pointing to a foreign path is repaired before terminal, never served [defect 3]', async () => {
    const h = seededJoiner();
    seedLiveRunning(h.firestore, 'run-A', Date.now());
    const foreign = Buffer.from('event: delta\ndata: {"text":"FOREIGN-SECRET"}\n\nevent: done\ndata: {}\n\n', 'utf8');
    h.bucket.objects.set(objectPath(KEY, 'run-other'), { data: foreign, metadata: { sha256: sha256Hex(foreign) } });
    let flipped = false;
    h.firestore.beforeGet = (): void => {
      if (flipped) return;
      flipped = true;
      const rec = h.firestore.store.get(DOC) as IdempotencyRecord;
      rec.status = 'complete';
      rec.outcomeObjectPath = objectPath(KEY, 'run-other'); // != canonical run-A path
      rec.outcomeBytes = foreign.length;
      rec.outcomeSha256 = sha256Hex(foreign);
      rec.terminalAt = Timestamp.fromMillis(Date.now());
      rec.expiresAt = Timestamp.fromMillis(Date.now() + 600_000);
    };

    const res = await h.invoke();
    expect(parseSse(res.body())).toEqual([{ event: 'error', data: { cause: 'upstream' } }]);
    expect(h.bucket.downloads).not.toContain(objectPath(KEY, 'run-other')); // never downloaded
    expect(res.body()).not.toContain('FOREIGN-SECRET');
    expect((h.firestore.store.get(DOC) as IdempotencyRecord).status).toBe('aborted');
  });
});
