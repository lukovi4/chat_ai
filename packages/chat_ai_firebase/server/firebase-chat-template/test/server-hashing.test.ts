import { describe, expect, it } from 'vitest';

import { canonicalJson, paramsHash, requestHash, storageSafeUid } from '../src/server/canonical';
import type { ChatRequest, WireContentPart, WireMessage } from '../src/core/wire';

// C. Canonical hashing (task §5/§12C): key reordering and Message bookkeeping
// are inert; matching-provider opaque is included, foreign-provider opaque is
// excluded from paramsHash; a real provider-effective change mismatches.

function msg(parts: WireContentPart[], extra: Partial<WireMessage> = {}): WireMessage {
  return { id: 'm', role: 'assistant', parts, status: 'complete', createdAt: '2026-07-13T00:00:00Z', ...extra };
}

function req(messages: WireMessage[], over: Partial<ChatRequest> = {}): ChatRequest {
  return { wireVersion: 1, botId: 'premium', system: 'S', messages, ...over };
}

describe('canonicalJson', () => {
  it('sorts object keys lexicographically at every level and preserves list order', () => {
    expect(canonicalJson({ b: 1, a: { d: [3, 1, 2], c: 4 } })).toBe('{"a":{"c":4,"d":[3,1,2]},"b":1}');
  });

  it('leaves scalars and Unicode untouched, compact', () => {
    expect(canonicalJson({ t: 'Привет 🌱', n: 2 })).toBe('{"n":2,"t":"Привет 🌱"}');
  });
});

describe('requestHash / paramsHash — inert differences', () => {
  it('object key reordering does not change either hash', () => {
    const a = req([msg([{ type: 'toolCall', toolCallId: 'c', name: 'n', args: { a: 1, b: 2 } }])]);
    const b = req([msg([{ type: 'toolCall', toolCallId: 'c', name: 'n', args: { b: 2, a: 1 } }])]);
    expect(requestHash(a)).toBe(requestHash(b));
    expect(paramsHash(a, 'openai')).toBe(paramsHash(b, 'openai'));
  });

  it('Message bookkeeping (id/status/createdAt/attemptKey) does not change hashes', () => {
    const a = req([msg([{ type: 'text', text: 'hi' }], { id: 'A', status: 'complete', createdAt: '2026-01-01T00:00:00Z', attemptKey: 'k-a' })]);
    const b = req([msg([{ type: 'text', text: 'hi' }], { id: 'B', status: 'interrupted', createdAt: '2030-12-31T23:59:59Z', attemptKey: 'k-b' })]);
    expect(requestHash(a)).toBe(requestHash(b));
    expect(paramsHash(a, 'openai')).toBe(paramsHash(b, 'openai'));
  });
});

describe('paramsHash — provider opaque filtering', () => {
  const openaiOpaque: WireContentPart = { type: 'providerOpaque', provider: 'openai', data: 'AAA' };
  const anthropicOpaque: WireContentPart = { type: 'providerOpaque', provider: 'anthropic', data: 'BBB' };

  it('a matching-provider opaque part changes paramsHash (included byte-exact)', () => {
    const without = req([msg([{ type: 'text', text: 'hi' }])]);
    const withOpenai = req([msg([{ type: 'text', text: 'hi' }, openaiOpaque])]);
    expect(paramsHash(withOpenai, 'openai')).not.toBe(paramsHash(without, 'openai'));
  });

  it('a foreign-provider opaque part does not change paramsHash (excluded)', () => {
    const without = req([msg([{ type: 'text', text: 'hi' }])]);
    const withAnthropic = req([msg([{ type: 'text', text: 'hi' }, anthropicOpaque])]);
    expect(paramsHash(withAnthropic, 'openai')).toBe(paramsHash(without, 'openai'));
  });

  it('requestHash keeps ALL opaque, so a foreign opaque part does change it', () => {
    const without = req([msg([{ type: 'text', text: 'hi' }])]);
    const withAnthropic = req([msg([{ type: 'text', text: 'hi' }, anthropicOpaque])]);
    expect(requestHash(withAnthropic)).not.toBe(requestHash(without));
  });
});

describe('storageSafeUid — collision-free, path-safe encoding (P1-6)', () => {
  it('encodes the reference uid to its base64url segment', () => {
    expect(storageSafeUid('user-1')).toBe('dXNlci0x');
  });

  it('is deterministic', () => {
    expect(storageSafeUid('user-1')).toBe(storageSafeUid('user-1'));
  });

  it.each(['a/b', '.', '..', 'a.b', 'Пользователь-🌱', 'x/../y', ''])(
    'produces a single path-safe segment for %j (no /, ., ..)',
    (uid) => {
      const seg = storageSafeUid(uid);
      expect(seg).not.toContain('/');
      expect(seg).not.toBe('.');
      expect(seg).not.toBe('..');
      // Round-trips to the exact UTF-8 bytes (injective, so collision-free).
      expect(Buffer.from(seg, 'base64url').toString('utf8')).toBe(uid);
    },
  );

  it('distinct uids never collide, including path-metacharacter neighbours', () => {
    const uids = ['user-1', 'user-2', 'a/b', 'a/b', 'a.b', '..', '.', 'ab', 'a', 'b'];
    const encoded = uids.map(storageSafeUid);
    expect(new Set(encoded).size).toBe(new Set(uids).size);
  });
});

describe('requestHash / paramsHash — real changes mismatch', () => {
  it('a changed message text mismatches both hashes', () => {
    const a = req([msg([{ type: 'text', text: 'hello' }])]);
    const b = req([msg([{ type: 'text', text: 'HELLO' }])]);
    expect(requestHash(a)).not.toBe(requestHash(b));
    expect(paramsHash(a, 'openai')).not.toBe(paramsHash(b, 'openai'));
  });

  it('a changed botId or system mismatches', () => {
    const a = req([msg([{ type: 'text', text: 'hi' }])]);
    expect(paramsHash(a, 'openai')).not.toBe(paramsHash(req([msg([{ type: 'text', text: 'hi' }])], { botId: 'free' }), 'openai'));
    expect(paramsHash(a, 'openai')).not.toBe(paramsHash(req([msg([{ type: 'text', text: 'hi' }])], { system: 'OTHER' }), 'openai'));
  });
});
