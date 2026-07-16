// In-memory, network-free concrete stand-ins for the injected dependencies
// (Vitest built-ins only; no mock/DI framework). They implement exactly the
// surface the handler uses and are cast to the concrete SDK types at the
// dependency boundary — the natural test seam of the factory (docs/
// server-template.md «Test seam»). No real Firebase, no API key, no sockets.

import { Timestamp } from 'firebase-admin/firestore';
import type { Auth } from 'firebase-admin/auth';
import type { AppCheck } from 'firebase-admin/app-check';
import type { Firestore } from 'firebase-admin/firestore';
import type OpenAI from 'openai';
import type { Responses } from 'openai/resources';

import { storageSafeUid } from '../../src/server/canonical';
import type { ChatServerDependencies, ReplayBucket } from '../../src/server/dependencies';
import type {
  ChatServerHooks,
  EntitlementResult,
  QuotaOutcome,
  QuotaReservation,
  RateLimitResult,
  ReserveQuotaRequest,
  ReserveQuotaResult,
  Tier,
} from '../../src/server/hooks';
import type { ChatHandlerRequest, ChatHandlerResponse } from '../../src/server/transport';
import type { IdempotencyRecord } from '../../src/server/firestore';

export const UID = 'user-1';
export const GOOD_TOKEN = 'good-id-token';
export const GOOD_APPCHECK = 'good-appcheck';
export const OPENAI_TIER: Tier = {
  id: 'premium',
  provider: 'openai',
  model: 'gpt-5',
  maxOutputTokens: 4096,
};

// --- Firestore ---------------------------------------------------------------

interface DocRef {
  path: string;
  get(): Promise<{ exists: boolean; data(): unknown }>;
}

export class FakeFirestore {
  readonly store = new Map<string, Record<string, unknown>>();
  private chain: Promise<unknown> = Promise.resolve();
  private txIndex = 0;
  /** Deterministic race hook: fires before each transaction (1-based index). */
  beforeTransaction?: (index: number) => void;
  /** Deterministic race hook: fires before each non-transactional read. */
  beforeGet?: () => void;

  doc(path: string): DocRef {
    const snap = (): { exists: boolean; data(): unknown } => {
      const data = this.store.get(path);
      return { exists: data !== undefined, data: () => data };
    };
    return {
      path,
      get: async () => {
        this.beforeGet?.();
        return snap();
      },
    };
  }

  seed(path: string, record: IdempotencyRecord): void {
    this.store.set(path, record as unknown as Record<string, unknown>);
  }

  async runTransaction<T>(fn: (tx: FakeTransaction) => Promise<T>): Promise<T> {
    // Serialize transactions (Firestore is serializable); exactly one create wins.
    const run = this.chain.then(async () => {
      this.txIndex += 1;
      this.beforeTransaction?.(this.txIndex);
      const tx = new FakeTransaction(this.store);
      const result = await fn(tx);
      tx.commit();
      return result;
    });
    this.chain = run.catch(() => undefined);
    return run as Promise<T>;
  }
}

type WriteOp =
  | { kind: 'set'; path: string; data: Record<string, unknown> }
  | { kind: 'update'; path: string; data: Record<string, unknown> }
  | { kind: 'delete'; path: string };

class FakeTransaction {
  private readonly writes: WriteOp[] = [];
  constructor(private readonly store: Map<string, Record<string, unknown>>) {}

  async get(ref: DocRef): Promise<{ exists: boolean; data(): unknown }> {
    const data = this.store.get(ref.path);
    return { exists: data !== undefined, data: () => data };
  }

  set(ref: DocRef, data: Record<string, unknown>): void {
    this.writes.push({ kind: 'set', path: ref.path, data });
  }

  update(ref: DocRef, data: Record<string, unknown>): void {
    this.writes.push({ kind: 'update', path: ref.path, data });
  }

  delete(ref: DocRef): void {
    this.writes.push({ kind: 'delete', path: ref.path });
  }

  commit(): void {
    for (const op of this.writes) {
      if (op.kind === 'set') this.store.set(op.path, op.data);
      else if (op.kind === 'update') this.store.set(op.path, { ...this.store.get(op.path), ...op.data });
      else this.store.delete(op.path);
    }
  }
}

export function asFirestore(fake: FakeFirestore): Firestore {
  return fake as unknown as Firestore;
}

// --- GCS bucket --------------------------------------------------------------

export interface StoredObject {
  data: Buffer;
  metadata: Record<string, unknown>;
}

export interface BucketHooks {
  /** Throw to simulate a failed create/finalize of a given path. */
  onSave?: (path: string) => void;
  /** Return tampered bytes to fail read-back verification. */
  onDownload?: (path: string, stored: Buffer) => Buffer;
}

export class FakeBucket {
  readonly objects = new Map<string, StoredObject>();
  /** Every path actually downloaded (to assert a wrong path is never read). */
  readonly downloads: string[] = [];
  constructor(private readonly hooks: BucketHooks = {}) {}

  file(path: string): {
    save(data: Buffer, opts: SaveOptions): Promise<void>;
    download(): Promise<[Buffer]>;
    getMetadata(): Promise<[{ metadata: Record<string, unknown> }]>;
    delete(opts?: { ignoreNotFound?: boolean }): Promise<void>;
  } {
    return {
      save: async (data, opts) => {
        this.hooks.onSave?.(path);
        const createOnly = opts?.preconditionOpts?.ifGenerationMatch === 0;
        if (createOnly && this.objects.has(path)) {
          throw new Error('precondition failed: object exists');
        }
        this.objects.set(path, {
          data: Buffer.from(data),
          metadata: (opts?.metadata?.metadata ?? {}) as Record<string, unknown>,
        });
      },
      download: async () => {
        this.downloads.push(path);
        const stored = this.objects.get(path);
        if (stored === undefined) throw new Error('object not found');
        const bytes = this.hooks.onDownload?.(path, stored.data) ?? stored.data;
        return [bytes];
      },
      getMetadata: async () => {
        const stored = this.objects.get(path);
        if (stored === undefined) throw new Error('object not found');
        return [{ metadata: stored.metadata }];
      },
      delete: async (opts) => {
        if (!this.objects.has(path) && opts?.ignoreNotFound) return;
        this.objects.delete(path);
      },
    };
  }
}

interface SaveOptions {
  resumable?: boolean;
  contentType?: string;
  preconditionOpts?: { ifGenerationMatch?: number };
  metadata?: { metadata?: Record<string, string> };
}

export function asBucket(fake: FakeBucket): ReplayBucket {
  return fake as unknown as ReplayBucket;
}

// --- Auth / App Check --------------------------------------------------------

export function makeAuth(validToken = GOOD_TOKEN, uid = UID): Auth {
  return {
    verifyIdToken: async (token: string) => {
      if (token !== validToken) throw new Error('invalid id token');
      return { uid };
    },
  } as unknown as Auth;
}

export function makeAppCheck(validToken = GOOD_APPCHECK): AppCheck {
  return {
    verifyToken: async (token: string) => {
      if (token !== validToken) throw new Error('invalid app check token');
      return { appId: 'app-1' };
    },
  } as unknown as AppCheck;
}

// --- Business hooks ----------------------------------------------------------

export interface HookOverrides {
  checkEntitlement?: (uid: string, botId: string) => Promise<EntitlementResult>;
  checkRateLimit?: (uid: string, botId: string) => Promise<RateLimitResult>;
  reserveQuota?: (request: ReserveQuotaRequest) => Promise<ReserveQuotaResult>;
  settleQuota?: (reservation: QuotaReservation, outcome: QuotaOutcome) => Promise<void>;
}

export class RecordingHooks implements ChatServerHooks {
  readonly calls: string[] = [];
  readonly settlements: Array<{ reservation: QuotaReservation; outcome: QuotaOutcome }> = [];
  readonly reserveRequests: ReserveQuotaRequest[] = [];

  constructor(private readonly overrides: HookOverrides = {}) {}

  async checkEntitlement(uid: string, botId: string): Promise<EntitlementResult> {
    this.calls.push('checkEntitlement');
    if (this.overrides.checkEntitlement) return this.overrides.checkEntitlement(uid, botId);
    return { kind: 'allowed', tier: OPENAI_TIER };
  }

  async checkRateLimit(uid: string, botId: string): Promise<RateLimitResult> {
    this.calls.push('checkRateLimit');
    if (this.overrides.checkRateLimit) return this.overrides.checkRateLimit(uid, botId);
    return { kind: 'allowed' };
  }

  async reserveQuota(request: ReserveQuotaRequest): Promise<ReserveQuotaResult> {
    this.calls.push(`reserveQuota:${request.kind}`);
    this.reserveRequests.push(request);
    if (this.overrides.reserveQuota) return this.overrides.reserveQuota(request);
    return { kind: 'reserved', reservation: { attemptKey: request.attemptKey, reservationId: 'res-1' } };
  }

  async settleQuota(reservation: QuotaReservation, outcome: QuotaOutcome): Promise<void> {
    this.calls.push(`settleQuota:${outcome.kind}`);
    this.settlements.push({ reservation, outcome });
    if (this.overrides.settleQuota) return this.overrides.settleQuota(reservation, outcome);
  }
}

// --- OpenAI client -----------------------------------------------------------

export type StreamBehavior =
  | { kind: 'events'; events: Responses.ResponseStreamEvent[] }
  | { kind: 'reject'; error: unknown }
  | { kind: 'generator'; make: (signal: AbortSignal) => AsyncGenerator<Responses.ResponseStreamEvent> };

export class FakeOpenAIClient {
  callCount = 0;
  lastRequest: Responses.ResponseCreateParamsStreaming | null = null;
  readonly maxRetries: number;

  constructor(private readonly behavior: StreamBehavior, maxRetries = 0) {
    this.maxRetries = maxRetries;
  }

  readonly responses = {
    create: async (
      body: Responses.ResponseCreateParamsStreaming,
      opts?: { signal?: AbortSignal },
    ): Promise<AsyncIterable<Responses.ResponseStreamEvent>> => {
      this.callCount += 1;
      this.lastRequest = body;
      if (this.behavior.kind === 'reject') throw this.behavior.error;
      if (this.behavior.kind === 'generator') {
        return this.behavior.make(opts?.signal ?? new AbortController().signal);
      }
      const events = this.behavior.events;
      return (async function* () {
        for (const event of events) yield event;
      })();
    },
  };
}

export function clientRegistry(client: FakeOpenAIClient, tierId = OPENAI_TIER.id): Map<string, OpenAI> {
  return new Map<string, OpenAI>([[tierId, client as unknown as OpenAI]]);
}

// --- HTTP req/res ------------------------------------------------------------

export class FakeReq {
  readonly method: string;
  readonly headers: Record<string, string | undefined>;
  readonly rawBody: Buffer;
  private readonly listeners = new Map<string, Array<() => void>>();

  constructor(opts: {
    method?: string;
    headers?: Record<string, string | undefined>;
    rawBody?: Buffer;
  }) {
    this.method = opts.method ?? 'POST';
    this.headers = opts.headers ?? {};
    this.rawBody = opts.rawBody ?? Buffer.alloc(0);
  }

  on(event: string, listener: () => void): this {
    const list = this.listeners.get(event) ?? [];
    list.push(listener);
    this.listeners.set(event, list);
    return this;
  }

  removeListener(event: string, listener: () => void): this {
    const list = this.listeners.get(event);
    if (list) this.listeners.set(event, list.filter((l) => l !== listener));
    return this;
  }

  /** Fires a request lifecycle event (e.g. 'close', 'aborted'). */
  emit(event: string): void {
    for (const listener of this.listeners.get(event) ?? []) listener();
  }

  /** Simulates an observed client disconnect (request close). */
  emitClose(): void {
    this.emit('close');
  }
}

export class FakeRes {
  statusCode = 200;
  headersSent = false;
  writableEnded = false;
  failWrite = false;
  readonly headers: Record<string, string> = {};
  readonly chunks: string[] = [];
  private readonly listeners = new Map<string, Array<() => void>>();

  setHeader(name: string, value: string | number): void {
    this.headers[name.toLowerCase()] = String(value);
  }

  flushHeaders(): void {
    this.headersSent = true;
  }

  write(chunk: string): boolean {
    if (this.failWrite) throw new Error('EPIPE: connection gone');
    this.headersSent = true;
    this.chunks.push(chunk);
    return true;
  }

  end(chunk?: string): void {
    this.headersSent = true;
    if (chunk !== undefined) this.chunks.push(chunk);
    this.writableEnded = true;
  }

  on(event: string, listener: () => void): this {
    const list = this.listeners.get(event) ?? [];
    list.push(listener);
    this.listeners.set(event, list);
    return this;
  }

  removeListener(event: string, listener: () => void): this {
    const list = this.listeners.get(event);
    if (list) this.listeners.set(event, list.filter((l) => l !== listener));
    return this;
  }

  /** Simulates the response stream closing / erroring (observed disconnect). */
  emit(event: 'close' | 'error'): void {
    for (const listener of this.listeners.get(event) ?? []) listener();
  }

  body(): string {
    return this.chunks.join('');
  }

  json(): unknown {
    return JSON.parse(this.body());
  }
}

export function asReq(fake: FakeReq): ChatHandlerRequest {
  return fake as unknown as ChatHandlerRequest;
}

export function asRes(fake: FakeRes): ChatHandlerResponse {
  return fake as unknown as ChatHandlerResponse;
}

// --- request/body/record builders -------------------------------------------

export function uuid(seed = 'a'): string {
  const h = seed.padEnd(2, '0').slice(0, 2);
  return `${h}bcdef0-1234-4567-89ab-cdef01234567`;
}

/** The storage-safe path segment for {@link UID} (base64url; P1-6). */
export const UID_SEGMENT = storageSafeUid(UID);

/** Firestore idempotency doc path for {@link UID} + a key (storage-safe uid). */
export function docPath(attemptKey: string): string {
  return `idempotency/${UID_SEGMENT}/keys/${attemptKey}`;
}

/** GCS replay object path for {@link UID} + a key + runId (storage-safe uid). */
export function objectPath(attemptKey: string, runId: string): string {
  return `chat-replays/${UID_SEGMENT}/${attemptKey}/${runId}.sse`;
}

export function validBody(
  overrides: Partial<Record<'wireVersion' | 'botId' | 'system' | 'messages' | 'tools', unknown>> = {},
): Record<string, unknown> {
  const base: Record<string, unknown> = {
    wireVersion: 1,
    botId: 'premium',
    system: 'You are helpful.',
    messages: [
      {
        id: 'm1',
        role: 'user',
        status: 'sent',
        createdAt: '2026-07-13T00:00:00Z',
        parts: [{ type: 'text', text: 'Hello' }],
      },
    ],
  };
  return { ...base, ...overrides };
}

export function makeReq(opts: {
  method?: string;
  authorization?: string | undefined;
  appCheck?: string | undefined;
  idempotencyKey?: string | undefined;
  body?: Record<string, unknown> | string;
  rawBody?: Buffer;
} = {}): FakeReq {
  const headers: Record<string, string | undefined> = {};
  if (opts.authorization !== null) {
    headers['authorization'] = opts.authorization ?? `Bearer ${GOOD_TOKEN}`;
  }
  if (opts.appCheck !== null) headers['x-firebase-appcheck'] = opts.appCheck ?? GOOD_APPCHECK;
  headers['idempotency-key'] = opts.idempotencyKey === undefined ? uuid('a') : opts.idempotencyKey;

  let rawBody: Buffer;
  if (opts.rawBody !== undefined) rawBody = opts.rawBody;
  else if (typeof opts.body === 'string') rawBody = Buffer.from(opts.body, 'utf8');
  else rawBody = Buffer.from(JSON.stringify(opts.body ?? validBody()), 'utf8');

  return new FakeReq({ method: opts.method ?? 'POST', headers, rawBody });
}

export function baseDeps(over: Partial<ChatServerDependencies>): ChatServerDependencies {
  // Respect an EXPLICIT `undefined` (fail-closed construction tests) — a key that
  // is present overrides the default even when its value is undefined.
  const pick = <K extends keyof ChatServerDependencies>(
    key: K,
    fallback: ChatServerDependencies[K],
  ): ChatServerDependencies[K] => (key in over ? (over[key] as ChatServerDependencies[K]) : fallback);
  return {
    hooks: pick('hooks', new RecordingHooks()),
    auth: pick('auth', makeAuth()),
    appCheck: pick('appCheck', makeAppCheck()),
    firestore: pick('firestore', asFirestore(new FakeFirestore())),
    bucket: pick('bucket', asBucket(new FakeBucket())),
    openAIClients: pick('openAIClients', clientRegistry(new FakeOpenAIClient({ kind: 'events', events: [] }))),
    functionTimeoutSeconds: pick('functionTimeoutSeconds', 60),
    replayTtlSeconds: pick('replayTtlSeconds', 600),
  };
}

/** Parses an SSE body into `{event, data}` records (ignores keepalive comments). */
export function parseSse(body: string): Array<{ event: string; data: unknown }> {
  const out: Array<{ event: string; data: unknown }> = [];
  for (const block of body.split('\n\n')) {
    const lines = block.split('\n');
    const eventLine = lines.find((l) => l.startsWith('event: '));
    const dataLine = lines.find((l) => l.startsWith('data: '));
    if (eventLine && dataLine) {
      out.push({ event: eventLine.slice('event: '.length), data: JSON.parse(dataLine.slice('data: '.length)) });
    }
  }
  return out;
}

export { Timestamp };
