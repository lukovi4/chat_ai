// Framework-independent wire/domain types shared by the whole BFF foundation.
// No Firebase, no OpenAI SDK, no HTTP here — only the shapes this increment
// actually needs (SERVER-CONTRACT §2/§5, V1_SPEC §6).
//
// Two directions live here:
//   1. Ingress: the ChatRequest wire shape the client POSTs. It mirrors the
//      Dart `encodeChatRequestBody` (lib/src/backend/chat_request_wire.dart)
//      byte-for-byte. Ingress is UNKNOWN until validated: the future HTTP
//      admission layer narrows an unknown body into a `ChatRequest`; the pure
//      functions in this increment consume the already-validated typed value.
//   2. Egress: the normalised SSE event stream the proxy emits, decoded by the
//      Dart `decodeSseFrame` (lib/src/backend/sse_event_decoder.dart). The
//      encoder in ./sse.ts turns these events into byte-compatible frames.

// ---------------------------------------------------------------------------
// Ingress — the validated ChatRequest (mirrors chat_request_wire.dart)
// ---------------------------------------------------------------------------

/** Message role on the wire (V1_SPEC §5). There is no `tool` role in v1. */
export type WireMessageRole = 'user' | 'assistant' | 'system';

/**
 * One content part in the storage JSON of a Message (V1_SPEC §5). The
 * discriminator is `type`; binary payloads (`image`, `providerOpaque`) ride as
 * base64 strings exactly as the Dart `ContentPart.toJson` writes them.
 */
export type WireContentPart =
  | { type: 'text'; text: string }
  | { type: 'image'; mimeType: 'image/jpeg'; data: string }
  | {
      type: 'toolCall';
      toolCallId: string;
      name: string;
      args: Record<string, unknown>;
    }
  | { type: 'toolResult'; toolCallId: string; content: string; isError: boolean }
  | { type: 'providerOpaque'; provider: 'openai' | 'anthropic'; data: string };

/**
 * One Message in the assembled context (V1_SPEC §6). The client-only fields
 * (`id`, `status`, `createdAt`, `attemptKey`) ride along and every provider
 * translator ignores them (SERVER-CONTRACT §6).
 */
export interface WireMessage {
  id: string;
  role: WireMessageRole;
  parts: WireContentPart[];
  status: string;
  attemptKey?: string;
  createdAt: string;
}

/** A Tool declaration on the wire (V1_SPEC §6; validated by ./tool-schema). */
export interface WireTool {
  name: string;
  description: string;
  parameters: Record<string, unknown>;
}

/**
 * The exact POST body shape of `encodeChatRequestBody` (V1_SPEC §6): always
 * `wireVersion`/`botId`/`system`/`messages`; `tools` omitted when empty; the
 * `Idempotency-Key` is a header, never in the body (ADR 0004). Consumed here as
 * an already-validated value — see the file header on ingress validation.
 */
export interface ChatRequest {
  wireVersion: number;
  botId: string;
  system: string;
  messages: WireMessage[];
  tools?: WireTool[];
}

// ---------------------------------------------------------------------------
// Egress — the normalised SSE event stream (SERVER-CONTRACT §2)
// ---------------------------------------------------------------------------

/**
 * The nine kebab-case server wire cause codes (SERVER-CONTRACT §2/§10,
 * V1_SPEC §6). The catalogue's tenth code `tool-loop-limit` is client-only and
 * is deliberately excluded from this type: it never crosses the wire.
 */
export type WireCause =
  | 'auth'
  | 'entitlement'
  | 'quota'
  | 'rate'
  | 'overloaded'
  | 'content-filter'
  | 'context-too-long'
  | 'network'
  | 'upstream';

/** The nine wire causes as a runtime set (defensive guard in ./sse.ts). */
export const WIRE_CAUSES: readonly WireCause[] = [
  'auth',
  'entitlement',
  'quota',
  'rate',
  'overloaded',
  'content-filter',
  'context-too-long',
  'network',
  'upstream',
];

/**
 * Normalised token usage carried by a leg's terminal event (SERVER-CONTRACT
 * §2, V1_SPEC §6). `usageRaw` is the provider's raw usage payload, kept for
 * logs/analytics. Decodes into the Dart `Usage` value object.
 */
export interface NormalizedUsage {
  inputTokens: number;
  outputTokens: number;
  usageRaw?: Record<string, unknown>;
}

/**
 * One normalised SSE event, provider-agnostic. Exactly the five the Dart
 * `decodeSseFrame` accepts. `provider_state.data` is raw bytes here (one
 * complete provider continuity item); ./sse.ts base64-encodes it on the wire.
 * `tool_call` is the terminal event of a tool leg and carries that leg's usage;
 * `done` is the terminal event of the final leg; `error` is a terminal Failure.
 */
export type NormalizedEvent =
  | { kind: 'delta'; text: string }
  | { kind: 'provider_state'; provider: 'openai' | 'anthropic'; data: Uint8Array }
  | {
      kind: 'tool_call';
      id: string;
      name: string;
      args: Record<string, unknown>;
      usage?: NormalizedUsage;
    }
  | { kind: 'done'; usage?: NormalizedUsage }
  | {
      kind: 'error';
      cause: WireCause;
      detail?: string;
      usage?: NormalizedUsage;
      retryAfterMs?: number;
    };
