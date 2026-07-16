# Firebase wire formats (exact shapes)

The exact HTTP JSON/SSE byte shapes of the Firebase transport, moved
unchanged from the core `V1_SPEC.md` §6/§8 when the adapter was extracted.
`SERVER-CONTRACT.md` defines the rules; this document pins the bytes. The
transport-neutral request/assembly rules and protocol-signal semantics stay
in the core spec (`V1_SPEC.md` §6 at the repo root). JSON keys are camelCase;
cause codes are the kebab-case strings of the core's CONTEXT.md §Failure.

## Request (client → proxy), one endpoint

```
POST <deployed function URL>
Authorization: Bearer <Firebase id-token>
X-Firebase-AppCheck: <App Check token>
Idempotency-Key: <UUID v4>            // per attempt / per leg — ADR 0004
Content-Type: application/json

{
  "wireVersion": 1,
  "botId": "premium",                 // Bot Profile id — a *request*
  "system": "<systemPrompt>",
  "messages": [ …assembled context… ],
  "tools": [ {"name": …, "description": …, "parameters": {…}} ]  // omit if none
}
```

- `messages` reuse the **storage JSON of `Message`** (V1_SPEC §5) — one
  serializer, no second mapper. The proxy ignores client-only fields (`id`,
  `status`, `createdAt`, `attemptKey`) and translates `parts` to the active
  provider's shape (SERVER-CONTRACT §1, §7).
- `wireVersion` is protocol-only and is excluded from the provider-effective
  request/hash. Unsupported versions fail as HTTP `426` before idempotency
  claim or provider call.
- An `ImagePart` rides as `{"type": "image", "mimeType": "image/jpeg",
  "data": "<base64>"}` — already resized by the Core.

## Response — pre-stream failures (HTTP status, no stream yet)

Every successful SSE response includes
`X-Chat-AI-Wire-Version: 1`. Pre-stream failures are `4xx/5xx` with body
`{"cause": "<code>", "detail": "<raw, logs-only>"?}` —
the cause catalogue per the **complete normalisation table,
SERVER-CONTRACT.md §10** (e.g. `401 {"cause":"auth"}`,
`403 {"cause":"entitlement"}`, `413 {"cause":"context-too-long"}`; request
payload limit: **10 MB**).

Unsupported `wireVersion` is
`426 {"cause":"upstream","detail":"unsupported-wire-version"}`. It creates
no idempotency/usage record and never calls a provider.

`FirebaseChatBackend` verifies HTTP `X-Chat-AI-Wire-Version: 1` before
yielding `Accepted`; missing/mismatched version becomes
`ErrorEvent(upstream, "unsupported-wire-version", …)`.

**Protocol signals** (not Failure causes — SERVER-CONTRACT.md §6/§10):
`409 Conflict` (same key, mismatched params), `410 Gone` (attempt aborted
server-side) and the replay hit (key `complete` — an ordinary SSE response
replaying the stored outcome). Their core-side mapping semantics are pinned
in the core `V1_SPEC.md` §6.

## Response — the SSE stream (`200`, `text/event-stream`)

```
event: delta
data: {"text": "<chunk>"}

event: provider_state
data: {"provider": "openai|anthropic", "data": "<base64>"}

event: tool_call
data: {"id": "<toolCallId>", "name": "<tool>",
       "args": { … complete, validated … },
       "usage": {"inputTokens": 123, "outputTokens": 45}?}

event: done
data: {"usage": {"inputTokens": 123, "outputTokens": 456, "usageRaw": {…}?}}

event: error
data: {"cause": "<code>", "detail": "…"?, "usage": {…}?, "retryAfterMs": 1200?}
```

- Each leg's response ends with exactly one terminal event — `tool_call`,
  `done` or `error` (semantics in the core `V1_SPEC.md` §6/§8).
- `Retry-After`: pre-stream HTTP failures use the standard header; in-stream
  `error` uses `retryAfterMs` — both land in `ErrorEvent.retryAfter`.
- Reserved for v2 resumable (SERVER-CONTRACT §8), **not emitted by the v1
  template, ignored by the v1 client**: `streamId` on the response,
  monotonic `eventId` on `delta`.

## SSE parser contract (client side)

Incremental UTF-8 decoding precedes line parsing; LF
and CRLF are accepted; comment/keepalive lines are ignored; consecutive `data:`
lines are joined with `\n` per SSE; more than one event may arrive in a transport
chunk. Malformed JSON/unknown event before terminal and EOF without terminal
produce exactly one `ErrorEvent(upstream, <logs-only detail>)`. The first
terminal closes the logical stream; duplicate terminals or later events are
ignored and reported to debug diagnostics, never emitted as a second outcome.
Parser defects never escape as stream errors.

## ToolResult encoding (server-only)

The client wire keeps the internal ToolResult intact (`content` + `isError`);
mapping it to a provider is a **server-only** step (SERVER-CONTRACT §7): OpenAI
Responses has no native `is_error`, so the proxy encodes the pair as a compact
JSON string `{"content":<string>,"isError":<bool>}` in `function_call_output.output`,
while a future Anthropic adapter must map the unchanged client shape to its
native result form. This does not change the client wire.
