import { describe, expect, it } from 'vitest';

import { createChatHandler, ChatServerConfigError } from '../src/server';
import {
  asFirestore,
  baseDeps,
  clientRegistry,
  FakeFirestore,
  FakeOpenAIClient,
  RecordingHooks,
} from './fixtures/server-fakes';

// A. Factory / config — fail-closed construction (task §3/§12A). All deps are
// injected; no global/default Firebase Admin state is ever touched (the factory
// simply builds from the fakes below).

describe('createChatHandler — construction', () => {
  it('builds a handler from injected concrete dependencies (no global state)', () => {
    const handler = createChatHandler(baseDeps({}));
    expect(typeof handler).toBe('function');
  });

  it('rejects a missing hook', () => {
    const hooks = new RecordingHooks();
    // Remove one required hook.
    (hooks as unknown as { settleQuota?: unknown }).settleQuota = undefined;
    expect(() => createChatHandler(baseDeps({ hooks }))).toThrow(ChatServerConfigError);
  });

  it('rejects a missing auth/appCheck instance', () => {
    expect(() => createChatHandler(baseDeps({ auth: undefined as never }))).toThrow(ChatServerConfigError);
    expect(() => createChatHandler(baseDeps({ appCheck: undefined as never }))).toThrow(ChatServerConfigError);
  });

  it('rejects a missing firestore/bucket', () => {
    expect(() => createChatHandler(baseDeps({ firestore: undefined as never }))).toThrow(ChatServerConfigError);
    expect(() => createChatHandler(baseDeps({ bucket: undefined as never }))).toThrow(ChatServerConfigError);
  });

  it('rejects an empty provider registry', () => {
    expect(() => createChatHandler(baseDeps({ openAIClients: new Map() }))).toThrow(ChatServerConfigError);
  });

  it('rejects a provider client that is not configured with maxRetries: 0', () => {
    const client = new FakeOpenAIClient({ kind: 'events', events: [] }, 2);
    expect(() => createChatHandler(baseDeps({ openAIClients: clientRegistry(client) }))).toThrow(
      ChatServerConfigError,
    );
  });

  it.each([0, -1, 1.5, Number.NaN])('rejects a non positive-integer functionTimeoutSeconds (%s)', (value) => {
    expect(() => createChatHandler(baseDeps({ functionTimeoutSeconds: value }))).toThrow(ChatServerConfigError);
  });

  it.each([29, 0, -1, 30.5])('rejects replayTtlSeconds below 30 or non-integer (%s)', (value) => {
    expect(() => createChatHandler(baseDeps({ replayTtlSeconds: value }))).toThrow(ChatServerConfigError);
  });

  it('accepts the minimum replayTtlSeconds of 30', () => {
    expect(() => createChatHandler(baseDeps({ replayTtlSeconds: 30 }))).not.toThrow();
  });

  it('does not touch Firestore/hooks/provider at construction time', () => {
    const firestore = new FakeFirestore();
    const hooks = new RecordingHooks();
    const client = new FakeOpenAIClient({ kind: 'events', events: [] });
    createChatHandler(baseDeps({ firestore: asFirestore(firestore), hooks, openAIClients: clientRegistry(client) }));
    expect(firestore.store.size).toBe(0);
    expect(hooks.calls).toEqual([]);
    expect(client.callCount).toBe(0);
  });
});
