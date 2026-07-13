import { describe, expect, it } from 'vitest';

import { createChatHandler } from '../src/server';
import { paramsHash, requestHash, sha256Hex } from '../src/server/canonical';
import { validateChatRequest } from '../src/server/validation';
import type { IdempotencyRecord } from '../src/server/firestore';
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

// D. Idempotency lifecycle (task §6/§12D) — seed-based state cases.

const KEY = uuid('a');
const DOC = docPath(KEY);
const objectFor = (runId: string): string => objectPath(KEY, runId);

function hashesFor(body = validBody()): { req: string; params: string } {
  const v = validateChatRequest(body);
  if (!v.ok) throw new Error('fixture body invalid');
  return { req: requestHash(v.request), params: paramsHash(v.request, 'openai') };
}

const OK_STREAM: StreamBehavior = {
  kind: 'events',
  events: [textDelta('hi'), responseCompleted(makeResponse({ usage: makeUsage(1, 1) }))],
};

function harness(behavior: StreamBehavior = OK_STREAM) {
  const firestore = new FakeFirestore();
  const bucket = new FakeBucket();
  const hooks = new RecordingHooks();
  const client = new FakeOpenAIClient(behavior);
  const handler = createChatHandler(
    baseDeps({ firestore: asFirestore(firestore), bucket, hooks, openAIClients: clientRegistry(client) }),
  );
  const run = async (): Promise<FakeRes> => {
    const res = new FakeRes();
    await handler(asReq(makeReq({ idempotencyKey: KEY })), asRes(res));
    return res;
  };
  return { run, firestore, bucket, hooks, client };
}

function record(over: Partial<IdempotencyRecord>): IdempotencyRecord {
  const now = Date.now();
  return {
    status: 'running',
    runId: 'run-old',
    requestHash: hashesFor().req,
    provider: null,
    paramsHash: null,
    outcomeObjectPath: null,
    outcomeSha256: null,
    outcomeBytes: null,
    createdAt: Timestamp.fromMillis(now),
    terminalAt: null,
    expiresAt: null,
    ...over,
  };
}

describe('idempotency — conflict (409)', () => {
  it('pre-resolution: a different requestHash mismatches', async () => {
    const h = harness();
    h.firestore.seed(DOC, record({ requestHash: 'DIFFERENT', provider: null }));
    const res = await h.run();
    expect(res.statusCode).toBe(409);
    expect(res.json()).toEqual({ cause: 'upstream', detail: 'idempotency-conflict' });
    expect(h.client.callCount).toBe(0);
    expect(h.hooks.calls).toEqual([]);
  });

  it('post-resolution: a different paramsHash mismatches under the stored provider', async () => {
    const h = harness();
    h.firestore.seed(DOC, record({ provider: 'openai', paramsHash: 'DIFFERENT' }));
    const res = await h.run();
    expect(res.statusCode).toBe(409);
    expect(h.client.callCount).toBe(0);
  });
});

describe('idempotency — terminal states', () => {
  it('complete: replays the stored object byte-exact, no provider/hooks', async () => {
    const h = harness();
    const bytes = Buffer.from('event: delta\ndata: {"text":"stored"}\n\nevent: done\ndata: {}\n\n', 'utf8');
    h.bucket.objects.set(objectFor('run-old'), { data: bytes, metadata: { sha256: sha256Hex(bytes) } });
    h.firestore.seed(
      DOC,
      record({
        status: 'complete',
        provider: 'openai',
        paramsHash: hashesFor().params,
        outcomeObjectPath: objectFor('run-old'),
        outcomeBytes: bytes.length,
        outcomeSha256: sha256Hex(bytes),
        terminalAt: Timestamp.fromMillis(Date.now()),
        expiresAt: Timestamp.fromMillis(Date.now() + 600_000),
      }),
    );
    const res = await h.run();
    expect(res.statusCode).toBe(200);
    expect(res.body()).toBe(bytes.toString('utf8'));
    expect(h.client.callCount).toBe(0);
    expect(h.hooks.calls).toEqual([]);
  });

  it('aborted: returns 410, no provider/hooks', async () => {
    const h = harness();
    h.firestore.seed(DOC, record({ status: 'aborted', expiresAt: Timestamp.fromMillis(Date.now() + 600_000) }));
    const res = await h.run();
    expect(res.statusCode).toBe(410);
    expect(res.json()).toEqual({ cause: 'upstream', detail: 'aborted' });
    expect(h.client.callCount).toBe(0);
    expect(h.hooks.calls).toEqual([]);
  });

  it('complete with a missing object: repaired to aborted + 410, no provider', async () => {
    const h = harness();
    h.firestore.seed(
      DOC,
      record({
        status: 'complete',
        provider: 'openai',
        paramsHash: hashesFor().params,
        outcomeObjectPath: objectFor('run-old'),
        outcomeBytes: 10,
        outcomeSha256: 'deadbeef',
        terminalAt: Timestamp.fromMillis(Date.now()),
        expiresAt: Timestamp.fromMillis(Date.now() + 600_000),
      }),
    );
    const res = await h.run();
    expect(res.statusCode).toBe(410);
    expect(res.json()).toEqual({ cause: 'upstream', detail: 'replay-missing' });
    expect((h.firestore.store.get(DOC) as IdempotencyRecord).status).toBe('aborted');
    expect(h.client.callCount).toBe(0);
  });

  it('complete pointing to a DIFFERENT valid object path: foreign bytes never served [defect 3]', async () => {
    const h = harness();
    // A foreign object with perfectly valid bytes/SHA at a NON-canonical path.
    const foreign = Buffer.from('event: delta\ndata: {"text":"FOREIGN-SECRET"}\n\nevent: done\ndata: {}\n\n', 'utf8');
    h.bucket.objects.set(objectFor('run-other'), { data: foreign, metadata: { sha256: sha256Hex(foreign) } });
    h.firestore.seed(
      DOC,
      record({
        status: 'complete',
        runId: 'run-X',
        provider: 'openai',
        paramsHash: hashesFor().params,
        outcomeObjectPath: objectFor('run-other'), // != replayObjectPath(uid, key, run-X)
        outcomeBytes: foreign.length,
        outcomeSha256: sha256Hex(foreign),
        terminalAt: Timestamp.fromMillis(Date.now()),
        expiresAt: Timestamp.fromMillis(Date.now() + 600_000),
      }),
    );
    const res = await h.run();
    expect(res.statusCode).toBe(410);
    expect(res.json()).toEqual({ cause: 'upstream', detail: 'replay-path' });
    expect(h.bucket.downloads).not.toContain(objectFor('run-other')); // never downloaded
    expect(res.body()).not.toContain('FOREIGN-SECRET');
    expect((h.firestore.store.get(DOC) as IdempotencyRecord).status).toBe('aborted');
  });

  it('complete with a corrupt (sha-mismatch) object: repaired to aborted + 410', async () => {
    const h = harness();
    const bytes = Buffer.from('event: done\ndata: {}\n\n', 'utf8');
    h.bucket.objects.set(objectFor('run-old'), { data: bytes, metadata: {} });
    h.firestore.seed(
      DOC,
      record({
        status: 'complete',
        provider: 'openai',
        paramsHash: hashesFor().params,
        outcomeObjectPath: objectFor('run-old'),
        outcomeBytes: bytes.length,
        outcomeSha256: 'not-the-real-sha',
        terminalAt: Timestamp.fromMillis(Date.now()),
        expiresAt: Timestamp.fromMillis(Date.now() + 600_000),
      }),
    );
    const res = await h.run();
    expect(res.statusCode).toBe(410);
    expect((h.firestore.store.get(DOC) as IdempotencyRecord).status).toBe('aborted');
  });
});

describe('idempotency — stale running recovery', () => {
  it('aborts, recovers via getExisting, settles unknown, returns 410', async () => {
    const h = harness();
    h.firestore.seed(
      DOC,
      record({
        provider: 'openai',
        paramsHash: hashesFor().params,
        createdAt: Timestamp.fromMillis(Date.now() - 70_000), // owner window is 60 s
      }),
    );
    const res = await h.run();
    expect(res.statusCode).toBe(410);
    expect(res.json()).toEqual({ cause: 'upstream', detail: 'stale' });
    expect(h.hooks.calls).toEqual(['reserveQuota:getExisting', 'settleQuota:unknown']);
    expect((h.firestore.store.get(DOC) as IdempotencyRecord).status).toBe('aborted');
    expect(h.client.callCount).toBe(0);
  });

  it('a stale running with a DIFFERENT request hash recovers (never a permanent 409) [P1-7]', async () => {
    const h = harness();
    h.firestore.seed(
      DOC,
      record({
        requestHash: 'DIFFERENT-HASH',
        provider: null,
        createdAt: Timestamp.fromMillis(Date.now() - 70_000), // owner window elapsed
      }),
    );
    const res = await h.run();
    // Stale owner-window is checked BEFORE the mismatch, so this recovers via 410
    // stale recovery instead of returning a stuck 409.
    expect(res.statusCode).toBe(410);
    expect(res.json()).toEqual({ cause: 'upstream', detail: 'stale' });
    expect(h.hooks.calls).toEqual(['reserveQuota:getExisting', 'settleQuota:unknown']);
    expect((h.firestore.store.get(DOC) as IdempotencyRecord).status).toBe('aborted');
    expect(h.client.callCount).toBe(0);
  });
});

describe('idempotency — terminal logical expiry', () => {
  it('an expired complete key is unknown: a fresh runId claims and cleanup hits only the old path', async () => {
    const h = harness();
    const oldBytes = Buffer.from('event: done\ndata: {}\n\n', 'utf8');
    h.bucket.objects.set(objectFor('run-old'), { data: oldBytes, metadata: {} });
    h.firestore.seed(
      DOC,
      record({
        status: 'complete',
        provider: 'openai',
        paramsHash: hashesFor().params,
        outcomeObjectPath: objectFor('run-old'),
        outcomeBytes: oldBytes.length,
        outcomeSha256: sha256Hex(oldBytes),
        terminalAt: Timestamp.fromMillis(Date.now() - 1_000_000),
        expiresAt: Timestamp.fromMillis(Date.now() - 500_000), // already expired
      }),
    );
    const res = await h.run();
    expect(res.statusCode).toBe(200);
    const fresh = h.firestore.store.get(DOC) as IdempotencyRecord;
    expect(fresh.status).toBe('complete');
    expect(fresh.runId).not.toBe('run-old');
    expect(h.client.callCount).toBe(1);
    // Old run object cleaned; the new run's object exists.
    expect(h.bucket.objects.has(objectFor('run-old'))).toBe(false);
    expect(h.bucket.objects.has(objectFor(fresh.runId))).toBe(true);
    expect(parseSse(res.body()).at(-1)!.event).toBe('done');
  });
});
