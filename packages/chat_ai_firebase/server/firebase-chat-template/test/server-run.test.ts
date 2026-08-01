import { afterEach, describe, expect, it, vi } from 'vitest';

import { createChatHandler } from '../src/server';
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
  OPENAI_TIER,
  parseSse,
  RecordingHooks,
  uuid,
  type StreamBehavior,
} from './fixtures/server-fakes';
import {
  functionCallAdded,
  functionCallDone,
  makeResponse,
  makeUsage,
  responseCompleted,
  responseFailed,
  textDelta,
} from './fixtures/openai-events';
import type { Responses } from 'openai/resources';

// E (admission/settlement) + F slice (translator reuse, success commit order).

function deferred<T>(): { promise: Promise<T>; resolve: (v: T) => void } {
  let resolve!: (v: T) => void;
  const promise = new Promise<T>((r) => (resolve = r));
  return { promise, resolve };
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

function ownerHarness(behavior: StreamBehavior, hookOverrides?: HookOverrides) {
  const firestore = new FakeFirestore();
  const bucket = new FakeBucket();
  const hooks = new RecordingHooks(hookOverrides);
  const client = new FakeOpenAIClient(behavior);
  const handler = createChatHandler(
    baseDeps({ firestore: asFirestore(firestore), bucket, hooks, openAIClients: clientRegistry(client) }),
  );
  const run = async (key = uuid('a')): Promise<FakeRes> => {
    const res = new FakeRes();
    await handler(asReq(makeReq({ idempotencyKey: key })), asRes(res));
    return res;
  };
  return { run, firestore, bucket, hooks, client };
}

const okEvents: StreamBehavior = {
  kind: 'events',
  events: [textDelta('He'), textDelta('llo'), responseCompleted(makeResponse({ usage: makeUsage(3, 4) }))],
};

describe('owner — successful done', () => {
  it('runs the fixed admission order then settles billed with exact usage', async () => {
    const h = ownerHarness(okEvents);
    await h.run();
    expect(h.hooks.calls).toEqual([
      'checkEntitlement',
      'checkRateLimit',
      'reserveQuota:createOrGet',
      'settleQuota:billed',
    ]);
    expect(h.hooks.settlements.at(-1)!.outcome).toEqual({ kind: 'billed', usage: { inputTokens: 3, outputTokens: 4 } });
  });

  it('reuses the request translator (exact typed Responses request)', async () => {
    const h = ownerHarness(okEvents);
    await h.run();
    const sent = h.client.lastRequest!;
    expect(sent.model).toBe(OPENAI_TIER.model);
    expect(sent.stream).toBe(true);
    expect(sent.store).toBe(false);
    expect(sent.include).toEqual(['reasoning.encrypted_content']);
    expect(sent.max_output_tokens).toBe(OPENAI_TIER.maxOutputTokens);
    expect(sent.parallel_tool_calls).toBe(false);
    // A tier without reasoningEffort/compactThreshold keeps the previous shape.
    expect('reasoning' in sent).toBe(false);
    expect('context_management' in sent).toBe(false);
  });

  it('a tier reasoningEffort reaches the actual OpenAI request', async () => {
    const h = ownerHarness(okEvents, {
      checkEntitlement: async () => ({ kind: 'allowed', tier: { ...OPENAI_TIER, reasoningEffort: 'high' } }),
    });
    await h.run();
    expect(h.client.lastRequest!.reasoning).toEqual({ effort: 'high' });
  });

  it('a tier compactThreshold reaches the actual OpenAI request', async () => {
    const h = ownerHarness(okEvents, {
      checkEntitlement: async () => ({ kind: 'allowed', tier: { ...OPENAI_TIER, compactThreshold: 200_000 } }),
    });
    await h.run();
    expect(h.client.lastRequest!.context_management).toEqual([
      { type: 'compaction', compact_threshold: 200_000 },
    ]);
  });

  it('reuses the stream translator, preserving delta order, done last, no re-batch', async () => {
    const h = ownerHarness(okEvents);
    const res = await h.run();
    expect(res.statusCode).toBe(200);
    expect(parseSse(res.body())).toEqual([
      { event: 'delta', data: { text: 'He' } },
      { event: 'delta', data: { text: 'llo' } },
      { event: 'done', data: { usage: { inputTokens: 3, outputTokens: 4, usageRaw: makeUsage(3, 4) } } },
    ]);
  });

  it('provider is called exactly once', async () => {
    const h = ownerHarness(okEvents);
    await h.run();
    expect(h.client.callCount).toBe(1);
  });

  it('writes a verified replay object and a complete record with matching facts', async () => {
    const h = ownerHarness(okEvents);
    const res = await h.run(uuid('c'));
    const record = h.firestore.store.get(docPath(uuid('c'))) as Record<string, unknown>;
    expect(record.status).toBe('complete');
    const path = record.outcomeObjectPath as string;
    expect(path).toBe(objectPath(uuid('c'), record.runId as string));
    const stored = h.bucket.objects.get(path)!;
    expect(record.outcomeBytes).toBe(stored.data.length);
    expect(record.outcomeSha256).toBe(stored.metadata.sha256);
    expect(record.expiresAt).toBeDefined();
    // The object holds exactly the streamed frames (no keepalive comment).
    expect(stored.data.toString('utf8')).toBe(res.body());
    expect(stored.data.toString('utf8')).not.toContain(': ping');
  });
});

describe('owner — successful tool_call terminal', () => {
  it('emits a single tool_call terminal (no done) and settles billed', async () => {
    const h = ownerHarness({
      kind: 'events',
      events: [
        functionCallAdded({ outputIndex: 0, callId: 'call_1', name: 'searchNotes' }),
        functionCallDone({ outputIndex: 0, callId: 'call_1', name: 'searchNotes', arguments: '{"period":"2026-06"}' }),
        responseCompleted(makeResponse({ usage: makeUsage(5, 1) })),
      ],
    });
    const res = await h.run();
    const events = parseSse(res.body());
    expect(events).toHaveLength(1);
    expect(events[0]).toEqual({
      event: 'tool_call',
      data: {
        id: 'call_1',
        name: 'searchNotes',
        args: { period: '2026-06' },
        usage: { inputTokens: 5, outputTokens: 1, usageRaw: makeUsage(5, 1) },
      },
    });
    expect(h.hooks.settlements.at(-1)!.outcome.kind).toBe('billed');
  });
});

describe('owner — admission denials (safe release, unbilled)', () => {
  it('entitlement denied → 403 entitlement, claim released, no provider call', async () => {
    const h = ownerHarness(okEvents, { checkEntitlement: async () => ({ kind: 'denied' }) });
    const res = await h.run(uuid('e'));
    expect(res.statusCode).toBe(403);
    expect(res.json()).toEqual({ cause: 'entitlement' });
    expect(h.client.callCount).toBe(0);
    expect(h.firestore.store.has(docPath(uuid('e')))).toBe(false); // released
    expect(h.hooks.calls).toEqual(['checkEntitlement']);
  });

  it('rate denied → 429 rate with Retry-After, released unbilled', async () => {
    const h = ownerHarness(okEvents, { checkRateLimit: async () => ({ kind: 'denied', retryAfterMs: 3000 }) });
    const res = await h.run(uuid('f'));
    expect(res.statusCode).toBe(429);
    expect(res.json()).toEqual({ cause: 'rate' });
    expect(res.headers['retry-after']).toBe('3');
    expect(h.hooks.settlements).toEqual([]); // no reservation existed yet
    expect(h.client.callCount).toBe(0);
  });

  it('quota reservation denied → 429 quota, released', async () => {
    const h = ownerHarness(okEvents, { reserveQuota: async () => ({ kind: 'denied' }) });
    const res = await h.run(uuid('9'));
    expect(res.statusCode).toBe(429);
    expect(res.json()).toEqual({ cause: 'quota' });
    expect(h.client.callCount).toBe(0);
  });

  it('a hook exception → 502 upstream (safe release)', async () => {
    const h = ownerHarness(okEvents, {
      checkEntitlement: async () => {
        throw new Error('boom');
      },
    });
    const res = await h.run();
    expect(res.statusCode).toBe(502);
    expect(res.json()).toEqual({ cause: 'upstream' });
    expect(h.client.callCount).toBe(0);
  });

  it('reserves quota with createOrGet before dispatch and settles the same attempt', async () => {
    const h = ownerHarness(okEvents);
    await h.run(uuid('7'));
    expect(h.hooks.reserveRequests).toEqual([
      { kind: 'createOrGet', uid: 'user-1', attemptKey: uuid('7'), botId: 'premium', tier: OPENAI_TIER },
    ]);
  });
});

describe('owner — release-object finalise failure aborts (no claim deletion)', () => {
  it('a safe-release whose release object cannot be finalised leaves the attempt aborted', async () => {
    const firestore = new FakeFirestore();
    const bucket = new FakeBucket({
      onSave: () => {
        throw new Error('gcs unavailable');
      },
    });
    const hooks = new RecordingHooks({ checkEntitlement: async () => ({ kind: 'denied' }) });
    const client = new FakeOpenAIClient(okEvents);
    const handler = createChatHandler(
      baseDeps({ firestore: asFirestore(firestore), bucket, hooks, openAIClients: clientRegistry(client) }),
    );
    const res = new FakeRes();
    const key = uuid('d');
    await handler(asReq(makeReq({ idempotencyKey: key })), asRes(res));
    // The claim is NOT deleted; it is aborted instead, and the owner returns upstream.
    expect(res.statusCode).toBe(502);
    expect(res.json()).toEqual({ cause: 'upstream' });
    const record = firestore.store.get(docPath(key)) as Record<string, unknown>;
    expect(record).toBeDefined();
    expect(record.status).toBe('aborted');
    expect(client.callCount).toBe(0);
  });
});

describe('owner — anthropic tier fails closed', () => {
  it('an anthropic tier never calls OpenAI and returns upstream (safe release)', async () => {
    const h = ownerHarness(okEvents, {
      checkEntitlement: async () => ({ kind: 'allowed', tier: { id: 'a', provider: 'anthropic', model: 'claude', maxOutputTokens: 100 } }),
    });
    const res = await h.run();
    expect(res.statusCode).toBe(502);
    expect(res.json()).toEqual({ cause: 'upstream' });
    expect(h.client.callCount).toBe(0);
  });
});

// --- P1-4 disconnect + P1-5 settlement regressions ---------------------------

function gatedHarness(makeGen: (signal: AbortSignal) => AsyncGenerator<Responses.ResponseStreamEvent>) {
  const firestore = new FakeFirestore();
  const bucket = new FakeBucket();
  const hooks = new RecordingHooks();
  const client = new FakeOpenAIClient({ kind: 'generator', make: makeGen });
  const handler = createChatHandler(
    baseDeps({ firestore: asFirestore(firestore), bucket, hooks, openAIClients: clientRegistry(client) }),
  );
  const req = makeReq({ idempotencyKey: uuid('a') });
  const res = new FakeRes();
  return { firestore, bucket, hooks, client, req, res, run: () => handler(asReq(req), asRes(res)) };
}

describe('owner — disconnect cancels provider [P1-4]', () => {
  it('an observed response close aborts upstream and settles unknown', async () => {
    let captured: AbortSignal | undefined;
    let aborted = false;
    const h = gatedHarness((signal) => {
      captured = signal;
      return (async function* (): AsyncGenerator<Responses.ResponseStreamEvent> {
        yield textDelta('partial');
        await new Promise<void>((_r, reject) =>
          signal.addEventListener('abort', () => {
            aborted = true;
            reject(new Error('aborted'));
          }, { once: true }),
        );
        yield responseCompleted(makeResponse({ usage: makeUsage(1, 1) }));
      })();
    });
    const done = h.run();
    await sleep(20); // 'partial' streamed; generator blocks on the signal
    h.res.emit('close'); // observed response close (not a request close)
    await done;

    expect(aborted).toBe(true);
    expect(captured!.aborted).toBe(true);
    expect(parseSse(h.res.body()).map((e) => e.event)).toEqual(['delta']);
    expect((h.firestore.store.get(docPath(uuid('a'))) as Record<string, unknown>).status).toBe('aborted');
    expect(h.hooks.settlements.at(-1)!.outcome.kind).toBe('unknown');
  });

  it('a failed write stops provider consumption and aborts + settles unknown', async () => {
    const gate = deferred<void>();
    let captured: AbortSignal | undefined;
    let pulledAfterFailure = false;
    const h = gatedHarness((signal) => {
      captured = signal;
      return (async function* (): AsyncGenerator<Responses.ResponseStreamEvent> {
        yield textDelta('one');
        await gate.promise;
        yield textDelta('two'); // this write fails on a dead connection
        pulledAfterFailure = true; // must never run — consumption stopped
        yield responseCompleted(makeResponse({ usage: makeUsage(1, 1) }));
      })();
    });
    const done = h.run();
    await sleep(20); // 'one' streamed
    h.res.failWrite = true; // connection now dead
    gate.resolve();
    await done;

    expect(captured!.aborted).toBe(true); // failed write aborted the provider
    expect(pulledAfterFailure).toBe(false); // consumption stopped after the failure
    expect((h.firestore.store.get(docPath(uuid('a'))) as Record<string, unknown>).status).toBe('aborted');
    expect(h.hooks.settlements.at(-1)!.outcome.kind).toBe('unknown');
  });
});

describe('owner — error/commit settlement [P1-5]', () => {
  it('a mid-stream error carrying exact usage settles billed (not unknown)', async () => {
    const h = ownerHarness({
      kind: 'events',
      events: [textDelta('x'), responseFailed(makeResponse({ status: 'failed', usage: makeUsage(3, 2) }))],
    });
    const res = await h.run(uuid('ab'));
    expect(h.hooks.settlements.at(-1)!.outcome).toEqual({ kind: 'billed', usage: { inputTokens: 3, outputTokens: 2 } });
    expect((h.firestore.store.get(docPath(uuid('ab'))) as Record<string, unknown>).status).toBe('aborted');
    expect(parseSse(res.body()).at(-1)!.event).toBe('error');
  });

  it('a complete-commit failure after a successful billed is NOT downgraded to unknown', async () => {
    const firestore = new FakeFirestore();
    // Ownership is lost after the object is durably written, so `running →
    // complete` fails — but the already-successful billed must not be re-settled.
    const bucket = new FakeBucket({
      onSave: () => {
        const rec = firestore.store.get(docPath(uuid('a'))) as Record<string, unknown> | undefined;
        if (rec) rec.runId = 'someone-else';
      },
    });
    const hooks = new RecordingHooks();
    const client = new FakeOpenAIClient(okEvents);
    const handler = createChatHandler(
      baseDeps({ firestore: asFirestore(firestore), bucket, hooks, openAIClients: clientRegistry(client) }),
    );
    const res = new FakeRes();
    await handler(asReq(makeReq({ idempotencyKey: uuid('a') })), asRes(res));

    expect(hooks.calls.filter((c) => c.startsWith('settleQuota'))).toEqual(['settleQuota:billed']);
    const events = parseSse(res.body());
    expect(events.some((e) => e.event === 'done')).toBe(false);
    expect(events.at(-1)!.event).toBe('error');
  });

  it('a commitComplete transaction that THROWS after billed does not downgrade [defect 1]', async () => {
    const h = ownerHarness(okEvents);
    // Transactions: claim(1), resolveProvider(2), commitComplete(3). Make the
    // complete commit throw — it must land in the single post-billed failure path.
    h.firestore.beforeTransaction = (index): void => {
      if (index === 3) throw new Error('firestore commit failed');
    };
    const res = await h.run(uuid('a'));

    expect(h.hooks.settlements.map((s) => s.outcome.kind)).toEqual(['billed']); // no unknown
    const events = parseSse(res.body());
    expect(events.some((e) => e.event === 'done')).toBe(false);
    expect(events.at(-1)).toEqual({ event: 'error', data: { cause: 'upstream' } });
    expect((h.firestore.store.get(docPath(uuid('a'))) as Record<string, unknown>).status).toBe('aborted');
  });
});

describe('owner — request aborted event cancels provider [defect 2]', () => {
  it('a request "aborted" event aborts upstream and settles unknown', async () => {
    let captured: AbortSignal | undefined;
    let aborted = false;
    const h = gatedHarness((signal) => {
      captured = signal;
      return (async function* (): AsyncGenerator<Responses.ResponseStreamEvent> {
        yield textDelta('partial');
        await new Promise<void>((_r, reject) =>
          signal.addEventListener('abort', () => {
            aborted = true;
            reject(new Error('aborted'));
          }, { once: true }),
        );
        yield responseCompleted(makeResponse({ usage: makeUsage(1, 1) }));
      })();
    });
    const done = h.run();
    await sleep(20);
    h.req.emit('aborted'); // http.IncomingMessage 'aborted' (distinct from close)
    await done;

    expect(aborted).toBe(true);
    expect(captured!.aborted).toBe(true);
    expect(parseSse(h.res.body()).map((e) => e.event)).toEqual(['delta']);
    expect((h.firestore.store.get(docPath(uuid('a'))) as Record<string, unknown>).status).toBe('aborted');
    expect(h.hooks.settlements.at(-1)!.outcome.kind).toBe('unknown');
  });
});

describe('owner — failed keepalive aborts provider [defect 2]', () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it('a keepalive write that throws at 15 s fires disconnect and aborts without a next event', async () => {
    vi.useFakeTimers();
    let captured: AbortSignal | undefined;
    let yieldedAfterBlock = false;
    const firestore = new FakeFirestore();
    const hooks = new RecordingHooks();
    const client = new FakeOpenAIClient({
      kind: 'generator',
      make: (signal) => {
        captured = signal;
        return (async function* (): AsyncGenerator<Responses.ResponseStreamEvent> {
          // No frames: the connection is idle, so the 15 s keepalive fires.
          await new Promise<void>((_r, reject) =>
            signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true }),
          );
          yieldedAfterBlock = true;
          yield responseCompleted(makeResponse({ usage: makeUsage(1, 1) }));
        })();
      },
    });
    const handler = createChatHandler(
      baseDeps({ firestore: asFirestore(firestore), bucket: new FakeBucket(), hooks, openAIClients: clientRegistry(client) }),
    );
    const res = new FakeRes();
    res.failWrite = true; // the keepalive write will throw on the dead connection

    const done = handler(asReq(makeReq({ idempotencyKey: uuid('a') })), asRes(res));
    await vi.advanceTimersByTimeAsync(15_000); // reach the keepalive tick

    // The abort came straight from the failed keepalive, not a provider event.
    expect(captured!.aborted).toBe(true);
    expect(yieldedAfterBlock).toBe(false);

    await done;
    expect((firestore.store.get(docPath(uuid('a'))) as Record<string, unknown>).status).toBe('aborted');
    expect(hooks.settlements.at(-1)!.outcome.kind).toBe('unknown');
  });
});

describe('owner — durable terminal ledger forbids re-dispatch [P1 410]', () => {
  it('reserveQuota terminal → pre-stream 410 attempt-terminal; no provider, no settle, aborted tombstone, no replay object', async () => {
    const firestore = new FakeFirestore();
    const bucket = new FakeBucket();
    const hooks = new RecordingHooks({ reserveQuota: async () => ({ kind: 'terminal' }) });
    const client = new FakeOpenAIClient(okEvents);
    const handler = createChatHandler(
      baseDeps({ firestore: asFirestore(firestore), bucket, hooks, openAIClients: clientRegistry(client) }),
    );
    const key = uuid('a');
    const res = new FakeRes();
    await handler(asReq(makeReq({ idempotencyKey: key })), asRes(res));

    expect(res.statusCode).toBe(410);
    expect(res.json()).toEqual({ cause: 'upstream', detail: 'attempt-terminal' });
    expect(client.callCount).toBe(0); // provider never dispatched
    expect(hooks.calls.some((c) => c.startsWith('settleQuota'))).toBe(false); // settlement not called
    // The provisional claim is an aborted tombstone (not safe-released/deleted).
    expect((firestore.store.get(docPath(key)) as Record<string, unknown>).status).toBe('aborted');
    expect(bucket.objects.size).toBe(0); // no release/replay object created
  });

  it('a repeat under the same key still never dispatches (the tombstone 410s)', async () => {
    const firestore = new FakeFirestore();
    const bucket = new FakeBucket();
    const hooks = new RecordingHooks({ reserveQuota: async () => ({ kind: 'terminal' }) });
    const client = new FakeOpenAIClient(okEvents);
    const handler = createChatHandler(
      baseDeps({ firestore: asFirestore(firestore), bucket, hooks, openAIClients: clientRegistry(client) }),
    );
    const key = uuid('a');

    const first = new FakeRes();
    await handler(asReq(makeReq({ idempotencyKey: key })), asRes(first));
    const second = new FakeRes();
    await handler(asReq(makeReq({ idempotencyKey: key })), asRes(second));

    expect(first.statusCode).toBe(410);
    expect(second.statusCode).toBe(410); // second hit the aborted tombstone
    expect(client.callCount).toBe(0); // no provider dispatch on either request
  });

  it('a throwing response.end while emitting the 410 never triggers a safe release [P2]', async () => {
    const firestore = new FakeFirestore();
    const bucket = new FakeBucket();
    const hooks = new RecordingHooks({ reserveQuota: async () => ({ kind: 'terminal' }) });
    const client = new FakeOpenAIClient(okEvents);
    const handler = createChatHandler(
      baseDeps({ firestore: asFirestore(firestore), bucket, hooks, openAIClients: clientRegistry(client) }),
    );
    const key = uuid('a');
    const res = new FakeRes();
    // The 410 emit fails: response.end throws AFTER headersSent is fixed. In the
    // pre-fix code this threw inside the reserveQuota try/catch and fell through to
    // ownerAdmissionExit → safeRelease, wrongly re-releasing a durable-terminal key
    // (a release object would appear). The refactor keeps result handling outside
    // that catch, so no safe release runs.
    res.end = ((): void => {
      res.headersSent = true;
      throw new Error('socket closed');
    }) as typeof res.end;

    await expect(handler(asReq(makeReq({ idempotencyKey: key })), asRes(res))).resolves.toBeUndefined();

    // No safe release: no release/replay object written, no settlement called.
    expect(bucket.objects.size).toBe(0);
    expect(hooks.calls.some((c) => c.startsWith('settleQuota'))).toBe(false);
    // Provider never dispatched; the provisional claim is an aborted tombstone.
    expect(client.callCount).toBe(0);
    expect((firestore.store.get(docPath(key)) as Record<string, unknown>).status).toBe('aborted');
  });
});
