# Server Contract (the BFF / proxy)

The contract between the Package's **AI Backend** client and the **proxy (BFF)** —
the server that holds the provider key and streams the reply. The proxy is deployed
fresh per Consuming App (own key, own billing). See ADR 0001 (key on server) and
ADR 0002 (stateless: the client sends the assembled context; the server stores no
durable conversation history).

> This is the wire contract, not an implementation. Any server honoring it is a
> valid AI Backend.

## 1. Provider normalisation happens on the server

The proxy translates **OpenAI and Anthropic** into **one normalised SSE event
stream** for the client. The Core knows only this normalised format, never a
provider's raw wire shape — so the Core stays provider-agnostic (ADR 0001), and
**adding or switching a provider is a server-only change** (no app release, matching
the server-config choice in ADR 0001). The "dirty" translation work lives where the
key lives. This normalisation covers **events** (§2), **error causes** (§2),
**tool formats** (§7), and **token usage** (the providers report it differently —
OpenAI in a final chunk, Anthropic split start/end — normalised into one count
carried by each leg's terminal event, `tool_call` or `done`; §2).

**Pinned provider families for v1:**

Both official provider SDK clients MUST be constructed with automatic retries
disabled (`maxRetries: 0`, or the exact zero-retry option of the pinned SDK
version). The proxy/Core retry contract is the only retry owner; an SDK must never
repeat 5xx/timeouts invisibly underneath the idempotency record.

- **OpenAI Responses API**, in manual/stateless mode: `store: false`, no
  `previous_response_id`, no background mode. When a selected reasoning model
  needs continuity, the adapter sets
  `include: ["reasoning.encrypted_content"]`, emits the complete opaque reasoning
  item as `provider_state`, and returns that item as input on the next matching
  OpenAI leg.
- **Anthropic Messages API** with
  `anthropic-version: 2023-06-01`. Complete `thinking` and
  `redacted_thinking` blocks (including signatures) are emitted as
  `provider_state` and returned unmodified on the next matching Anthropic leg.

`store: false` prevents provider-managed application state from becoming the
conversation store; it does **not** claim zero provider logging or Zero Data
Retention. Deploy validation MUST reject a configured model that does not
support vision, streaming, function calling and the stateless round-trip above.
Configured models must also support provider strict Tool schemas; otherwise the
tier fails deployment.

**System mapping is deterministic.** The proxy builds provider instructions from
`BotProfile.systemPrompt` first and persisted `system` Messages in chronological
order, then removes those Messages from ordinary history. OpenAI receives that
sequence as Responses instructions/input system material; Anthropic receives it
through the Messages `system` field. System Messages are never translated as
ordinary user/assistant turns.

## 2. The normalised SSE event stream (proxy → client)

| `event:` | data | meaning |
|---|---|---|
| `delta` | text chunk | a piece of the assistant's reply |
| `provider_state` | `provider` + base64 opaque bytes | a complete provider continuity item/block; ordered, nonterminal, never user-visible |
| `tool_call` | name + **complete parsed, schema-checked** arguments JSON + **this leg's Usage** | the bot is requesting a Tool (see §7) — **the terminal event of the current leg** |
| `done`  | **normalised Usage** (input/output tokens) + optional `usageRaw` | the **final leg** (and the whole reply) finished normally |
| `error` | a **machine cause code** + optional **usage** (input + partial output, counted by the proxy) + optional **`retryAfterMs`** | a Failure (including mid-stream) |

Rules:
- **Each leg's HTTP response ends with exactly one terminal event**:
  `tool_call` (the bot wants a Tool — this response is over, the tool-result
  comes back as a new request, §7), `done` (final leg, reply complete) or
  `error`. After `tool_call` no `done` follows in that response; the leg's
  idempotency record becomes `complete` with the `tool_call` as its stored
  outcome (a replay re-emits the same `tool_call` with the same id — the
  app's `toolCallId` dedupe already covers it). Each terminal event carries
  its own leg's usage; the client sums the legs into the reply's Usage fact.
- A `provider_state` event contains the UTF-8 bytes of one complete provider
  item/block encoded as base64. It is emitted only after the provider structure
  is complete, in its original content order. The proxy accepts it back only for
  the same provider; foreign-provider state is omitted during translation.
- **`done` is the only proof of completion of the final leg.** A stream that
  ends without a terminal event is treated by the client as interrupted →
  `Failed(upstream)` (see Retry Boundary). This is the normalised equivalent
  of OpenAI `[DONE]` / Anthropic `message_stop`.
- **`Retry-After` has one wire per path**: pre-stream HTTP failures carry the
  standard `Retry-After` header; the in-stream `error` event carries
  `retryAfterMs`. The client maps both onto the same backoff input.
- **Errors are events, not HTTP codes.** Once streaming starts the HTTP status is
  already `200`, so an error that occurs **after the first token** must arrive as an
  `event: error` inside the stream — never as a status code. Pre-stream failures
  (auth, entitlement, validation) may still use HTTP status, but the body still
  carries the same machine cause code.
- **The proxy translates provider errors into the Package's machine cause codes**
  (`auth` / `entitlement` / `quota` / `rate` / `overloaded` / `content-filter` /
  `context-too-long` / `network` / `upstream`). The client never sees raw
  OpenAI/Anthropic error text. An optional raw technical string may ride along for
  logs only (never shown to the user). (The catalogue's tenth code,
  `tool-loop-limit`, is emitted by the client Core itself and never crosses
  the wire.)
- **Transparent passthrough of deltas.** The proxy must not re-batch or reorder
  text; preserve every non-empty delta in order (re-batching has been observed
  to drop leading tokens in some proxy stacks, and it degrades typing
  smoothness for no gain — throttling for the UI is the client's job).

## 3. Streaming must not be buffered

A proxy that buffers the upstream response defeats streaming. The proxy MUST:
- send `Content-Type: text/event-stream`;
- set `X-Accel-Buffering: no` and `Cache-Control: no-cache, no-transform`;
- raise read/idle timeouts well above a single long generation (a reply can run
  minutes; the default ~60 s would cut it mid-stream);
- avoid HTTP/2 for the SSE route where the platform's HTTP/2 breaks streaming;
- send an SSE **keepalive comment** (`: ping`) every **15 s** of silence — for
  connection health (idle timeouts, dead-connection detection via write
  failure). Keepalive is **not** a cancel guarantee.

The v1 Firebase Functions gen2 deployment also has a 10 MB streaming-response
ceiling. This is handled as a **deploy compatibility gate**, not a new product
response setting: each tier's `maxOutputTokens` plus worst-case normalised SSE
overhead (including opaque provider-state) MUST fit, or that tier is rejected at
deployment. No Cloud Run migration is required for v1.

**Cancel = closing the connection; the upstream abort is best-effort.** There
is no cancel endpoint: the client's "stop" closes the SSE connection. The
guarantees are split honestly:

- **Client-side (guaranteed):** `cancel()` immediately stops reading, lands the
  Core on `Cancelled` and keeps the partial — regardless of what the server
  observes.
- **Server-side (best-effort, MUST-attempt):** the proxy MUST abort the
  upstream provider request when it **observes** the disconnect — via the
  runtime's disconnect signal where delivered, and via a **failed write**
  (next `delta` or keepalive to a dead connection) otherwise. Some platforms
  (e.g. Cloud Run behind HTTP/1.1) do not deliver client disconnects to the
  container, so detection may lag until the next write.
- **The orphan is bounded:** a generation whose client is gone runs at most to
  the function timeout / the tier's `max_output_tokens` — never unbounded.
  Its usage row (§9) is written as far as the proxy knows (best-effort).

## 4. Auth & entitlement (server-side)

- The client authenticates (Firebase Auth id-token + App Check, as in
  `record_transcribe`); failures map to `auth` (`id-token` / `app-check`).
- The client's **Bot Profile is a request**; the server resolves it against its
  **tier→model map** (server config, ADR 0001), and may downgrade or reject
  (`entitlement`) before spending the key. The map is never sent to the client.
- **Every model in the tier→model map MUST support vision** — the proxy
  template validates this at deploy time. This makes "an image sent to a
  text-only model" impossible by construction, so the cause catalogue needs no
  code for it. A text-only model cannot be added to a v1 tier.

**Admission order is part of the money contract:**

1. verify Firebase Auth and App Check;
2. validate `wireVersion`, JSON/schema and the 10 MB payload limit;
3. look up/claim the idempotency key;
4. for `running|complete|aborted`, join/replay/return 410 immediately — no new
   provider-generation rate check or quota reservation. A stale-running
   observer may call idempotent `reserveQuota(getExisting, attemptKey)` only to retrieve the
   existing reservation and settle that ledger `unknown`; this is recovery, not
   a new reservation;
5. only the owner of a newly claimed key runs
   `checkEntitlement → checkRateLimit → reserveQuota(createOrGet) → provider`.

The provider/tier config may be read to construct the provider-effective hash,
but no billable admission hook moves ahead of the idempotency claim. Hook
rejections map respectively to `entitlement`, `rate` or `quota`; a hook exception
maps to `upstream`. Quota reservation and settlement are idempotent by
`attemptKey`; replay/join never reserve again. Exact hook types and settlement
outcomes are in `server-template.md` and §9.

Every admission exit before provider dispatch is provably unbilled: emit the
mapped pre-stream error, settle/release any reservation as `unbilled`, and remove
the provisional idempotency claim. No `running` record is left behind. This does
not make non-retryable causes automatic; it only keeps the same key honest for a
later explicit command after the underlying condition changes.

## 5. Request (client → proxy)

The client sends the **assembled context** (system prompt + prior messages + new
message, per ADR 0002) plus the requested Bot Profile id and
`"wireVersion": 1`. The server stores no durable conversation history.

The proxy validates the version before creating any idempotency/usage record or
calling a provider. Unsupported/missing versions return
`426 {"cause":"upstream","detail":"unsupported-wire-version"}`. Every successful
SSE response carries `X-Chat-AI-Wire-Version: 1`.

## 6. Idempotency (double-billing protection)

The one place money is spent is guarded by an idempotency key — the industry
standard for retry-safe LLM calls, and the same spine as `record_transcribe`.

- The client sends an **`Idempotency-Key`** header: a random UUID (V4) minted
  per **new Attempt** (ADR 0004; the Stripe-style industry pattern). Send,
  edit-rerun, regenerate of a `complete` reply, and each new tool leg mint a
  fresh key. A silent retry, an explicit resend of the same failed user Message,
  and the recovery-first step of regenerate on an `interrupted` reply carry the
  persisted key because they request the outcome of an existing Attempt. That
  interrupted recovery mints a fresh key only for its one `409`/`410` fallback.
- The server retains **terminal** key records for a short replay TTL (a few
  minutes — long enough to cover a flaky-network retry, not a durable cache).
  Firestore stores only status/metadata; a successful normalised terminal
  outcome is stored in the private replay object
  `chat-replays/{uid}/{key}/{runId}.sse` (ADR 0006), outside the 1 MiB Firestore
  document limit. Every transition `unknown → running` mints a fresh UUID
  `runId`, including a same-key run after safe release/expiry; cleanup always
  addresses the old run's exact path and cannot delete a newer replay.
  A `running` record is never deleted by this TTL while its owner may still be
  alive. A request under a key has **exactly one meaning — "give me the outcome
  of this Attempt"** — and the server resolves
  it purely by the key record's state; there are no special request kinds
  (no recovery-only mode, no probe endpoint):

  | key state | server response |
  |---|---|
  | unknown | atomically mint `runId`, claim, then **run the request** |
  | `running`, owner window live | **join/await** the in-flight generation — never a second call |
  | `running`, owner window elapsed | atomically mark **`aborted`**, set its terminal TTL, return **`410 Gone`** — never guess that the provider did no work |
  | `complete` | verify the stored object path/size/SHA-256 and **replay the complete normalised SSE outcome**; never call the provider |
  | `complete` but replay object missing/corrupt | atomically change to `aborted`, return **`410 Gone`**; explicit recovery may use its one fresh-key fallback |
  | `aborted` | **`410 Gone`** while the tombstone is retained: the first run may already have spent tokens, and a re-run in that window would be a second generation under the same key |
  | params mismatch with the stored record | **`409 Conflict`** |

  **Key release vs. `aborted` uses a small exact allowlist, never a wildcard HTTP
  family.** With SDK retries disabled, the proxy owns every repeat.

  | condition | key disposition |
  |---|---|
  | proxy-local validation before provider call | no provider call; remove the newly claimed record |
  | DNS/TCP/TLS connect failure with proof that zero request bytes were written | release |
  | OpenAI HTTP `429` recognised by the pinned adapter as a retryable rate-limit response (not provider-credit/insufficient-quota) | `rate` + release |
  | Anthropic HTTP `429` + `rate_limit_error` | `rate` + release |
  | Anthropic HTTP `529` + `overloaded_error` | `overloaded` + release |
  | generic `500/502/504`, unknown `5xx`, timeout/reset after any request byte, break before headers, mid-stream failure, cancel/disconnect after upstream start | `aborted` |

  These are the only provider-response release cases in v1 because the providers
  explicitly recommend retrying them. Adapter fixtures pin the exact structured
  shapes; a bare/unknown 429, any wildcard 5xx, or a newly observed code defaults
  to `aborted` until the canonical allowlist is deliberately updated. A released
  key becomes unknown and may run under the same-key silent retry; an ambiguous
  key becomes `aborted` and future repeats receive 410.

  **A joiner never takes ownership after release.** Every join request captures
  the current `runId`. Before an owner deletes a claim for a safe-release or any
  other post-claim/pre-provider exit, it first finalises that run's GCS object
  with one normalised `error` outcome (`cause`, optional detail and exact
  `retryAfterMs`), marks the ledger `unbilled`, and only then deletes the
  Firestore key. A joiner that observes the deletion reads
  `chat-replays/{uid}/{key}/{capturedRunId}.sse` and returns **that same error
  outcome**; it never claims the now-unknown key and never calls the provider
  inside the same HTTP request. The owner may expose Retry-After as an HTTP
  header; the joiner's already-open SSE path carries the identical duration as
  `retryAfterMs`.

  Only a **subsequent client backend request** may see `unknown`, mint a new
  `runId` and run. If the release-outcome object cannot be finalised, the owner
  does not delete the claim: it marks the Attempt `aborted`, returns
  `error(upstream)`/410 as applicable, and no joiner restarts it.

  **Running-record lifecycle.** The owner window ends exactly at
  `createdAt + deployedFunctionTimeout`. `expiresAt` is absent while status is
  `running`. Once the owner window has elapsed, the
  next observer atomically changes `running → aborted` and returns `410`; it
  does not call the provider. It calls idempotent
  `reserveQuota(getExisting, attemptKey)` to recover the existing
  `reservationId`, then settles that same ledger `unknown` if no exact provider
  outcome was recorded; it never creates another reservation. `complete` and `aborted` receive
  `expiresAt = terminalAt + replayTTL`, and only those terminal records are
  removed by Firestore TTL. A joiner waits for the same record to become
  terminal or disappear after its run-scoped release object is durable; it then
  replays that captured run's outcome and never calls the provider.

  **Successful terminal commit order is strict:**

  1. stream each normalised `delta`/`provider_state` to the client and append it
     to the private replay object;
  2. append the candidate `done` or `tool_call` terminal to the object, but do
     not emit that success terminal to the client yet;
  3. finalise the object and verify its byte count and SHA-256;
  4. settle the existing usage/quota ledger (settlement failure records
     `unknown`), then atomically update Firestore to `complete` with
     `outcomeObjectPath/outcomeBytes/outcomeSha256`;
  5. only then emit the success terminal to the client.

  If object finalisation or the Firestore complete commit fails, the proxy MUST
  NOT emit `done`/`tool_call`; it marks the attempt `aborted` and emits
  `error(upstream)` when the connection is writable (otherwise EOF). The client
  keeps the partial. A joiner waits for a Firestore terminal and, on `complete`,
  reads/verifies the object; it never tails a partially written object. A retained
  `complete` record with a missing/corrupt object is permanently repaired to
  `aborted` and returns 410; it MUST NOT call the provider under that key, but an
  explicit command is no longer trapped and may perform its single fresh-key
  fallback.

  Replay validation happens **before** HTTP 200/SSE headers and before client
  `Accepted`: read the complete object, verify path/size/SHA-256, then open the
  replay stream. Permanent failure is therefore a real pre-stream 410, not an
  in-stream approximation.

  **Logical expiry is authoritative.** On every read, `expiresAt <= now` is
  treated atomically as `unknown`; metadata is replaced/cleaned and the old
  `runId` object's exact path is scheduled for deletion. Firestore TTL and the GCS lifecycle policy
  are cleanup only and may run later. Incomplete/orphan objects are cleaned by
  bucket lifecycle.

  **The invariant, stated honestly:** while a key record is retained, the
  server never starts a second generation under it — `running` joins, `complete`
  replays, `aborted` refuses. Only an unknown key runs. A completed paid reply
  is replayed within the terminal TTL, never re-billed. Terminal expiry
  intentionally forgets the key; a later explicit recovery sees `unknown` and
  may run, outside the silent-retry window.

  **Client rules for `409`/`410`** (they are protocol signals, not Failure
  causes — see §10):
  - in a **silent retry**: `409` is a client/protocol **bug** — the retried
    request MUST be the frozen, byte-identical `ChatRequest` of its Attempt;
    `410` is a normal outcome of a previously aborted server attempt —
    terminal **`Failed(upstream)`**, no fresh key is minted silently;
  - after an **explicit** resend or interrupted-reply recovery: `409`/`410` →
    **one automatic re-run under a fresh key** (a deliberate, billable act by definition —
    e.g. the Bot Profile legitimately changed after a restart). Never more
    than one automatic fallback per command.
- **No long-lived response cache or durable server history.** Chat replies are non-deterministic
  (`temperature`), so caching "the same answer" is pointless; the goal is only to
  **not pay twice**. The TTL replay buffer above is not such a cache — it lives
  minutes and exists to hand a paid reply to its own retry. This keeps the
  server near-stateless (short-lived metadata + a private replay object), honoring
  the "minimal server, critical-only" rule.
- Same-key-mismatched-params (`409`) detection has one short admission-safe
  bootstrap because entitlement may downgrade to another provider. The initial
  claim stores `requestHash` over canonical protocol input after stripping
  `wireVersion` and Message bookkeeping; while `provider/paramsHash` are still
  null, repeats compare that hash and join. After entitlement resolves the actual
  tier, the owner stores the frozen provider and
  **`paramsHash` = SHA-256 over the canonical JSON of the
  *provider-effective request*** — the request body **after removing the
  client/protocol-only fields the proxy ignores anyway** (`wireVersion` and
  `id`, `status`, `createdAt`, `attemptKey` on every message), i.e. exactly the
  data translated to the selected provider. Matching-provider opaque parts are
  included byte-for-byte; foreign-provider opaque parts are omitted. For an
  existing key the stored provider determines this projection, so a server
  config change cannot corrupt a live silent retry. Canonical JSON: UTF-8, keys sorted lexicographically
  at every level, no insignificant whitespace. Both halves matter for the
  restart case: canonical form survives re-serialisation (key order), and
  the client-only strip survives the Core's restart normalisation
  (`sending → failed`, `streaming → interrupted`, fresh `createdAt` /
  `attemptKey` bookkeeping) — a semantically identical repeat must hash
  identical, or a legal replay would be refused as `409`. A true mismatch is
  still safe: `409` → the explicit command's one automatic fresh-key re-run.
  The shape is the provider's own `idempotency_conflict`; client handling:
  see the rules above. `paramsHash` is persisted before quota reserve/provider
  dispatch and is non-null on every terminal record; `requestHash` remains only
  the safe comparator for the brief pre-resolution running state.

## 7. Tools (function calling) — normalised on the server

Tools are declared and executed **by the app**; the server only normalises the wire
formats so the Core stays provider-agnostic (same principle as §1).

- **Declaration format:** the client sends `name`, `description` and
  `parameters` in the closed **Chat AI Tool Schema v1** dialect below. The proxy
  maps the same schema to OpenAI function `parameters` and Anthropic
  `input_schema`, with provider strict mode enabled.

### Chat AI Tool Schema v1 (canonical portable dialect)

This is the only schema language accepted by the Dart Core, TypeScript BFF and
both provider translators in v1:

- Tool `name` matches `^[A-Za-z0-9_-]{1,64}$`; names are unique within one
  frozen Bot Profile.
- `parameters` root is always `{ "type": "object", ... }`.
- Allowed keywords are only `type`, `description`, `enum`, `properties`,
  `required`, `additionalProperties` and `items`.
- Allowed scalar types are `string`, `number`, `integer`, `boolean` and `null`;
  compound types are `object` and `array`.
- Every object declares `properties`, lists **every** property name in
  `required`, and sets `additionalProperties: false`. A semantically optional
  value is represented as required-but-nullable with
  `"type": ["<one non-null type>", "null"]`.
- An array has exactly one `items` schema. `enum` contains JSON scalar values
  compatible with the declared scalar type; a nullable enum includes `null`.
  Nested objects/arrays recursively follow the same rules.
- Everything else is rejected in v1, including `$schema`, `$id`, `$ref`,
  `$defs`, `const`, `default`, `oneOf`, `anyOf`, `allOf`, `not`, conditional
  schemas, `pattern`, `format`, length/range/item-count constraints,
  `uniqueItems`, `patternProperties`, and schema-valued/true
  `additionalProperties`.

The proxy sends `strict: true` to both providers. It never relies on an SDK to
silently transform or drop unsupported keywords. The Core validates declarations
on `ChatSession` construction and `botProfile` assignment; invalid name,
duplicate name or invalid dialect throws `ArgumentError` (setter leaves the old
profile unchanged, with no key/backend call). The BFF repeats validation before
idempotency claim/provider dispatch.

One shared fixture corpus is normative:
`test/contract_fixtures/tool_schema_v1/` contains accepted/rejected schemas and
valid/invalid argument instances. Dart and TypeScript validators, plus both
translator contract tests, MUST produce the same verdict for every fixture.
- **Argument assembly is the server's job.** Providers stream tool-call arguments as
  JSON **fragments that don't respect JSON boundaries** (a chunk can end mid-string).
  The proxy **buffers fragments until the call closes, parses the JSON, checks the
  tool name and arguments against the frozen declared JSON Schema, and only then
  emits a single `tool_call` event** with complete arguments. Invalid name/schema
  is still delivered as one complete call so the Core can append the canonical
  safe `is_error` ToolResult; it is never passed to the app resolver. The Core
  repeats the declaration/schema check as the trust boundary for any backend/Fake.
  Half-parsed/non-JSON arguments emit `error(upstream)`, never a partial call.
- **v1 disables parallel tool calls.** Both providers send multiple calls per
  reply **by default**; the proxy MUST pass the provider's own switch
  (`parallel_tool_calls: false` on OpenAI, `disable_parallel_tool_use: true` on
  Anthropic) so that a leg carries at most **one** `tool_call` — the "single
  `tool_call` event" rule above holds by construction, and the Core's
  one-call-at-a-time `AwaitingTool` never desynchronises from the bot.
  Multiple-call support is v2 and extends the form without breaking it
  (ADR 0003).
- **Interrupted tool-call** (stream broke before the call closed, e.g. token limit)
  → **no** `tool_call` is emitted; the stream ends without `done` → `upstream` (per
  Retry Boundary). Nothing partial is applied.
- **The result round-trip:** after the app executes the Tool, the client sends the
  result back as an ordinary follow-up request — the assembled context now ends
  with the in-progress assistant Message whose parts close with
  `toolCall + toolResult` (ADR 0003 Amendment; no `tool` role) — under the same
  Idempotency-Key **discipline** but with its **own fresh key**: each leg is a
  distinct billable call (ADR 0004; re-using the first leg's key would trip the
  §6 same-key conflict). The proxy relays it and the bot continues.
- The server **never executes a Tool** — execution is always app code.

### Provider translation matrix (v1)

| Normalised concept | OpenAI Responses API | Anthropic Messages API |
|---|---|---|
| system instructions | `instructions` / system input, in the §1 order | top-level `system`, in the §1 order |
| text/image history | Responses input items/content; base64 JPEG image input | Messages `text` / base64 `image` content blocks |
| tool declaration | function tool with JSON Schema parameters; parallel calls disabled | `tools[].input_schema`; parallel use disabled through tool choice |
| tool call | completed `function_call` item; streamed arguments buffered | completed `tool_use` block; streamed input buffered |
| tool result | `function_call_output` paired by call id | `tool_result` paired by `tool_use_id` |
| opaque continuity | complete reasoning item/encrypted content → `provider_state` | complete `thinking`/`redacted_thinking` block → `provider_state` |
| usage | final Responses usage → leg Usage | message start/delta usage combined → leg Usage |
| normal final | completed response with no pending function call → `done` | `message_stop` with `end_turn`/`stop_sequence` → `done` |
| tool terminal | one completed function call → `tool_call`, no `done` | `stop_reason: tool_use` → `tool_call`, no `done` |
| truncated/invalid terminal | incomplete/max-output or failed response → `error(upstream)` | `max_tokens`, incomplete block or invalid stop sequence → `error(upstream)` |
| refusal/filter | refusal/safety result → `error(content-filter)` | refusal/safety stop → `error(content-filter)` |

Translator goldens pin the exact event names/fields accepted from each API and
the byte-exact normalised output. Unknown provider event/stop reason is fail-closed
as `upstream`; it is never silently treated as `done`.

## 8. Resumable streaming (form laid for v2, not built in v1)

"Catch up to the full reply after the client was backgrounded" (what ChatGPT does)
is **v2**, not v1 (see Retry Boundary, ADR 0002). v1 behaviour: a break = `upstream`
+ kept partial + explicit regenerate. The wire form is reserved so v2 drops in
without a breaking change:

- Each streamed reply carries a **stream id**, and `delta` events carry a
  monotonic **event id**; on reconnect the client may send the **last received
  event id** to resume.
- v1 servers may ignore these fields; a v1 client simply never resumes.

**This requires a stateful generation component — and it is the app's, not the
package proxy's** (the proxy keeps no durable conversation history; its short-lived
completed replay object is not a resumable live stream, ADR 0002/0006). The decoupled pattern is:
generation runs **detached from the client connection**, tokens are written to an
**intermediate store** (Redis / Firestore) keyed by stream id, and a reconnecting
client reads what it missed.

**Firebase caveat for v2.** A bare Cloud Function's lifecycle is **tied to the
request it serves**: it cannot keep generating for a client that is gone —
once its response ends, background network access is reset (and per §3, the
disconnect itself may only surface as a failed write, not a signal). Resumable
on Firebase therefore needs **Cloud Run or a detached background task**
writing tokens to **Firestore/Redis**, not a bare Cloud Function. (Firestore
also naturally holds the ADR 0001 `tier→model` config.)

## 9. Usage accounting is server-side

The **authoritative record of spend lives on the server**, not the client. After
entitlement/rate admission and before provider dispatch,
`reserveQuota(createOrGet, attemptKey)` atomically creates or reuses exactly one combined
usage/quota ledger at `usage/{uid}/attempts/{attemptKey}`, linked to the
`running` claim. That ledger persists `reservationId`, so
`QuotaReservation(attemptKey, reservationId)` is reconstructable after a crash.
Join/replay update or read that row; they never create another. On terminal/abort
the same row is settled with exact
provider usage when available, otherwise nullable counts and any defensible
estimate from relayed deltas.

Quota settlement has four typed outcomes:

| outcome | meaning / reservation action |
|---|---|
| `billed` | exact provider usage known; settle reservation to exact usage |
| `unbilled` | pre-provider exit or exact safe-release provider rejection; release reservation |
| `estimated` | exact usage unavailable but a defensible estimate exists; settle conservatively to it |
| `unknown` | billing cannot be proven either way; retain the reservation (never release speculatively) |

`reserveQuota(createOrGet|getExisting, attemptKey)` and `settleQuota(...)` are
idempotent by `attemptKey`. A safe key release requires settlement `unbilled`;
if the client then performs the allowed same-key retry, `reserveQuota` reopens
that **same** attempt ledger from `unbilled` to reserved rather than creating a
second reservation/usage row. Duplicate calls in one state are no-ops; the only
reopen transition is `unbilled → reserved`. An exception while settling records
`unknown`, logs the accounting fault and does not free quota; it does not discard
an otherwise verified/replayable provider result.
Provider-generation rate limiting applies only to a newly claimed owner and
therefore never blocks a join/replay recovery.

A process crash after reservation has no separate "usage write" gap: stale
recovery calls `reserveQuota(getExisting)` with the same key, obtains the same ledger, and
settles it `unknown` if the provider outcome cannot be classified.

This is not conversation state: the server-side `entitlement` re-check (§4) and
the `quota` cause code require per-user accounting. No durable conversation
history is stored, only accounting rows and short-lived replay artifacts.
Pricing, quotas, paywalls and analytics remain the deploying app's business
logic, not the Package's.

Wire consequence: the client-delivered `usage` (in `done`, and best-effort in
`error`, §2) is a **display fact** for the app's UX; on cancel the client may
receive nothing — the server record is the truth.

## 10. Error normalisation table (complete)

The single mapping from provider/proxy conditions to the machine cause codes
(CONTEXT.md §Failure). The proxy implements the server rows; the client maps
its own transport rows. `detail` always carries the raw underlying message,
logs-only.

| Condition | Cause code |
|---|---|
| Firebase id-token invalid/expired; App Check rejected | `auth` (detail: `id-token` / `app-check`) |
| Requested tier not allowed for this user (tier→model check, §4) | `entitlement` |
| The app's own per-user allowance exhausted (server-side books, §9) | `quota` |
| Anthropic `429` + `rate_limit_error`; pinned OpenAI retryable rate-limit `429` excluding insufficient-quota/credit errors | `rate`, relay `Retry-After`, release per §6 |
| Anthropic `529` + `overloaded_error` | `overloaded`, release per §6 |
| OpenAI `response.failed` with documented `server_error`; OpenAI HTTP `503` | `upstream`, not `overloaded`; aborted. v1 has no documented OpenAI overload code that is safe to release |
| Provider moderation / content-filter block; refusal stop reason | `content-filter` |
| Provider context-length error (OpenAI `context_length_exceeded`, Anthropic "prompt is too long"); request body over the payload limit (`413`) | `context-too-long` |
| **Deployer's provider-key problem** (OpenAI `insufficient_quota`, Anthropic credit exhausted, invalid key) — the deployer's issue, not the end user's | `upstream` |
| Generic provider `500/502/504`, unknown `5xx`, any other provider `4xx/5xx`, mid-stream provider error, unknown stop reason, stream ended without a terminal event | `upstream`; ambiguous attempts become `aborted` |
| **Proxy→provider connect failure before the request bytes were written** (DNS / TCP / TLS) — provably unbilled, the key is **released** (§6) | `network` |
| **Proxy→provider timeout/reset after the request bytes were written** — ambiguous outcome, the record becomes `aborted` (§6) | `upstream` |
| Entitlement/rate/reserve hook throws; live replay-object write/final commit failure | `upstream` |
| Unsupported/missing `wireVersion` (`426`); local request/tool validation failure before provider call | `upstream` (no provider call; no retained key for pre-claim validation) |
| Client-side transport failure — no connection, DNS, TLS, socket drop with no response (mapped by the **client**, not the proxy) | `network` |
| Tool Use Cycle exceeded the leg cap (emitted by the **client Core**, never crosses the wire) | `tool-loop-limit` |

**Protocol signals that are NOT Failure causes** (handled by the client per
§6, surfaced as a Failure only when the §6 rules say terminal):

| HTTP | Meaning | Client handling (§6) |
|---|---|---|
| `426` | unsupported/missing wire version; no key/provider call | `Failed(upstream)`; update package/BFF deployment |
| `409` | same key, mismatched params | silent retry: bug → `Failed(upstream)`; explicit reused-key command: one fresh-key re-run |
| `410` | attempt aborted server-side; refused while its tombstone is retained | silent retry: `Failed(upstream)`; explicit reused-key command: one fresh-key re-run |

## 11. Client retry matrix (closed)

`Accepted` is at most once per backend HTTP request and precedes its first SSE
data event; one same-key Attempt may have several backend requests. It proves
that the proxy selected run/join/replay, not that the provider billed.

| observed outcome | before first visible token | after first visible token |
|---|---|---|
| `auth`, `entitlement`, `quota`, `content-filter`, `context-too-long` | terminal; never automatic | terminal; never automatic |
| `rate`, `overloaded` with key safely released by §6 | same-key silent retry within deadline/Retry-After | no silent retry; keep partial, explicit recovery |
| client `network` break (with or without `Accepted`) | same-key silent retry within deadline; server will run/join/replay/refuse safely | no silent retry; keep partial, explicit recovery |
| `upstream`, ambiguous provider outcome, unknown provider signal | no speculative fresh call; retained key becomes/returns `aborted` | keep partial; explicit recovery only |
| silent-path `409` / `410` | terminal `Failed(upstream)`; no fresh key | terminal `Failed(upstream)`; no fresh key |
| explicit resend/recovery `409` / `410` | exactly one checkpointed fresh-key fallback | exactly one checkpointed fresh-key fallback |

The 30-second deadline is consulted only before a retry/backoff decision. It
never fires into an accepted live stream. A live stream may think silently past
the deadline; if it later fails before the first token, the next decision sees
the elapsed deadline and stops.

## 12. Normative external references

- [OpenAI Responses streaming reference](https://platform.openai.com/docs/api-reference/responses-streaming/response/refusal/delta?lang=curl)
- [OpenAI function calling strict-mode requirements](https://developers.openai.com/api/docs/guides/function-calling#strict-mode)
- [OpenAI data controls by endpoint](https://platform.openai.com/docs/models/default-usage-policies-by-endpoint)
- [OpenAI 429 retry/backoff guidance](https://help.openai.com/en/articles/5955604-how-can-i-solve-429-too-many-requests-errors)
- [Anthropic extended thinking and tool-use preservation](https://platform.claude.com/docs/en/build-with-claude/extended-thinking)
- [Anthropic strict tool use](https://platform.claude.com/docs/en/agents-and-tools/tool-use/strict-tool-use)
- [Anthropic typed API errors](https://platform.claude.com/docs/en/api/errors)
- [Firestore document limits](https://firebase.google.com/docs/firestore/quotas)
- [Cloud Run functions quotas (10 MB streaming response)](https://docs.cloud.google.com/functions/quotas)
- [Cloud Storage lifecycle behaviour](https://docs.cloud.google.com/storage/docs/lifecycle)
- [Cloud Storage Public Access Prevention](https://docs.cloud.google.com/storage/docs/public-access-prevention)
