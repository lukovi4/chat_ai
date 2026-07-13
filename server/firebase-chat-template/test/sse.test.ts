import { describe, expect, it } from 'vitest';

import { encodeSseFrame } from '../src/core/sse';
import { NormalizedEvent } from '../src/core/wire';

describe('normalised SSE encoder — exact frames', () => {
  it('delta', () => {
    expect(encodeSseFrame({ kind: 'delta', text: 'hi' })).toBe(
      'event: delta\ndata: {"text":"hi"}\n\n',
    );
  });

  it('provider_state (base64 of the raw continuity bytes)', () => {
    const bytes = new Uint8Array([0x7b, 0x22, 0x61, 0x22, 0x7d]); // {"a"}
    const base64 = Buffer.from(bytes).toString('base64');
    expect(encodeSseFrame({ kind: 'provider_state', provider: 'openai', data: bytes })).toBe(
      `event: provider_state\ndata: {"provider":"openai","data":"${base64}"}\n\n`,
    );
  });

  it('tool_call with usage', () => {
    expect(
      encodeSseFrame({
        kind: 'tool_call',
        id: 'call_1',
        name: 'searchNotes',
        args: { period: '2026-06' },
        usage: { inputTokens: 12, outputTokens: 3 },
      }),
    ).toBe(
      'event: tool_call\n' +
        'data: {"id":"call_1","name":"searchNotes","args":{"period":"2026-06"},' +
        '"usage":{"inputTokens":12,"outputTokens":3}}\n\n',
    );
  });

  it('done with usage + usageRaw', () => {
    expect(
      encodeSseFrame({
        kind: 'done',
        usage: { inputTokens: 10, outputTokens: 20, usageRaw: { total_tokens: 30 } },
      }),
    ).toBe(
      'event: done\n' +
        'data: {"usage":{"inputTokens":10,"outputTokens":20,"usageRaw":{"total_tokens":30}}}\n\n',
    );
  });

  it('done without usage is an empty object', () => {
    expect(encodeSseFrame({ kind: 'done' })).toBe('event: done\ndata: {}\n\n');
  });

  it('error with detail, usage and retryAfterMs', () => {
    expect(
      encodeSseFrame({
        kind: 'error',
        cause: 'rate',
        detail: 'slow down',
        usage: { inputTokens: 5, outputTokens: 0 },
        retryAfterMs: 1200,
      }),
    ).toBe(
      'event: error\n' +
        'data: {"cause":"rate","detail":"slow down",' +
        '"usage":{"inputTokens":5,"outputTokens":0},"retryAfterMs":1200}\n\n',
    );
  });

  it('error with only a cause', () => {
    expect(encodeSseFrame({ kind: 'error', cause: 'upstream' })).toBe(
      'event: error\ndata: {"cause":"upstream"}\n\n',
    );
  });
});

describe('normalised SSE encoder — invariants', () => {
  it('preserves Unicode scalars verbatim (no \\u escaping of BMP/astral chars)', () => {
    const frame = encodeSseFrame({ kind: 'delta', text: 'Привет 🌱' });
    expect(frame).toBe('event: delta\ndata: {"text":"Привет 🌱"}\n\n');
  });

  it('emits compact JSON (no insignificant whitespace)', () => {
    const frame = encodeSseFrame({
      kind: 'tool_call',
      id: 'c',
      name: 'n',
      args: { a: 1, b: [2, 3] },
      usage: { inputTokens: 1, outputTokens: 1 },
    });
    const data = frame.split('\n')[1]!.slice('data: '.length);
    expect(data).not.toMatch(/: /); // no space after a colon
    expect(data).not.toMatch(/, /); // no space after a comma
  });

  it('provider_state base64 round-trips byte-exact', () => {
    const bytes = new Uint8Array([0, 1, 2, 253, 254, 255]);
    const frame = encodeSseFrame({ kind: 'provider_state', provider: 'anthropic', data: bytes });
    const data = JSON.parse(frame.split('\n')[1]!.slice('data: '.length)) as { data: string };
    expect(new Uint8Array(Buffer.from(data.data, 'base64'))).toEqual(bytes);
  });

  it('ends every frame with a blank line', () => {
    expect(encodeSseFrame({ kind: 'delta', text: 'x' }).endsWith('\n\n')).toBe(true);
  });

  it('never emits the client-only tool-loop-limit cause, and leaks no payload', () => {
    // A cast smuggles the client-only cause past the type system; the defensive
    // guard fails closed and its message never echoes the offending value.
    const smuggled = { kind: 'error', cause: 'tool-loop-limit' } as unknown as NormalizedEvent;
    expect(() => encodeSseFrame(smuggled)).toThrow();
    try {
      encodeSseFrame(smuggled);
    } catch (e) {
      expect((e as Error).message).not.toContain('tool-loop-limit');
    }
  });
});
