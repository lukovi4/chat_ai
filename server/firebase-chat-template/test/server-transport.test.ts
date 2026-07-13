import { afterEach, describe, expect, it, vi } from 'vitest';

import { SseWriter } from '../src/server/transport';
import { asRes, FakeRes } from './fixtures/server-fakes';

// F (transport slice): SSE headers and the 15-second keepalive (fake timers).

afterEach(() => {
  vi.useRealTimers();
});

describe('SseWriter — headers', () => {
  it('opens the exact streaming headers once', () => {
    const res = new FakeRes();
    new SseWriter(asRes(res)).openHeaders();
    expect(res.statusCode).toBe(200);
    expect(res.headers['content-type']).toBe('text/event-stream');
    expect(res.headers['cache-control']).toBe('no-cache, no-transform');
    expect(res.headers['x-accel-buffering']).toBe('no');
    expect(res.headers['x-chat-ai-wire-version']).toBe('1');
  });
});

describe('SseWriter — keepalive', () => {
  it('emits a : ping after 15 s of outgoing silence and repeats', () => {
    vi.useFakeTimers();
    const res = new FakeRes();
    const writer = new SseWriter(asRes(res));
    writer.openHeaders();

    vi.advanceTimersByTime(14_999);
    expect(res.chunks).not.toContain(': ping\n\n');
    vi.advanceTimersByTime(1);
    expect(res.chunks.filter((c) => c === ': ping\n\n')).toHaveLength(1);
    vi.advanceTimersByTime(15_000);
    expect(res.chunks.filter((c) => c === ': ping\n\n')).toHaveLength(2);
  });

  it('a real frame resets the silence window (no ping while active)', () => {
    vi.useFakeTimers();
    const res = new FakeRes();
    const writer = new SseWriter(asRes(res));
    writer.openHeaders();

    vi.advanceTimersByTime(10_000);
    writer.writeFrame('event: delta\ndata: {"text":"x"}\n\n');
    vi.advanceTimersByTime(10_000); // 10 s since the frame < 15 s
    expect(res.chunks).not.toContain(': ping\n\n');
    vi.advanceTimersByTime(5_000); // now 15 s of silence since the frame
    expect(res.chunks).toContain(': ping\n\n');
  });

  it('stops writing and reports failure once the connection is dead', () => {
    const res = new FakeRes();
    res.failWrite = true;
    const writer = new SseWriter(asRes(res));
    writer.openHeaders();
    expect(writer.writeFrame('event: delta\ndata: {}\n\n')).toBe(false);
    expect(writer.disconnected).toBe(true);
  });

  it('a failed keepalive write invokes onDisconnect exactly once [defect 2]', () => {
    vi.useFakeTimers();
    const res = new FakeRes();
    res.failWrite = true; // the keepalive write will throw
    let count = 0;
    const writer = new SseWriter(asRes(res));
    writer.onDisconnect = (): void => {
      count += 1;
    };
    writer.openHeaders();
    vi.advanceTimersByTime(15_000); // keepalive tick → failed write → onDisconnect
    expect(count).toBe(1);
    expect(writer.disconnected).toBe(true);
  });
});
