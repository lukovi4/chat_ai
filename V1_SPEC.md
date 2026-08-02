# V1 Spec — Chat AI Kit

The technical specification for **v1** of the package. It turns the domain model
(CONTEXT.md), the decisions (docs/adr), the Firebase server contract
(`packages/chat_ai_firebase/docs/SERVER-CONTRACT.md`) and the surface specs
(docs/widgets-spec.md, `packages/chat_ai_firebase/docs/server-template.md`) into
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

- **iOS 18+**, **Android 14 (API 34)+**. API 34 is the minimum supported
  Android version for v1; older Android releases stay out of scope (personal
  apps, small audience: fewer legacy workarounds, current platform APIs).
- iOS+Android only — no web, no desktop.
- **The package requests zero permissions.** Photos come through the app's
  own picker (`onAttach` callback), voice through the app's own
  recording/transcription (`onMic` callback) — camera, gallery and microphone
  permissions are entirely the app's business.

**v1 provider scope:** the shipped server adapter is **OpenAI Responses only**.
Anthropic is deferred to the product backlog and is not a v1 acceptance
criterion. Any `anthropic` discriminator or mapping mentioned below is a
reserved persisted/wire value or a future-adapter design reference; it does not
claim an installed SDK, working dispatch path or v1 support.

## 2. Dependencies (all internal to the package)

The app does **not** see these. The core carries **no transport dependency**:
Firebase/dio/SSE live in the `chat_ai_firebase` adapter and the direct OpenAI
Realtime WebSocket in the `chat_ai_openai_realtime` adapter — each with its own
dependency table. (WebRTC belongs to the OPTIONAL
`chat_ai_openai_realtime_voice` speech-to-speech package, which is not a
`ChatBackend` and is not used by `ChatSession`.)
Policy: **maintained, current packages only** — verified against pub.dev at
spec time (2026-07-10).

| Purpose | Package | Note |
|---------|---------|------|
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

**The synchronous constructor is connection-bound, always.** It performs the
restart normalization of §5 unconditionally and never talks to the backend;
cancelling a subscription of a plain `ChatBackend` stays a wire-cancel. The
optional durable reply lifecycle (a reply that keeps running remotely while no
client observes it) is reachable ONLY through the additive async entry point
`ChatSession.open(...)` and ONLY when the supplied backend implements the
optional `DurableChatBackend` capability (§8). Everything else about the v1
façade is unchanged.

```dart
final session = ChatSession(
  backend: backend,                    // the app-supplied ChatBackend: the
                                       //   chosen adapter's transport
                                       //   (chat_ai_firebase /
                                       //   chat_ai_openai_realtime), or
                                       //   FakeChatBackend() in tests
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
                                       // persists chats across launches —
                                       // and FORBIDDEN (ArgumentError) with a
                                       // ServerManagedDurableChatBackend (§8),
                                       // whose admitReply persists the
                                       // snapshot itself
);

session.botProfile = otherBot;  // mutable: "switching bots is just the next
                                // send with a different profile" (CONTEXT.md
                                // §Bot Profile) — takes effect on the NEXT
                                // command; the reply in flight (all its legs,
                                // incl. AwaitingTool) keeps the profile
                                // snapshotted at its send

// Tool configuration guards (loud configuration errors): a session can never
// hold tools without a resolver, duplicate/invalid Tool names, or a schema
// outside the Chat AI Tool Schema v1 dialect (docs/TOOL-SCHEMA-V1.md).
// CONSTRUCTOR/setter throw ArgumentError on a violation; the setter leaves the
// old profile unchanged, with no backend call or Idempotency-Key.
// The ONE exception: with a ServerManagedDurableChatBackend (§8) the tool loop
// is the server's, so tools without a resolver are legal — the declarations
// themselves are validated identically.

// Commands (money semantics per ADR 0004 / CONTEXT.md §Retry Boundary):
session.send(text, images: [...]);   // fresh Idempotency-Key; text may be
                                     //   empty if images are present (an image
                                     //   with no text is a valid Message)
session.regenerate();                // interrupted reply OR final sent user with
                                     //   no assistant: recover-before-rebill
                                     //   first under that Message's attemptKey;
                                     //   on 410/409 falls back ONCE to a fresh
                                     //   key. A complete reply starts fresh.
                                     //   With a ServerManagedDurableChatBackend
                                     //   (§8) EVERY regenerate starts fresh: a
                                     //   new logical reply with a new
                                     //   attemptKey and a new replyId.
session.editAndResend(id, newText);  // fresh key; truncates the conversation
                                     //   to that Message and re-sends — without
                                     //   asking (loss-protection = the app's
                                     //   copy-before-truncate, CONTEXT.md
                                     //   §Regenerate/Edit); keeps the original
                                     //   ImageParts untouched (no re-resize),
                                     //   replaces the text parts; no built-in UI
session.resend(id);                  // failed user Message, ONLY while it is
                                     //   the LAST Message of the conversation:
                                     //   SAME persisted attemptKey (safe side
                                     //   of the Retry Boundary); on 410/409 →
                                     //   one fresh-key re-run (explicit
                                     //   command). An older failed user with
                                     //   later history is a full no-op —
                                     //   resend never truncates; restarting
                                     //   from an earlier point is
                                     //   editAndResend's job
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

// The additive async entry point (durable extension): the SAME parameters and
// defaults as the constructor. With a plain ChatBackend it IS the constructor.
// With a DurableChatBackend and a persisted trailing `streaming` assistant it
// consults `attachReply` exactly once, after every local check of the
// constructor has passed (so invalid configuration/history never reaches the
// transport).
static Future<ChatSession> open({
  required ChatBackend backend,
  required BotProfile botProfile,
  OnToolCall? onToolCall,
  Conversation? history,
  int? trimBudget,
  int maxToolTurns = 5,
  Duration retryDeadline = const Duration(seconds: 30),
  ImageSendOptions imageOptions = const ImageSendOptions(),
  ConversationCheckpoint? checkpoint,
});

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
typedef ErrorBuilder      = Widget Function(BuildContext, FailureCause, VoidCallback? retry);
                            // retry == null = no valid recovery (a pre-Message
                            //   rejection); the app shows no retry control

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
| `resend(id)` | ✅ if `id` is a `failed` **user** Message **and the last Message of the conversation**; an older `failed` user with later Messages is a full no-op (no truncation, no state change, no key/checkpoint/backend) | no-op | no-op | no-op | same rule |
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
snapshot and before **every billable dispatch the Core itself owns**. Which
dispatches those are — and through which method — depends on the declared
backend:

- a plain `ChatBackend` — the first leg, each new tool leg and a fresh-key
  fallback after explicit `409`/`410` recovery; each dispatch is
  `ChatBackend.send`;
- a `DurableChatBackend` — the same legs, each dispatched through `startReply`
  (§8), never `send`; admission stays two-step (checkpoint, then start);
- a `ServerManagedDurableChatBackend` — **no `checkpoint` at all**: passing a
  non-null one together with this backend is an `ArgumentError`, thrown
  synchronously before any backend call. The whole logical reply is admitted by
  the **single `admitReply(replyId, request, snapshot)`** (§8), which persists
  that exact snapshot and creates the Job in ONE server transaction — so the
  first-leg `attemptKey` is committed there, not through a Dart callback, and
  there is no crash-gap between "Messages saved" and "Job created". The
  server-owned legs that follow are persisted by the app on its own server —
  its awaited `runChatReply.onLegStart` (§9).

A silent retry of an already-checkpointed frozen Attempt does not checkpoint
again. "First leg" includes the first backend request of an explicit same-key
resend/recovery command, because an expired/unknown key may run.
`checkpoint: null` is valid only when the Consuming App intentionally has no
cross-launch conversation persistence — or when the backend is a
`ServerManagedDurableChatBackend`, where `null` is the ONLY legal value.

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
- `ProviderOpaquePart.provider` is `openai` or `anthropic`; `openai` is active
  in v1, while `anthropic` is a reserved backlog discriminator. Opaque parts
  are kept in source order and sent only to the same supported provider. They
  are ignored for the visible grammar, UI, Token Stream and builder callbacks.
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
  int maxLongEdge = 2048;       // must be > 0
  int jpegQuality = 85;         // must be within 1..100 inclusive
  int maxImagesPerMessage = 4;  // Core source of truth; must be > 0
}
```

Image-option values outside these exact ranges (`maxLongEdge > 0`,
`jpegQuality` 1..100 inclusive, `maxImagesPerMessage > 0`) throw
`ArgumentError` at session construction. A
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

The core pins the transport-neutral shapes: the frozen `ChatRequest` (§8),
the rules of context assembly and the protocol-signal semantics below. How a
`ChatRequest` rides a concrete transport is each adapter's contract — the
exact Firebase HTTP JSON/SSE byte shapes that used to live in this section
moved unchanged to
**`packages/chat_ai_firebase/docs/WIRE-FORMATS.md`**. JSON keys are
camelCase; cause codes are the kebab-case strings of CONTEXT.md §Failure.

### Request (client → backend)

Every leg dispatches one frozen `ChatRequest` (§8) — on the Firebase wire it
becomes one POST with the `Idempotency-Key` header (see the adapter doc).
Its rules:

- `messages` reuse the **storage JSON of `Message`** (§5) — one serializer,
  no second mapper. A backend ignores client-only fields (`id`, `status`,
  `createdAt`, `attemptKey`) and translates `parts` to the active provider's
  shape.
- `wireVersion` is protocol-only and is excluded from the provider-effective
  request/hash. On the Firebase wire an unsupported version fails as HTTP
  `426` before idempotency claim or provider call.
- An `ImagePart` rides in its storage JSON shape `{"type": "image",
  "mimeType": "image/jpeg", "data": "<base64>"}` — already resized by the
  Core.

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
  ordinary history and maps the combined sequence to OpenAI instructions. A
  future provider adapter must preserve the same order.
- `ProviderOpaquePart` remains ordered inside its assistant Message. The proxy
  returns it only to the matching provider and omits foreign-provider opaque
  parts after a provider switch; matching opaque bytes remain part of the
  provider-effective request and `paramsHash`.
- Context Trimming (when enabled) runs **once, pre-assembly**; no
  "trim → still too long" loop — the server stays the final arbiter
  (`context-too-long`). Degenerate case (system + one Message already over
  budget) = immediate `Failed(context-too-long)`, never retried silently.

### Response — protocol signals (transport-neutral semantics)

The full HTTP binding — pre-stream failure statuses/bodies, the wire-version
header/`426`, and the exact SSE event frames — is pinned in the adapter's
`WIRE-FORMATS.md`. The core-side semantics:

- **Conflict** (`ConflictEvent`; HTTP `409` on the Firebase wire) — same key,
  mismatched params. In a **silent retry** this is a client bug
  (`Failed(upstream)`, assert in debug — the Attempt's `ChatRequest` is
  frozen and byte-identical by construction); in an **explicit** resend or
  interrupted-reply recovery → **one** automatic re-run under a fresh key.
- **Gone** (`GoneEvent`; HTTP `410`) — the attempt is recorded as aborted and
  refused while its tombstone is retained. Silent retry → terminal
  `Failed(upstream)`; explicit reused-key command → **one** automatic
  fresh-key re-run.
- A **replay hit** (key `complete`) is an ordinary response replaying the
  stored outcome — the whole text may arrive as one big `delta`, then `done`.
- **Each leg's response ends with exactly one terminal event** — `tool_call`
  (this leg is over, carries the leg's usage; the tool-result comes back as a
  new request), `done` (final leg; the reply is complete) or `error`. After
  `tool_call` no `done` follows in that response; the Core sums the legs'
  usage into the reply's `Done(usage)`.
- `provider_state` is nonterminal and ordered with the visible deltas/tool
  parts. The Core appends the decoded opaque bytes to the assistant Message;
  it never emits them on `tokens` and widgets never render or build them.
- A stream ending without a terminal event = `Failed(upstream)`.
- `Retry-After`: pre-stream failures use the standard header; in-stream
  `error` uses `retryAfterMs` — both land in `ErrorEvent.retryAfter` (§8).

### Tool-result round-trip

The tool-result goes back as an **ordinary request** (above): the assembled
context now ends with the in-progress assistant Message whose parts close
with `toolCall + toolResult` (`toolCallId`, `content`, `isError`) — under a
**fresh** `Idempotency-Key` (per-leg, contract §7); the assistant Message's
`attemptKey` is updated to the new leg's key.

The client wire keeps the internal ToolResult intact (`content` + `isError`);
mapping it to a provider is a **backend-only** step — the Firebase proxy's
exact encoding is pinned in the adapter's SERVER-CONTRACT §7. It never
changes the client shape.

## 7. Widgets — concrete configuration

Visual behaviour is docs/widgets-spec.md; this pins the exact public surface.
Required inputs: `session` on `ChatMessageList` and `ChatInputBar`, `message`
on `MessageBubble`, and — only on `ChatMessageList` — `failureText`;
everything else has a working default ("codes out, strings
never": the package ships zero user-facing strings — no tooltips, no error
texts; the only user-facing error text comes from the app's `failureText`, or
the app's `errorBuilder` replaces the error row entirely).

### Exact widget signatures

Builder/callback typedefs are §3's, verbatim (`AvatarBuilder`,
`ThinkingBuilder`, `ErrorBuilder`, `PartBuilder`, `EmptyReplyBuilder`,
`OnAttach`, `OnMic`, `OnImageTap`).

```dart
enum AvatarSide { leading, trailing }
enum TimestampPosition { none, belowBubble }

const ChatMessageList({
  Key? key,
  required ChatSession session,
  required String Function(FailureCause cause) failureText,
  ChatTheme theme = const ChatTheme(),
  bool ownMessagesRight = true,
  bool showAvatars = false,
  AvatarSide avatarSide = AvatarSide.leading,
  TimestampPosition timestamps = TimestampPosition.none,
  bool markdown = true,
  AvatarBuilder? avatarBuilder,
  ThinkingBuilder? thinkingBuilder,
  ErrorBuilder? errorBuilder,
  PartBuilder? partBuilder,
  EmptyReplyBuilder? emptyReplyBuilder,   // default: compact regenerate icon-button
  OnImageTap? onImageTap,                 // null = tap does nothing
});

const MessageBubble({                     // exported standalone
  Key? key,
  required Message message,
  ChatTheme theme = const ChatTheme(),
  bool markdown = true,
  PartBuilder? partBuilder,
  OnImageTap? onImageTap,
});

const ChatInputBar({
  Key? key,
  required ChatSession session,
  ChatTheme theme = const ChatTheme(),
  String? hint,             // null = empty placeholder, no default text
  OnAttach? onAttach,       // null = no attach button (app's picker otherwise)
  OnMic? onMic,             // null = no mic button; result text is INSERTED, not sent
  int? maxAttachments,      // null = session.imageOptions limit; non-null must
                            //   be > 0 and may only LOWER that limit
});
```

### ChatTheme — exact fields and defaults

`ChatTheme` is a plain immutable **const** value class; every field is
nullable, null = derived from the app `Theme` at build time. There are **no**
separate `userTextColor`/`assistantTextColor` fields (text color rides in the
`TextStyle`s) and no tail/animation/icon/controller/scroll fields — a bubble
tail is a custom `ShapeBorder`.

| Field | null default |
|---|---|
| `Color? backgroundColor` | `colorScheme.surface` |
| `Color? userBubbleColor` | `colorScheme.primaryContainer` |
| `Color? assistantBubbleColor` | `colorScheme.surfaceContainerHighest` |
| `Color? iconColor` | `colorScheme.onSurfaceVariant` |
| `Color? errorColor` | `colorScheme.error` |
| `Color? inputFillColor` | `colorScheme.surfaceContainerHighest` |
| `EdgeInsetsGeometry? messageListPadding` | `EdgeInsets.all(12)` |
| `EdgeInsetsGeometry? bubblePadding` | `EdgeInsets.symmetric(horizontal: 12, vertical: 8)` |
| `EdgeInsetsGeometry? inputBarPadding` | `EdgeInsets.all(8)` |
| `double? messageSpacing` | `8` |
| `TextStyle? userTextStyle` | `textTheme.bodyMedium` + `colorScheme.onPrimaryContainer` |
| `TextStyle? assistantTextStyle` | `textTheme.bodyMedium` + `colorScheme.onSurface` |
| `TextStyle? timestampTextStyle` | `textTheme.bodySmall` + `colorScheme.onSurfaceVariant` |
| `TextStyle? errorTextStyle` | `textTheme.bodySmall` + `colorScheme.error` |
| `TextStyle? inputTextStyle` | `textTheme.bodyLarge` + `colorScheme.onSurface` |
| `TextStyle? hintTextStyle` | `textTheme.bodyLarge` + `colorScheme.onSurfaceVariant` |
| `ShapeBorder? userBubbleShape` | `RoundedRectangleBorder`, radius 16 |
| `ShapeBorder? assistantBubbleShape` | `RoundedRectangleBorder`, radius 16 |
| `double? maxBubbleWidthFactor` | `0.8` of the available width |
| `Size? imageThumbnailSize` | `Size(160, 160)` |

Constraints — a violation throws **`ArgumentError` during widget build, before
rendering or invoking any callback**, with identical behaviour in debug and
release; it is never a debug-only `assert` or a silent clamp:
`0 < maxBubbleWidthFactor <= 1`; `messageSpacing >= 0`;
`imageThumbnailSize.width`/`height > 0`; a non-null `maxAttachments > 0`.

### Responsibility boundaries

- **MessageBubble** renders exactly one `Message` — its visible ContentParts
  and status markers — and implements Copy. It does not hold a `ChatSession`
  and never shows the failure row, the thinking placeholder, resend/regenerate
  or the empty-reply action; a `complete` assistant Message with no visible
  content draws no bubble at all. A `system` Message renders as plain text in
  the assistant visual style. `MessageBubble` owns **no outer alignment** and
  does not wrap itself in `Align`/a positioning `Row`: when used standalone,
  its parent positions it.
- **ChatMessageList** subscribes to `session.states` and `session.tokens` and
  reads `session.snapshot`; it owns the thinking placeholder, the failure row,
  the resend/regenerate actions, the empty-reply action and **all outer bubble
  alignment**. Assistant/system Messages are left-aligned; user Messages are
  right-aligned when `ownMessagesRight` is true and left-aligned otherwise.
- **ChatInputBar** owns its draft and image previews; `ChatTheme` styles it
  too. No public controller/focus/keyboard or scroll APIs in v1.

**Part rendering chain**: `TextPart`/`ImagePart`/`ToolCallPart`/
`ToolResultPart` are offered to `partBuilder` first; a null return means the
default rendering (the tool parts' default is hidden). `ProviderOpaquePart`
is never rendered **and never passed to `partBuilder`**.

### Built-in actions

Wired directly to the façade — a button is one Core call, no retry logic in
widgets:

- send→stop toggle (`cancel`), active in Sending/AwaitingTool/Streaming;
- resend button **only when the last Message of the conversation is a `failed`
  user Message** (`resend(id)`); an older `failed` user Message gets no button
  (resend there is a Core no-op, §4);
- regenerate on an `interrupted` reply and on the empty-`complete`-reply
  action. A `complete` reply with visible content gets no regenerate.
  Assistant status `failed` does not exist (CONTEXT.md §Message Status);
- **the error row's one action is the Core's recovery target of the current
  `Failed`, not inferred from history**: `resend(id)` when THIS command's
  anchor user Message actually became `failed`, `regenerate` when THIS reply's
  assistant actually became `interrupted`, and **no action** for a pre-Message
  rejection (malformed image / oversized payload) or any other `Failed` with
  no valid recovery — the Core carries this target and hands it to the widget
  through a package-internal bridge. The row still shows the failure (icon +
  `failureText`); with no valid recovery a supplied `errorBuilder` receives a
  `null` `retry` (never a no-op);
- Copy on long-press: joins the Message's visible `TextPart`s in order with
  `"\n"`, source text as-is (markdown included); image/tool/opaque parts are
  never copied; no visible text = Copy is a no-op.

### Markdown, timestamps, scroll

- `markdown` exists on exactly two widgets — `ChatMessageList` and
  `MessageBubble` — default `true`; it applies **only to assistant
  `TextPart`s** (rendered via `gpt_markdown`; `markdown: false` → plain).
  User and system text is always plain.
- `TimestampPosition.none` shows nothing; `belowBubble` shows the Message's
  `createdAt` in local time, formatted per the ambient Flutter/Material
  locale.
- The list stays glued to the bottom on new Messages/tokens **only if the
  user was already at the bottom**; a user who scrolled up is never pulled
  back down by streaming.

### Input Bar behaviour

- Effective attachment cap = `min(maxAttachments,
  session.imageOptions.maxImagesPerMessage)`; the Core re-checks its own cap
  for direct API calls. Repeated attaches add images up to the cap; a callback
  returning more than the remaining slots keeps the first images in source
  order up to the cap; `[]` = user cancelled the picker, nothing changes.
- `onAttach`/`onMic` are awaited; a callback exception keeps draft/previews
  and is reported through `FlutterError`, never as a chat Failure. `onMic`
  returning null changes nothing; a non-empty result is inserted at the
  current selection (replacing it) with the cursor placed after the insert —
  mic never sends automatically.
- Draft and previews are cleared only on the Core's private `accepted`
  disposition; `noOp`/`rejected` keep both (§3).

### Default Material icons (no strings)

send `Icons.send` · stop `Icons.stop` · attach `Icons.attach_file` · mic
`Icons.mic` · remove preview `Icons.close` · resend / regenerate /
empty-reply regenerate `Icons.refresh` · failure `Icons.error_outline` ·
interrupted `Icons.stop_circle_outlined` · default avatar `Icons.person`.
No tooltips and no other built-in user-facing strings.

## 8. AI Backend interface

```dart
abstract class ChatBackend {
  Stream<BackendEvent> send(ChatRequest request);
  // cancelling the subscription = wire-cancel: the transport MUST close the
  // connection; any upstream abort is BEST-EFFORT (observed
  // disconnect / write failure) and the orphan is bounded — the adapter's
  // contract
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

Production transports implement this interface in the companion adapters:
`FirebaseChatBackend` (`chat_ai_firebase` — dio + Firebase tokens + the SSE
pipeline; its wire-version check, SSE parser contract and HTTP binding moved
unchanged to the adapter's docs) and `OpenAIRealtimeChatBackend`
(`chat_ai_openai_realtime` — a direct OpenAI Realtime **WebSocket**, text
output; no WebRTC and no microphone).

**Deadline mechanics in the Core** (realizes CONTEXT.md §Retry Boundary): the
Core records `startedAt` at the command and checks elapsed time only at
**retry decision points** (before an attempt, before a backoff wait) — no
timer fires into a live stream, so a thinking model is never cut. A
pre-first-token provider rejection returns the flow to a decision point;
within the deadline the same-key retry runs again (the proxy released the key
on an exact safe-release rejection, §6 contract), past it → `Failed` with the
last real cause.

The retry loop (silent side of the Retry Boundary) lives in the **Core**, not
the backend — the Fake then exercises it too. **The Core freezes the
serialized `ChatRequest` for the lifetime of an Attempt** — every silent
retry re-sends it byte-identical — and the **Bot Profile snapshot lives for
the whole logical reply**: all legs of one reply use the profile taken at the
send; `session.botProfile =` during `AwaitingTool` affects only the next
command, never the reply in flight.

For every **new billable leg the Core owns**, it first updates the Message/key,
awaits `checkpoint`, and only then dispatches: `ChatBackend.send` with a plain
backend, `DurableChatBackend.startReply` with the client-owned durable one
(§8). This includes the first leg, every tool-result leg and the one fresh-key
fallback authorised by explicit recovery; a silent retry reuses the
already-checkpointed frozen request and key, and the callback is never
overlapped with a backend dispatch for that leg.

A `ServerManagedDurableChatBackend` is NOT one of those paths: it has no Dart
`checkpoint` (the pair is an `ArgumentError`) and no `startReply`. The Core owns
exactly one dispatch there — the single `admitReply(replyId, request,
snapshot)`, which hands the server the snapshot to persist atomically with the
Job — and the server-owned legs after it are persisted by the app on its own
server, never here.

### The optional durable capability (additive)

A transport MAY additionally implement `DurableChatBackend` — a long-running
operation instead of a connection. `ChatBackend.send` and its semantics are
unchanged, and a session takes this path only when the backend implements it.

There are **two independent opt-in durable modes**. They are **separate
interfaces** — `ServerManagedDurableChatBackend` is NOT a subtype of
`DurableChatBackend`; both only `implements ChatBackend` — and the declared
interface alone decides which one applies. They are never mixed:

| | `DurableChatBackend` | `ServerManagedDurableChatBackend` |
|---|---|---|
| owner of the logical reply | the **Core** (client-owned tool loop) | the **server** |
| entry point | `startReply` — one billable **leg** | `admitReply` — the whole logical **reply**, once |
| admission | **two steps**: `checkpoint`, then `startReply` | **one atomic server transaction** inside `admitReply` (Messages + Job) |
| Dart `checkpoint` | required before every Core-owned dispatch | **forbidden** — the pair throws `ArgumentError` |
| `tool_call` on the wire | expected; `onToolCall` answers it | a contract violation |
| next leg's `attemptKey` | minted+checkpointed by the Core | the server's |
| silent retry / fresh-key fallback | as in v1 | never |

```dart
abstract interface class DurableChatBackend implements ChatBackend {
  Stream<BackendEvent> startReply(String replyId, ChatRequest request);
    // a NEW billable leg of the logical reply; cancelling the subscription is
    // DETACH ONLY — the remote generation keeps running
  Future<Stream<BackendEvent>?> attachReply(String replyId);
    // a Stream = the reply exists and its CURRENT leg is replayed from the
    //   beginning; never a new provider call
    // null    = the backend PROVED there is no active reply
    // throw   = the status is unknown (never treated as null)
  Future<void> cancelReply(String replyId);
    // the explicit remote cancel; at most once per logical reply
}
```

Three identities, never mixed or reused for one another: `replyId` (the whole
logical reply — the assistant `Message.id`, no new persisted field, schema
stays 1), `attemptKey` (one billable leg) and `toolCallId` (one tool call).

In both durable modes the assistant Message is created **before** the first
dispatch — empty, `streaming`, carrying that leg's key — and persisted before
any provider work: through the existing checkpoint with a `DurableChatBackend`,
inside the admitted snapshot with a `ServerManagedDurableChatBackend`. Either
way the app owns a stable reply identity before any provider work. It is
excluded from that leg's wire (`legBaselineParts == 0`),
so the provider-effective first leg stays identical to the legacy one. With a
`DurableChatBackend` the tool loop then stays in the Core: the next leg is
`startReply` with the SAME `replyId` and a new checkpointed `attemptKey`.

Lifecycle: neither a terminal nor `dispose()` ever fires a remote cancel. A
terminal `BackendEvent` (`done`/`error`) ends the reply itself and its
observation; `dispose()` only detaches the observation, so a reply that has not
terminated may still be running remotely. Only the user's `cancel()` requests
remote cancellation: it ends the local session in `Cancelled`, keeps the partial
and fires `cancelReply` at most once **per logical reply** (a later reply of the
same session is cancellable in turn) — and never at all when no leg reached the
backend.

Recovery (only through `ChatSession.open`): the candidate is a trailing
`streaming` assistant Message; a returned stream keeps it `streaming`, moves
the user Message right before it `sending → sent` and attaches without
assembly, checkpoint, key or dispatch; `null` applies the ordinary restart
normalization; a throw propagates untouched. The attached leg has no frozen
request, so ANY of its outcomes — retryable causes included — is terminal for
that session: recovery never dispatches. The package ships no durable backend
implementation.

### The server-managed variant (additive, opt-in)

```dart
abstract interface class ServerManagedDurableChatBackend
    implements ChatBackend {          // NOT a DurableChatBackend: no startReply
  Stream<BackendEvent> admitReply(
    String replyId,                   // id of the empty `streaming` assistant
    ChatRequest request,              // the frozen FIRST-leg request
    Conversation snapshot,            // the exact frozen Conversation to persist
  );
    // ONE atomic server operation for the WHOLE logical reply: persist that
    // snapshot AND create (or safely join) the single Job of `replyId`, in one
    // transaction, before any provider call. `accepted` is the receipt of that
    // commit and is the stream's first successful event; a repeated transport
    // delivery of the same admission joins the Job instead of creating a
    // second one. An error BEFORE `accepted` is legal only as a PROVEN refusal
    // (no Job, no provider run); an undetermined network outcome must first be
    // resolved by `replyId` and may never be reported as such a refusal.
    // The server runs the tools and every following leg itself.
  Future<Stream<BackendEvent>?> attachReply(String replyId);
    // same three outcomes; the replay restarts the reply's VISIBLE TEXT from
    // the beginning
  Future<void> cancelReply(String replyId);
    // idempotent and race-safe with an admission still in flight: a cancel
    // after `admitReply` but before `accepted` may neither be lost nor allow a
    // later provider dispatch of that reply
}
```

No new event type, no ownership enum, no mode flag: the interface IS the
declaration. The observation stream carries exactly `accepted`, `delta`, `done`
and `error`; server-owned `tool_call`s, their results and the provider
continuity state never reach the session. `ChatBackend.send` stays inherited
for type compatibility only — a `ChatSession` never calls it in this mode.

The atomic transaction, the Job, the store and the admission endpoint are the
**Consuming App's**: the package still ships no production durable backend.

What the Core does differently in this mode, and nothing else:

- a Bot Profile **with tools needs no `onToolCall`** (the declarations are
  validated exactly as always);
- a non-null `checkpoint` is **rejected**: `ChatSession` and `ChatSession.open`
  throw `ArgumentError` synchronously, before `attachReply`, `admitReply`,
  `send`, the checkpoint itself or any other backend call;
- the assistant Message is still created before the first dispatch, its
  `Message.id` is the `replyId` and its persisted `attemptKey` stays the first
  leg's key — it is persisted by the admitted snapshot instead of a checkpoint;
- `admitReply` happens **exactly once per logical reply**, with the frozen
  first-leg `ChatRequest` and the `Conversation` snapshot captured right after
  that assistant was created (so the admitted value never follows the session's
  later local updates): no `_handleToolCall`/`onToolCall`, no next-leg keys, no
  silent retry, no fresh-key fallback, no `send`, no `startReply` and no second
  admission; `rate`/`overloaded`/`network`/`error` are the **terminal result of
  the observed server reply**;
- `accepted` splits the two pre-token failures that look alike on the wire:
  - **before it** — a PROVEN refusal, no Job: the empty assistant is removed,
    the anchor user Message becomes `failed`, the recovery is `resend` (its
    persisted key was never spent) and nothing is re-admitted automatically;
  - **after it, before the first `delta`** — the admission was committed and
    the turn provably ran: the empty assistant is removed, the user Message
    stays `sent`, the terminal is `Failed(…, FailurePhase.sending)` and the
    recovery is `regenerate`;
  - **after a visible `delta`** — unchanged: the partial is kept on an
    `interrupted` assistant, `Failed(…, FailurePhase.streaming)`, recovery
    `regenerate`;
- a `replyId` is admitted **at most once**, so the two shapes of "a second
  admission" never mix: the SAME `replyId` again is a transport duplicate that
  joins the existing Job, while an explicit `regenerate` is a NEW logical
  reply — the previous assistant leaves the active branch and the Core mints a
  new `attemptKey` and a new `replyId` (this replaces recover-before-rebill in
  this mode only; plain and client-owned durable keep theirs unchanged);
- an unexpected `provider_state`, `tool_call`, `409` or `410` is a
  **backend-contract violation**: the reply ends as one `upstream` failure,
  with no resolver call and no new dispatch;
- lifecycle is unchanged — `dispose()` only detaches, `cancel()` fires
  `cancelReply` at most once per logical reply (including a cancel between the
  `admitReply` call and its `accepted`), `ChatSession.open` consults
  `attachReply` once and a successful attach dispatches nothing; the first
  replayed delta replaces the persisted partial as a whole.

## 9. Server template

The reusable Firebase Functions gen2 server template ships with the Firebase
adapter package — **`packages/chat_ai_firebase/`**: the template itself at
`server/firebase-chat-template/`, its normative ownership/composition and
deployment invariants in the adapter's `docs/server-template.md`, and the
wire/idempotency contract in the adapter's `docs/SERVER-CONTRACT.md`. The
template is copied and deployed into each consuming app's own Firebase
project (own key, own billing, ADR 0001).

Implementation scope for v1 is **OpenAI Responses only**. The normalised
client/server boundary remains provider-agnostic, but no second provider is
promised by v1. **Anthropic is product backlog**: its adapter, SDK,
translator fixtures, error/safe-release mapping and deployment support are
future work. Existing `anthropic` persisted/wire discriminator values remain
reserved so this scope decision does not require a breaking data or wire
migration.

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

Items 1–14 are the core's own test contract, against `FakeChatBackend`
unless noted. Items 15–18 belong to the **`chat_ai_firebase` companion
package** (its transport, SSE layers, server template and platform smoke)
and run in that package; the numbering is kept for continuity:

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
   With a `ServerManagedDurableChatBackend` every `regenerate` instead starts a
   NEW logical reply (new `attemptKey`, new `replyId`, one new `admitReply`, the
   old `replyId` never re-admitted), while a pre-`accepted` refusal keeps the
   unchanged same-key `resend`.
7. **Checkpoint**: snapshot contains the new Message/key before callback;
   first-leg failure marks user `failed` + `FailurePhase.sending`; tool-leg
   failure marks assistant `interrupted` + `FailurePhase.streaming`; backend is
   never called. Every billable dispatch the Core owns awaits a checkpoint —
   first leg, every tool leg and the explicit fresh fallback; a silent retry
   does not repeat it. With a `ServerManagedDurableChatBackend` there is no
   checkpoint to await: the pair throws `ArgumentError` (constructor and
   `ChatSession.open`, before any backend call), and the single `admitReply`
   carries the frozen snapshot the server persists atomically with the Job.
8. **Tool cycle and safety**: fresh key per leg; leg usage sums; `tool_call` is
   terminal without `done`; resolver exceptions are sanitised `is_error`;
   unknown tool/schema-invalid args never invoke resolver; existing result
   deduplicates the same toolCallId; loop limit keeps partial; profile snapshot
   remains fixed for the full logical reply. Constructor/setter reject missing
   resolver, duplicate/invalid names and non-v1 schemas with `ArgumentError`;
   shared accepted/rejected schema + argument fixtures produce identical Dart,
   TypeScript and OpenAI-translator verdicts. A future provider adapter must pass
   the same corpus before it can ship.
9. **Provider opaque continuity**: OpenAI opaque parts round-trip byte-exact
   through JSON/restart/tool legs, preserve ordering and are returned only to
   OpenAI; they never enter Token Stream, rendering or `partBuilder`. Reserved
   Anthropic opaque parts remain byte-exact in persisted JSON but are not
   dispatched by the v1 server. Whole-message trimming keeps opaque parts with
   their tool exchange.
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
13. **Widgets**: all states render; no built-in user-facing string;
    message-attached actions outside `Failed` follow message status (`resend`
    only for the LAST `failed` user Message; `regenerate` for an `interrupted`
    assistant and the empty `complete` reply; a `complete` reply with visible
    content gets none), while the error row's action during `Failed` comes
    solely from the Core-computed recovery target of the current `Failed`
    (`resend(messageId)`, `regenerate` or `none`); `none` means no button and
    `ErrorBuilder` receives `null`, never a fabricated no-op callback;
    `ChatTheme`/`maxAttachments` constraint violations
    throw `ArgumentError` during build before rendering/callbacks, identically
    in debug/release (never an assert-only guard or clamp); `partBuilder` receives
    text/image parts and hidden tool parts but never `ProviderOpaquePart`;
    `markdown` affects only assistant TextParts on the two widgets exposing
    it; Copy joins visible TextParts with `"\n"` and no-ops without text; the
    list sticks to the bottom only when the user was already there;
    `onAttach`/`onMic` errors go to `FlutterError` and preserve
    draft/previews; over-cap attach keeps the first images up to the cap; mic
    inserts at the selection and never sends; buttons invoke one Core command.
14. **Context/system mapping**: failed users excluded, interrupted partials
    included, empty complete replies omitted from provider wire, image-only
    sends; BotProfile prompt precedes chronological persisted system Messages,
    which are removed from ordinary provider history.
15. **Wire/version and backend failures-as-data** (`chat_ai_firebase`):
    request/header version 1;
    missing/mismatch and server 426 become upstream data; no backend stream
    error escapes. `wireVersion` and client-only Message fields do not affect
    `paramsHash`.
16. **SSE parser** (`chat_ai_firebase`): UTF-8 scalar split across chunks; LF/CRLF; comments and
    `: ping`; multiple `data:` lines; multiple events/chunk; JSON split across
    chunks; malformed JSON; unknown event; duplicate terminal; event after
    terminal; EOF without terminal; ordered `provider_state` replay.
17. **Server contract/integration** (`chat_ai_firebase`; real template, not Fake):
    - pinned OpenAI Responses fixtures translate text, images, system
      instructions, tools/results, opaque state, usage, stop reasons and exact
      provider error structures into byte-exact normalised SSE;
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
    - the OpenAI adapter safe-release is the exact pinned retryable-429
      allowlist; generic
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
      validations fail closed; the OpenAI SDK is configured with zero automatic
      retries and a forced 5xx/timeout fixture produces exactly one
      provider request; every tier's worst-case normalized SSE passes the 10 MB
      Functions streaming-response deploy gate.
18. **Cancel/platform smoke** (`chat_ai_firebase`): observed disconnect/write failure invokes the
    best-effort upstream abort; keepalive is emitted; orphan bounded by function
    timeout/`maxOutputTokens`; terminal accounting remains idempotent. A real
    device → deployed gen2 smoke records platform behaviour but does not gate the
    build.

## References

- README.md — the single integration guide of the repository (this spec stays
  the normative contract, not the how-to)
- CONTEXT.md — the domain glossary this spec realizes
- docs/TOOL-SCHEMA-V1.md — the canonical Tool Schema v1 dialect
- docs/adr/0002–0005 — the core decisions
- docs/widgets-spec.md — the widget surface spec
- `packages/chat_ai_firebase/docs/` — the Firebase adapter's SERVER-CONTRACT
  (wire/idempotency rules), WIRE-FORMATS (the exact HTTP/SSE bytes),
  server-template guide and ADRs 0001/0006
- `packages/chat_ai_openai_realtime/` — the OpenAI Realtime adapter
- Sibling: `record_transcribe/V1_SPEC.md` — the structural template
