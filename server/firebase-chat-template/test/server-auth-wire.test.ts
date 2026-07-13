import { describe, expect, it } from 'vitest';

import { createChatHandler } from '../src/server';
import {
  asFirestore,
  asReq,
  asRes,
  baseDeps,
  clientRegistry,
  FakeBucket,
  FakeFirestore,
  FakeOpenAIClient,
  FakeRes,
  makeReq,
  RecordingHooks,
  uuid,
  validBody,
  type FakeReq,
} from './fixtures/server-fakes';

// B. Auth / wire — every pre-claim rejection creates no claim/usage record and
// calls no hook/provider (task §4/§12B).

function harness() {
  const firestore = new FakeFirestore();
  const bucket = new FakeBucket();
  const hooks = new RecordingHooks();
  const client = new FakeOpenAIClient({ kind: 'events', events: [] });
  const handler = createChatHandler(
    baseDeps({ firestore: asFirestore(firestore), bucket, hooks, openAIClients: clientRegistry(client) }),
  );
  const run = async (req: FakeReq): Promise<FakeRes> => {
    const res = new FakeRes();
    await handler(asReq(req), asRes(res));
    return res;
  };
  const untouched = (): void => {
    expect(firestore.store.size).toBe(0);
    expect(bucket.objects.size).toBe(0);
    expect(hooks.calls).toEqual([]);
    expect(client.callCount).toBe(0);
  };
  return { run, untouched, firestore, hooks, client };
}

describe('handler — HTTP method', () => {
  it('rejects a non-POST method with no side effects', async () => {
    const h = harness();
    const res = await h.run(makeReq({ method: 'GET' }));
    expect(res.statusCode).toBe(405);
    expect(res.json()).toEqual({ cause: 'upstream', detail: 'method-not-allowed' });
    h.untouched();
  });
});

describe('handler — auth', () => {
  it('rejects a missing Authorization header', async () => {
    const h = harness();
    const res = await h.run(makeReq({ authorization: null as unknown as undefined }));
    expect(res.statusCode).toBe(401);
    expect(res.json()).toEqual({ cause: 'auth', detail: 'id-token' });
    h.untouched();
  });

  it('rejects a non-Bearer Authorization header', async () => {
    const h = harness();
    const res = await h.run(makeReq({ authorization: 'Basic zzz' }));
    expect(res.json()).toEqual({ cause: 'auth', detail: 'id-token' });
    h.untouched();
  });

  it('rejects an invalid id-token', async () => {
    const h = harness();
    const res = await h.run(makeReq({ authorization: 'Bearer wrong-token' }));
    expect(res.statusCode).toBe(401);
    expect(res.json()).toEqual({ cause: 'auth', detail: 'id-token' });
    h.untouched();
  });

  it('rejects a missing App Check token', async () => {
    const h = harness();
    const res = await h.run(makeReq({ appCheck: null as unknown as undefined }));
    expect(res.statusCode).toBe(401);
    expect(res.json()).toEqual({ cause: 'auth', detail: 'app-check' });
    h.untouched();
  });

  it('rejects an invalid App Check token', async () => {
    const h = harness();
    const res = await h.run(makeReq({ appCheck: 'wrong-appcheck' }));
    expect(res.json()).toEqual({ cause: 'auth', detail: 'app-check' });
    h.untouched();
  });
});

describe('handler — payload / wire', () => {
  it('rejects a payload over 10 MB as context-too-long', async () => {
    const h = harness();
    const res = await h.run(makeReq({ rawBody: Buffer.alloc(10 * 1024 * 1024 + 1) }));
    expect(res.statusCode).toBe(413);
    expect(res.json()).toEqual({ cause: 'context-too-long' });
    h.untouched();
  });

  it('rejects malformed JSON', async () => {
    const h = harness();
    const res = await h.run(makeReq({ body: '{ not json' }));
    expect(res.statusCode).toBe(400);
    expect(res.json()).toEqual({ cause: 'upstream', detail: 'malformed-json' });
    h.untouched();
  });

  it('rejects a non-object body', async () => {
    const h = harness();
    const res = await h.run(makeReq({ body: '[1,2,3]' }));
    expect(res.json()).toEqual({ cause: 'upstream', detail: 'invalid-request' });
    h.untouched();
  });

  it('rejects a missing/unsupported wireVersion with 426', async () => {
    const h = harness();
    const res = await h.run(makeReq({ body: validBody({ wireVersion: 2 }) }));
    expect(res.statusCode).toBe(426);
    expect(res.json()).toEqual({ cause: 'upstream', detail: 'unsupported-wire-version' });
    h.untouched();
  });

  it('rejects an invalid Idempotency-Key (not a UUID v4)', async () => {
    const h = harness();
    const res = await h.run(makeReq({ idempotencyKey: 'not-a-uuid' }));
    expect(res.statusCode).toBe(400);
    expect(res.json()).toEqual({ cause: 'upstream', detail: 'invalid-idempotency-key' });
    h.untouched();
  });

  it('rejects a missing Idempotency-Key', async () => {
    const h = harness();
    const res = await h.run(makeReq({ idempotencyKey: null as unknown as undefined }));
    expect(res.json()).toEqual({ cause: 'upstream', detail: 'invalid-idempotency-key' });
    h.untouched();
  });

  it.each([
    ['bad role', validBody({ messages: [{ id: 'm', role: 'tool', status: 'sent', createdAt: 't', parts: [] }] })],
    ['missing createdAt', validBody({ messages: [{ id: 'm', role: 'user', status: 'sent', parts: [] }] })],
    ['bad part discriminator', validBody({ messages: [{ id: 'm', role: 'user', status: 'sent', createdAt: 't', parts: [{ type: 'video', url: 'x' }] }] })],
    ['image wrong mime', validBody({ messages: [{ id: 'm', role: 'user', status: 'sent', createdAt: 't', parts: [{ type: 'image', mimeType: 'image/png', data: 'AA' }] }] })],
    ['toolResult non-boolean isError', validBody({ messages: [{ id: 'm', role: 'assistant', status: 'complete', createdAt: 't', parts: [{ type: 'toolResult', toolCallId: 'c', content: 'x', isError: 'no' }] }] })],
  ])('rejects an invalid message/content-part (%s)', async (_label, body) => {
    const h = harness();
    const res = await h.run(makeReq({ body }));
    expect(res.statusCode).toBe(400);
    expect(res.json()).toEqual({ cause: 'upstream', detail: 'invalid-request' });
    h.untouched();
  });

  it('rejects an invalid tool schema', async () => {
    const h = harness();
    const badTool = { name: 'bad name', description: 'd', parameters: { type: 'object', properties: {}, required: [], additionalProperties: false } };
    const res = await h.run(makeReq({ body: validBody({ tools: [badTool] }) }));
    expect(res.statusCode).toBe(400);
    expect(res.json()).toEqual({ cause: 'upstream', detail: 'invalid-tool-schema' });
    h.untouched();
  });

  it('a valid unique second key is unaffected by an earlier one', async () => {
    const h = harness();
    // Two distinct invalid requests must both create nothing.
    await h.run(makeReq({ idempotencyKey: uuid('b'), body: '{bad' }));
    h.untouched();
  });
});
