import { describe, expect, it } from 'vitest';

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
  parseSse,
  RecordingHooks,
  uuid,
  type BucketHooks,
  type StreamBehavior,
} from './fixtures/server-fakes';
import {
  makeReasoningItem,
  makeResponse,
  makeUsage,
  reasoningItemDone,
  responseCompleted,
  responseFailed,
  textDelta,
} from './fixtures/openai-events';
import type { Responses } from 'openai/resources';

// F. OpenAI/SSE lifecycle (task §11/§12F): ordering, terminal commit order,
// object/commit failure, and cancellation.

const KEY = uuid('a');
const DOC = docPath(KEY);

function harness(behavior: StreamBehavior, bucketHooks?: BucketHooks) {
  const firestore = new FakeFirestore();
  const bucket = new FakeBucket(bucketHooks);
  const hooks = new RecordingHooks();
  const client = new FakeOpenAIClient(behavior);
  const handler = createChatHandler(
    baseDeps({ firestore: asFirestore(firestore), bucket, hooks, openAIClients: clientRegistry(client) }),
  );
  const req = makeReq({ idempotencyKey: KEY });
  const res = new FakeRes();
  return { handler, req, res, firestore, bucket, hooks, client };
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

describe('SSE — ordering and passthrough', () => {
  it('preserves delta/provider_state order without re-batching or reordering', async () => {
    const h = harness({
      kind: 'events',
      events: [
        textDelta('a'),
        reasoningItemDone(makeReasoningItem({ encrypted_content: 'ENC' })),
        textDelta('b'),
        responseCompleted(makeResponse({ usage: makeUsage(2, 2) })),
      ],
    });
    await h.handler(asReq(h.req), asRes(h.res));
    const events = parseSse(h.res.body());
    expect(events.map((e) => e.event)).toEqual(['delta', 'provider_state', 'delta', 'done']);
    expect(events[0]).toEqual({ event: 'delta', data: { text: 'a' } });
    expect((events[1]!.data as { provider: string }).provider).toBe('openai');
    expect(events[2]).toEqual({ event: 'delta', data: { text: 'b' } });
  });
});

describe('SSE — object finalise/verify failure never emits a success terminal', () => {
  it('a failed object write aborts, settles unknown, and emits only error(upstream)', async () => {
    const h = harness(
      { kind: 'events', events: [textDelta('hi'), responseCompleted(makeResponse({ usage: makeUsage(1, 1) }))] },
      {
        onSave: () => {
          throw new Error('gcs write failed');
        },
      },
    );
    await h.handler(asReq(h.req), asRes(h.res));
    const events = parseSse(h.res.body());
    expect(events.map((e) => e.event)).toEqual(['delta', 'error']);
    expect(events.at(-1)).toEqual({ event: 'error', data: { cause: 'upstream' } });
    expect((h.firestore.store.get(DOC) as IdempotencyRecord).status).toBe('aborted');
    expect(h.hooks.settlements.at(-1)!.outcome.kind).toBe('unknown');
  });

  it('a read-back verification mismatch aborts and emits no done', async () => {
    const h = harness(
      { kind: 'events', events: [textDelta('hi'), responseCompleted(makeResponse({ usage: makeUsage(1, 1) }))] },
      { onDownload: () => Buffer.from('tampered', 'utf8') },
    );
    await h.handler(asReq(h.req), asRes(h.res));
    const events = parseSse(h.res.body());
    expect(events.some((e) => e.event === 'done')).toBe(false);
    expect(events.at(-1)!.event).toBe('error');
    expect((h.firestore.store.get(DOC) as IdempotencyRecord).status).toBe('aborted');
  });
});

describe('SSE — Firestore complete-commit failure never emits a success terminal', () => {
  it('a lost-ownership commit aborts and emits no done', async () => {
    const firestore = new FakeFirestore();
    // After the object is durably written, ownership is lost (runId changes),
    // so the `running → complete` transition must fail closed.
    const bucketHooks: BucketHooks = {
      onSave: () => {
        const rec = firestore.store.get(DOC) as IdempotencyRecord | undefined;
        if (rec) rec.runId = 'someone-else';
      },
    };
    const bucket = new FakeBucket(bucketHooks);
    const hooks = new RecordingHooks();
    const client = new FakeOpenAIClient({
      kind: 'events',
      events: [textDelta('hi'), responseCompleted(makeResponse({ usage: makeUsage(1, 1) }))],
    });
    const handler = createChatHandler(
      baseDeps({ firestore: asFirestore(firestore), bucket, hooks, openAIClients: clientRegistry(client) }),
    );
    const res = new FakeRes();
    await handler(asReq(makeReq({ idempotencyKey: KEY })), asRes(res));
    const events = parseSse(res.body());
    expect(events.some((e) => e.event === 'done')).toBe(false);
    expect(events.at(-1)!.event).toBe('error');
  });
});

describe('SSE — mid-stream failure', () => {
  it('aborts, settles unknown, and delivers error(upstream) in-stream (no object)', async () => {
    const h = harness({
      kind: 'events',
      events: [textDelta('x'), responseFailed(makeResponse({ status: 'failed' }))],
    });
    await h.handler(asReq(h.req), asRes(h.res));
    const events = parseSse(h.res.body());
    expect(events.map((e) => e.event)).toEqual(['delta', 'error']);
    expect(events.at(-1)).toEqual({ event: 'error', data: { cause: 'upstream' } });
    expect((h.firestore.store.get(DOC) as IdempotencyRecord).status).toBe('aborted');
    expect(h.hooks.settlements.at(-1)!.outcome.kind).toBe('unknown');
    expect(h.bucket.objects.size).toBe(0); // aborted mid-stream writes no replay object
  });
});

describe('SSE — cancellation', () => {
  it('an observed disconnect aborts upstream and settles unknown', async () => {
    let aborted = false;
    const gate = new Promise<void>(() => {
      /* never resolves; released only by abort */
    });
    const behavior: StreamBehavior = {
      kind: 'generator',
      make: (signal: AbortSignal) =>
        (async function* (): AsyncGenerator<Responses.ResponseStreamEvent> {
          yield textDelta('partial');
          await new Promise<void>((_resolve, reject) => {
            signal.addEventListener(
              'abort',
              () => {
                aborted = true;
                reject(new Error('aborted'));
              },
              { once: true },
            );
            void gate;
          });
          yield responseCompleted(makeResponse({ usage: makeUsage(1, 1) }));
        })(),
    };
    const h = harness(behavior);
    const done = h.handler(asReq(h.req), asRes(h.res));
    await sleep(20); // first delta streamed; generator blocks awaiting the signal
    h.req.emitClose(); // observed disconnect
    await done;

    expect(aborted).toBe(true);
    const events = parseSse(h.res.body());
    expect(events.map((e) => e.event)).toEqual(['delta']); // partial kept, no terminal to a gone client
    expect((h.firestore.store.get(DOC) as IdempotencyRecord).status).toBe('aborted');
    expect(h.hooks.settlements.at(-1)!.outcome.kind).toBe('unknown');
  });
});
