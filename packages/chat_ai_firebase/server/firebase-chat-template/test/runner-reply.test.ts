// The connection-independent reply runner: its dependency boundary, the
// app-owned billable leg boundary, the server-side tool loop, cancellation at
// every awaited callback, sink failures and usage aggregation. Only the real
// risks — the provider translators themselves are covered by their own suites.
//
// This file deliberately imports NO Firebase/HTTP fixture: the runner must be
// usable from a detached worker with nothing but the OpenAI SDK.

import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { describe, expect, it } from 'vitest';
import type OpenAI from 'openai';
import type { Responses } from 'openai/resources';

import {
  ChatReplyConfigurationError,
  runChatReply,
  type ChatReplyEventDelivery,
  type ChatReplyLegContext,
  type ChatReplyResult,
  type RunChatReplyOptions,
} from '../src/runner';
import type { ChatRequest, WireTool } from '../src/core/wire';
import type { ResolvedOpenAITier } from '../src/providers/openai/request';
import {
  functionCallDone,
  makeResponse,
  makeUsage,
  responseCompleted,
  responseFailed,
  textDelta,
} from './fixtures/openai-events';

const TIER: ResolvedOpenAITier = { model: 'gpt-5', maxOutputTokens: 4096 };
const REPLY_ID = 'reply-1';

function key(seed: string): string {
  const head = seed.padEnd(2, '0').slice(0, 2);
  return `${head}bcdef0-1234-4567-89ab-cdef01234567`;
}

/** The caller-owned key of leg 0 — persisted before the runner is entered. */
const FIRST_KEY = key('0');

function request(overrides: Partial<ChatRequest> = {}): ChatRequest {
  return {
    wireVersion: 1,
    botId: 'premium',
    system: 'be kind',
    messages: [
      {
        id: 'u-1',
        role: 'user',
        parts: [{ type: 'text', text: 'hi' }],
        status: 'sent',
        attemptKey: key('u'),
        createdAt: '2026-07-10T09:00:00.000Z',
      },
    ],
    ...overrides,
  };
}

const SEARCH_TOOL: WireTool = {
  name: 'search',
  description: 'search notes',
  parameters: {
    type: 'object',
    properties: { q: { type: 'string' } },
    required: ['q'],
    additionalProperties: false,
  },
};

/** One scripted provider response per leg. */
type LegScript =
  | { kind: 'events'; events: Responses.ResponseStreamEvent[] }
  | { kind: 'reject'; error: unknown }
  | {
      kind: 'generator';
      make: (signal: AbortSignal | undefined) => AsyncGenerator<Responses.ResponseStreamEvent>;
    };

/** A minimal OpenAI stand-in: no network, no key, one script per leg. */
class FakeClient {
  readonly requests: Responses.ResponseCreateParamsStreaming[] = [];
  readonly signals: (AbortSignal | undefined)[] = [];

  constructor(
    private readonly script: LegScript[],
    readonly maxRetries = 0,
  ) {}

  readonly responses = {
    create: async (
      body: Responses.ResponseCreateParamsStreaming,
      opts?: { signal?: AbortSignal },
    ): Promise<AsyncIterable<Responses.ResponseStreamEvent>> => {
      this.requests.push(body);
      this.signals.push(opts?.signal);
      const leg = this.script.shift();
      if (leg === undefined) throw new Error('no scripted leg left');
      if (leg.kind === 'reject') throw leg.error;
      if (leg.kind === 'generator') return leg.make(opts?.signal);
      const events = leg.events;
      return (async function* () {
        for (const event of events) yield event;
      })();
    },
  };
}

function asClient(client: FakeClient): OpenAI {
  return client as unknown as OpenAI;
}

/** A finished text reply with exact usage. */
function textLeg(text: string, inputTokens = 10, outputTokens = 5): LegScript {
  return {
    kind: 'events',
    events: [
      textDelta(text),
      responseCompleted(makeResponse({ usage: makeUsage(inputTokens, outputTokens) })),
    ],
  };
}

/** A finished tool-call leg with exact usage. */
function toolLeg(callId: string, name: string, args: string, tokens = 3): LegScript {
  return {
    kind: 'events',
    events: [
      functionCallDone({ outputIndex: 0, callId, name, arguments: args }),
      responseCompleted(makeResponse({ usage: makeUsage(tokens, tokens) })),
    ],
  };
}

function run(
  client: FakeClient,
  overrides: Partial<RunChatReplyOptions> = {},
): Promise<ChatReplyResult> {
  // Leg 0 rides FIRST_KEY; onLegStart only ever answers for the legs after it.
  let issued = 1;
  return runChatReply({
    replyId: REPLY_ID,
    request: request(),
    client: asClient(client),
    tier: TIER,
    firstAttemptKey: FIRST_KEY,
    onLegStart: () => ({ attemptKey: key(String(issued++)) }),
    ...overrides,
  });
}

describe('dependency boundary', () => {
  it('the runner import graph carries no HTTP, Firebase, GCS or smoke dependency', () => {
    const forbidden = [
      'firebase-admin',
      'firebase-functions',
      'node:http',
      '@google-cloud/storage',
      './handler',
      './transport',
      './firestore',
      './replay',
      './hooks',
      './dependencies',
      'smoke/',
    ];
    const runnerDir = resolve(__dirname, '../src/runner');
    const seen = new Set<string>();
    const visit = (file: string): void => {
      if (seen.has(file)) return;
      seen.add(file);
      const source = readFileSync(file, 'utf8');
      for (const marker of forbidden) {
        expect(source, `${file} must not import ${marker}`).not.toContain(`'${marker}`);
      }
      for (const match of source.matchAll(/from '(\.[^']+)'/g)) {
        const specifier = match[1]!;
        const target = resolve(dirname(file), specifier);
        visit(target.endsWith('.ts') ? target : `${target}.ts`);
      }
    };
    visit(`${runnerDir}/index.ts`);
    // The barrel really did pull the whole runner graph in.
    expect(seen.size).toBeGreaterThan(3);
  });
});

describe('configuration errors happen before onLegStart and the provider', () => {
  const cases: [string, Partial<RunChatReplyOptions>, string][] = [
    ['missing replyId', { replyId: '  ' }, 'missing-reply-id'],
    ['tools without a handler', { request: request({ tools: [SEARCH_TOOL] }) }, 'tools-without-handler'],
    ['non-positive maxToolTurns', { maxToolTurns: 0 }, 'invalid-max-tool-turns'],
  ];

  for (const [name, overrides, reason] of cases) {
    it(`${name} throws ChatReplyConfigurationError`, async () => {
      const client = new FakeClient([textLeg('hi')]);
      let legStarts = 0;
      const failure = await run(client, {
        onLegStart: () => {
          legStarts += 1;
          return { attemptKey: key('a') };
        },
        ...overrides,
      }).catch((error: unknown) => error);

      expect(failure).toBeInstanceOf(ChatReplyConfigurationError);
      expect((failure as ChatReplyConfigurationError).reason).toBe(reason);
      expect(legStarts).toBe(0);
      expect(client.requests).toHaveLength(0);
    });
  }

  it('a provider client with SDK retries is refused', async () => {
    const client = new FakeClient([textLeg('hi')], 2);
    const failure = await run(client).catch((error: unknown) => error);

    expect(failure).toBeInstanceOf(ChatReplyConfigurationError);
    expect((failure as ChatReplyConfigurationError).reason).toBe('provider-retries-enabled');
    expect(client.requests).toHaveLength(0);
  });
});

describe('billable leg boundary', () => {
  it('the first leg rides firstAttemptKey verbatim, without onLegStart', async () => {
    const client = new FakeClient([textLeg('hi')]);
    let legStarts = 0;
    const result = await run(client, {
      firstAttemptKey: FIRST_KEY,
      onLegStart: () => {
        legStarts += 1;
        return { attemptKey: key('9') };
      },
    });

    expect(legStarts).toBe(0);
    expect(result.legs.map((leg) => leg.attemptKey)).toEqual([FIRST_KEY]);
    expect(result.legs[0]!.dispatched).toBe(true);
    expect(result.termination).toEqual({ kind: 'done' });
  });

  it('onLegStart runs once before each leg after the first, and its key rides the record', async () => {
    const client = new FakeClient([
      toolLeg('call_1', 'search', '{"q":"notes"}'),
      textLeg('found'),
    ]);
    const order: string[] = [];
    const contexts: ChatReplyLegContext[] = [];

    const result = await run(client, {
      request: request({ tools: [SEARCH_TOOL] }),
      onToolCall: () => {
        order.push('tool');
        return { content: '3 notes' };
      },
      onLegStart: (leg) => {
        order.push(`legStart:${leg.legIndex}:${client.requests.length}`);
        contexts.push(leg);
        return { attemptKey: key(String(leg.legIndex)) };
      },
    });

    // Leg 0 never asks; the tool leg's boundary completed BEFORE its own SDK
    // call (the request counter is still the previous leg's).
    expect(order).toEqual(['tool', 'legStart:1:1']);
    expect(contexts).toHaveLength(1);
    expect(contexts[0]!.replyId).toBe(REPLY_ID);
    // The context carries the exact provider-effective request of that leg.
    expect(contexts[0]!.request).toEqual(client.requests[1]);
    expect(result.legs.map((leg) => leg.attemptKey)).toEqual([FIRST_KEY, key('1')]);
    expect(result.legs.every((leg) => leg.dispatched)).toBe(true);
  });

  it('a firstAttemptKey that is not a UUID v4 never reaches the provider', async () => {
    const client = new FakeClient([textLeg('hi')]);
    const result = await run(client, { firstAttemptKey: 'not-a-uuid' });

    expect(client.requests).toHaveLength(0);
    expect(result.termination).toMatchObject({
      kind: 'local-error',
      stage: 'leg-start',
      legIndex: 0,
      disposition: 'not-dispatched',
    });
    expect(result.legs).toHaveLength(0);
    expect(result.usage).toEqual({ inputTokens: 0, outputTokens: 0, exact: true });
  });

  it('an onLegStart throw is a local error that stops the next provider call', async () => {
    const client = new FakeClient([
      toolLeg('call_1', 'search', '{"q":"notes"}'),
      textLeg('never dispatched'),
    ]);
    const boom = new Error('db down');
    const result = await run(client, {
      request: request({ tools: [SEARCH_TOOL] }),
      onToolCall: () => ({ content: '3 notes' }),
      onLegStart: () => {
        throw boom;
      },
    });

    // The first leg was dispatched under firstAttemptKey; the second was not.
    expect(client.requests).toHaveLength(1);
    expect(result.termination).toEqual({
      kind: 'local-error',
      stage: 'leg-start',
      legIndex: 1,
      disposition: 'not-dispatched',
      error: boom,
    });
  });

  it('an onLegStart key that is not a UUID v4 stops the next provider call', async () => {
    const client = new FakeClient([
      toolLeg('call_1', 'search', '{"q":"notes"}'),
      textLeg('never dispatched'),
    ]);
    const result = await run(client, {
      request: request({ tools: [SEARCH_TOOL] }),
      onToolCall: () => ({ content: '3 notes' }),
      onLegStart: () => ({ attemptKey: 'not-a-uuid' }),
    });

    expect(client.requests).toHaveLength(1);
    expect(result.termination).toMatchObject({
      kind: 'local-error',
      stage: 'leg-start',
      legIndex: 1,
      disposition: 'not-dispatched',
    });
    expect(result.legs.map((leg) => leg.attemptKey)).toEqual([FIRST_KEY]);
  });
});

describe('event delivery and provider translation', () => {
  it('every delivery carries replyId, legIndex and attemptKey', async () => {
    const client = new FakeClient([textLeg('hello')]);
    const deliveries: ChatReplyEventDelivery[] = [];
    const result = await run(client, { onEvent: (delivery) => void deliveries.push(delivery) });

    expect(deliveries.map((delivery) => delivery.event.kind)).toEqual(['delta', 'done']);
    for (const delivery of deliveries) {
      expect(delivery.replyId).toBe(REPLY_ID);
      expect(delivery.legIndex).toBe(0);
      expect(delivery.attemptKey).toBe(key('0'));
    }
    // The existing translators produced the request and the events.
    expect(client.requests[0]).toMatchObject({
      model: 'gpt-5',
      stream: true,
      store: false,
      parallel_tool_calls: false,
      instructions: 'be kind',
    });
    expect(result.parts).toEqual([{ type: 'text', text: 'hello' }]);
    expect(result.termination).toEqual({ kind: 'done' });
  });

  it('a pre-stream provider error keeps its release disposition', async () => {
    const { APIError } = await import('openai');
    // The documented retryable rate-limit body shape (SERVER-CONTRACT §10).
    const headers = new Headers({ 'retry-after-ms': '1500' });
    const rateLimited = new APIError(
      429,
      { code: 'rate_limit_exceeded', message: 'x', type: 'y', param: null },
      'rate limited',
      headers,
    );
    const client = new FakeClient([{ kind: 'reject', error: rateLimited }]);
    const deliveries: ChatReplyEventDelivery[] = [];
    const result = await run(client, { onEvent: (delivery) => void deliveries.push(delivery) });

    // Exactly one synthesized normalised error event — no new event type.
    expect(deliveries).toHaveLength(1);
    expect(deliveries[0]!.event).toEqual({
      kind: 'error',
      cause: 'rate',
      retryAfterMs: 1500,
    });
    expect(result.termination).toEqual({
      kind: 'provider-error',
      cause: 'rate',
      detail: undefined,
      retryAfterMs: 1500,
      disposition: 'release',
    });
    expect(result.legs[0]!.outcome).toEqual({
      kind: 'release',
      cause: 'rate',
      retryAfterMs: 1500,
    });
  });

  it('a mid-stream error is always ambiguous', async () => {
    const client = new FakeClient([
      {
        kind: 'events',
        events: [
          textDelta('par'),
          responseFailed(makeResponse({ usage: makeUsage(4, 2) })),
        ],
      },
    ]);
    const result = await run(client);

    expect(result.termination).toMatchObject({
      kind: 'provider-error',
      cause: 'upstream',
      disposition: 'aborted',
    });
    expect(result.legs[0]!.outcome).toEqual({ kind: 'aborted', cause: 'upstream' });
    // The already accepted partial survives.
    expect(result.parts).toEqual([{ type: 'text', text: 'par' }]);
  });
});

describe('server-side tool loop', () => {
  it('a declared tool continues the reply with a new leg and key', async () => {
    const client = new FakeClient([
      toolLeg('call_1', 'search', '{"q":"notes"}'),
      textLeg('found 3'),
    ]);
    const result = await run(client, {
      request: request({ tools: [SEARCH_TOOL] }),
      onToolCall: (call) => {
        expect(call).toEqual({
          toolCallId: 'call_1',
          name: 'search',
          args: { q: 'notes' },
        });
        return { content: '3 notes' };
      },
    });

    expect(client.requests).toHaveLength(2);
    // The next leg carries the accumulated assistant Message.
    const secondInput = client.requests[1]!.input as unknown[];
    expect(JSON.stringify(secondInput)).toContain('call_1');
    expect(result.parts).toEqual([
      { type: 'toolCall', toolCallId: 'call_1', name: 'search', args: { q: 'notes' } },
      { type: 'toolResult', toolCallId: 'call_1', content: '3 notes', isError: false },
      { type: 'text', text: 'found 3' },
    ]);
    expect(result.legs.map((leg) => leg.outcome.kind)).toEqual(['tool-call', 'done']);
    expect(result.termination).toEqual({ kind: 'done' });
  });

  it('the tier reasoning effort rides every leg of the loop', async () => {
    const client = new FakeClient([
      toolLeg('call_1', 'search', '{"q":"notes"}'),
      textLeg('found 3'),
    ]);
    await run(client, {
      tier: { ...TIER, reasoningEffort: 'high' },
      request: request({ tools: [SEARCH_TOOL] }),
      onToolCall: () => ({ content: '3 notes' }),
    });

    expect(client.requests).toHaveLength(2);
    expect(client.requests.map((sent) => sent.reasoning)).toEqual([
      { effort: 'high' },
      { effort: 'high' },
    ]);
  });

  it('unknown tools, invalid arguments and handler failures are safe results', async () => {
    const scenarios: [string, LegScript, string][] = [
      ['unknown', toolLeg('call_1', 'missing', '{}'), 'unknown-tool'],
      ['invalid args', toolLeg('call_1', 'search', '{"q":42}'), 'invalid-tool-arguments'],
      ['handler throws', toolLeg('call_1', 'search', '{"q":"notes"}'), 'tool-execution-failed'],
    ];

    for (const [name, leg, expected] of scenarios) {
      const client = new FakeClient([leg, textLeg('after')]);
      let calls = 0;
      const result = await run(client, {
        request: request({ tools: [SEARCH_TOOL] }),
        onToolCall: () => {
          calls += 1;
          throw new Error('tool blew up');
        },
      });

      const toolResult = result.parts.find((part) => part.type === 'toolResult');
      expect(toolResult, name).toMatchObject({ content: expected, isError: true });
      // The refused calls never reach the handler.
      expect(calls, name).toBe(expected === 'tool-execution-failed' ? 1 : 0);
      expect(result.termination.kind, name).toBe('done');
    }
  });

  it('a repeated toolCallId reuses its result without calling the handler twice', async () => {
    const client = new FakeClient([
      toolLeg('call_1', 'search', '{"q":"notes"}'),
      // The provider repeats the SAME call id (at-least-once delivery).
      toolLeg('call_1', 'search', '{"q":"notes"}'),
      textLeg('done'),
    ]);
    let calls = 0;
    const result = await run(client, {
      request: request({ tools: [SEARCH_TOOL] }),
      onToolCall: () => {
        calls += 1;
        return { content: '3 notes' };
      },
    });

    expect(calls).toBe(1);
    expect(result.parts.filter((part) => part.type === 'toolCall')).toHaveLength(1);
    expect(result.parts.filter((part) => part.type === 'toolResult')).toHaveLength(1);
    expect(result.termination).toEqual({ kind: 'done' });
  });

  it('the tool-loop limit stops before the handler and the next leg', async () => {
    const client = new FakeClient([
      toolLeg('call_1', 'search', '{"q":"a"}'),
      toolLeg('call_2', 'search', '{"q":"b"}'),
      textLeg('never dispatched'),
    ]);
    let calls = 0;
    const result = await run(client, {
      request: request({ tools: [SEARCH_TOOL] }),
      maxToolTurns: 1,
      onToolCall: () => {
        calls += 1;
        return { content: 'ok' };
      },
    });

    expect(calls).toBe(1);
    expect(client.requests).toHaveLength(2);
    expect(result.termination).toEqual({ kind: 'tool-loop-limit' });
    // The last tool_call stays in the accumulated reply, unanswered.
    expect(result.parts.filter((part) => part.type === 'toolCall')).toHaveLength(2);
    expect(result.parts.filter((part) => part.type === 'toolResult')).toHaveLength(1);
  });
});

describe('cancellation', () => {
  it('an already aborted signal dispatches nothing', async () => {
    const client = new FakeClient([textLeg('hi')]);
    const controller = new AbortController();
    controller.abort();
    let legStarts = 0;

    const result = await run(client, {
      signal: controller.signal,
      onLegStart: () => {
        legStarts += 1;
        return { attemptKey: key('0') };
      },
    });

    expect(legStarts).toBe(0);
    expect(client.requests).toHaveLength(0);
    expect(result.termination).toEqual({
      kind: 'cancelled',
      legIndex: 0,
      disposition: 'not-dispatched',
    });
  });

  it('aborting during onLegStart finishes promptly and swallows the late failure', async () => {
    const client = new FakeClient([
      toolLeg('call_1', 'search', '{"q":"notes"}'),
      textLeg('never dispatched'),
    ]);
    const controller = new AbortController();
    let rejectLate: (error: unknown) => void = () => {};

    const result = await run(client, {
      request: request({ tools: [SEARCH_TOOL] }),
      onToolCall: () => ({ content: '3 notes' }),
      signal: controller.signal,
      onLegStart: () => {
        controller.abort();
        return new Promise((_, reject) => {
          rejectLate = reject;
        });
      },
    });

    expect(result.termination).toMatchObject({ kind: 'cancelled', disposition: 'not-dispatched' });
    // Only the first leg (firstAttemptKey) ever reached the provider.
    expect(client.requests).toHaveLength(1);
    // The app's promise is not cancellable: its late rejection must be
    // swallowed, never surface as an unhandled rejection.
    rejectLate(new Error('late'));
    await new Promise((resolve) => setImmediate(resolve));
  });

  it('aborting during the provider stream aborts the request and is ambiguous', async () => {
    const client = new FakeClient([
      {
        kind: 'generator',
        make: async function* () {
          yield textDelta('par');
          yield responseCompleted(makeResponse({ usage: makeUsage(1, 1) }));
        },
      },
    ]);
    const controller = new AbortController();
    const result = await run(client, {
      signal: controller.signal,
      onEvent: () => {
        controller.abort();
      },
    });

    expect(client.signals[0]!.aborted).toBe(true);
    expect(result.termination).toEqual({
      kind: 'cancelled',
      legIndex: 0,
      disposition: 'aborted',
    });
    expect(result.legs[0]!.outcome).toEqual({ kind: 'aborted' });
    // The abort won the delivery boundary, so that event is NOT applied: the
    // accumulated parts stay exactly what was provably accepted.
    expect(result.parts).toEqual([]);
  });

  it('aborting during the tool handler starts no next leg', async () => {
    const client = new FakeClient([
      toolLeg('call_1', 'search', '{"q":"notes"}'),
      textLeg('never dispatched'),
    ]);
    const controller = new AbortController();
    const result = await run(client, {
      request: request({ tools: [SEARCH_TOOL] }),
      signal: controller.signal,
      onToolCall: () => {
        controller.abort();
        return new Promise<never>(() => {});
      },
    });

    expect(client.requests).toHaveLength(1);
    expect(result.termination).toEqual({
      kind: 'cancelled',
      legIndex: 0,
      disposition: 'not-dispatched',
    });
    // The completed leg keeps its successful record; no late tool result.
    expect(result.legs[0]!.outcome).toEqual({ kind: 'tool-call', toolCallId: 'call_1' });
    expect(result.parts.some((part) => part.type === 'toolResult')).toBe(false);
  });
});

describe('event sink failure', () => {
  it('stops delivery, aborts the provider and reports the ambiguous disposition', async () => {
    const client = new FakeClient([
      {
        kind: 'generator',
        make: async function* () {
          yield textDelta('one');
          yield textDelta('two');
          yield responseCompleted(makeResponse({ usage: makeUsage(1, 1) }));
        },
      },
    ]);
    const boom = new Error('sink down');
    const seen: string[] = [];
    const result = await run(client, {
      onEvent: (delivery) => {
        seen.push(delivery.event.kind);
        if (seen.length === 2) throw boom;
      },
    });

    expect(seen).toEqual(['delta', 'delta']);
    expect(client.signals[0]!.aborted).toBe(true);
    expect(result.termination).toEqual({
      kind: 'sink-error',
      legIndex: 0,
      disposition: 'aborted',
      error: boom,
    });
    // A leg that was already streaming stays ambiguous.
    expect(result.legs[0]!.outcome).toEqual({ kind: 'aborted' });
    // The rejected event is NOT applied: parts are exactly what was accepted.
    expect(result.parts).toEqual([{ type: 'text', text: 'one' }]);
    expect(result.usage).toEqual({ inputTokens: null, outputTokens: null, exact: false });
  });

  it('keeps the release disposition when the refused event was a released one', async () => {
    const { APIError } = await import('openai');
    // The documented retryable rate-limit body shape (SERVER-CONTRACT §10).
    const rateLimited = new APIError(
      429,
      { code: 'rate_limit_exceeded', message: 'x', type: 'y', param: null },
      'rate limited',
      new Headers(),
    );
    const client = new FakeClient([{ kind: 'reject', error: rateLimited }]);
    const boom = new Error('sink down');
    const result = await run(client, {
      onEvent: () => {
        throw boom;
      },
    });

    expect(result.termination).toEqual({
      kind: 'sink-error',
      legIndex: 0,
      disposition: 'release',
      error: boom,
    });
    // The leg record must not contradict that terminal: the provider proved
    // this leg unbilled, so its attemptKey stays safely reusable.
    expect(result.legs[0]!.outcome).toEqual({
      kind: 'release',
      cause: 'rate',
      retryAfterMs: undefined,
    });
  });

  it('carries the classified retryAfterMs onto a released leg record', async () => {
    const { APIError } = await import('openai');
    const rateLimited = new APIError(
      429,
      { code: 'rate_limit_exceeded', message: 'x', type: 'y', param: null },
      'rate limited',
      new Headers({ 'retry-after-ms': '1500' }),
    );
    const client = new FakeClient([{ kind: 'reject', error: rateLimited }]);
    const result = await run(client, {
      onEvent: () => {
        throw new Error('sink down');
      },
    });

    expect(result.termination).toMatchObject({ kind: 'sink-error', disposition: 'release' });
    expect(result.legs[0]!.outcome).toEqual({
      kind: 'release',
      cause: 'rate',
      retryAfterMs: 1500,
    });
  });

  it('a fail-closed pre-stream rejection refused by the sink stays ambiguous', async () => {
    const { APIError } = await import('openai');
    // insufficient_quota: never released (SERVER-CONTRACT §10).
    const quota = new APIError(
      429,
      { code: 'insufficient_quota', message: 'x', type: 'y', param: null },
      'no quota',
      new Headers(),
    );
    const client = new FakeClient([{ kind: 'reject', error: quota }]);
    const result = await run(client, {
      onEvent: () => {
        throw new Error('sink down');
      },
    });

    expect(result.termination).toMatchObject({ kind: 'sink-error', disposition: 'aborted' });
    expect(result.legs[0]!.outcome).toEqual({ kind: 'aborted' });
  });
});

describe('usage aggregation', () => {
  it('sums exact usage across legs and keeps usageRaw for a single leg', async () => {
    const single = new FakeClient([textLeg('hi', 10, 5)]);
    const singleResult = await run(single);
    expect(singleResult.usage).toMatchObject({
      inputTokens: 10,
      outputTokens: 5,
      exact: true,
    });
    expect(singleResult.usage.usageRaw).toBeDefined();

    const multi = new FakeClient([
      toolLeg('call_1', 'search', '{"q":"notes"}', 3),
      textLeg('found', 10, 5),
    ]);
    const multiResult = await run(multi, {
      request: request({ tools: [SEARCH_TOOL] }),
      onToolCall: () => ({ content: '3 notes' }),
    });
    expect(multiResult.usage).toEqual({ inputTokens: 13, outputTokens: 8, exact: true });
    expect(multiResult.legs.map((leg) => leg.usage?.inputTokens)).toEqual([3, 10]);
  });

  it('never presents a partial sum as an exact aggregate', async () => {
    const client = new FakeClient([
      toolLeg('call_1', 'search', '{"q":"notes"}', 3),
      { kind: 'reject', error: new Error('connection reset') },
    ]);
    const result = await run(client, {
      request: request({ tools: [SEARCH_TOOL] }),
      onToolCall: () => ({ content: '3 notes' }),
    });

    expect(result.termination).toMatchObject({ kind: 'provider-error', disposition: 'aborted' });
    expect(result.usage).toEqual({ inputTokens: null, outputTokens: null, exact: false });
    // The exact per-leg value is still available.
    expect(result.legs[0]!.usage).toMatchObject({ inputTokens: 3, outputTokens: 3 });
  });

  it('reports a provable zero when nothing was dispatched', async () => {
    const client = new FakeClient([textLeg('hi')]);
    const result = await run(client, { firstAttemptKey: 'nope' });

    expect(result.legs).toHaveLength(0);
    expect(result.usage).toEqual({ inputTokens: 0, outputTokens: 0, exact: true });
  });
});
