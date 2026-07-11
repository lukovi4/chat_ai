# V1 Spec — Chat AI Kit

The technical specification for **v1** of the package. It turns the domain model
(CONTEXT.md), the decisions (docs/adr), the server contract (SERVER-CONTRACT.md)
and the surface specs (docs/widgets-spec.md, docs/server-template.md) into
concrete API shapes, defaults, and a test contract that implementation can
follow directly.

> This document is **v1 only**. Anything CONTEXT.md marks as v2/out-of-scope
> (resumable streaming §8, conversation lists, composite chat screen, edit UI,
> parallel tool calls, …) is **out of v1** and not specified here.

---

## 0. Audience & distribution

- The package is **private** — consumed by the owner's own apps (first
  consumer: the **"chat with AI about life"** app, already named as a consumer
  of the sibling `record_transcribe` kit). Not published to pub.dev.
- Distributed as a **git dependency**: the package lives in its own repository;
  each app pins it in `pubspec.yaml`:
  ```yaml
  chat_ai:
    git:
      url: <private git url>
      ref: main        # or a tag to freeze a given app on a version
  ```
  A fix in the package reaches every app on `pub upgrade`.
- Discipline of a public package is kept — not for the public, but because
  "future you on app #2/#3" is the same third party. The two closed
  catalogues that may grow — **Failure causes** (10 codes, CONTEXT.md
  §Failure) and **Conversation State phases** — grow in a way that only
  breaks **strict** consumers, never **soft** ones; apps are advised to write
  soft (a default branch on failure codes, `maybeWhen(orElse:)` on states).
- **No speculative flexibility** beyond what CONTEXT.md already names as v2.

## 1. Platforms

- **iOS 18+**, **Android 16 (API 36)+**. Same deliberately high floor as the
  sibling kit (personal apps, small audience): fewer legacy workarounds,
  current platform APIs.
- iOS+Android only — no web, no desktop.
- **The package requests zero permissions.** Photos come through the app's
  own picker (`onAttach` callback), voice through the app's own
  recording/transcription (`onMic` callback) — camera, gallery and microphone
  permissions are entirely the app's business.

## 2. Dependencies (all internal to the package)

The app does **not** see these except Firebase (which the app initializes
itself). Policy: **maintained, current packages only** — verified against
pub.dev at spec time (2026-07-10).

| Purpose | Package | Note |
|---------|---------|------|
| HTTP + SSE stream | `dio` (`ResponseType.stream`) | same as the sibling kit; `CancelToken` = wire-cancel ("closing the connection", SERVER-CONTRACT §3); interceptor attaches auth headers |
| SSE parsing | **own ~50-line parser** | `data:`-line format is trivial; existing Flutter SSE packages are half-alive — a dependency costs more than 50 lines |
| Auth token | `firebase_auth` | contract §4 |
| Anti-abuse attestation | `firebase_app_check` | contract §4 |
| Sealed unions + value models (codegen) | `freezed` | Conversation State phases and the 10 Failure causes are sealed unions |
| Idempotency-Key | `uuid` | random V4 per attempt (ADR 0004) |
| Image resize | `image` (pure Dart) | 2048 px JPEG re-encode in an isolate (`compute`); no platform plugins |
| Markdown rendering in bubbles | `gpt_markdown` | built for streaming LLM text (tolerates unclosed markup); **isolated behind the message-part builder slot — swapping the renderer is not a breaking change** |

Deliberately **absent**: state-management (the package speaks plain streams +
value objects outward, any app state-management consumes it via
`StreamBuilder`), image picker (the app's), audio (the app's / sibling kit),
`path_provider` (the package writes nothing to disk — storage is the app's,
ADR 0002). `flutter_markdown` rejected: abandoned by the Flutter team
(handed to community, 2025).

## 3. Public API surface

One package, everything inside. A single façade class; **one instance = one
open Conversation** — the "one active Conversation in memory" rule
(CONTEXT.md) expressed literally.

The domain operation **open(history) is the constructor**: constructing a
session *is* opening a conversation (in-flight message statuses normalized,
session starts in Idle — CONTEXT.md §Conversation Lifecycle). There is no
`open()` method to call mid-life: a session's history binding is immutable,
which keeps the operation-safety matrix small. Switching conversations =
dispose the old session, construct a new one — cheap, and idiomatic Flutter
(create in `initState`, dispose in `dispose`).

```dart
final session = ChatSession(
  backend: FirebaseChatBackend(...),   // or FakeChatBackend() in tests
  botProfile: BotProfile(...),         // {id, systemPrompt, tools} — ADR 0005
  onToolCall: ...,                     // the app's tool resolver — see the
                                       //   tools⇄resolver guard below
  history: saved,                      // omitted/empty = new conversation
  trimBudget: null,                    // null = context trimming off (default)
  maxToolTurns: 5,                     // Tool Use Cycle loop guard (CONTEXT.md)
  retryDeadline: Duration(seconds: 30),// silent-retry wall clock (§Retry Boundary)
  imageOptions: ImageSendOptions(
    maxLongEdge: 2048,
    jpegQuality: 85,
    maxImagesPerMessage: 4,
  ),
  checkpoint: saveConversation,        // required by contract when the app
                                       // persists chats across launches
);

session.botProfile = otherBot;  // mutable: "switching bots is just the next
                                // send with a different profile" (CONTEXT.md
                                // §Bot Profile) — takes effect on the NEXT
                                // command; the reply in flight (all its legs,
                                // incl. AwaitingTool) keeps the profile
                                // snapshotted at its send

// Tool configuration guards (loud configuration errors): a session can never
// hold tools without a resolver, duplicate/invalid Tool names, or a schema
// outside SERVER-CONTRACT §7's Chat AI Tool Schema v1 dialect.
// CONSTRUCTOR/setter throw ArgumentError on a violation; the setter leaves the
// old profile unchanged, with no backend call or Idempotency-Key.

// Commands (money semantics per ADR 0004 / CONTEXT.md §Retry Boundary):
session.send(text, images: [...]);   // fresh Idempotency-Key; text may be
                                     //   empty if images are present (an image
                                     //   with no text is a valid Message)
session.regenerate();                // interrupted reply OR final sent user with
                                     //   no assistant: recover-before-rebill
                                     //   first under that Message's attemptKey;
                                     //   on 410/409 falls back ONCE to a fresh
                                     //   key. A complete reply starts fresh.
session.editAndResend(id, newText);  // fresh key; truncates the conversation
                                     //   to that Message and re-sends — without
                                     //   asking (loss-protection = the app's
                                     //   copy-before-truncate, CONTEXT.md
                                     //   §Regenerate/Edit); keeps the original
                                     //   ImageParts untouched (no re-resize),
                                     //   replaces the text parts; no built-in UI
session.resend(id);                  // failed user Message: SAME persisted
                                     //   attemptKey (safe side of the Retry
                                     //   Boundary); on 410/409 → one fresh-key
                                     //   re-run (explicit command)
session.cancel();                    // wire-cancel → Cancelled, keep-partial;
                                     //   upstream abort is best-effort (§3 contract)

// Observation:
session.states;    // Stream<ConversationState> — phase changes
session.state;     // current phase (sync read)
session.tokens;    // Stream<String> — accumulated bot text, grows per delta
session.snapshot;  // current Conversation value — serialize & store (ADR 0002)
await session.dispose();
```

### Exact signatures

```dart
// Future<void> semantics for all commands EXCEPT dispose(): the Future
// completes after the command pipeline has made its synchronous/no-op decision
// or reached dispatch/rejection; it never waits for the provider's terminal
// response and never throws on operational outcomes. Outcomes travel through
// `states`. dispose() is the exception: its Future completes only when the
// resources are actually freed (streams closed, connection torn down).

Future<void> send(String text, {List<Uint8List> images = const []});
  // no-op if text is empty AND images is empty; image bytes are raw picker
  // output — the Core resizes (§2, §11)
Future<void> regenerate();
Future<void> resend(String messageId);
Future<void> editAndResend(String messageId, String newText);
  // newText may be empty only if the Message keeps ≥1 image; otherwise no-op
void cancel();
Future<void> dispose();

Stream<ConversationState> get states;   ConversationState get state;
Stream<String> get tokens;              Conversation get snapshot;
BotProfile botProfile;                  // mutable (get/set)

// Callbacks (all supplied by the app):
typedef OnToolCall   = Future<ToolResult> Function(ToolCall call);
typedef ConversationCheckpoint = Future<void> Function(Conversation snapshot);
typedef OnAttach     = Future<List<Uint8List>> Function();  // [] = user cancelled the picker
typedef OnMic        = Future<String?> Function();          // null = nothing dictated
typedef OnImageTap   = void Function(Uint8List bytes);

// Builder slots (widgets, §7):
typedef AvatarBuilder     = Widget Function(BuildContext, MessageRole);
typedef ThinkingBuilder   = Widget Function(BuildContext);
typedef ErrorBuilder      = Widget Function(BuildContext, FailureCause, VoidCallback retry);
typedef PartBuilder       = Widget? Function(BuildContext, Message, ContentPart);
                            // return null = "use the default rendering"
typedef EmptyReplyBuilder = Widget Function(BuildContext, VoidCallback regenerate);
```

The public command type remains `Future<void>`. Inside the package, the Core
returns a private command disposition — `accepted | rejected | noOp` — to the
package widgets. `ChatInputBar` clears its draft only on `accepted`; it keeps the
draft on a busy/empty no-op and on preprocessing/checkpoint rejection. This is an
implementation bridge inside the package library, not a new public product API.
The lower-case command disposition is unrelated to transport
`BackendEvent.Accepted`.

Deliberate parallels with the sibling kit: `backend:` with a Fake twin
(CONTEXT.md §Fake AI Backend), plain streams + value objects outward, explicit
`dispose`, zero global state. Honest difference: the sibling holds three
services under a thin holder (`AudioKit`); here there is exactly one service —
the conversation — so commands sit directly on the façade, no intermediate
layer.

**Not** on the façade, by design: no conversation list (another conversation =
another session), no storage (snapshot out — persisting it is the app's job,
ADR 0002), no generation parameters (ADR 0005), no attempt-count/backoff
knobs (those are code defaults inside the Retry Boundary; the one deliberate
retry knob is `retryDeadline`, CONTEXT.md §Retry Boundary).

## 4. Conversation state machine

Semantics live in CONTEXT.md §Conversation State / §Cancel / §Tool Use Cycle —
this section only pins the API-level behaviour.

```
Idle → Sending → Streaming → Done
            ↑               ↘ Failed / Cancelled
            └── AwaitingTool ←┘
```

- A session is constructed in **Idle**; a passed `history` is normalized first
  (in-flight `sending` → `failed`, `streaming` → `interrupted` —
  CONTEXT.md §Message Status).
- Done / Failed / Cancelled are terminal **for the current reply only**; any
  command re-enters `Sending`.
- One reply in flight per session, by construction. **No command queue** — see
  the matrix: a command in the wrong phase is dropped, never deferred (a
  deferred command would be a hidden billable call firing later).

**Async preprocessing does not create a public phase.** A command synchronously
acquires one private command gate before its first `await`; while that gate is
held, another command is a no-op. The exact first-leg sequence is:

1. acquire the private gate;
2. validate/count/resize images and check the resulting serialized payload;
3. create the user Message and `attemptKey`;
4. enter public `Sending`;
5. await the persistence checkpoint;
6. dispatch the frozen request to the backend.

`cancel()` becomes active only at step 4, preserving the canonical meaning of
cancel-in-`Sending` (the user Message exists and remains `sent`). `dispose()`
invalidates the gate at any step and prevents a late preprocessing/checkpoint
completion from dispatching. No callback completion may resurrect an invalidated
command.

The first-leg user Message starts as `sending`; `BackendEvent.Accepted` (or the
first data event defensively) makes it `sent`. An exhausted pre-token operational
failure makes it `failed`. Explicit cancel during public `Sending` makes it
`sent`, even if the checkpoint was still pending, because the user chose to keep
that committed turn.

### Operation safety (no-op matrix)

Commands never throw on phase misuse — wrong phase = silent no-op in release,
`assert`/debug-log in debug builds. Two loud exceptions, both programming/
configuration bugs by Flutter convention: **any command except a repeated
`dispose()` after disposal throws `StateError`**, and **Tool configuration
guards throw `ArgumentError`** (missing resolver, invalid/duplicate Tool
name/schema; constructor/setter, §3/§5).

| Command | Idle | Sending | AwaitingTool | Streaming | Done / Failed / Cancelled |
|---|---|---|---|---|---|
| `send` | ✅ → Sending | no-op | no-op | no-op | ✅ → Sending |
| `send` with empty text **and** no images | no-op everywhere (nothing to send) | | | | |
| `regenerate` | ✅ for a bot reply, or for the final `sent` user Message with no assistant after it; else no-op | no-op | no-op | no-op | same rule |
| `resend(id)` | ✅ if `id` is a `failed` **user** Message, else no-op | no-op | no-op | no-op | same rule |
| `editAndResend(id, …)` | ✅ if `id` is a user Message, else no-op | no-op | no-op | no-op | same rule |
| `cancel` | no-op | ✅ → Cancelled (no bot Message created) | ✅ → Cancelled (keep partial) | ✅ → Cancelled (keep partial) | no-op — **Done wins** the race (CONTEXT.md §Cancel) |

The private preprocessing gate is busy but is not `Sending`: all public commands
are no-op there except `dispose()`. A `failed` user Message is recovered only by
`resend(id)`; pre-token recovery by `regenerate()` applies only to a `sent` final
user Message with no following assistant Message.

### Tool resolver edge rules

- `onToolCall` completing **after** a terminal (user cancelled while the app's
  tool ran) — result silently ignored (CONTEXT.md §Tool Use Cycle). The
  ignore is **result-only**: whatever side effect the Tool already performed
  has happened; the Package cannot undo app code.
- Tool execution is **at-least-once**: after a restart or a recovery repeat
  the app may see the same call again with the **same `toolCallId`** — an app
  whose Tool writes anywhere MUST deduplicate by `toolCallId`. The Core's own
  guarantee: it **never invokes the resolver for a `toolCall` part whose
  matching `toolResult` part already exists** in the Message.
- An unknown tool name or arguments that do not validate against the frozen
  declaration's JSON Schema never reach `onToolCall`; the Core appends a safe
  `is_error` result. A resolver exception is likewise converted to a sanitised
  `is_error` result with no stack trace, secret or raw exception text. The bot
  decides how to react; neither case becomes a chat Failure.
- No tool timeout in the Core; the cancel exit always exists.

### Persistence checkpoint

`checkpoint` is awaited after the relevant Message and `attemptKey` are in the
snapshot and before **every billable provider dispatch**: the first leg, each new
tool leg, and a fresh-key fallback after explicit `409`/`410` recovery. A silent
retry of an already-checkpointed frozen Attempt does not checkpoint again.
"First leg" includes the first backend request of an explicit same-key
resend/recovery command, because an expired/unknown key may run.
`checkpoint: null` is valid only when the Consuming App intentionally has no
cross-launch conversation persistence.

- First-leg checkpoint failure: backend is not called; the user Message becomes
  `failed`; terminal state is
  `Failed(upstream, FailurePhase.sending, "checkpoint-failed")`.
- Later tool-leg checkpoint failure: backend is not called; the in-progress
  assistant Message becomes `interrupted`; terminal state is
  `Failed(upstream, FailurePhase.streaming, "checkpoint-failed")`.
- Malformed image preprocessing creates no Message/key and calls no backend; it
  ends as `Failed(upstream, FailurePhase.sending, "malformed-image")`.
- A post-resize request over 10 MB likewise creates no Message/key/backend call
  and ends as `Failed(contextTooLong, FailurePhase.sending, "payload-too-large")`.
- Cancel/dispose during a checkpoint invalidates the pending dispatch. The
  cancel/dispose terminal decision wins over any late callback success or error.
- The checkpoint callback MUST NOT reentrantly invoke a command on the same
  session; the reentrant command throws `StateError`. This is the existing
  programming-misuse exception, not a Failure cause.

### Disposal

`dispose()` is idempotent (second call is a no-op). Called mid-flight it
closes the SSE connection — the wire-cancel; the proxy's upstream abort is
best-effort and the orphan is bounded (SERVER-CONTRACT.md §3) — then frees
both streams and all subscriptions. During preprocessing/checkpoint it first
invalidates the command epoch, awaits/ignores the in-flight work safely, and
guarantees no late backend dispatch. The Core never observes the app's OS
lifecycle (CONTEXT.md §Lifecycle & Disposal); backgrounding policy is the app's.

## 5. Public data models

All models are `freezed` value objects. Semantics are CONTEXT.md's; this
section pins fields, ids and JSON.

### Persisted (the snapshot the app stores — ADR 0002)

```dart
Conversation {
  int schemaVersion;            // = 1
  List<Message> messages;
}

Message {
  String id;                    // UUID v4, minted by the Core at creation
  MessageRole role;             // user | assistant | system — NO tool role in v1
  List<ContentPart> parts;
  MessageStatus status;
  String? attemptKey;           // persisted Idempotency-Key: user = the send's
                                //   key; assistant = current/last leg's key
                                //   (updated through the Tool Use Cycle)
  DateTime createdAt;           // stamped by the Core, stored as ISO-8601 UTC
}

enum MessageRole { user, assistant, system }
enum MessageStatus { sending, sent, failed,             // user
                     streaming, complete, interrupted } // assistant
                     // system messages are always `complete`

sealed ContentPart =
  | TextPart(String text)
  | ImagePart(Uint8List bytes)               // processed JPEG, ≤ configured maxLongEdge
  | ToolCallPart(String toolCallId, String name, Map<String, dynamic> args)
  | ToolResultPart(String toolCallId, String content, bool isError)
  | ProviderOpaquePart(String provider, Uint8List data);
      // hidden provider-continuity state; persisted but never rendered/built
  // `file` kind: shape reserved in CONTEXT.md, NOT in v1 — added later as a
  // new union case (breaks only strict consumers, §0)
```

**Invariants** (enforced by the Core, checked on `fromJson`):

- `Message.id` values are unique inside a Conversation.
- role↔status: `user` → `sending|sent|failed`; `assistant` →
  `streaming|complete|interrupted`; `system` → `complete`.
- A dispatched user Message and every assistant Message have a non-null
  `attemptKey`. A `system` Message is `complete`, text-only, and has
  `attemptKey == null`.
- Ignoring `ProviderOpaquePart`, assistant parts follow the visible grammar
  (CONTEXT.md §Message):
  `text* (toolCall toolResult text*)* toolCall?` — the trailing unmatched
  `toolCall` is legal **only** on `streaming`/`interrupted`; a `complete`
  Message never has one. A `toolResult.toolCallId` matches the nearest
  unclosed call. `toolCallId` is unique inside one logical reply. Tool and
  provider-opaque parts never appear on `user`/`system` Messages.
- `ProviderOpaquePart.provider` is `openai` or `anthropic`; it is kept in
  source order and sent only to that same provider. It is ignored for the
  visible grammar, UI, Token Stream and builder callbacks.
- One reply = one assistant Message: tool-call and tool-result parts live
  **inside it**, so history can never separate a call from its result (and
  Context Trimming, which drops whole Messages, cannot either).

- **Message `id`** exists so `resend(id)` / `editAndResend(id, …)` have an
  address, and so the app can key its own UI/DB rows. The Core mints it; a
  loaded history must carry it (it round-trips through the app's storage).
- **`toolCallId`** is the provider's call id, normalized by the proxy
  (SERVER-CONTRACT.md §7) — it pairs a ToolResultPart to its ToolCallPart.
- **Conversation has no id** — identity/keys of stored conversations are the
  app's (storage is the app's, ADR 0002). The app wraps the snapshot in its
  own record.
- **Images serialize as base64** inside the JSON. Honest cost: ~1 MB per
  default-sized image in the app's DB (2048 px JPEG). Accepted for v1 —
  simplest end-to-end shape; if an app outgrows it, an external-reference
  scheme is a `schemaVersion` bump, not a redesign.
- **JSON**: `toJson()`/`fromJson()` on `Conversation` (codegen). The v1
  reader accepts `schemaVersion == 1` only and throws otherwise; bumping the
  version is a deliberate act with a migration note.

**Exact JSON.** Discriminator is `"type"` on parts; enums serialize as the
strings below; `attemptKey` is omitted when null:

```json
{
  "schemaVersion": 1,
  "messages": [
    { "id": "9b2f…", "role": "user", "status": "sent",
      "attemptKey": "5e01…", "createdAt": "2026-07-10T09:15:00Z",
      "parts": [
        { "type": "text",  "text": "What's on this photo?" },
        { "type": "image", "mimeType": "image/jpeg", "data": "<base64>" } ] },
    { "id": "c41a…", "role": "assistant", "status": "complete",
      "attemptKey": "77aa…", "createdAt": "2026-07-10T09:15:04Z",
      "parts": [
        { "type": "text",       "text": "Let me check your notes." },
        { "type": "toolCall",   "toolCallId": "call_1", "name": "searchNotes",
          "args": { "period": "2026-06" } },
        { "type": "toolResult", "toolCallId": "call_1",
          "content": "3 notes found", "isError": false },
        { "type": "providerOpaque", "provider": "openai",
          "data": "<base64 opaque provider item>" },
        { "type": "text",       "text": "You noted this plant in June…" } ] }
  ]
}
```

**Read policy** (forward-compat without speculation): unknown JSON **fields**
are ignored on read; an unknown part `"type"`, `role`, `status` or a
violated invariant is a **read error** in v1 (`schemaVersion` governs
evolution). Enum values on the wire: roles `user|assistant|system`; statuses
`sending|sent|failed|streaming|complete|interrupted`; part types
`text|image|toolCall|toolResult|providerOpaque`.

### Ephemeral (never serialized)

```dart
sealed ConversationState =
  | Idle | Sending | AwaitingTool(ToolCall call) | Streaming
  | Done(Usage? usage)     // usage = SUM over all legs of the reply (§8);
                           //   usageRaw kept only for single-leg replies
  | Failed(FailureCause cause, FailurePhase phase, String? developerDetail)
  | Cancelled;

enum FailureCause {                  // the closed 10-code catalogue,
  auth, entitlement, quota, rate,    //   CONTEXT.md §Failure
  overloaded, contentFilter, contextTooLong,
  network, upstream, toolLoopLimit,  // toolLoopLimit: client-side only
}
enum FailurePhase { sending, streaming }

Usage { int inputTokens; int outputTokens; Map<String, dynamic>? usageRaw }
```

### Configuration (per session / per send)

```dart
BotProfile { String id; String systemPrompt; List<Tool> tools }   // ADR 0005
Tool { String name; String description; Map<String, dynamic> parameters }
     // Chat AI Tool Schema v1 — SERVER-CONTRACT §7

ToolCall { String id; String name; Map<String, dynamic> args }    // → onToolCall
ToolResult { String content; bool isError }                       // ← the app
typedef OnToolCall = Future<ToolResult> Function(ToolCall call);

ImageSendOptions {
  int maxLongEdge = 2048;
  int jpegQuality = 85;
  int maxImagesPerMessage = 4;  // Core source of truth; must be > 0
}
```

Invalid image-option values throw `ArgumentError` at session construction. A
command whose raw image count exceeds `maxImagesPerMessage` is internally
`rejected`: no public phase change, Message, key, checkpoint or backend call;
the public Future completes and package widgets keep the draft.

`BotProfile` is **not** part of the snapshot — it rides with every send
(stateless, ADR 0002); switching bots is just the next send.

Tool declarations use exactly SERVER-CONTRACT §7's portable v1 dialect: root
object; unique regex-constrained names; only primitive/object/array types,
properties/required/`additionalProperties:false`/items/enum/description; every
property required, optional semantics via a nullable type pair. Constructor and
`botProfile` setter validate locally and throw `ArgumentError` before any
key/backend work. Dart and TypeScript consume the same normative
`test/contract_fixtures/tool_schema_v1/` corpus.

## 6. Wire formats (exact shapes)

SERVER-CONTRACT.md defines the rules; this section pins the bytes. JSON keys
are camelCase; cause codes are the kebab-case strings of CONTEXT.md §Failure.

### Request (client → proxy), one endpoint

```
POST <deployed function URL>
Authorization: Bearer <Firebase id-token>
X-Firebase-AppCheck: <App Check token>
Idempotency-Key: <UUID v4>            // per attempt / per leg — ADR 0004
Content-Type: application/json

{
  "wireVersion": 1,
  "botId": "premium",                 // Bot Profile id — a *request* (§4)
  "system": "<systemPrompt>",
  "messages": [ …assembled context… ],
  "tools": [ {"name": …, "description": …, "parameters": {…}} ]  // omit if none
}
```

- `messages` reuse the **storage JSON of `Message`** (§5) — one serializer,
  no second mapper. The proxy ignores client-only fields (`id`, `status`,
  `createdAt`, `attemptKey`) and translates `parts` to the active provider's
  shape (§1, §7).
- `wireVersion` is protocol-only and is excluded from the provider-effective
  request/hash. Unsupported versions fail as HTTP `426` before idempotency
  claim or provider call.
- An `ImagePart` rides as `{"type": "image", "mimeType": "image/jpeg",
  "data": "<base64>"}` — already resized by the Core.

**What the Core assembles** (`[system] + [prior Messages] + [new Message]`,
CONTEXT.md §Context Assembly — filtering pinned here):

- **`failed` user Messages are excluded** — they never reached the bot; their
  only path into the context is a successful `resend`.
- **`interrupted` assistant partials are included** — the user saw that text,
  it is real conversation (the ChatGPT/Claude stop-button behaviour).
- **Empty `complete` assistant Messages are dropped from the wire** (providers
  reject empty assistant content) but stay in storage/UI.
- Tool-call / tool-result parts ride as-is, embedded in their assistant
  Message; **the proxy splits them into the active provider's shapes**
  deterministically (e.g. `[text, toolCall]` → provider assistant message,
  `[toolResult]` → provider tool/user-result message, trailing `text*` →
  assistant continuation) — the split is the same normalisation work as §1/§7
  of the contract, in reverse.
- System input order is exact: `BotProfile.systemPrompt`, then persisted
  `system` Messages chronologically. The proxy removes those Messages from
  ordinary history and maps the combined sequence to provider instructions
  (OpenAI) / system (Anthropic).
- `ProviderOpaquePart` remains ordered inside its assistant Message. The proxy
  returns it only to the matching provider and omits foreign-provider opaque
  parts after a provider switch; matching opaque bytes remain part of the
  provider-effective request and `paramsHash`.
- Context Trimming (when enabled) runs **once, pre-assembly**; no
  "trim → still too long" loop — the server stays the final arbiter
  (`context-too-long`). Degenerate case (system + one Message already over
  budget) = immediate `Failed(context-too-long)`, never retried silently.

### Response — pre-stream failures (HTTP status, no stream yet)

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

**Protocol signals** (not Failure causes — SERVER-CONTRACT.md §6/§10):

- **`409 Conflict`** — same key, mismatched params. In a **silent retry**
  this is a client bug (`Failed(upstream)`, assert in debug — the Attempt's
  `ChatRequest` is frozen and byte-identical by construction); in an
  **explicit** resend or interrupted-reply recovery → **one** automatic re-run
  under a fresh key.
- **`410 Gone`** — the attempt is recorded as aborted and refused while its
  tombstone is retained. Silent retry → terminal `Failed(upstream)`; explicit
  reused-key command → **one** automatic fresh-key re-run.
- A **replay hit** (key `complete`) is an ordinary SSE response replaying the
  stored outcome — the whole text may arrive as one big `delta`, then `done`.

### Response — the SSE stream (`200`, `text/event-stream`)

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

- **Each leg's response ends with exactly one terminal event** — `tool_call`
  (this leg is over, carries the leg's usage; the tool-result comes back as a
  new request), `done` (final leg; the reply is complete) or `error`. After
  `tool_call` no `done` follows in that response; the Core sums the legs'
  usage into the reply's `Done(usage)`.
- `provider_state` is nonterminal and ordered with the visible deltas/tool
  parts. The Core appends the decoded opaque bytes to the assistant Message;
  it never emits them on `tokens` and widgets never render or build them.
- A stream ending without a terminal event = `Failed(upstream)` (§2 of the
  contract).
- `Retry-After`: pre-stream HTTP failures use the standard header; in-stream
  `error` uses `retryAfterMs` — both land in `ErrorEvent.retryAfter` (§8).
- Reserved for v2 resumable (§8 of the contract), **not emitted by the v1
  template, ignored by the v1 client**: `streamId` on the response,
  monotonic `eventId` on `delta`.

### Tool-result round-trip

The tool-result goes back as an **ordinary request** (above): the assembled
context now ends with the in-progress assistant Message whose parts close
with `toolCall + toolResult` (`toolCallId`, `content`, `isError`) — under a
**fresh** `Idempotency-Key` (per-leg, contract §7); the assistant Message's
`attemptKey` is updated to the new leg's key.

## 7. Widgets — concrete configuration

Visual behaviour is docs/widgets-spec.md; this pins the parameters. The one
**required** parameter across all three widgets is `failureText` on the
Message List — everything else has a working default ("codes out, strings
never": the package ships zero user-facing strings).

```dart
ChatMessageList(
  session: session,                          // required
  failureText: (FailureCause c) => …,        // required — the app's switch over 10 codes
  theme: ChatTheme(…),                       // optional; defaults derive from Theme.of(context)
  // layout switches (widgets-spec «Переключатели»):
  ownMessagesRight: true,
  showAvatars: false, avatarSide: …,
  timestamps: TimestampPosition.none,
  // builder slots (each nullable = default rendering):
  avatarBuilder, thinkingBuilder, errorBuilder,
  partBuilder,                               // visible ContentParts only; never providerOpaque
  emptyReplyBuilder,                         // default: compact regenerate icon-button
  onImageTap,                                // null = tap does nothing
)

MessageBubble(message: …, theme:, partBuilder:, onImageTap:)   // exported standalone

ChatInputBar(
  session: session,
  hint: null,                                // null = empty placeholder, no default text
  onAttach: null,                            // null = no attach button (app's picker otherwise)
  onMic: null,                               // null = no mic button; result text is INSERTED, not sent
  maxAttachments: null,                      // null = session.imageOptions limit;
                                             // non-null may only LOWER that limit
)
```

- `ChatTheme` is a plain immutable value class (colors, paddings,
  `TextStyle`s, shapes, image-thumbnail size — the list in widgets-spec);
  every field nullable, null = derived from the app `Theme`.
- Built-in actions wire directly to the façade: send→stop toggle (`cancel`,
  active in Sending/AwaitingTool/Streaming), resend button on a `failed` user
  bubble (`resend(id)`), regenerate on an `interrupted` reply and on the
  error row after a `Failed` with no assistant only when the last user Message
  is `sent`; if that user Message is `failed`, the row calls `resend(id)`.
  Assistant status `failed` does not exist (CONTEXT.md §Message Status). Copy
  is on long-press. No retry logic in widgets — a button is one Core call.
- The Input Bar owns its draft/controller internally. It awaits `onAttach` and
  `onMic`; callback exceptions keep the draft and are reported through
  `FlutterError`, not as a chat Failure. It clears the draft only when the
  Core's private command disposition is `accepted`. Its effective attachment
  cap is `min(local override, session.imageOptions.maxImagesPerMessage)`; the
  Core re-checks the session cap for direct API calls.
- Bot text renders via `gpt_markdown` by default (`markdown: false` → plain);
  user text is always plain.

## 8. AI Backend interface + Firebase adapter

```dart
abstract class ChatBackend {
  Stream<BackendEvent> send(ChatRequest request);
  // cancelling the subscription = wire-cancel: the transport MUST close the
  // connection; the proxy's upstream abort is BEST-EFFORT (observed
  // disconnect / write failure) and the orphan is bounded — contract §3
}

ChatRequest { int wireVersion = 1; String botId; String system;
              List<Message> messages; List<Tool> tools;
              String idempotencyKey; }

sealed BackendEvent =
  | Accepted()              // at most once PER BACKEND REQUEST (a same-key
                            //   Attempt may see several across its silent
                            //   retries), before any other event of that
                            //   request: a valid SSE response arrived after
                            //   the proxy atomically selected one safe path:
                            //   create-and-run, join running, or replay
                            //   complete (§6 contract). Asserts safe server
                            //   handling/liveness — NOT proof the provider
                            //   billed anything. A pre-stream failure may end
                            //   the request WITHOUT Accepted ever arriving.
  | Delta(String text)
  | ProviderStateEvent(ProviderOpaquePart part) // ordered, nonterminal
  | ToolCallEvent(ToolCall call, Usage? usage)   // terminal event of the
                            //   current LEG; carries that leg's usage
  | DoneEvent(Usage? usage)                      // terminal event of the
                            //   FINAL leg; the Core sums all legs' usage into
                            //   the reply's Done(usage) fact (usageRaw kept
                            //   only for single-leg replies)
  | ErrorEvent(FailureCause cause, String? detail, Usage? usage,
               Duration? retryAfter)             // retryAfter: from the
                            //   standard Retry-After header (pre-stream HTTP)
                            //   or the `retryAfterMs` field of the SSE error
                            //   event — one backoff input, two wires
  | ConflictEvent()         // HTTP 409 — same key, mismatched params
  | GoneEvent();            // HTTP 410 — attempt aborted server-side
  // The Core maps Conflict/Gone per §6: inside a silent retry →
  // Failed(upstream) (409 additionally asserts in debug — a frozen request
  // cannot legally conflict); after an explicit command → one automatic
  // fresh-key re-run.
```

**The backend stream never throws.** Every outcome — transport failure
included — is one of the events above ("failures are data" extends to the
transport layer); a thrown error escaping `send()` is a bug by contract.
`FirebaseChatBackend` verifies HTTP
`X-Chat-AI-Wire-Version: 1` before yielding `Accepted`; missing/mismatched
version becomes `ErrorEvent(upstream, "unsupported-wire-version", …)`.

**SSE parser contract:** incremental UTF-8 decoding precedes line parsing; LF
and CRLF are accepted; comment/keepalive lines are ignored; consecutive `data:`
lines are joined with `\n` per SSE; more than one event may arrive in a transport
chunk. Malformed JSON/unknown event before terminal and EOF without terminal
produce exactly one `ErrorEvent(upstream, <logs-only detail>)`. The first
terminal closes the logical stream; duplicate terminals or later events are
ignored and reported to debug diagnostics, never emitted as a second outcome.
Parser defects never escape as stream errors.

**Deadline mechanics in the Core** (realizes CONTEXT.md §Retry Boundary): the
Core records `startedAt` at the command and checks elapsed time only at
**retry decision points** (before an attempt, before a backoff wait) — no
timer fires into a live stream, so a thinking model is never cut. A
pre-first-token provider rejection returns the flow to a decision point;
within the deadline the same-key retry runs again (the proxy released the key
on an exact safe-release rejection, §6 contract), past it → `Failed` with the
last real cause.

`FirebaseChatBackend(url)` implements it with `dio` (`ResponseType.stream` +
`CancelToken`), pulls the id-token from `firebase_auth` and the attestation
from `firebase_app_check` per request, parses SSE with the internal parser.
The retry loop (silent side of the Retry Boundary) lives in the **Core**, not
the backend — the Fake then exercises it too. **The Core freezes the
serialized `ChatRequest` for the lifetime of an Attempt** — every silent
retry re-sends it byte-identical — and the **Bot Profile snapshot lives for
the whole logical reply**: all legs of one reply use the profile taken at the
send; `session.botProfile =` during `AwaitingTool` affects only the next
command, never the reply in flight.

For every **new billable leg**, the Core first updates the Message/key, awaits
`checkpoint`, and only then invokes `ChatBackend.send`. This includes the
first leg, every tool-result leg and the one fresh-key fallback authorised by
explicit recovery. A silent retry reuses the already-checkpointed frozen
request and key. The callback is never overlapped with a backend dispatch for
that leg.

## 9. Server template

Spec: docs/server-template.md (Firebase CF gen2 + Firestore). Implementation
order pinned here: **OpenAI translator first** (its tool-declaration shape is
already our wire format — the thinnest translation, the reference
implementation), **Anthropic second** — the second real provider is what
*proves* the normalisation layer (§1) instead of assuming it. Both ship in
the v1 template; which one a deployment uses is its `tier→model` map.

## 10. Fake backend (v1, `package:chat_ai/testing.dart`)

`FakeChatBackend implements ChatBackend` — no network, no money. Scriptable
per CONTEXT.md §Fake AI Backend, one builder-style config:

```dart
FakeChatBackend()
  ..reply("token by token", tokenDelay: …)     // Token Stream + throttling
  ..failWith(FailureCause.overloaded, afterTokens: 3)  // Failure / Retry Boundary
  ..breakAfterFirstToken()                     // keep-partial rule
  ..requestTool("search", args: …)             // Tool Use Cycle incl. is_error, loop limit
  ..emptyReply()                               // valid empty Done
  ..replayOnSameKey() / ..respondGone410() / ..respondConflict409()
                                               // recover-before-rebill: replay,
                                               //   aborted-attempt and conflict paths
```

## 11. Defaults (the numbers, all code defaults — not config)

| What | Default | Source |
|---|---|---|
| Silent-retry wall-clock deadline | **30 s**, app-configurable (`retryDeadline`); never cuts a *thinking* model — it bounds getting the request *accepted*, pre-first-token | CONTEXT.md §Retry Boundary |
| Silent-retry backoff | jittered exponential, honours `Retry-After` for `rate`, within the deadline | §Failure |
| Token Stream UI throttle | ~15 emissions/s (66 ms); accumulator always complete | §Token Stream |
| `maxToolTurns` | 5 (`ChatSession` param) | §Tool Use Cycle |
| Images per message | 4, app-configurable (`ImageSendOptions.maxImagesPerMessage`), enforced by Core; Input Bar follows it | §Image Attachment |
| Image resize | longest side 2048 px, JPEG q=85, in an isolate — app-tunable (`imageOptions`) | §Image Attachment |
| Context trimming | **off** (`trimBudget: null`); on = system + newest-that-fit, chars/4 estimate | §Context Trimming |
| Server terminal replay TTL | 10 min after `complete`/`aborted` (template default); outcome in private GCS, metadata in Firestore; logical expiry checked on read | contract §6 / ADR 0006 |
| SSE keepalive | `: ping` every 15 s of silence (template) | contract §3 |
| Max request payload | 10 MB (`413` → `context-too-long`) | contract §10 |
| Functions gen2 streaming response | tier `maxOutputTokens` + worst-case normalised SSE must fit 10 MB; deploy gate, not public setting | contract §3 |
| Orphaned-generation bound | function timeout + per-tier `maxOutputTokens` (template config) | contract §3 |
| **Flutter / Dart floor** | **Flutter ≥ 3.44, Dart ≥ 3.12** (package `pubspec.yaml`); actual kickoff toolchain: the **shared stable-channel Flutter SDK — Flutter 3.44.6 / Dart 3.12.2** (kept on latest stable; no FVM, no separate SDK, no repository-local pin file) | — |

## 12. Test contract (must pass before v1 "done")

Against `FakeChatBackend` unless noted:

1. **State machine and private gate**: every legal transition; one reply in
   flight; two sends racing during async resize produce one preprocessing job,
   one Message/key and at most one backend call. The private gate is never
   exposed as a public state.
2. **No-op/disposition contract**: every invalid matrix cell changes nothing;
   package widgets observe `noOp`/`rejected` and keep the draft, `accepted`
   clears it. Post-dispose commands and checkpoint reentrancy throw
   `StateError`; repeated `dispose()` frees resources once.
3. **Open normalisation and invariants**: stale `sending`/`streaming` becomes
   `failed`/`interrupted`; duplicate Message ids, illegal role/status/parts,
   missing required attempt keys and duplicate reply-local toolCall ids fail
   validation.
4. **Cancel/dispose races**: cancel from public Sending (user Message remains
   `sent`, no assistant), Streaming and AwaitingTool (partial kept); Done wins;
   late tool/checkpoint/preprocessing completions cannot dispatch or mutate a
   terminal/disposed session.
5. **Retry matrix**: pre-token `rate|overloaded|network` are retry-eligible
   inside the deadline only through a safe same-key run/join/replay/release;
   a provider response outside the exact release allowlist aborts/410 instead. Causes
   `auth|entitlement|quota|content-filter|context-too-long` never retry;
   upstream and every post-token break require explicit recovery. Deadline is
   checked only at decisions, never cuts a live stream;
   `Retry-After` must fit. Run/join/replay each yield one `Accepted` per backend
   request before data; a pre-stream failure may yield none.
6. **Recover-before-rebill**: interrupted assistant and final `sent` user with
   no assistant first reuse their persisted key; failed user uses `resend`;
   complete regenerate starts fresh. Explicit reused-key `409/410` permits
   exactly one checkpointed fresh-key fallback; silent `409/410` is terminal.
7. **Checkpoint**: snapshot contains the new Message/key before callback;
   first-leg failure marks user `failed` + `FailurePhase.sending`; tool-leg
   failure marks assistant `interrupted` + `FailurePhase.streaming`; backend is
   never called. First leg, every tool leg and explicit fresh fallback await a
   checkpoint; a silent retry does not repeat it.
8. **Tool cycle and safety**: fresh key per leg; leg usage sums; `tool_call` is
   terminal without `done`; resolver exceptions are sanitised `is_error`;
   unknown tool/schema-invalid args never invoke resolver; existing result
   deduplicates the same toolCallId; loop limit keeps partial; profile snapshot
   remains fixed for the full logical reply. Constructor/setter reject missing
   resolver, duplicate/invalid names and non-v1 schemas with `ArgumentError`;
   shared accepted/rejected schema + argument fixtures produce identical Dart,
   TypeScript, OpenAI-translator and Anthropic-translator verdicts.
9. **Provider opaque continuity**: OpenAI and Anthropic opaque parts round-trip
   byte-exact through JSON/restart/tool legs, preserve ordering and are returned
   only to the matching provider; they never enter Token Stream, rendering or
   `partBuilder`. Whole-message trimming keeps them with their tool exchange.
10. **Edge replies/throttle**: empty done is a complete empty Message;
    tool-only and whitespace replies work; cancellation keeps the full internal
    accumulator, not only the last throttled emission.
11. **Serialization**: all part kinds/statuses/ids/keys/timestamps round-trip;
    unknown fields are ignored, unknown discriminators/schema versions and
    violated invariants throw; provider opaque data is base64.
12. **Images**: the configurable Core limit applies to direct `send` and
    widgets; widget override can only lower it; resize is off-UI-isolate;
    malformed data gives rejected + `Failed(upstream, sending,
    malformed-image)` with no Message/backend; dispose invalidates resize;
    post-resize payload >10 MB gives rejected `contextTooLong` before backend;
    edit/resend preserves processed ImageParts without re-resize.
13. **Widgets**: all states render; no built-in user-facing string; action is
    chosen by history (`resend` for failed user, `regenerate` for sent user
    without assistant or interrupted assistant); `onAttach`/`onMic` errors go
    to `FlutterError` and preserve draft; buttons invoke one Core command.
14. **Context/system mapping**: failed users excluded, interrupted partials
    included, empty complete replies omitted from provider wire, image-only
    sends; BotProfile prompt precedes chronological persisted system Messages,
    which are removed from ordinary provider history.
15. **Wire/version and backend failures-as-data**: request/header version 1;
    missing/mismatch and server 426 become upstream data; no backend stream
    error escapes. `wireVersion` and client-only Message fields do not affect
    `paramsHash`.
16. **SSE parser**: UTF-8 scalar split across chunks; LF/CRLF; comments and
    `: ping`; multiple `data:` lines; multiple events/chunk; JSON split across
    chunks; malformed JSON; unknown event; duplicate terminal; event after
    terminal; EOF without terminal; ordered `provider_state` replay.
17. **Server contract/integration** (real template, not Fake):
    - pinned OpenAI Responses and Anthropic Messages fixtures translate text,
      images, system instructions, tools/results, opaque state, usage, stop
      reasons and exact provider error structures into byte-exact normalised SSE;
    - two concurrent same-key requests make one provider call; live `running`
      joins; stale owner atomically aborts; complete replay reproduces `done` or
      the same `tool_call`; aborted returns 410; canonical provider-effective
      hashing ignores status/time/key/wireVersion differences but detects real
      parameter differences; a concurrent repeat during pre-entitlement
      admission compares the provisional requestHash and joins, then the
      resolved/downgraded provider is frozen before quota/provider dispatch;
    - GCS terminal order is enforced: no client terminal until object finalize +
      SHA verification + Firestore complete; failed finalize becomes aborted and
      never exposes terminal. Logical expiry acts immediately even before TTL;
      corrupt/missing replay object never calls provider under retained key;
      it atomically becomes `aborted`/410 so explicit recovery performs its one
      fresh-key fallback; every unknown→running mints a fresh `runId` and old-run
      cleanup cannot delete the newer replay object;
    - adapter safe-release is the exact pinned 429/529 allowlist; generic
      500/502/504, unknown 5xx and any ambiguous after-bytes failure abort. A
      released key can rerun only on the next backend request; an aborted key
      cannot. A cross-instance joiner captures the owner's `runId`, receives the
      identical release `cause` and `retryAfter` from that run object, and makes
      zero provider calls; release-object commit failure aborts instead of
      deleting the claim;
    - unknown attempt executes claim → entitlement → generation rate limit →
      quota reserve → provider; join/replay bypass new checks/reservations;
      reservation/settlement and `usage/{uid}/attempts/{attemptKey}` are
      idempotent; billed/unbilled/estimated/unknown settlement is covered and
      unknown never releases quota; the ledger persists `reservationId`, and
      stale-running recovery calls `reserveQuota(getExisting, attemptKey)` only to obtain
      that same reservation before settling it unknown;
    - unsupported wire version, malformed body and local validation create no
      key/usage/provider call; private bucket access and lifecycle/deploy config
      validations fail closed; both provider SDKs are configured with zero
      automatic retries and a forced 5xx/timeout fixture produces exactly one
      provider request; every tier's worst-case normalized SSE passes the 10 MB
      Functions streaming-response deploy gate.
18. **Cancel/platform smoke**: observed disconnect/write failure invokes the
    best-effort upstream abort; keepalive is emitted; orphan bounded by function
    timeout/`maxOutputTokens`; terminal accounting remains idempotent. A real
    device → deployed gen2 smoke records platform behaviour but does not gate the
    build.

## References

- CONTEXT.md — the domain glossary this spec realizes
- SERVER-CONTRACT.md — wire rules (this spec pins the exact shapes, §6)
- docs/adr/0001–0006 — the decisions
- docs/widgets-spec.md, docs/server-template.md — surface specs
- Sibling: `record_transcribe/V1_SPEC.md` — the structural template
