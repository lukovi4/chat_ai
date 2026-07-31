// The connection-independent reply runner: one full logical AI reply —
// several billable provider legs, the server-side tool loop, normalised events,
// a structured terminal outcome and aggregated usage — with NO HTTP/SSE request
// lifecycle and NO Firebase.
//
// It is a narrow composition of the existing provider logic, not a framework:
// `buildOpenAIResponsesRequest`, `translateOpenAIStream`, `classifyOpenAIError`,
// `hasZeroRetries` and `validateArgumentInstance` are reused, never copied.
//
// Ownership boundary (docs/server-template.md): persistence, admission, quota,
// idempotency, the worker host and its deployment belong to the APPLICATION.
// The runner keeps no state beyond one call, mints no `attemptKey`, retries
// nothing and stores nothing. The app owns every billable leg's key: the FIRST
// leg uses the `firstAttemptKey` the caller had already persisted before the
// runner was entered, and `onLegStart` is awaited before every FOLLOWING
// provider dispatch — so no billable leg is hidden.
//
// Three identities, never mixed: `replyId` (the whole logical reply, minted by
// the caller), `attemptKey` (one billable provider leg, minted by the app in
// `onLegStart`) and `toolCallId` (one tool call, minted by the provider).

import type OpenAI from 'openai';
import type { Responses } from 'openai/resources';

import { validateArgumentInstance } from '../core/tool-schema';
import type {
  ChatRequest,
  NormalizedEvent,
  NormalizedUsage,
  WireCause,
  WireContentPart,
  WireMessage,
  WireTool,
} from '../core/wire';
import { buildOpenAIResponsesRequest, type ResolvedOpenAITier } from '../providers/openai/request';
import { translateOpenAIStream } from '../providers/openai/stream';
import { classifyOpenAIError, hasZeroRetries } from '../server/openai';

// ---------------------------------------------------------------------------
// Public contract
// ---------------------------------------------------------------------------

/** Why a runner call was refused before any provider work happened. */
export type ChatReplyConfigurationErrorReason =
  | 'missing-reply-id'
  | 'provider-retries-enabled'
  | 'tools-without-handler'
  | 'invalid-max-tool-turns';

/**
 * A local configuration fault. Thrown BEFORE `onLegStart` and before any
 * provider dispatch — it is never reported as `aborted`, because nothing was
 * dispatched. The message is the stable reason string; no payload rides along.
 */
export class ChatReplyConfigurationError extends Error {
  override readonly name = 'ChatReplyConfigurationError';

  constructor(readonly reason: ChatReplyConfigurationErrorReason) {
    super(reason);
  }
}

/** What the app is told before one billable provider leg is dispatched. */
export interface ChatReplyLegContext {
  readonly replyId: string;
  /**
   * Zero-based index of this provider leg inside the logical reply. Always
   * `>= 1`: leg 0 runs under the caller's `firstAttemptKey`.
   */
  readonly legIndex: number;
  /** The exact provider-effective SDK request of this leg. */
  readonly request: Responses.ResponseCreateParamsStreaming;
}

/** The app's answer: its own stable `attemptKey` (UUID v4, ADR 0004). */
export interface ChatReplyLegDispatch {
  readonly attemptKey: string;
}

/**
 * The app-owned persistence boundary, awaited before every
 * `client.responses.create` EXCEPT the first one — that leg's key is the
 * caller's `firstAttemptKey`, already persisted before the runner was entered.
 * The package neither generates nor stores the returned key and runs no
 * admission/quota/idempotency of its own.
 */
export type ChatReplyLegStart = (
  leg: ChatReplyLegContext,
) => ChatReplyLegDispatch | Promise<ChatReplyLegDispatch>;

/**
 * One normalised event plus its identity context, so the app never has to
 * correlate events through an external mutable closure. `NormalizedEvent` is
 * unchanged: this envelope is not a second provider event model.
 */
export interface ChatReplyEventDelivery {
  readonly replyId: string;
  readonly legIndex: number;
  readonly attemptKey: string;
  readonly event: NormalizedEvent;
}

/** Ordered, awaited event delivery. Absent sink ⇒ every event is accepted. */
export type ChatReplyEventSink = (
  delivery: ChatReplyEventDelivery,
) => void | Promise<void>;

/** A declared tool call with arguments already re-validated by the runner. */
export interface ChatReplyToolCall {
  readonly toolCallId: string;
  readonly name: string;
  readonly args: Record<string, unknown>;
}

/** The app's tool answer; `isError: true` tells the bot the tool failed. */
export interface ChatReplyToolResult {
  readonly content: string;
  readonly isError?: boolean;
}

export type ChatReplyToolHandler = (
  call: ChatReplyToolCall,
) => ChatReplyToolResult | Promise<ChatReplyToolResult>;

export interface RunChatReplyOptions {
  readonly replyId: string;
  /** An ALREADY validated `ChatRequest`; the runner adds no second ingress. */
  readonly request: ChatRequest;
  readonly client: OpenAI;
  readonly tier: ResolvedOpenAITier;
  /**
   * The key of the FIRST provider leg (UUID v4, ADR 0004): minted and
   * persisted by the caller before the runner was entered, so `onLegStart` is
   * never asked for it. A value that is not a UUID v4 ends the run as
   * `local-error` / `leg-start` / `not-dispatched`, with no provider call.
   */
  readonly firstAttemptKey: string;
  readonly onLegStart: ChatReplyLegStart;
  readonly onEvent?: ChatReplyEventSink;
  readonly onToolCall?: ChatReplyToolHandler;
  readonly maxToolTurns?: number;
  readonly signal?: AbortSignal;
}

/** The outcome of ONE provider leg. */
export type ChatReplyLegOutcome =
  /** The provider was never called for this leg. */
  | { readonly kind: 'not-dispatched' }
  /** Terminal `done`. */
  | { readonly kind: 'done' }
  /** Terminal `tool_call`. */
  | {
      readonly kind: 'tool-call';
      readonly toolCallId: string;
    }
  /** A pre-stream provider rejection that is PROVABLY unbilled (safe retry). */
  | {
      readonly kind: 'release';
      readonly cause: WireCause;
      readonly retryAfterMs?: number;
    }
  /** Ambiguous outcome (fail closed): mid-stream error, abort or sink failure. */
  | {
      readonly kind: 'aborted';
      readonly cause?: WireCause;
    };

export interface ChatReplyLegRecord {
  readonly legIndex: number;
  readonly attemptKey: string;
  readonly dispatched: boolean;
  readonly outcome: ChatReplyLegOutcome;
  /** This leg's exact provider usage, when it reported one. */
  readonly usage?: NormalizedUsage;
}

/** The terminal outcome of the whole logical reply. */
export type ChatReplyTermination =
  | { readonly kind: 'done' }
  | {
      readonly kind: 'provider-error';
      readonly cause: WireCause;
      readonly detail?: string;
      readonly retryAfterMs?: number;
      readonly disposition: 'release' | 'aborted';
    }
  | { readonly kind: 'tool-loop-limit' }
  | {
      readonly kind: 'cancelled';
      readonly legIndex: number;
      /** The fate of the leg in flight when the cancellation was observed. */
      readonly disposition: 'not-dispatched' | 'aborted';
    }
  | {
      readonly kind: 'local-error';
      readonly stage: 'request-translation' | 'leg-start';
      readonly legIndex: number;
      readonly disposition: 'not-dispatched';
      readonly error: unknown;
    }
  | {
      readonly kind: 'sink-error';
      readonly legIndex: number;
      readonly disposition: 'release' | 'aborted';
      readonly error: unknown;
    };

/**
 * Aggregated usage over the REALLY dispatched legs. Missing usage is never
 * faked with zeros: a partial sum is reported as `null` totals with
 * `exact: false`, and the exact per-leg values stay in `legs[i].usage`.
 */
export interface ChatReplyUsage {
  readonly inputTokens: number | null;
  readonly outputTokens: number | null;
  readonly exact: boolean;
  /** Kept only for a single-dispatched-leg reply. */
  readonly usageRaw?: Record<string, unknown>;
}

export interface ChatReplyResult {
  readonly replyId: string;
  readonly termination: ChatReplyTermination;
  /** Accumulated assistant parts — exactly what the sink accepted. */
  readonly parts: readonly WireContentPart[];
  readonly usage: ChatReplyUsage;
  readonly legs: readonly ChatReplyLegRecord[];
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

/** The Dart Core's tool-loop cap (V1_SPEC §11): five tool turns, six legs. */
const DEFAULT_MAX_TOOL_TURNS = 5;

/** Canonical UUID v4 — the `attemptKey` discipline of ADR 0004. */
const UUID_V4_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/** The sanitised tool-result contents (V1_SPEC §4): stable machine markers. */
const UNKNOWN_TOOL = 'unknown-tool';
const INVALID_TOOL_ARGUMENTS = 'invalid-tool-arguments';
const TOOL_EXECUTION_FAILED = 'tool-execution-failed';

type Raced<T> =
  | { readonly status: 'ok'; readonly value: T }
  | { readonly status: 'aborted' }
  | { readonly status: 'failed'; readonly error: unknown };

/**
 * Awaits an app callback but finishes promptly when the caller aborts. The
 * app's promise is never physically cancelled: its late result is ignored and
 * its late rejection is swallowed here, so it can never become an unhandled
 * rejection.
 */
async function raceAbort<T>(
  run: () => T | Promise<T>,
  signal: AbortSignal | undefined,
): Promise<Raced<T>> {
  // An already aborted caller never reaches the app's callback at all.
  if (isAborted(signal)) return { status: 'aborted' };
  let settled: Promise<Raced<T>>;
  try {
    settled = Promise.resolve(run()).then(
      (value): Raced<T> => ({ status: 'ok', value }),
      (error: unknown): Raced<T> => ({ status: 'failed', error }),
    );
  } catch (error) {
    // A synchronous throw of the callback itself.
    return { status: 'failed', error };
  }
  if (signal === undefined) return settled;
  // An abort raised BY the callback itself (or between the two reads) wins the
  // boundary: the event/result is treated as not accepted, never applied.
  if (signal.aborted) return { status: 'aborted' };

  const listener = new AbortController();
  const aborted = new Promise<Raced<T>>((resolve) => {
    signal.addEventListener('abort', () => resolve({ status: 'aborted' }), {
      once: true,
      signal: listener.signal,
    });
  });
  try {
    return await Promise.race([settled, aborted]);
  } finally {
    listener.abort(); // detaches the listener; `settled` stays handled
  }
}

/** Chains the caller signal into this leg's own controller. */
function linkAbort(signal: AbortSignal | undefined, controller: AbortController): () => void {
  if (signal === undefined) return () => {};
  if (signal.aborted) {
    controller.abort();
    return () => {};
  }
  const listener = new AbortController();
  signal.addEventListener('abort', () => controller.abort(), {
    once: true,
    signal: listener.signal,
  });
  return () => listener.abort();
}

/**
 * Reads the caller signal through a call, so an earlier check never narrows
 * the flag away: `aborted` flips between two reads by design.
 */
function isAborted(signal: AbortSignal | undefined): boolean {
  return signal !== undefined && signal.aborted;
}

function isUuidV4(value: unknown): value is string {
  return typeof value === 'string' && UUID_V4_RE.test(value);
}

function isToolResult(value: unknown): value is ChatReplyToolResult {
  if (typeof value !== 'object' || value === null) return false;
  const candidate = value as { content?: unknown; isError?: unknown };
  if (typeof candidate.content !== 'string') return false;
  return candidate.isError === undefined || typeof candidate.isError === 'boolean';
}

/** Outcome of one awaited event delivery. */
type Delivery =
  | { readonly status: 'ok' }
  | { readonly status: 'aborted' }
  | { readonly status: 'failed'; readonly error: unknown };

/** What one provider leg ended with, before it is turned into a record. */
type LegRun =
  | {
      readonly kind: 'tool-call';
      readonly toolCallId: string;
      readonly name: string;
      readonly args: Record<string, unknown>;
      readonly usage?: NormalizedUsage;
    }
  | { readonly kind: 'done'; readonly usage?: NormalizedUsage }
  | {
      readonly kind: 'provider-error';
      readonly cause: WireCause;
      readonly detail?: string;
      readonly retryAfterMs?: number;
      readonly disposition: 'release' | 'aborted';
      readonly usage?: NormalizedUsage;
    }
  | { readonly kind: 'cancelled' }
  | {
      readonly kind: 'sink-error';
      readonly error: unknown;
      readonly disposition: 'release' | 'aborted';
      /** The classified provider cause, kept when the leg stays released. */
      readonly cause?: WireCause;
      readonly retryAfterMs?: number;
    };

/**
 * Runs one billable provider leg: dispatch → normalised events → deliver →
 * apply. Deliberately private to this module — the runner exposes one entry
 * point, not a leg framework.
 */
async function runOneLeg(
  client: OpenAI,
  providerRequest: Responses.ResponseCreateParamsStreaming,
  signal: AbortSignal | undefined,
  deliver: (event: NormalizedEvent) => Promise<Delivery>,
  applyNonTerminal: (event: NormalizedEvent) => void,
): Promise<LegRun> {
  const controller = new AbortController();
  const unlink = linkAbort(signal, controller);
  try {
    let stream: AsyncIterable<Responses.ResponseStreamEvent>;
    try {
      stream = await client.responses.create(providerRequest, { signal: controller.signal });
    } catch (error) {
      if (isAborted(signal)) return { kind: 'cancelled' };
      // The existing closed allowlist decides release vs fail-closed; its
      // cause/retryAfterMs/disposition are carried through verbatim.
      const classified = classifyOpenAIError(error);
      const event: NormalizedEvent =
        classified.retryAfterMs === undefined
          ? { kind: 'error', cause: classified.cause }
          : { kind: 'error', cause: classified.cause, retryAfterMs: classified.retryAfterMs };
      const delivered = await deliver(event);
      if (delivered.status === 'failed') {
        // A refused delivery does not re-open the provider question: a
        // provably unbilled pre-stream rejection stays released, with its
        // classified cause, so the leg record cannot contradict the terminal.
        return {
          kind: 'sink-error',
          error: delivered.error,
          disposition: classified.disposition,
          cause: classified.cause,
          retryAfterMs: classified.retryAfterMs,
        };
      }
      if (delivered.status === 'aborted') return { kind: 'cancelled' };
      return {
        kind: 'provider-error',
        cause: classified.cause,
        retryAfterMs: classified.retryAfterMs,
        disposition: classified.disposition,
      };
    }

    for await (const event of translateOpenAIStream(stream)) {
      if (isAborted(signal)) {
        controller.abort();
        return { kind: 'cancelled' };
      }
      const delivered = await deliver(event);
      if (delivered.status === 'failed') {
        controller.abort();
        return { kind: 'sink-error', error: delivered.error, disposition: 'aborted' };
      }
      if (delivered.status === 'aborted') {
        controller.abort();
        return { kind: 'cancelled' };
      }
      // Only an accepted event is applied to the accumulated reply.
      switch (event.kind) {
        case 'delta':
        case 'provider_state':
          applyNonTerminal(event);
          break;
        case 'tool_call':
          return {
            kind: 'tool-call',
            toolCallId: event.id,
            name: event.name,
            args: event.args,
            usage: event.usage,
          };
        case 'done':
          return { kind: 'done', usage: event.usage };
        case 'error':
          // Mid-stream failure: a leg was streaming, so the outcome is
          // ambiguous by definition.
          return {
            kind: 'provider-error',
            cause: event.cause,
            detail: event.detail,
            retryAfterMs: event.retryAfterMs,
            disposition: 'aborted',
            usage: event.usage,
          };
      }
    }
    // Defensive: the translator always yields exactly one terminal.
    return { kind: 'provider-error', cause: 'upstream', disposition: 'aborted' };
  } finally {
    unlink();
  }
}

/**
 * Runs one full logical reply to its terminal outcome.
 *
 * Throws [ChatReplyConfigurationError] — and only that — before any provider
 * work; every other outcome is data in the returned [ChatReplyResult].
 */
export async function runChatReply(options: RunChatReplyOptions): Promise<ChatReplyResult> {
  const { replyId, request, client, tier, firstAttemptKey, onLegStart, onEvent, onToolCall, signal } =
    options;
  const maxToolTurns = options.maxToolTurns ?? DEFAULT_MAX_TOOL_TURNS;

  if (typeof replyId !== 'string' || replyId.trim().length === 0) {
    throw new ChatReplyConfigurationError('missing-reply-id');
  }
  if (!hasZeroRetries(client)) {
    throw new ChatReplyConfigurationError('provider-retries-enabled');
  }
  const declarations: readonly WireTool[] = request.tools ?? [];
  if (declarations.length > 0 && onToolCall === undefined) {
    throw new ChatReplyConfigurationError('tools-without-handler');
  }
  if (!Number.isSafeInteger(maxToolTurns) || maxToolTurns <= 0) {
    throw new ChatReplyConfigurationError('invalid-max-tool-turns');
  }

  const parts: WireContentPart[] = [];
  const legs: ChatReplyLegRecord[] = [];
  // One stable timestamp for the synthetic assistant Message of later legs;
  // provider translation ignores it, but the value must not drift per leg.
  const createdAt = new Date().toISOString();
  let legIndex = 0;
  let toolTurnsUsed = 0;

  const finish = (termination: ChatReplyTermination): ChatReplyResult => ({
    replyId,
    termination,
    parts: [...parts],
    usage: aggregateUsage(legs),
    legs: [...legs],
  });

  /** The provider-effective request of the next leg; `request` is never mutated. */
  const requestForLeg = (): ChatRequest => {
    if (parts.length === 0) return request;
    const assistant: WireMessage = {
      id: replyId,
      role: 'assistant',
      parts: [...parts],
      status: 'streaming',
      createdAt,
    };
    return { ...request, messages: [...request.messages, assistant] };
  };

  const applyNonTerminal = (event: NormalizedEvent): void => {
    if (event.kind === 'delta') {
      const last = parts[parts.length - 1];
      if (last !== undefined && last.type === 'text') {
        parts[parts.length - 1] = { type: 'text', text: last.text + event.text };
      } else {
        parts.push({ type: 'text', text: event.text });
      }
      return;
    }
    if (event.kind === 'provider_state') {
      parts.push({
        type: 'providerOpaque',
        provider: event.provider,
        data: Buffer.from(event.data).toString('base64'),
      });
    }
  };

  for (;;) {
    if (isAborted(signal)) {
      return finish({ kind: 'cancelled', legIndex, disposition: 'not-dispatched' });
    }

    let providerRequest: Responses.ResponseCreateParamsStreaming;
    try {
      providerRequest = buildOpenAIResponsesRequest(requestForLeg(), tier);
    } catch (error) {
      return finish({
        kind: 'local-error',
        stage: 'request-translation',
        legIndex,
        disposition: 'not-dispatched',
        error,
      });
    }

    // The app-owned billable boundary. The first leg's key was already minted
    // and persisted by the caller, so it is used verbatim and `onLegStart` is
    // not consulted for it; every following leg is awaited here, before the
    // SDK call. Either way an invalid key means no provider call, and no
    // automatic replacement key is ever minted.
    let attemptKey: string;
    if (legIndex === 0) {
      if (!isUuidV4(firstAttemptKey)) {
        return finish({
          kind: 'local-error',
          stage: 'leg-start',
          legIndex,
          disposition: 'not-dispatched',
          error: new TypeError('firstAttemptKey must be a UUID v4'),
        });
      }
      attemptKey = firstAttemptKey;
    } else {
      const started = await raceAbort<ChatReplyLegDispatch>(
        () => onLegStart({ replyId, legIndex, request: providerRequest }),
        signal,
      );
      if (started.status === 'aborted') {
        return finish({ kind: 'cancelled', legIndex, disposition: 'not-dispatched' });
      }
      if (started.status === 'failed') {
        return finish({
          kind: 'local-error',
          stage: 'leg-start',
          legIndex,
          disposition: 'not-dispatched',
          error: started.error,
        });
      }
      const nextKey = started.value?.attemptKey;
      if (!isUuidV4(nextKey)) {
        return finish({
          kind: 'local-error',
          stage: 'leg-start',
          legIndex,
          disposition: 'not-dispatched',
          error: new TypeError('onLegStart must return an attemptKey that is a UUID v4'),
        });
      }
      attemptKey = nextKey;
    }

    if (isAborted(signal)) {
      legs.push({ legIndex, attemptKey, dispatched: false, outcome: { kind: 'not-dispatched' } });
      return finish({ kind: 'cancelled', legIndex, disposition: 'not-dispatched' });
    }

    const deliver = async (event: NormalizedEvent): Promise<Delivery> => {
      if (onEvent === undefined) return { status: 'ok' };
      const raced = await raceAbort(
        () => onEvent({ replyId, legIndex, attemptKey, event }),
        signal,
      );
      if (raced.status === 'ok') return { status: 'ok' };
      if (raced.status === 'aborted') return { status: 'aborted' };
      return { status: 'failed', error: raced.error };
    };

    const run = await runOneLeg(client, providerRequest, signal, deliver, applyNonTerminal);

    if (run.kind === 'done') {
      legs.push({
        legIndex,
        attemptKey,
        dispatched: true,
        outcome: { kind: 'done' },
        usage: run.usage,
      });
      return finish({ kind: 'done' });
    }

    if (run.kind === 'provider-error') {
      legs.push({
        legIndex,
        attemptKey,
        dispatched: true,
        outcome:
          run.disposition === 'release'
            ? { kind: 'release', cause: run.cause, retryAfterMs: run.retryAfterMs }
            : { kind: 'aborted', cause: run.cause },
        usage: run.usage,
      });
      return finish({
        kind: 'provider-error',
        cause: run.cause,
        detail: run.detail,
        retryAfterMs: run.retryAfterMs,
        disposition: run.disposition,
      });
    }

    if (run.kind === 'cancelled') {
      legs.push({ legIndex, attemptKey, dispatched: true, outcome: { kind: 'aborted' } });
      return finish({ kind: 'cancelled', legIndex, disposition: 'aborted' });
    }

    if (run.kind === 'sink-error') {
      // The leg record follows the same disposition as the terminal: a
      // released pre-stream rejection stays a safe `release` (its attemptKey
      // is reusable), everything else is ambiguous.
      legs.push({
        legIndex,
        attemptKey,
        dispatched: true,
        outcome:
          run.disposition === 'release' && run.cause !== undefined
            ? { kind: 'release', cause: run.cause, retryAfterMs: run.retryAfterMs }
            : { kind: 'aborted' },
      });
      return finish({
        kind: 'sink-error',
        legIndex,
        disposition: run.disposition,
        error: run.error,
      });
    }

    // --- the server-side tool loop (mirrors the Dart Core) -------------------

    // 1. The call joins the accumulated reply (at-least-once: never twice).
    if (!parts.some((part) => part.type === 'toolCall' && part.toolCallId === run.toolCallId)) {
      parts.push({
        type: 'toolCall',
        toolCallId: run.toolCallId,
        name: run.name,
        args: run.args,
      });
    }
    // 2. This leg is a successful `tool-call` with its own usage.
    legs.push({
      legIndex,
      attemptKey,
      dispatched: true,
      outcome: { kind: 'tool-call', toolCallId: run.toolCallId },
      usage: run.usage,
    });
    // 3. The loop guard runs BEFORE the callback and before the next leg.
    if (toolTurnsUsed >= maxToolTurns) {
      return finish({ kind: 'tool-loop-limit' });
    }
    // 4. Resolve — or reuse an existing result for this exact call.
    if (!parts.some((part) => part.type === 'toolResult' && part.toolCallId === run.toolCallId)) {
      const resolved = await resolveToolCall(
        { toolCallId: run.toolCallId, name: run.name, args: run.args },
        declarations,
        onToolCall,
        signal,
      );
      if (resolved === null) {
        // Cancelled while the app's tool was running: its late result is
        // ignored (already-executed side effects are never rolled back) and no
        // next leg starts.
        return finish({ kind: 'cancelled', legIndex, disposition: 'not-dispatched' });
      }
      // 5. The matching result closes the exchange.
      parts.push({
        type: 'toolResult',
        toolCallId: run.toolCallId,
        content: resolved.content,
        isError: resolved.isError,
      });
    }
    // 6.-8. Continue the SAME logical reply with the next billable leg.
    toolTurnsUsed += 1;
    legIndex += 1;
  }
}

/**
 * The tool disposition of one call. `null` means the caller aborted while the
 * app's handler was running. A refused call never reaches the handler and gets
 * a sanitised `is_error` result; a handler that throws (or answers with a
 * runtime-invalid value) yields `tool-execution-failed` — its message, stack
 * and any payload never reach the provider.
 */
async function resolveToolCall(
  call: ChatReplyToolCall,
  declarations: readonly WireTool[],
  onToolCall: ChatReplyToolHandler | undefined,
  signal: AbortSignal | undefined,
): Promise<{ content: string; isError: boolean } | null> {
  const declared = declarations.find((tool) => tool.name === call.name);
  if (declared === undefined) {
    return { content: UNKNOWN_TOOL, isError: true };
  }
  if (!validateArgumentInstance(declared.parameters, call.args)) {
    return { content: INVALID_TOOL_ARGUMENTS, isError: true };
  }
  if (onToolCall === undefined) {
    // Unreachable through the public entry (a non-empty toolset without a
    // handler is a configuration error), kept as a fail-closed guard.
    return { content: TOOL_EXECUTION_FAILED, isError: true };
  }
  const raced = await raceAbort(() => onToolCall(call), signal);
  if (raced.status === 'aborted') return null;
  if (raced.status === 'failed' || !isToolResult(raced.value)) {
    return { content: TOOL_EXECUTION_FAILED, isError: true };
  }
  return { content: raced.value.content, isError: raced.value.isError ?? false };
}

/** Aggregates usage over the really dispatched legs (never faked with zeros). */
function aggregateUsage(legs: readonly ChatReplyLegRecord[]): ChatReplyUsage {
  const dispatched = legs.filter((leg) => leg.dispatched);
  if (dispatched.length === 0) {
    // Nothing was dispatched, so nothing was spent — provable, not assumed.
    return { inputTokens: 0, outputTokens: 0, exact: true };
  }
  const usages: NormalizedUsage[] = [];
  for (const leg of dispatched) {
    if (leg.usage === undefined) {
      // A partial sum is never presented as the full aggregate.
      return { inputTokens: null, outputTokens: null, exact: false };
    }
    usages.push(leg.usage);
  }
  const inputTokens = usages.reduce((sum, usage) => sum + usage.inputTokens, 0);
  const outputTokens = usages.reduce((sum, usage) => sum + usage.outputTokens, 0);
  const single = usages.length === 1 ? usages[0] : undefined;
  const usageRaw = single?.usageRaw;
  return usageRaw === undefined
    ? { inputTokens, outputTokens, exact: true }
    : { inputTokens, outputTokens, exact: true, usageRaw };
}
