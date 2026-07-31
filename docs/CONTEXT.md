# Context

A canonical **chat-with-AI kit** for Flutter — one package that closes the large
common part of building a full chat-with-an-AI-bot product (in the spirit of the
ChatGPT / Claude apps), so a new app doesn't re-implement it. It targets a chat
client: **text messages, streamed bot replies, image attachments sent to the bot**,
and everything a chat surface needs. (Voice is only a typing aid — see Voice Input;
storing chats is the app's job — see Conversation Scope.)

It is **not** logic-only: like the sibling `record_transcribe` kit, it ships
ready, richly-configurable chat **widgets** (message list, message bubble, input
bar) so an app can "install, tune the visuals, and forget", while still exposing
the raw data/streams for apps that build their own UI. The Core owns the
**mechanism** (the one active conversation, its state, and reply streaming);
rendering is the widget's or app's job, and **storage is the app's** (the Package
holds one conversation in memory and hands it over as serializable data). (This is
the same Core-plus-optional-widgets boundary `record_transcribe` chose — see its
ADR 0007.)

This package is for **personal use** — built and consumed by the same author,
distributed as a **private git dependency** (not published to pub.dev), like its
sibling kit.

> NOTE: This file is the **domain glossary**: every term with its
> **behavioural semantics** — what it means and how it behaves — plus
> explicitly-labelled **defaults** the app can tune. No implementation detail
> (types, methods, wire shapes): that is spec/ТЗ level. Decisions with real
> trade-offs go in `docs/adr/`; wire behaviour lives in `SERVER-CONTRACT.md`
> (shipped with the Firebase adapter: `packages/chat_ai_firebase/docs/` —
> every `SERVER-CONTRACT.md` reference below points there).

## Glossary

### Package
The canonical chat-with-AI kit being built here: a reusable Flutter library
covering the chat-client lifecycle of **one active conversation** (send → stream
reply), plus image attachments to the bot and a set of configurable chat widgets.
Data + streams + optional widgets. It does **not** store chats or manage a list of
them (the app does — see Conversation Scope), and voice is only a typing aid (see
Voice Input). Not an application.

### Core
The pure Dart/Flutter logic of the Package: conversation state, message
streaming, history, attachments — backend-agnostic, knows only an abstraction of
the AI backend, no UI. The single source of truth a Consuming App renders from.

### Chat Widgets
The ready, richly-configurable Flutter widgets the Package ships — exactly
three parts: **Message List**, **Message Bubble**, **Input Bar**. There is
deliberately **no composite chat screen**: assembling a screen from the parts
is the app's job (a few lines of layout). **Optional**: an app may use them,
tune their visuals, or ignore them and render the Core's data itself. The
Package owns the mechanism; the widget owns the rendering. Same spine as
`record_transcribe`'s Waveform Widget.

**Customization boundary** (the "mechanism, not policy" line, applied to UI):
everything about **how it looks** is under the app's full control — colors,
paddings, text styles, bubble shapes (a tail is just a custom shape; text
color rides in the text styles) — carried by a **Chat Theme** config whose
defaults derive from the app's `Theme`, so an unconfigured chat already matches
the app's style; the exact field list, defaults and constraints are pinned in
V1_SPEC.md §7. **How it is composed** is configurable only up to ready-made
switches (a closed list in v1: own-bubble alignment, avatar visibility/side,
timestamp position — V1_SPEC.md §7);
arbitrary rearrangement is **not** a parameter — an app wanting a different
layout replaces a part via a builder slot or composes its own screen from the
exported parts (that is what they are exported for). This is the honest ceiling
of packaged UI in Flutter; above it lies only giving up the ready widgets.

### Consuming App
An application owned by the same author that depends on the Package and supplies
its own UI (or uses the Chat Widgets). Consumed as a **private git dependency**
(not published to pub.dev): the package lives in its own repository and each app
pins it via `git:` in `pubspec.yaml`.

### Conversation
The **one active chat** the Package works with: an ordered list of Messages plus
its Bot Profile, held **in memory** as session state and exposed as serializable
data. The Package handles **one conversation at a time** — it does **not** know
about multiple chats, switching between them, or listing them.

### Conversation Scope
The Package is infrastructure for **one conversation**, so an app doesn't rebuild
chat plumbing each time. Everything around it is the app's: **how many chats,
switching between them, where and how to store them, and all app settings** are
out of scope. The Core holds the active conversation in memory and hands it over /
takes it back as **serializable data** — the Core owns the *meaning*, the app owns
the *storage*. (Direct parallel to `record_transcribe`'s "one recording at a time,
no lists/libraries"; storage lives next to the app, not in the Package.) The
Package ships no database and forces no storage schema.

**How app-side storage works (the load/save round trip).** No database is needed to
*talk* to the bot — the Core holds the active conversation in memory. A database is
needed only to keep chats **across app launches**, and that DB is the app's (any
kind: Firestore, sqlite, files):
1. open a chat → the **app** loads its history from its DB → hands it to the Core as
   data;
2. the user sends → before each billable dispatch **the Core itself owns** it
   exposes an updated snapshot (including the Message and its `attemptKey`)
   through an **awaited checkpoint** supplied by the app; an app that keeps
   chats across launches persists that snapshot before the dispatch;
3. the Core streams the reply and continues exposing the current Conversation as
   **serializable data** → the **app** saves subsequent updates to its DB.
The Package never sees the DB and has none of its own. (Same hand-off shape as
`record_transcribe`'s serializable `RecordingStatus`: Core owns the meaning, the app
owns the storage.)

### Context Assembly (stateless)
How a request to the bot is built. The model has **no memory**: each turn, the full
conversation must be re-sent, so the Core **assembles the request on the client** —
`[system prompt from Bot Profile] + [prior Messages] + [new Message]` — and hands it
to the AI Backend. The Package is **stateless**: neither the Core nor the proxy
keeps durable conversation history server-side. The proxy temporarily retains
only a terminal Attempt outcome for its short idempotency-replay TTL; that is a
recovery artifact, not conversation history (SERVER-CONTRACT.md §6, ADR 0006).

Why client-side, and not a provider/server-stored history, is argued in
**ADR 0002** — in short: storage is the app's job anyway (see Conversation
Scope), the package server is reserved for the critical-only (the key,
ADR 0001), and money is neutral either way (OpenAI prompt caching
discounts a repeated prefix regardless of who stores it). The system prompt
lives in the **Bot Profile, on the app side** — all bot/prompt configuration is
the app's; the Package only carries it as a parameter.

System instructions have one deterministic order: the Bot Profile's
`systemPrompt` first, then persisted `system` Messages in chronological order.
Those Messages are text-only configuration history; the proxy maps the combined
sequence to the selected provider's instruction/system field rather than sending
them as ordinary chat turns.

### Context Trimming
Deciding which older Messages to drop when a conversation no longer fits the
model's context window. Because every turn re-sends the whole history (see Context
Assembly, ADR 0002), a long chat eventually approaches the window — and something
must give. The Package's stance is **mechanism, not policy**: the Core owns the
mechanism, the **app chooses the values and when to apply it**. (Same shape as
`record_transcribe`'s Recording Limit: the Core owns the "stop at N" mechanism,
the app owns N.)

**v1 ships one strategy**: *system prompt + as many most-recent Messages as fit
a token budget* (oldest dropped first). **The budget is a number the app
supplies** — the deploying author owns the tier→model map (ADR 0001), so the
app knows its tiers' windows first-hand and sets the budget with headroom.
Client-side token counting is deliberately **approximate** (the chars/4 rule);
precision is unnecessary because **the server stays the final arbiter**: an
over-budget request that still doesn't fit simply returns `context-too-long`.
The strategy runs once, pre-assembly — there is no "trim → still doesn't fit"
loop; the degenerate case (even system + one Message doesn't fit) is a terminal
`Failed(context-too-long)`, never retried silently.

**Default: the Core does not trim silently.** Out of the box no strategy is
applied — an over-window request surfaces `context-too-long` (the app renders
its own wording, e.g. "start a new chat"), and the app then opts into the
trimming mechanism deliberately (so the Core never quietly drops the user's
words on its own initiative). Smart history **summarisation** (compressing old
turns rather than dropping them) is heavy and is **v2**, not v1.

### Conversation State
The Core's single coarse-grained lifecycle of the active Conversation, exposed as
one broadcast stream plus a current-value snapshot:

```
Idle → Sending → Streaming → Done
            ↑               ↘ Failed / Cancelled
            └── AwaitingTool ←┘   (bot asked for a Tool; app executes, then the
                                   Core resumes the loop — see Tool Use Cycle)
```

`AwaitingTool` is entered when the bot emits a tool-call mid-reply: the Core pauses
on it, hands the call to the app, and on the app's result resumes Sending (the
tool-result goes back to the bot).

**`Sending` = "thinking", `Streaming` = "typing".** The first token is the boundary:
`Sending` means the user Message/key exist and the request is being checkpointed
or is on its way, while **no token has arrived yet** — this is the "bot is thinking"
phase the app renders as a pulsing `···` indicator. Image preprocessing happens
behind a private command gate before this public phase. `Streaming`
begins at the **first token** and is the "bot is typing" phase (growing text). No
separate `Thinking` state is needed — `Sending` already expresses it, and the
first-token boundary is already load-bearing (Retry Boundary, resumable).

**On a multi-leg reply (Tool Use Cycle) every first-token notion is per leg.**
After a tool-result goes back to the bot the conversation is `Sending` again,
and "no token yet" means no token **of the current leg** (the previous leg's
text is already on screen); the first delta of the new leg re-enters
`Streaming`. The Retry Boundary applies per leg too — each leg is its own HTTP
call with its own first token and its own Idempotency-Key (see Idempotency
Key).

These phases change **rarely** — they are what an
app hangs its UI logic and
Entitlement on (show a spinner, disable send, etc.). The fast-moving token text is
deliberately **kept off** this stream (same reasoning `record_transcribe` used to
keep amplitude / upload progress off its Pipeline State). Terminal states: Done,
Failed, Cancelled — terminal for the **current reply**, not the conversation:
any next command (send, Resend, Regenerate) re-enters `Sending` from any of
them, and from `Idle`.

### Token Stream
The assistant's reply as it arrives, on its **own high-frequency stream**, separate
from Conversation State. The provider sends **deltas** (small text chunks) over
SSE; the Core accumulates them and exposes the growing reply, **throttled** to
~10–20 updates/second (a code default): finer updates aren't perceptible, and
each emission costs a widget **rebuild** — vsync caps paints, not rebuild work,
so unthrottled deltas burn CPU/battery for nothing. **Throttling affects only
the UI emissions — the Core's accumulator is complete**: whatever is kept on a
cancel or a break is the full accumulated text, never the last throttled
snapshot. The
message-list widget subscribes here to grow the "typing" bubble; phase-only
listeners on Conversation State are not disturbed. Same spine as
`record_transcribe`'s Amplitude Stream / Upload Progress.

### Regenerate / Edit (truncate-and-resend)
Re-running the bot from an earlier point — **regenerate** (re-run the last reply) and
**edit** (change a user Message, then re-run from it) — both reduce to **one Core
mechanism: truncate the active conversation to a chosen point and re-send**. The
Core works on the **one linear conversation in memory**; it does **not** keep a tree.

**Branching is the app's, not the Package's.** A branch tree, "1 of N" pager, or
fork navigation is a *storage/UI* concern — and storage is the app's (ADR 0002). If
the app wants to preserve the old branch before truncating, it copies it in its own
DB first; the Package only offers "restart from here". A full branch tree is **not
v1** (and likely never the Package's job: ChatGPT and Claude *do* keep branches —
the "2/2" pager — but in their storage/UI layer, which is exactly where it
belongs here: the app's). Mechanism, not policy.

Regenerate/edit is **always explicit**, never silent. Edit and regenerate of a
`complete` reply start a new billable Attempt immediately. Regenerate of an
`interrupted` reply, or of the last `sent` user Message when no assistant Message
follows it, first attempts free recovery under the persisted key and merely
authorises one fresh-key fallback. Any new spend therefore follows a deliberate
command. A `failed` user Message uses **Resend**, not Regenerate.

**The Core truncates without asking** — the command comes from the app, and
whether to warn the user first ("this will rewrite the conversation") is the
app's policy. This matches the leaders: ChatGPT and Claude edit without any
confirmation dialog — their loss-protection is keeping the old branch, which
here is the app's copy-before-truncate (above).

### Reply Edge Cases (never crash)
The Core never has undefined behaviour on an unusual reply — it always lands on a
clean terminal, the same discipline as `record_transcribe`'s "never a crash".
- **Tool-only reply** (a tool-call with no text) is **normal**, not an error — the
  bot may ask for a Tool with zero text (→ `AwaitingTool`, see Tool Use Cycle).
- **Empty reply** (`done` arrived with no token and no tool-call) is a **valid
  `Done`** carrying an empty assistant Message — **not** a Failure. The server did
  its job; the bot simply said nothing (e.g. a filter tripped midway, or the model
  changed its mind). The Core hands over the empty fact; *whether to show "the bot
  was silent", hide it, or offer regenerate* is the app's call. (Mechanism, not
  policy — forcing `Failed` would impose policy.)
- **Whitespace-only / odd content** is just content — rendering or trimming it is
  the app's/widget's job, not a Core concern.

### Cancel (stop generating)
The **user** pressing "stop" while the reply is **Streaming**: generation is
aborted, and the **partial reply is kept** in history as the assistant's message,
marked interrupted (so it can be regenerated) — it is **not** discarded. This
follows the ChatGPT/Claude convention and mirrors `record_transcribe`'s "keep what
was captured" principle. A distinct **Cancelled** terminal, never reported as a
Failure.

**Cancel while `Sending` ("thinking") is also allowed** — the stop button works
from the moment the Message/key exist and public Sending begins (including its
awaited checkpoint). No token has arrived yet, so **no
assistant Message is created** (nothing partial to keep — the `···` indicator
simply disappears); the user Message stays in history as `sent` (the user gave
up on the reply, not on the send). The same distinct **Cancelled** terminal.
The race stays "first token wins": once a token has arrived the conversation is
already Streaming and the keep-partial rule above applies. On the wire, cancel
is simply the client closing the SSE connection; the client-side outcome
(`Cancelled`, partial kept) is guaranteed locally, while the proxy's abort of
the provider call is **best-effort** — it fires when the disconnect is
observed (platforms differ in delivering it; a failed write to the dead
connection is the fallback signal), and an orphaned generation is bounded by
the server's timeout / token cap (SERVER-CONTRACT.md §3).

Distinct from an **unexpected mid-stream break** (network drop / error after the
first token), which is **not** Cancelled but `Failed(upstream)` (see Failure and
Retry Boundary). The two share one behaviour — **the partial reply is always
kept** — but differ in cause: Cancelled = the user chose to stop; `upstream` = the
stream broke on its own.

**Race with completion.** If the full reply has already arrived at the moment
cancel fires, **Done wins** — there is nothing left to wait for. (Same race rule as
`record_transcribe`'s Cancel Transcription.)

### Retry Boundary (the first token)
The line that decides whether a failed reply may be retried **silently** or only by
**explicit** user action — drawn at the **first token**: that is where the
user-visible reply begins, and a restart past it produces a *second, possibly
different* answer, which must never be substituted silently. Money-safety on
the silent side comes from the **Idempotency Key, not from "nothing spent
yet"** — input tokens are billed before the first output token; the key is
what makes a silent retry the *same* logical call instead of a second bill.

- **Before the first token** (connect/send failed) → silent automatic retry, safe
  like `record_transcribe`'s Network Retry. `rate` (429) and `overloaded` (529)
  also back off silently, honoring `Retry-After`. **All silent retrying lives
  under one wall-clock deadline** (the gRPC-deadline / AWS `apiCallTimeout`
  pattern): default **30 s** from the send command, app-configurable;
  `Retry-After` is honored only if it fits the remaining budget. On expiry the
  attempt lands on `Failed` with the last actual cause (`rate` / `overloaded` /
  `network`) — an endless `Sending` is impossible by construction. **The
  deadline bounds *getting a request accepted*** (connects, backoffs, waits
  between attempts) — it does **not** cut down an accepted, live request whose
  model is still thinking: reasoning models may legitimately stay silent well
  past 30 s before their first token, and an open, accepted stream is the
  liveness signal. **Mechanically the deadline is a clock, not a timer**: the
  Core records `startedAt` at the send command and consults the elapsed time
  only at **retry decision points** (before starting an attempt, before a
  backoff wait) — no timer ever fires into a live stream. **Accepted** — the
  transport received a valid SSE response after the proxy atomically selected
  exactly one safe idempotency path for this backend request: create-and-run an
  unknown key, join a live `running` key, or replay a `complete` key
  (SERVER-CONTRACT.md §6). It occurs **at most once per backend request** — a
  same-key Attempt may see several across its silent retries — before any other
  event of that request, and opens the untimed live window. It asserts safe
  server handling, **not** proof the provider billed anything. A pre-stream failure may
  legitimately end an attempt **without** `Accepted` ever arriving. If the
  provider then rejects before the first token, the flow returns to a
  decision point: within the deadline the retry re-runs **under the same
  key** (the proxy releases the key only for its exact retryable allowlist —
  SERVER-CONTRACT.md §6); past it, the attempt lands on `Failed`. Attempt
  counts and backoff formulas are code defaults, not part of this contract.
- **After the first token** (stream broke, or an `error` event arrived after HTTP
  200) → **no** silent retry: the partial reply is kept and the state is
  `Failed(upstream)`; retrying is the user's explicit choice. A stream is only
  "complete" if the normalised **`done`** event arrived; its absence means
  interrupted. (Core watches the normalised `done`, never a provider's raw
  `[DONE]` / `message_stop` — the proxy translates those into `done`; see
  SERVER-CONTRACT.md §2.) **The explicit retry recovers before it re-bills**:
  the Core first repeats under the **same leg key** (persisted as the
  Message's `attemptKey`) — if the reply had in fact completed and only the
  final `done` was lost on the way down, the server replays the stored full
  reply **free of charge** (§6). If the server instead answers `410` (the
  attempt is recorded as aborted — not re-run while its tombstone is retained) the
  explicit command falls back **once, automatically,** to a fresh key — a
  real, billable Regenerate; an unknown key (terminal TTL expired) simply runs.
  Within the replay window a lost last packet costs a replay, never a second
  generation; after expiry the explicit command may start a new one.
- **Regenerate** is always explicit, but has three entry paths: an
  `interrupted` reply first performs the recovery repeat above under the
  assistant Message's persisted key; a final `sent` user Message with no
  following assistant Message recovers under that user Message's persisted key;
  a `complete` reply (or an intentional model switch) starts a new billable
  Attempt under a fresh key immediately. A `failed` user Message is handled by
  Resend. (Same spine as `record_transcribe`'s Transcription Retry: the one
  place money is spent is always a deliberate act.)

**Resumable streaming** — resuming a broken stream from the exact token where it
dropped, so the user returns to the **full** reply (what ChatGPT does after
backgrounding) — is the single genuinely heavy feature here and is **v2, not v1**.
(The optional durable attach below is NOT this: it re-delivers a running reply
from the start of its current provider leg — or, in the server-managed mode,
from the start of the reply's visible text — never from the last event the
client saw. Exact `streamId`/`eventId` cursor resume stays v2 and unimplemented
on both sides.)
v1's "break → keep partial → user taps regenerate" is fully workable. (Deferred like
`record_transcribe` deferred Chunking; the shape is laid so v2 drops in without
rework — a stream id + per-event id reserved in the SSE contract.)

It needs a **stateful server that keeps generating after the client disconnects** —
generation **decoupled** from the connection, tokens in an intermediate store
(Redis/Firestore) keyed by stream id, read back on reconnect. That server is the
**app's**, never the package proxy (which keeps no durable conversation history;
its short terminal replay object is not resumable state, ADR 0002/0006). On Firebase
this means **Cloud Run / a detached task + Firestore**, not a bare Cloud Function
(whose lifecycle is tied to the request it serves — it cannot keep generating
for a client that is gone). See SERVER-CONTRACT.md §8.

### Lifecycle & Disposal
How the Core manages its resources. It exposes `dispose()` (called once, frees all
streams / the SSE connection / subscriptions — cancelling subscriptions in `dispose`
is non-negotiable in Flutter) and `cancel` (already defined). The Core is **pure
logic and does not observe the app's OS lifecycle** — it never reacts to
backgrounding on its own.

**Backgrounding / leaving the chat screen.** The Core does **nothing automatically**.
The professional default — *cancel a long stream when backgrounded* (iOS suspends
the process shortly after backgrounding, and a client-held stream dies with it;
keeping the reply alive *regardless* of the client is exactly the v2
resumable-streaming feature — decoupled generation) — is achieved by the **app
or the chat widget** watching `AppLifecycleState` and calling `cancel` (which keeps
the partial reply). Whether to cancel, keep receiving, or do real background
generation is the **app's choice**, not the Core's. (Mechanism, not policy.) **True
background generation** (iOS VoIP/CallKit-class, Android foreground service) is
**out of scope, v2+** — same boundary as `record_transcribe`'s Background Recording.

### Fake AI Backend (testing, v1)
A ready-made fake implementation of the AI Backend, shipped in a **testing-only**
part of the package (`package:chat_ai/testing.dart`, kept out of production builds).
It behaves like a bot but **calls no provider and spends no money** — no server, no
network. Cheap to build because the AI Backend is already an abstraction (ADR 0001),
and needed to test the Core's state machine without paid calls. **Part of v1.**

It can emulate everything the design rests on, so each decision is testable:
- **stream a reply token-by-token** with a configurable delay (tests Token Stream +
  throttling);
- **fail with any chosen cause from the catalogue** — tests Failure;
- **break after the first token** — tests the Retry Boundary and the "keep partial"
  rule;
- **request a tool-call** and accept the tool-result back — tests the Tool Use
  Cycle, including the tool-loop limit and `is_error` results;
- return an **empty reply** — tests the valid-empty-`Done` edge case;
- emulate **cancel** and the "Done wins" race.

Same spine as `record_transcribe`'s Fake Backend.

### Idempotency Key
A key the client sends with each billable request so a **silent retry never
double-pays**. It is a random UUID minted for each **new Attempt**: send,
edit-rerun, regenerate of a `complete` reply, and every new tool leg mint a
fresh key. Everything that re-sends an *existing* Attempt — the silent
pre-first-token retries of the Retry Boundary, an explicit Resend of a `failed`
user Message, and the **recovery repeat of an interrupted leg** — carries the
persisted key, so the server can return that Attempt's outcome before any new
generation is considered. Thus an explicit `regenerate()` of an `interrupted`
reply starts with recovery under the old key; only its `409`/`410` fallback
mints a fresh key. If the terminal TTL already expired, that old key is unknown
and the explicit recovery request safely runs under it.

Identical duplicate messages ("yes" twice) are two new Attempts. **On a
multi-leg reply each leg mints its own key** — a tool-result follow-up is a new
billable call, not a retry of the first leg (re-using the first leg's key would
collide as a same-key, different-params conflict, SERVER-CONTRACT.md §6);
  silent retries re-use the key of *their* leg. The key is deliberately **not**
  derived from request content — a content hash silently deduped Regenerate and required canonical
hashing (see ADR 0004). A repeat under a key means exactly one thing — **"give
me the outcome of this Attempt"**: the server joins a running call, replays a
completed one, and refuses an aborted one **while the terminal record is
retained**. Terminal records expire after the short replay TTL; expiry
deliberately makes the key unknown again, which is safe because a request then
comes only from an explicit recovery outside the silent-retry window
(SERVER-CONTRACT.md §6). No long-lived response cache (chat replies are
non-deterministic — the goal is "don't pay twice", not "return the same text").

**The key survives restarts because it is persisted on the Message before the
billable dispatch** (`attemptKey`): a user Message carries the key of its original send (so a
Resend after an app restart is still the *same* logical call), and an
assistant Message carries the key of its current/last leg (updated through the
Tool Use Cycle, so a recovery repeat targets the right leg). The Core awaits the
Consuming App's persistence checkpoint before each billable dispatch **it owns**:
`send` with a plain backend, `startReply` on the durable paths, and — with a
server-managed durable backend — only the single `startReply` that carries the
first leg's key, because the server-owned legs after it are checkpointed by the
app on its own server (its awaited `runChatReply.onLegStart`), not here. A silent
retry of an already-checkpointed Attempt does not checkpoint again. If an app
persists chats across launches, providing that checkpoint is part of the storage
contract. Within a live
Attempt the Core freezes the assembled request and silent retries re-send it
**byte-identical** — the same-key-different-params conflict (`409`) is a bug
by construction. This guards the one place the Package spends money, the same
spine as `record_transcribe`'s idempotency. See ADR 0004, SERVER-CONTRACT.md
§6 and the Retry Boundary.

### AI Backend
**Provider scope v1: OpenAI Responses only.** Anthropic is explicitly deferred
to the product backlog. Existing provider-neutral shapes and reserved
`anthropic` discriminator values are compatibility seams, not a claim of v1
support.

The **transport**: where chat requests are sent and the model's response streams
back. The Package treats it as an abstraction — it knows an endpoint and an
authentication method, not the raw provider protocol. **The provider API key is
never on the device**: it lives only on the server side. Adding a future provider
means adding a server adapter without touching the Core. Same spine as
`record_transcribe`'s Transcription Backend.

**Provider normalisation is the server's job.** The v1 proxy translates OpenAI
into **one normalised SSE event stream** (`delta` / `provider_state` /
`tool_call` / `done` / `error`) that the Core consumes. `provider_state` is an
opaque continuity item: the Core persists and returns it but never interprets or
renders it. Thus provider-specific reasoning/thinking state survives a stateless
tool loop without leaking provider semantics into product UI. Adding or switching
a provider remains server-side translation work. See SERVER-CONTRACT.md and
ADR 0001/0003.

The canonical implementation is a **server proxy (BFF)** that holds the key and
**streams the response back over SSE**. The proxy is also the single place that
enforces Entitlement, rate limits, and provider access policy. (Key-on-server-only is
the industry and provider-recommended pattern; an embedded client key is trivially
extracted from a mobile binary.) See ADR 0001.

### Usage
The token counts a reply actually cost, handed to the app **as a fact** — input
tokens, output tokens. The **server is the authoritative source** (it saw the real
provider response), and it **normalises** OpenAI usage into one count. A future
provider adapter must produce the same Usage fact.
**On a multi-leg reply usage arrives per leg** (each leg's terminal
event carries its own count — SERVER-CONTRACT.md §2) and the Core **sums the
legs** into the one Usage fact delivered with the reply's `Done`. An optional
opaque **`usageRaw`** may ride along for logs/analytics (cf.
`record_transcribe`'s `billedMs` / `usageRaw`) — kept when the reply was a
single leg, `null` on a multi-leg reply (no client-side array of raw blobs;
the per-leg raw data stays in the server usage-log, §9).

**Mechanism, not policy.** The Package reports *what was spent*; it does **not**
price it in currency, track quotas, or accumulate a running total. *How much that
costs, how much the user has left, when to show a paywall* is the app's math
(consistent with Entitlement living server/app-side, ADR 0001). The Core does not
keep usage state beyond emitting each reply's fact.

**The authoritative books are server-side.** The client-delivered Usage is a
*display fact* for the app's UX; the **proxy logs every billable call's usage**
(user, model, tokens) to the deploying app's own store — including aborted
calls, where the client receives nothing. Quota checks, per-user spend and
cost analytics run off that server log, never off the client (which can
disconnect — or lie). See SERVER-CONTRACT.md §9. On a mid-stream Failure the
`error` event carries best-effort usage; after a Cancel the client may get no
usage at all — by design.

### Failure
A pipeline error surfaced **as data**: a terminal `Failed` Conversation State
carrying a **machine cause code** and the **phase** it occurred in (`Sending` or
`Streaming`) — never a stream error, never user-facing text. Cancellation is
distinct (a separate `Cancelled` terminal, never a Failure). The set of causes is
**closed** (the app renders UI from it), following `record_transcribe`'s catalogue
discipline.

**Cause catalogue (v1).** Adapted from `record_transcribe` for an OpenAI-backed
LLM chat while retaining provider-neutral client codes. Split **by the fix, not by HTTP class**: causes
the user/app must act on (sign in, pay, rephrase, shorten) vs. transient
provider/transport causes the Core retries silently under the Retry Boundary
deadline (`rate`, `overloaded`, `network`):

- `auth` (→ `id-token` / `app-check`) — authentication problem (sign in again).
- `entitlement` — the requested model/tier isn't allowed; server re-check of
  free/premium. (Central here, unlike the sibling where it was priced-tier-only.)
- `quota` — balance/allowance exhausted; a paywall, retry won't help.
- `rate` — too many requests (429); **silently** back off, honoring
  `Retry-After`, only while the same Attempt remains safe to join/replay or its
  key was released by the exact retryable provider allowlist. An ambiguous provider response aborts
  instead of risking a second charge.
- `overloaded` — a reserved provider-neutral overload cause. The v1 OpenAI
  adapter does not emit it; a future provider adapter must define an exact,
  fixture-backed safe-release mapping before using it.
- `content-filter` — provider moderation blocked the request/output (rephrase).
- `context-too-long` — conversation/attachment exceeded the model's context window
  (start a new chat / shorten). Distinct fix from `content-filter`.
- `network` — transport failure / no response, after retries are exhausted.
- `upstream` — a technical pipeline failure (provider, proxy, persistence
  checkpoint or image preprocessing) that is not safely classified as another
  cause. Technical sub-details such as `checkpoint-failed` and
  `malformed-image` are logs-only.
- `tool-loop-limit` — the Tool Use Cycle exceeded the app's leg cap (see Tool
  Use Cycle, Loop guard). **Client-side only**: emitted by the Core itself,
  never by the proxy.

**Code, not text.** A Failure is a machine label; turning it into words the user
reads — any language, any tone — is **always the app's job**. The Package ships no
user-facing strings; localization stays out of the package entirely.

**Developer detail (logs only).** A Failure may carry an **optional raw technical
string** (the underlying provider/transport message, an HTTP status detail) for
logs / bug reports — English, unstructured, **never shown to the user**. Optional;
absent when there's nothing useful to add.

### Bot Profile
The **bot a chat runs against**, defined by exactly **three fields** — the
minimal agent triad (see ADR 0005):

- **`id`** — the *request* for a tier ("free", "premium"): an intent the
  **server resolves to the actual model** via its tier→model map (ADR 0001),
  re-verifying the user is allowed it;
- **`systemPrompt`** — the bot's persona/instructions (app-side, rides in the
  assembled context, ADR 0002);
- **`tools`** — the Tool declarations this bot gets (see Tool).

**No generation parameters (temperature etc.)** — a model's knobs live next to
the model in the server's tier→model config, never in the profile (rationale
and the industry comparison: ADR 0005). Distinct from the AI Backend
(transport) — the profile answers "with what bot", not "to where". The Core
only carries it; it knows nothing about subscriptions or pricing. (Mechanism,
not policy.)

**Switching bots mid-conversation is free by construction**: the Package is
stateless, every send carries the profile anew — "switch" is just the next
send with a different profile; the history is untouched, nothing is
renegotiated. A new app may define several Bots (different tier/persona/tools)
for its several chats. **Granularity: the profile is snapshotted per logical
reply** — the snapshot taken at the send is used for *every* leg of that
reply (a change during `AwaitingTool` must not switch the model mid-answer);
a profile change applies from the next command.

### Message
One turn in a conversation: a **role** (`user` / `assistant` / `system`) plus a
list of **Content Parts**. It is **not** a single text field — a Message is a
list of parts so it can carry text, images, and tool-call / tool-result parts
together. This is the provider-agnostic multimodal + tool-use shape used by the
OpenAI v1 adapter and suitable for future adapters, laid from day one so adding part kinds later (file) is
non-breaking — the same "lay the optional shape early" discipline `record_transcribe`
used for its Transcript segments/words.

**One reply = one assistant Message, tool parts inside.** A multi-leg reply
(Tool Use Cycle) stays a single assistant Message; the tool-call **and** the
tool-result the app fed back live as ordered parts inside it, so the leg order
is preserved by the parts list itself and history can never separate a call
from its result. There is **no `tool` role** in v1 — the mechanism doesn't use
one (the proxy splits the parts into provider shapes on the wire). Ignoring hidden
provider-opaque continuity parts, the visible parts of an assistant Message follow
the grammar

```
text* (toolCall toolResult text*)* toolCall?
```

— the trailing unmatched `toolCall` is legal only while the reply is
`streaming` (the call is being executed, `AwaitingTool`) or when it ended
`interrupted` (cancel/crash before the result); a `complete` Message never
contains an unmatched `toolCall`. A tool-result's `toolCallId` always matches
the nearest unclosed call.

### Message Status
The state of **one Message** as part of history — a small, **serializable** value
carried on the Message (so it rides into the app's DB, like `record_transcribe`'s
`RecordingStatus`). Distinct from Conversation State: that is the *ephemeral*
"what's happening in the conversation right now" (one per conversation); Message
Status is the *persistent* "what state is **this** message in". Two different axes,
no overlap.

By role:
- **user message:** `sending` → `sent` when the backend accepts the Attempt/reply
  begins, or when the user explicitly cancels public `Sending` and thereby keeps
  the committed turn; `failed` when preprocessing/checkpoint/pre-token sending
  fails → the app may **resend** it.
- **assistant message:** `streaming` (being typed now — this covers the whole
  multi-leg reply, including `AwaitingTool` pauses: the message is still being
  produced) → `complete` (a `done` arrived; an empty reply lands here too, as a
  normal `complete` with empty content), or `interrupted` (cancelled or a
  mid-stream break — partial text kept) → the app may **regenerate** (see
  Cancel, Retry Boundary, Regenerate / Edit).

**Resend vs. Regenerate are different.** *Resend* re-sends a **user** message that
never reached the bot (a `failed` send — no bot call happened yet, so it's safe and
not a re-bill of a generation). *Regenerate* re-runs a **reply** (a billable bot
call, always explicit). Resend follows the Retry Boundary's "before the first
token" side; it carries the same Idempotency-Key so a resent message that *did*
quietly arrive isn't processed twice.

**Resend applies only to the LAST Message of the conversation.** An older
`failed` user message with later history after it is a full no-op: nothing is
truncated, no state changes, no key/checkpoint/backend work happens. Resend
never rewrites history — restarting the conversation from an earlier point is
the explicit truncate-and-resend mechanism (editAndResend), a deliberate
command, never a side effect of retrying an old send.

**No in-flight status survives a restart.** When the app hands a stored
conversation back to the Core (the load half of the round trip, see Conversation
Scope), the Core **normalises stale in-flight statuses itself** — they cannot be
true after a restart: a user message stuck in `sending` becomes `failed` (resend
offered; the Idempotency Key already guards the quietly-delivered case), a
`streaming` assistant message becomes `interrupted` (partial kept, regenerate
offered). The conversation always opens in `Idle`. This is the messengers'
standard — never an eternal "sending…" after a kill; the difference from a
messenger is only that repair is a button, not automatic (a retry here costs
money — "the one place money is spent is a deliberate act").

**Legacy restart normalization vs. optional durable attach.** The rule above is
the *legacy* one and stays the default: with an ordinary connection-bound
backend a reply cannot outlive the process, so a `streaming` assistant message
is necessarily stale. It applies verbatim to the synchronous constructor —
always, whatever the backend is.

A backend MAY instead run a reply as a **long-running operation** that survives
the client (the optional durable capability). Only then, and only through the
async `ChatSession.open`, does the Core first ask that backend — once,
atomically — whether the persisted trailing `streaming` reply is still running:

- the backend hands back a stream ⇒ the reply is genuinely still being
  produced, so it is NOT stale: it stays `streaming`, the user message right
  before it becomes `sent` (its send provably reached the provider), and the
  session attaches to the running generation without a new bot call;
- the backend proves there is no active reply ⇒ exactly the legacy
  normalization above;
- the backend cannot tell ⇒ nothing is normalized and the open fails, because
  silently guessing "stale" would hide a reply the user is still paying for.

Ceasing to observe such a reply is a **detach**, never a remote cancel: after
`dispose()` the remote generation may keep running, because nothing told it to
stop. A terminal event is different in kind — `done`/`error` is the reply
*ending*, so there is nothing left running to detach from; it too never cancels
remotely. Stopping a still-running reply is a separate explicit command — the
user's Cancel — which fires exactly one remote cancel **per logical reply** (the
next reply of the same session is cancellable in turn).

**Two durable modes, one of which moves the Tool Use Cycle to the server.** The
capability a backend declares decides the owner: with `DurableChatBackend` the
tool loop stays the Core's, and each leg is started by the Core; with
`ServerManagedDurableChatBackend` the server owns the WHOLE logical reply —
its tools and all its provider legs — so the Core starts it once, observes
`accepted`/`delta`/`done`/`error` and never resolves a tool call itself.

**None of this means the kit ships a running backend.** Both durable
capabilities are *contracts*: the long-running generation, its store, its host,
its admission/quota/idempotency and its retry policy are the app's. The package
ships no production durable backend implementation — see README.md §11.

### Content Part
One piece of a Message's content. Product-visible kinds: **text**, **image**,
**tool-call** (the bot asking to run a Tool) and **tool-result** (the outcome the
app fed back), plus (laid for later, not v1) **file**. v1 also has one hidden
technical kind, **provider-opaque**, used only to preserve provider continuity
state across stateless tool legs. The Core stores it byte-for-byte, never
interprets it, and the widgets never render it or pass it to a builder. It is sent
back only to the provider that produced it. A single Message may hold several
parts. (Audio is **not** a part kind — voice never reaches the Package; see Voice
Input.)

### Tool
A capability the **app** exposes to the bot — search a local DB for a period, create
a mood card, write a product row, fill a table, etc. Declared as a name +
description + a **portable v1 JSON Schema dialect** shared by the Dart Core,
server and OpenAI translator (exact subset: SERVER-CONTRACT.md §7),
registered by the app on the Bot Profile. The Package carries the
**mechanism** (declare → send to bot → recognise a call → hand it to the app →
take the result back → continue); it **never implements or executes a Tool** — the
implementation is the app's code, touching the app's DB. (Mechanism, not policy.)

**No tools exist yet** — they'll be added by apps in the future. v1 ships the
*socket* (the working mechanism), not any plug. The shape is laid so the first real
Tool drops in without changing the Package — the "lay the form now, fill later"
discipline (cf. `record_transcribe`'s empty timestamp fields). See ADR 0003.

### Tool Use Cycle
The multi-step loop the Core runs when the bot wants a Tool:

```
bot streams → tool-call(name, args) → Core state: AwaitingTool
  → app executes the Tool (its code, its DB) → returns a result
  → Core sends the tool-result back to the bot → bot continues
  → (more text, or another tool-call) → … → Done
```

The bot only *asks*; the **app always executes**. (Which side of the app runs
the loop depends on the declared backend interface: the Core drives it for an
ordinary `ChatBackend` and for `DurableChatBackend`, while a
`ServerManagedDurableChatBackend` moves the whole loop to the app's server — the
Core then never calls `onToolCall`. The rules below describe the Core-driven
loop.) Tool-call **arguments are
assembled and validated against the declared Tool schema on the server** (the
proxy buffers streamed JSON fragments, which do not respect JSON boundaries, and
emits one complete call). The Core independently refuses an unknown tool or
schema-invalid arguments: it never calls the app resolver and appends a safe,
sanitised `is_error` result instead. An interrupted tool-call yields no partial
call — it follows the Retry Boundary (`upstream`, nothing applied). See ADR 0003
and SERVER-CONTRACT.md §7.

**The result lands in the same assistant Message** — as a `toolResult` part
appended after its `toolCall` part (see Message: one reply = one Message, the
parts grammar) — and goes back to the bot on the next leg. The Core **never
invokes the app's resolver twice for a call whose matching result is already
in the parts** (e.g. when a later leg is retried, earlier legs are history,
not work).

**Side effects are the app's, and cancel doesn't undo them.** A cancel during
`AwaitingTool` ignores the late result, but whatever the Tool already did (a
DB write) has happened — the Package cannot roll back app code. Execution
semantics are honestly **at-least-once**: after a crash/restart or a recovery
repeat the app may see the same call again, with the **same `toolCallId`** —
an app whose Tool has side effects MUST deduplicate by `toolCallId` (its
idempotency key for tools). Exactly-once is not promised and not buildable
from the Package's side.

**Exits from `AwaitingTool` (never a dead end).** Three rules:
- **Cancel works here too**: the user's stop → `Cancelled`, any first-leg
  partial text kept (the usual keep-partial rule); a tool-result the app
  returns *after* the terminal is silently ignored.
- **A tool execution error is NOT a Failure**: the app returns a tool-result
  **flagged as an error** (`is_error`), it goes back to the bot, and the bot
  decides how to react — the standard OpenAI tool mechanism. `Failed`
  stays reserved for provider/transport causes; the cause catalogue gains no
  tool code.
- **The Core keeps no tool timeout**: a Tool is app code — not hanging is the
  app's responsibility (OpenAI does not impose a per-tool timeout either),
  and the user always has the cancel exit above.

**Loop guard (mechanism, not policy).** The Core caps the number of billable
tool legs per reply — the app sets the cap, the default is **5** (the same
`max_iterations` guard used by agent SDK runners). Exceeding it
stops the loop on a terminal `Failed(tool-loop-limit)`; accumulated text is
kept as usual (`interrupted`), so the app can offer regenerate. This is the
guard against an endless bot→tool→bot loop spending money unattended.

### Image Attachment
An image the user adds **to a message during a conversation with the bot** — and
nothing more. Its only purpose is to be sent to the bot as an image Content Part
in **this session**. It rides through the proxy **transiently** (like audio in
`record_transcribe`, it passes through the BFF and is **not** stored), translated
to the provider's wire format (base64 inline or URL/file-id — both are standard).

**Send discipline (defaults, app-tunable).** The Core always **resizes before
sending**: long edge to **2048 px**, JPEG — a practical cap for the configured
OpenAI models, so a phone-camera original stops being wasted traffic and money.
`maxImagesPerMessage` defaults to
**4** and is enforced by the Core for every entry path; the Input Bar reads the
same session setting (a widget-local override may only lower it). An image **with
no text at all is a valid Message**. The numbers are code defaults (mechanism);
the app tunes them (policy) within loud exact bounds: the long edge and the
per-message count must be positive and JPEG quality must lie in 1..100
inclusive — anything outside is a configuration error (`ArgumentError` at
session construction), never a silent clamp.

The Package is **chat-only**: it does **not** store images, manage a media library,
upload to Cloud Storage, or encrypt anything. Images the user keeps or uploads
*outside a bot conversation* are **out of scope** — not the Package's concern.
(Same boundary spirit as `record_transcribe`: the kit handles the in-session round
trip; persistence/storage belongs to the app or is simply not a thing here.)

### Voice Input (dictation only)
Speaking instead of typing: the user talks, **text appears in the input field**,
and from then on it is an ordinary text Message. Voice is purely a **dictation
aid** to avoid typing by hand — **not** a content kind and **not** part of the
Core. By the time the Package sees anything, it is just text; how that text reached
the input (typed by hand, or dictated by some external mechanism) is invisible to
the Package. At most, the input-bar widget may show a mic button that calls a
**dictation callback the app supplies** — but the Core knows nothing about voice,
audio, or transcription, and the Package has **no dependency on `record_transcribe`
or any audio package**. (The two packages are entirely unrelated.)

### Entitlement (free / premium)
A **business** rule about which model/tier a given user is allowed — free vs.
premium. This is **not** decided by the user and **not** owned by the Core. The
**developer sets the tier→model map in a server config** (not baked into the app
build), so models and pricing rules change **without an app release**. The
**server** is the single source of truth: the client's Bot Profile is only a
request, which the server may downgrade or reject (e.g. a "not entitled" error)
before spending the key. The Core never sees the map. (Mechanism, not policy.)
See ADR 0001.
