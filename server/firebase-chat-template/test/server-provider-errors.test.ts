import { describe, expect, it } from 'vitest';
import { APIError } from 'openai';

import { createChatHandler } from '../src/server';
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
  RecordingHooks,
  uuid,
} from './fixtures/server-fakes';

// G (handler slice): pre-stream provider rejections drive the exact key
// disposition and settlement (task §7/§9/§12E/G).

const KEY = uuid('a');
const DOC = docPath(KEY);

function apiError(status: number, code: string | undefined, headers: Headers = new Headers()): APIError {
  const body = code === undefined ? {} : { code, message: 'x', type: 'y', param: null };
  return new APIError(status, body, 'x', headers);
}

async function run(error: unknown) {
  const firestore = new FakeFirestore();
  const bucket = new FakeBucket();
  const hooks = new RecordingHooks();
  const client = new FakeOpenAIClient({ kind: 'reject', error });
  const handler = createChatHandler(
    baseDeps({ firestore: asFirestore(firestore), bucket, hooks, openAIClients: clientRegistry(client) }),
  );
  const res = new FakeRes();
  await handler(asReq(makeReq({ idempotencyKey: KEY })), asRes(res));
  return { res, firestore, bucket, hooks, client };
}

describe('provider pre-stream — safe release (rate)', () => {
  it('a retryable 429 releases the claim unbilled with Retry-After', async () => {
    const { res, firestore, bucket, hooks, client } = await run(
      apiError(429, 'rate_limit_exceeded', new Headers({ 'retry-after': '2' })),
    );
    expect(res.statusCode).toBe(429);
    expect(res.json()).toEqual({ cause: 'rate' });
    expect(res.headers['retry-after']).toBe('2');
    expect(firestore.store.has(DOC)).toBe(false); // claim released → unknown again
    expect(hooks.settlements.at(-1)!.outcome).toEqual({ kind: 'unbilled' });
    expect(client.callCount).toBe(1);
    // A durable release object exists for cross-instance joiners.
    const release = [...bucket.objects.values()][0]!;
    expect(release.metadata.outcomeKind).toBe('release');
  });
});

describe('provider pre-stream — fail closed (aborted)', () => {
  it('insufficient_quota → 502 upstream, aborted, settled unknown, claim retained', async () => {
    const { res, firestore, hooks } = await run(apiError(429, 'insufficient_quota'));
    expect(res.statusCode).toBe(502);
    expect(res.json()).toEqual({ cause: 'upstream' });
    expect((firestore.store.get(DOC) as IdempotencyRecord).status).toBe('aborted');
    expect(hooks.settlements.at(-1)!.outcome.kind).toBe('unknown');
  });

  it('context_length_exceeded → 413 context-too-long, aborted', async () => {
    const { res, firestore } = await run(apiError(400, 'context_length_exceeded'));
    expect(res.statusCode).toBe(413);
    expect(res.json()).toEqual({ cause: 'context-too-long' });
    expect((firestore.store.get(DOC) as IdempotencyRecord).status).toBe('aborted');
  });

  it('a bare/unknown 429 → 502 upstream, aborted (not released)', async () => {
    const { res, firestore } = await run(apiError(429, undefined));
    expect(res.statusCode).toBe(502);
    expect(res.json()).toEqual({ cause: 'upstream' });
    expect((firestore.store.get(DOC) as IdempotencyRecord).status).toBe('aborted');
  });

  it('a 503 server error → 502 upstream, aborted', async () => {
    const { res, firestore } = await run(apiError(503, 'server_error'));
    expect(res.statusCode).toBe(502);
    expect((firestore.store.get(DOC) as IdempotencyRecord).status).toBe('aborted');
  });
});

describe('provider pre-stream — safe-release failure is not a release [P1-2]', () => {
  const RATE = apiError(429, 'rate_limit_exceeded', new Headers({ 'retry-after': '2' }));

  it('a thrown unbilled settlement keeps the claim and falls back to unknown', async () => {
    const firestore = new FakeFirestore();
    const bucket = new FakeBucket();
    const hooks = new RecordingHooks({
      settleQuota: async (_reservation, outcome) => {
        if (outcome.kind === 'unbilled') throw new Error('ledger unavailable');
      },
    });
    const client = new FakeOpenAIClient({ kind: 'reject', error: RATE });
    const handler = createChatHandler(
      baseDeps({ firestore: asFirestore(firestore), bucket, hooks, openAIClients: clientRegistry(client) }),
    );
    const res = new FakeRes();
    await handler(asReq(makeReq({ idempotencyKey: KEY })), asRes(res));

    // A non-settleable release must NOT be reported as safe: upstream, claim kept.
    expect(res.statusCode).toBe(502);
    expect(res.json()).toEqual({ cause: 'upstream' });
    expect(firestore.store.has(DOC)).toBe(true);
    expect((firestore.store.get(DOC) as IdempotencyRecord).status).toBe('aborted');
    expect(hooks.calls).toContain('settleQuota:unbilled'); // attempted
    expect(hooks.calls).toContain('settleQuota:unknown'); // fallback
  });

  it('a deleteClaim that returns false is not a safe release (claim retained)', async () => {
    const firestore = new FakeFirestore();
    const bucket = new FakeBucket();
    const hooks = new RecordingHooks();
    const client = new FakeOpenAIClient({ kind: 'reject', error: RATE });
    // Transactions: claim(1), resolveProvider(2), deleteClaim(3). Flip the runId
    // right before deleteClaim so it cannot delete a claim it no longer owns.
    firestore.beforeTransaction = (index): void => {
      if (index !== 3) return;
      const rec = firestore.store.get(DOC) as IdempotencyRecord | undefined;
      if (rec) rec.runId = 'someone-else';
    };
    const handler = createChatHandler(
      baseDeps({ firestore: asFirestore(firestore), bucket, hooks, openAIClients: clientRegistry(client) }),
    );
    const res = new FakeRes();
    await handler(asReq(makeReq({ idempotencyKey: KEY })), asRes(res));

    expect(res.statusCode).toBe(502);
    expect(res.json()).toEqual({ cause: 'upstream' });
    expect(firestore.store.has(DOC)).toBe(true); // claim not deleted
  });
});
