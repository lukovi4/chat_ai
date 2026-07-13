import { describe, expect, it } from 'vitest';

import { translateOpenAIStream } from '../src/providers/openai/stream';
import { NormalizedEvent } from '../src/core/wire';
import {
  asStream,
  errorEvent,
  functionArgsDelta,
  functionCallAdded,
  functionCallDone,
  makeReasoningItem,
  makeResponse,
  makeUsage,
  reasoningItemDone,
  refusalDone,
  responseCompleted,
  responseFailed,
  responseIncomplete,
  textDelta,
} from './fixtures/openai-events';
import type { Responses } from 'openai/resources';

async function drain(
  stream: AsyncIterable<Responses.ResponseStreamEvent>,
): Promise<NormalizedEvent[]> {
  const out: NormalizedEvent[] = [];
  for await (const e of translateOpenAIStream(stream)) out.push(e);
  return out;
}

async function collect(events: Responses.ResponseStreamEvent[]): Promise<NormalizedEvent[]> {
  return drain(asStream(events));
}

/** A provider stream that yields `before`, then throws (iterator failure). */
async function* throwingStream(
  before: Responses.ResponseStreamEvent[],
): AsyncGenerator<Responses.ResponseStreamEvent> {
  for (const e of before) yield e;
  throw new Error('SENTINEL-STREAM-ERROR');
}

const okUsage = makeResponse({ status: 'completed', usage: makeUsage(3, 4) });

describe('OpenAI stream — text deltas', () => {
  it('preserves exact order and boundaries; drops empty deltas', async () => {
    const out = await collect([
      textDelta('He'),
      textDelta(''),
      textDelta('llo'),
      textDelta(' wor'),
      textDelta('ld'),
      responseCompleted(okUsage),
    ]);
    expect(out).toEqual([
      { kind: 'delta', text: 'He' },
      { kind: 'delta', text: 'llo' },
      { kind: 'delta', text: ' wor' },
      { kind: 'delta', text: 'ld' },
      { kind: 'done', usage: { inputTokens: 3, outputTokens: 4, usageRaw: makeUsage(3, 4) } },
    ]);
  });
});

describe('OpenAI stream — provider opaque continuity', () => {
  it('emits a byte-exact provider_state for a complete encrypted reasoning item', async () => {
    const item = makeReasoningItem({ id: 'rs_9', encrypted_content: 'ENCRYPTED-BYTES' });
    const out = await collect([reasoningItemDone(item), responseCompleted(okUsage)]);
    const expectedBytes = new Uint8Array(Buffer.from(JSON.stringify(item), 'utf8'));
    expect(out[0]).toEqual({ kind: 'provider_state', provider: 'openai', data: expectedBytes });
    expect(out[1]?.kind).toBe('done');
  });

  it('does not emit provider_state for a reasoning item without encrypted content', async () => {
    const item = makeReasoningItem({ encrypted_content: null });
    const out = await collect([reasoningItemDone(item), responseCompleted(okUsage)]);
    expect(out).toEqual([
      { kind: 'done', usage: { inputTokens: 3, outputTokens: 4, usageRaw: makeUsage(3, 4) } },
    ]);
  });
});

describe('OpenAI stream — function calls', () => {
  const ARGS = '{"period":"2026-06","limit":3}';

  it('buffers argument fragments split at every boundary into one tool_call', async () => {
    for (let cut = 0; cut <= ARGS.length; cut++) {
      const out = await collect([
        functionCallAdded({ outputIndex: 0, callId: 'call_1', name: 'searchNotes' }),
        functionArgsDelta({ outputIndex: 0, delta: ARGS.slice(0, cut) }),
        functionArgsDelta({ outputIndex: 0, delta: ARGS.slice(cut) }),
        responseCompleted(makeResponse({ usage: makeUsage(5, 1) })),
      ]);
      expect(out).toEqual([
        {
          kind: 'tool_call',
          id: 'call_1',
          name: 'searchNotes',
          args: { period: '2026-06', limit: 3 },
          usage: { inputTokens: 5, outputTokens: 1, usageRaw: makeUsage(5, 1) },
        },
      ]);
    }
  });

  it('tool_call is terminal, carries the leg usage, and is not followed by done', async () => {
    const out = await collect([
      functionCallAdded({ outputIndex: 0, callId: 'c1', name: 'n' }),
      functionCallDone({ outputIndex: 0, callId: 'c1', name: 'n', arguments: '{}' }),
      responseCompleted(makeResponse({ usage: makeUsage(2, 0) })),
    ]);
    expect(out).toHaveLength(1);
    expect(out[0]).toEqual({
      kind: 'tool_call',
      id: 'c1',
      name: 'n',
      args: {},
      usage: { inputTokens: 2, outputTokens: 0, usageRaw: makeUsage(2, 0) },
    });
  });

  it('truncated/invalid argument JSON is a terminal upstream, never a partial call', async () => {
    const out = await collect([
      functionCallAdded({ outputIndex: 0, callId: 'c1', name: 'n' }),
      functionArgsDelta({ outputIndex: 0, delta: '{"a":' }),
      responseCompleted(makeResponse({ usage: makeUsage(1, 0) })),
    ]);
    expect(out).toEqual([{ kind: 'error', cause: 'upstream' }]);
  });

  it('arguments that parse to a non-object are upstream', async () => {
    const out = await collect([
      functionCallAdded({ outputIndex: 0, callId: 'c1', name: 'n' }),
      functionArgsDelta({ outputIndex: 0, delta: '123' }),
      responseCompleted(makeResponse({ usage: makeUsage(1, 0) })),
    ]);
    expect(out).toEqual([{ kind: 'error', cause: 'upstream' }]);
  });

  it('a second function call on the leg fails closed (upstream)', async () => {
    const out = await collect([
      functionCallAdded({ outputIndex: 0, callId: 'c1', name: 'n' }),
      functionCallAdded({ outputIndex: 1, callId: 'c2', name: 'n2' }),
    ]);
    expect(out).toEqual([{ kind: 'error', cause: 'upstream' }]);
  });

  it('a tool call without leg usage is upstream, never a faked-zero usage', async () => {
    const out = await collect([
      functionCallAdded({ outputIndex: 0, callId: 'c1', name: 'n' }),
      functionCallDone({ outputIndex: 0, callId: 'c1', name: 'n', arguments: '{}' }),
      responseCompleted(makeResponse({})), // no usage
    ]);
    expect(out).toEqual([{ kind: 'error', cause: 'upstream' }]);
  });
});

describe('OpenAI stream — normal completion', () => {
  it('emits done with normalised usage and the raw usage payload', async () => {
    const out = await collect([textDelta('hi'), responseCompleted(makeResponse({ usage: makeUsage(10, 20) }))]);
    expect(out[out.length - 1]).toEqual({
      kind: 'done',
      usage: { inputTokens: 10, outputTokens: 20, usageRaw: makeUsage(10, 20) },
    });
  });

  it('a completion without a final usage is upstream, not a faked zero', async () => {
    const out = await collect([textDelta('hi'), responseCompleted(makeResponse({}))]);
    expect(out).toEqual([{ kind: 'delta', text: 'hi' }, { kind: 'error', cause: 'upstream' }]);
  });
});

describe('OpenAI stream — refusal, failure and truncation', () => {
  it('a documented refusal outcome is content-filter (terminal)', async () => {
    const out = await collect([refusalDone(), responseCompleted(okUsage)]);
    expect(out).toEqual([{ kind: 'error', cause: 'content-filter' }]);
  });

  it('response.failed is upstream and leaks no raw provider message', async () => {
    const out = await collect([
      responseFailed(makeResponse({ status: 'failed', error: { code: 'server_error', message: 'SECRET-boom' } })),
    ]);
    expect(out).toHaveLength(1);
    const err = out[0] as Extract<NormalizedEvent, { kind: 'error' }>;
    expect(err.kind).toBe('error');
    expect(err.cause).toBe('upstream');
    expect(err.detail).toBeUndefined();
    expect(JSON.stringify(err)).not.toContain('SECRET-boom');
  });

  it('response.incomplete for max_output_tokens is upstream', async () => {
    const out = await collect([
      responseIncomplete(makeResponse({ status: 'incomplete', incomplete_details: { reason: 'max_output_tokens' } })),
    ]);
    expect(out).toEqual([{ kind: 'error', cause: 'upstream' }]);
  });

  it('response.incomplete for content_filter is content-filter', async () => {
    const out = await collect([
      responseIncomplete(makeResponse({ status: 'incomplete', incomplete_details: { reason: 'content_filter' } })),
    ]);
    expect(out).toEqual([{ kind: 'error', cause: 'content-filter' }]);
  });

  it('a stream-level error event is upstream with no leaked payload', async () => {
    const out = await collect([errorEvent()]);
    const err = out[0] as Extract<NormalizedEvent, { kind: 'error' }>;
    expect(err).toEqual({ kind: 'error', cause: 'upstream' });
    expect(err.detail).toBeUndefined();
  });

  it('EOF without a terminal event is upstream', async () => {
    const out = await collect([textDelta('partial')]);
    expect(out).toEqual([{ kind: 'delta', text: 'partial' }, { kind: 'error', cause: 'upstream' }]);
  });
});

describe('OpenAI stream — terminal lifecycle', () => {
  it('first terminal wins; duplicate and post-terminal events are ignored', async () => {
    const out = await collect([
      responseCompleted(makeResponse({ usage: makeUsage(1, 1) })),
      responseCompleted(makeResponse({ usage: makeUsage(9, 9) })),
      textDelta('late'),
    ]);
    expect(out).toEqual([
      { kind: 'done', usage: { inputTokens: 1, outputTokens: 1, usageRaw: makeUsage(1, 1) } },
    ]);
  });
});

describe('OpenAI stream — input-iterator errors as data', () => {
  it('an iterator throwing before the first event is one upstream terminal', async () => {
    expect(await drain(throwingStream([]))).toEqual([{ kind: 'error', cause: 'upstream' }]);
  });

  it('a delta then an iterator throw keeps the delta and appends one upstream', async () => {
    const out = await drain(throwingStream([textDelta('partial')]));
    expect(out).toEqual([{ kind: 'delta', text: 'partial' }, { kind: 'error', cause: 'upstream' }]);
  });

  it('the raw iterator exception (message/stack/sentinel) never reaches the events', async () => {
    const out = await drain(throwingStream([textDelta('x')]));
    expect(JSON.stringify(out)).not.toContain('SENTINEL-STREAM-ERROR');
    const err = out[out.length - 1] as Extract<NormalizedEvent, { kind: 'error' }>;
    expect(err.detail).toBeUndefined();
  });

  it('an iterator that throws AFTER a terminal is never read (terminal stays single)', async () => {
    // The generator returns on the terminal, so the post-terminal throw is
    // never pulled — exactly one terminal, no extra event.
    const out = await drain(throwingStream([responseCompleted(makeResponse({ usage: makeUsage(1, 1) }))]));
    expect(out).toEqual([
      { kind: 'done', usage: { inputTokens: 1, outputTokens: 1, usageRaw: makeUsage(1, 1) } },
    ]);
  });
});

describe('OpenAI stream — usage validation', () => {
  it.each([
    ['fractional input', 1.5, 2],
    ['fractional output', 2, 0.5],
    ['negative input', -1, 2],
    ['negative output', 2, -3],
    ['NaN input', Number.NaN, 2],
    ['Infinity output', 2, Number.POSITIVE_INFINITY],
  ])('a completion with invalid usage (%s) is upstream, no done', async (_label, input, output) => {
    const out = await collect([responseCompleted(makeResponse({ usage: makeUsage(input, output) }))]);
    expect(out).toEqual([{ kind: 'error', cause: 'upstream' }]);
  });

  it.each([
    ['zero', 0, 0],
    ['positive integers', 7, 13],
  ])('a completion with valid non-negative integer usage (%s) is done', async (_label, input, output) => {
    const out = await collect([responseCompleted(makeResponse({ usage: makeUsage(input, output) }))]);
    expect(out).toEqual([
      { kind: 'done', usage: { inputTokens: input, outputTokens: output, usageRaw: makeUsage(input, output) } },
    ]);
  });

  it('a failed event with invalid usage keeps its error terminal but attaches no usage', async () => {
    const out = await collect([responseFailed(makeResponse({ status: 'failed', usage: makeUsage(-1, 2) }))]);
    expect(out).toEqual([{ kind: 'error', cause: 'upstream' }]);
  });

  it('a failed event with valid usage attaches best-effort usage', async () => {
    const out = await collect([responseFailed(makeResponse({ status: 'failed', usage: makeUsage(3, 0) }))]);
    expect(out).toEqual([
      { kind: 'error', cause: 'upstream', usage: { inputTokens: 3, outputTokens: 0, usageRaw: makeUsage(3, 0) } },
    ]);
  });
});
