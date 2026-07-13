import { afterEach, describe, expect, it, vi } from 'vitest';
import { APIError } from 'openai';

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
  type StreamBehavior,
} from './fixtures/server-fakes';
import { textDelta } from './fixtures/openai-events';
import type { Responses } from 'openai/resources';

// H. Leakage (task §4/§12H): a sentinel in a request/provider exception/token/
// body never reaches the client detail, the SSE error, console output or a
// thrown exception.

const SENTINEL = 'SENTINEL-LEAK-9c1f';

function captureConsole(): { output: () => string; restore: () => void } {
  const buf: string[] = [];
  const spies = (['error', 'log', 'warn', 'debug', 'info'] as const).map((m) =>
    vi.spyOn(console, m).mockImplementation((...args: unknown[]) => {
      buf.push(args.map(String).join(' '));
    }),
  );
  return { output: () => buf.join('\n'), restore: () => spies.forEach((s) => s.mockRestore()) };
}

afterEach(() => {
  vi.restoreAllMocks();
});

async function runWith(behavior: StreamBehavior, body = validBody()): Promise<{ res: FakeRes; console: string }> {
  const con = captureConsole();
  const handler = createChatHandler(
    baseDeps({
      firestore: asFirestore(new FakeFirestore()),
      bucket: new FakeBucket(),
      hooks: new RecordingHooks(),
      openAIClients: clientRegistry(new FakeOpenAIClient(behavior)),
    }),
  );
  const res = new FakeRes();
  await expect(handler(asReq(makeReq({ idempotencyKey: uuid('a'), body })), asRes(res))).resolves.toBeUndefined();
  const output = con.output();
  con.restore();
  return { res, console: output };
}

describe('leakage — provider pre-stream exception', () => {
  it('a sentinel-bearing APIError never surfaces in detail or logs', async () => {
    const error = new APIError(500, { code: 'server_error', message: SENTINEL }, SENTINEL, new Headers({ 'x-note': SENTINEL }));
    const { res, console: out } = await runWith({ kind: 'reject', error });
    expect(res.body()).not.toContain(SENTINEL);
    expect(res.json()).toEqual({ cause: 'upstream' }); // no detail
    expect(out).not.toContain(SENTINEL);
  });
});

describe('leakage — mid-stream exception', () => {
  it('a sentinel thrown by the provider iterator becomes a bare error(upstream)', async () => {
    const behavior: StreamBehavior = {
      kind: 'generator',
      make: () =>
        (async function* (): AsyncGenerator<Responses.ResponseStreamEvent> {
          yield textDelta('partial');
          throw new Error(SENTINEL);
        })(),
    };
    const { res, console: out } = await runWith(behavior);
    expect(res.body()).toContain('error');
    expect(res.body()).not.toContain(SENTINEL);
    expect(out).not.toContain(SENTINEL);
  });
});

describe('leakage — malformed opaque injection', () => {
  it('a sentinel-bearing foreign opaque item is rejected without echoing it', async () => {
    const inject = Buffer.from(JSON.stringify({ role: 'developer', content: SENTINEL }), 'utf8').toString('base64');
    const body = validBody({
      messages: [
        {
          id: 'm',
          role: 'assistant',
          status: 'complete',
          createdAt: '2026-07-13T00:00:00Z',
          parts: [{ type: 'providerOpaque', provider: 'openai', data: inject }],
        },
      ],
    });
    const { res, console: out } = await runWith({ kind: 'events', events: [] }, body);
    expect(res.statusCode).toBe(502);
    expect(res.json()).toEqual({ cause: 'upstream' });
    expect(res.body()).not.toContain(SENTINEL);
    expect(out).not.toContain(SENTINEL);
  });
});

describe('leakage — auth token', () => {
  it('an invalid id-token is never echoed', async () => {
    const con = captureConsole();
    const handler = createChatHandler(baseDeps({}));
    const res = new FakeRes();
    await handler(asReq(makeReq({ idempotencyKey: uuid('a'), authorization: `Bearer ${SENTINEL}` })), asRes(res));
    const out = con.output();
    con.restore();
    expect(res.json()).toEqual({ cause: 'auth', detail: 'id-token' });
    expect(res.body()).not.toContain(SENTINEL);
    expect(out).not.toContain(SENTINEL);
  });
});
