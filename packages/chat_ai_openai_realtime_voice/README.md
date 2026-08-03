# chat_ai_openai_realtime_voice

> **Detailed voice API reference.** The minimal wiring (installation, creating
> a session, what the app owns) lives in the repository
> [README.md](../../README.md) — the single integration guide. This file
> documents the full voice surface: modes, transcripts, recording, tools,
> guardrail and limitations.

An **optional** speech-to-speech voice session for `chat_ai`. It is a separate
package in the same repository — not a separate Git repository, and not
published.

It is **not** a `ChatBackend` and it does **not** use `ChatSession`. It owns one
stateful session over a **direct device → OpenAI Realtime WebRTC** call:

- an ephemeral secret from the app's existing `ClientSecretProvider`;
- one microphone track and one remote assistant audio track;
- one `oai-events` data channel;
- the official `POST /v1/realtime/calls` signaling (one POST, no redirects);
- server-side **semantic VAD** (the server creates the responses — the client
  never sends `response.create`);
- automatic user **barge-in** (`interrupt_response: true` — the server cancels
  and truncates; the client sends no redundant `response.cancel`/`truncate`).

**One instance == one WebRTC session.** `start()` runs exactly once (a repeat is
a programming error); there is exactly one mint and one signaling POST; there is
**no retry, no reconnect, no session renewal**. The maximum server-side Realtime
session length is documented as 60 minutes, but no renewal is implemented here.
`stop()`/`dispose()` are idempotent, and a late-materialized resource is closed
exactly once.

## Public API

```dart
import 'package:chat_ai_openai_realtime_voice/chat_ai_openai_realtime_voice.dart';
```

Exactly **fourteen** declarations are exported: `OpenAIRealtimeVoiceSession`,
`OpenAIRealtimeVoiceMode`, `OpenAIRealtimeVoicePhase`,
`OpenAIRealtimeVoiceState`, `OpenAIRealtimeVoiceFailure`, the transcript
declarations `OpenAIRealtimeVoiceTranscriptRole`, `OpenAIRealtimeVoiceTranscript`
and `OpenAIRealtimeVoiceTranscriptDelta`, the recording declarations
`OpenAIRealtimeVoiceRecordingRole`, `OpenAIRealtimeVoiceRecording` and
`OpenAIRealtimeVoiceRecordingFailure`, and the output-guardrail declarations
`OpenAIRealtimeVoiceGuardrailDecision`, `OpenAIRealtimeVoiceOutputGuardrail` and
`OpenAIRealtimeVoiceGuardrailEvent`.

The **initial history** and **tools** features add no new declaration — they
reuse the core `chat_ai` types (`Conversation`, `Tool`, `ToolCall`, `ToolResult`,
`OnToolCall`).

Every reply carries a **local `turnId`** (a UUID v4 minted by this package, never
an OpenAI id) that links the reply's transcript, delta, recording and any
recording failure. `maxToolTurns` (default 5) and the guardrail's fixed 250 ms
check interval are limits of **this package**, not of the OpenAI Realtime API.

```dart
final session = OpenAIRealtimeVoiceSession(
  clientSecretProvider: myProvider, // mints one ephemeral secret
  botProfile: myBotProfile,         // systemPrompt (+ optional tools)
  mode: OpenAIRealtimeVoiceMode.singleTurn, // or conversation
  // tools are OPTIONAL; a non-empty `botProfile.tools` requires `onToolCall`
  // (see the Tools section below).
);

session.states.listen((s) => print(s.phase)); // coarse phase only
await session.start();
// ... singleTurn auto-ends after the one response; conversation loops ...
await session.stop();   // idempotent
await session.dispose();
```

### Modes

- **singleTurn** — accept exactly one user reply, wait for the assistant's one
  response, then auto-close to `ended` after both `response.done` and
  `output_audio_buffer.stopped`. A new reply needs a brand-new instance.
- **conversation** — keep one connection for many VAD turns; return to
  `listening` after each response; end only via `stop`/`dispose`, a terminal
  failure or transport death.

### Optional final transcripts

Off by default. When enabled, the session emits the **final** user and assistant
transcripts of the **same** direct device → OpenAI Realtime call — no
`record_transcribe`, no second audio request:

```dart
final session = OpenAIRealtimeVoiceSession(
  clientSecretProvider: provider,
  botProfile: profile,
  transcriptsEnabled: true,
);

session.transcripts.listen((transcript) {
  // Application decides whether to display or persist transcript.text.
});
```

What to expect, honestly:

- **`transcripts` carries final transcripts only** — no deltas, no partials. It
  carries only successfully-received final text; a *missing* user event can
  simply mean the input ASR never produced a transcript. (Assistant transcript
  **deltas** are available separately — see below.)
- **Both sides** — `OpenAIRealtimeVoiceTranscriptRole.user` and `.assistant`.
- **Default off** — nothing is emitted unless you set `transcriptsEnabled: true`.
- **Input transcription is a separate OpenAI ASR model**
  (`inputTranscriptionModel`, default `gpt-4o-mini-transcribe`) and **may be
  billed separately** from the voice session.
- The user transcript is a **rough guide**: it is produced by that separate ASR
  pass and can differ from how the Realtime model actually understood the audio.
- The user transcript is **asynchronous** relative to the assistant response —
  it can arrive after the response events.
- A **transcript failure does not end the voice session** — the optional side
  channel simply yields no user event for that reply; the speech-to-speech
  conversation keeps working.
- The package **stores nothing**: transcripts exist only in memory, on the
  broadcast stream, for as long as you listen. It never logs or persists them.

### Assistant transcript deltas

The **same** `transcriptsEnabled` opt-in also drives a
`Stream<OpenAIRealtimeVoiceTranscriptDelta>` of the assistant's transcript
**deltas** for the current response — there is no separate option:

```dart
session.assistantTranscriptDeltas.listen((event) {
  // event.turnId correlates with this reply's transcript / recording.
  // Append event.delta yourself to build the live text. Nothing else is emitted.
});
```

> **Breaking change (this increment).** The old `Stream<String>` was replaced by
> `Stream<OpenAIRealtimeVoiceTranscriptDelta>` (a `turnId` + the raw `delta`). The
> `String` stream is gone — migrate `listen((s) => ...)` to
> `listen((d) => ... d.delta ...)`.

- Each event's `delta` is the raw `delta` of a
  `response.output_audio_transcript.delta`, **verbatim and in order** — never
  trimmed, normalized, merged, deduplicated or accumulated (two identical
  adjacent fragments are **both** emitted). The application assembles any
  displayed text itself.
- **Current response only**, strictly attributed to the active `response_id`;
  deltas before `response.created`, foreign, malformed, or after an
  interrupt/barge-in/terminal/`dispose()` are dropped.
- It carries the reply's local **`turnId`** and the `delta` only — **no** OpenAI
  id, index or usage, and never the final `.done` (that stays on `transcripts`).
  Broadcast, in-memory only, no history; closed by `dispose()`.

### Local turnIds

Every reply is tagged with a **local `turnId`** — a UUID v4 minted by this
package, **never** an OpenAI item/response/call id. The same `turnId` links one
reply's `assistantTranscriptDeltas`, its final `transcripts` entry and its
`recordings` / `recordingFailures`:

- a user `turnId` is minted on a **strictly-validated** `input_audio_buffer.speech_started`;
- an assistant `turnId` is minted on the first `response.created` of a logical
  reply and **preserved across all tool legs** of that reply;
- a **new** user speech turn and a **new** ordinary assistant reply each get a
  new id; the guardrail replacement gets a **new** id.

`OpenAIRealtimeVoiceTranscript` carries an `interrupted` flag, and the assistant
final transcript is **published only once its outcome is decided** — it is never
published `interrupted: false` and then corrected. It is `interrupted: false` only
after a valid final transcript **and** `response.done(completed)` **and**
`output_audio_buffer.stopped` **and** (when a guardrail is set) an allow verdict
**and** no interruption; if a barge-in, `interruptResponse()`, guardrail block or
teardown intervenes first, the held final is published `interrupted: true`. A late
final transcript of an already-interrupted reply is delivered once with
`interrupted: true`.

Every `OpenAIRealtimeVoiceRecordingFailure` carries the `turnId` of the reply it
belongs to — a failure is **never anonymous**. A recording side whose native tap
fails to attach *before* any reply remembers the breakage internally and surfaces
its one failure only once a concrete reply begins, tied to that reply's `turnId`.

**Strict VAD-pair contract.** One package-private VAD state (identical with
recording ON or OFF) governs a user turn. A valid `speech_started` requires a
non-empty `item_id`, a non-negative `audio_start_ms`, no already-open segment and
a not-yet-used `item_id`; a valid `speech_stopped` requires the same `item_id`, a
non-negative `audio_end_ms` and `audio_end_ms >= audio_start_ms`. Only a valid
start mints the `turnId`, opens the recording segment and performs a barge-in;
only a valid stop closes the turn, registers the transcript item and (in
`singleTurn`) disables the mic. Malformed, duplicate, overlapping, reused and
foreign VAD events are **fully inert** — they change no turnId / epoch / phase /
mic / recording and never reset the guardrail replacement budget.

### Initial history

An optional `initialConversation` (a core `Conversation`) is seeded into the
Realtime session **before the microphone goes live**:

```dart
final session = OpenAIRealtimeVoiceSession(
  clientSecretProvider: provider,
  botProfile: profile,
  initialConversation: myConversation, // core chat_ai Conversation snapshot
);
```

- **Validation is synchronous** (before any mint/network): only
  `schemaVersion == 1` is accepted; a `user` message with status `sending` or an
  `assistant` message with status `streaming` throws `ArgumentError`. The passed
  object is never mutated, normalized, shortened or stored.
- **Sent:** system text, user text, user JPEG images, assistant text, and
  **completed** `ToolCall` + `ToolResult` pairs (as `function_call` /
  `function_call_output`). `BotProfile.systemPrompt` stays the session
  `instructions`.
- **Filtered out:** `failed` user messages, `ProviderOpaquePart`, an unmatched
  (incomplete) `ToolCall`, an orphan `ToolResult`, an assistant that maps to
  nothing, and all local `Message.id` / statuses / timestamps / attempt keys. An
  `interrupted` assistant is preserved. There are no audio or file references in
  v1.
- **A user message that maps to no supported content is not sent** — both
  `parts: []` and an opaque-only user message. The message stays in your
  `Conversation` untouched; only the `conversation.item.create` for it is
  skipped, and the remaining history keeps its order. A `TextPart('')` (or a
  whitespace-only one) is ordinary content and is still sent as an `input_text`
  — the rule is the actual mapping result, not string interpretation. This is a
  **drop, not an exception**: `prepareInitialHistory` is itself the filtering
  layer over your stored `Conversation`, so a stored message with nothing to
  say never fails the session start.
- **One item at a time:** each item is sent as a `conversation.item.create` and
  the next one waits for a well-formed `conversation.item.added` — the only
  acknowledgement (the trailing `conversation.item.done` confirms nothing). No
  client-side item id is sent or correlated (the server assigns the ids) — with
  the mic off and no `response.create`, exactly one acknowledgement can be
  outstanding, so any well-formed ack confirms the pending item; a malformed
  event (no `item`, a non-Map `item`, a missing/empty/non-String `item.id`)
  confirms nothing. The mic is armed only after the **whole** history is
  acknowledged.
- Every acknowledgement is bounded by `responseIdleTimeout` (default 60 s). A
  server error, a transport death or a **lost acknowledgement during loading** is
  a terminal `session` failure — the mic never enables, the next item is never
  sent, and there is **no** retry / reconnect / re-mint; a late ack is inert.
- `session.update` sets `"truncation": "disabled"`; on a context overflow the
  server deletes nothing automatically — this package never silently drops
  history.

### Tools

Universal tools reuse the core `Tool` / `ToolCall` / `ToolResult` / `OnToolCall`:

```dart
final session = OpenAIRealtimeVoiceSession(
  clientSecretProvider: provider,
  botProfile: BotProfile(id: 'bot', systemPrompt: '...', tools: myTools),
  onToolCall: (call) async => runMyTool(call), // required when tools are non-empty
  maxToolTurns: 5, // this package's per-reply cap (default 5)
);
```

- **Validated synchronously** (before mint): `maxToolTurns > 0`; non-empty tools
  require `onToolCall`; names, duplicates and JSON Schema are checked against the
  **Chat AI Tool Schema v1** dialect. `session.update` carries the tools plus
  `tool_choice: "auto"` and `parallel_tool_calls: false`. With no tools the
  payload is the prior no-tools shape.
- **One tool call at a time.** A completed `response.done` is scanned for ALL
  `function_call` items: **zero** is an ordinary audio completion; **exactly one**
  is a tool leg; **two or more** is a protocol violation (`parallel_tool_calls:
  false` is always sent) that terminates the session immediately
  (`OpenAIRealtimeVoiceFailure.transport`). A **malformed function call**
  (missing/empty `call_id` or `name`) likewise terminates the session and is never
  mistaken for an audio completion. A **repeat `call_id`** is also a protocol
  violation and terminates the session (`transport`) — never re-run or re-sent.
- The `arguments` are validated at RUNTIME against the tool's **Chat AI Tool
  Schema v1** declaration (the same closed dialect used for the declaration
  check). The resolver runs **only** for arguments that parse to a JSON object
  AND conform to the schema. An **unknown tool**, **malformed / non-object
  arguments**, a **schema mismatch**, or a **resolver exception** becomes a
  sanitized `ToolResult(isError: true)` — neither the schema, the raw arguments,
  the exception text nor a stack trace ever reaches the wire, state, events or
  logs.
- A successful result is sent as **one** `function_call_output`, followed by
  **exactly one** `response.create`. There is **no** retry after either possible
  send.
- The per-reply cap (`maxToolTurns`, default 5) bounds a runaway tool loop: the
  sixth resolver call is **not** started, no `function_call_output` /
  `response.create` is sent for it, and the session ends with the coarse
  `OpenAIRealtimeVoiceFailure.toolLoopLimit`.
- A tool-only leg does **not** wait for `output_audio_buffer.stopped`. A pending
  resolver is part of the current reply: `interruptResponse()`, a barge-in, a new
  valid user turn and `dispose()` all invalidate it, and its late result then
  becomes inert (no `function_call_output`, no `response.create`). When the only
  in-flight work is a pending resolver, `interruptResponse()` cancels the tool
  chain WITHOUT a meaningless `response.cancel` (`conversation` returns to
  `listening`; `singleTurn` ends). All tool legs of one reply share one assistant
  `turnId`.

### Output guardrail

An optional, low-latency **post-generation** guardrail (default OFF):

```dart
final session = OpenAIRealtimeVoiceSession(
  clientSecretProvider: provider,
  botProfile: profile,
  outputGuardrail: ({required turnId, required accumulatedText}) async {
    return isUnsafe(accumulatedText)
        ? OpenAIRealtimeVoiceGuardrailDecision.block
        : OpenAIRealtimeVoiceGuardrailDecision.allow;
  },
  safeReplacementInstructions: 'Say only that you cannot help with that.',
);

session.guardrailEvents.listen((event) {
  // event.turnId only — no text, reason, provider ids or raw detail.
});
```

- **Both or neither.** `outputGuardrail` and `safeReplacementInstructions` must
  both be supplied (and the replacement instructions non-empty) — otherwise an
  `ArgumentError` is thrown before any mint.
- For each assistant reply the package runs **periodic** checks on the
  accumulated deltas — **at most once per 250 ms** (fixed) — plus a **mandatory
  final check on the AUTHORITATIVE exact final transcript** from
  `response.output_audio_transcript.done` (not the accumulated deltas). At most
  **one** app callback runs at a time across the whole session (a new turn's check
  waits for a previous callback to physically finish); new text during a callback
  is checked afterwards; the reply's completion **waits** for the final verdict,
  and the public final transcript is **not** published until the guardrail
  **allows** it (on a block/exception the published final carries
  `interrupted: true`). If audio completes before the final transcript, the wait
  is bounded by the EXISTING response idle watchdog; a lost final transcript ends
  the reply as a controlled `responseTimeout`. It works even when
  `transcriptsEnabled` is `false` (using the assistant transcript events
  internally) — it never turns on user input ASR and never publishes a transcript
  stream that is off. A late callback result after a new turn / stop / dispose is
  inert.
- **Fail-closed** on the first `block` or a callback exception: a targeted
  `response.cancel`, an `output_audio_buffer.clear`, the original assistant
  recording finalized as `interrupted`, exactly one coarse `guardrailEvents` event
  (turnId only), and **exactly one** replacement response with a **new** assistant
  `turnId` and the exact no-context / no-tools payload
  (`{input: [], tools: [], instructions: <safeReplacementInstructions>}`). No old
  context, initial history, tools, tool results or the original unsafe text ride
  the replacement. There is **no** retry after the replacement `response.create`.
- The replacement passes the same periodic + exact-final checks. A block (or
  callback exception) **inside** the replacement is terminal — the session ends
  with `OpenAIRealtimeVoiceFailure.guardrail` and **no** second replacement is ever
  created.
- **The one-replacement budget is per USER TURN.** Each new valid user speech turn
  re-opens the right to a single replacement; it is not consumed session-wide, so
  a later turn whose original reply is blocked still gets its own replacement.

> **Honest latency limitation.** This is a low-latency post-generation guardrail,
> not premoderation. Part of the reply's audio may already have played by the time
> a `block` is decided — a few words can be heard before the callback resolves.
> The package does **not** buffer the whole reply and does **not** pre-moderate.

### Programmatic interrupt

`Future<void> interruptResponse()` cancels the **current** assistant response
(it is neither `stop()` nor `dispose()`). In **`conversation`** it does **not**
end the session — it returns to `listening`; in **`singleTurn`** (whose one user
turn is already closed) it ends the session as `ended` (see the mode note
below):

```dart
await session.interruptResponse();
```

- **No active response → a completed no-op** (no client event, no state/transport
  change, no re-mint).
- With an active response it sends **exactly one** `response.cancel` immediately
  followed by **one** `output_audio_buffer.clear` over the existing data channel
  (no ack wait, no retry), finalizes an open assistant recording segment as an
  interrupted partial, and abandons the response (its late
  delta/audio/`response.done(cancelled)` become inert).
- **`conversation`** stays live and returns to `listening` (mic still on, ready
  for the next turn); **`singleTurn`** — whose one user turn is already closed —
  ends as `ended` with exactly one transport close.
- **Idempotent / memoized** per response: concurrent or repeat calls share one
  operation (one cancel, one clear, one finalize).
- A **send failure** surfaces only one coarse `OpenAIRealtimeVoiceFailure.transport`
  with exactly-once teardown — no retry, reconnect, re-mint, second cancel/clear
  or new response, and the raw exception never reaches state or logs.

### Privacy

`OpenAIRealtimeVoiceState` carries only a coarse `phase` and an optional coarse
`failure`. The ephemeral secret, SDP, Authorization header, system prompt,
audio, raw Realtime events, response bodies, provider errors, ids, usage and
track ids never reach state, logs or exceptions.

The only content the package ever surfaces is the optional transcript text —
and only when the app opted in: the final `transcripts` stream (text alone, no
ids/usage/failure) and the assistant `assistantTranscriptDeltas` stream (raw
delta strings alone, no ids/indices/usage). Input audio and transcripts are
handled directly inside the device → OpenAI Realtime session; the app's backend
still receives only the mint request, never audio or a transcript. The package
never logs or stores a transcript or a delta, not even in debug/test.

## Physical smoke status

Physical **iOS** smoke of this package has been **run successfully** on a
physical iPhone against the production `OpenAIRealtimeVoiceSession`, in both
`singleTurn` and `conversation`, covering:

- **final transcripts** — final user and assistant transcripts confirmed;
- **assistant transcript deltas** — the `assistantTranscriptDeltas` fragments
  grew during a reply and the assembled text matched the spoken answer;
- **local recording** — separate user and assistant `.m4a` files were produced
  and played back; `afinfo` confirmed the format on real device files (M4A /
  AAC-LC / 16 kHz / mono / non-zero duration / ~32 kbit/s), file names are unique
  and existing files are never deleted or overwritten;
- **programmatic interrupt** — `interruptResponse()` stopped the assistant audio,
  kept the `conversation` session live (back to `listening`), produced an
  `interrupted: true` assistant partial, and stopped further deltas; a barge-in
  and a manual `stop()` during user / assistant audio produced valid
  `interrupted: true` partials and a clean `ended`;
- normal replies reached `ended` / `listening` with **no** false
  `responseTimeout`.

This reflects a specific manual run, not an exhaustive guarantee. Physical
**Android** smoke has **not** been run — Android is **not** claimed as ready.

> **This increment (initial history, tools, output guardrail, unified
> `turnId`s) has NOT been re-smoked on a physical iPhone yet.** It is covered by
> the automated tests, `flutter analyze`, `flutter test` and an unsigned
> `flutter build ios --no-codesign` only; the physical iPhone smoke is a separate,
> later step.

## Known limitations (out-of-order audio-buffer events)

One low-severity behaviour exists only when the provider's event stream is
**not spec-compliant** — events arrive out of order. On a well-ordered OpenAI
Realtime stream (as exercised by the passing physical iOS smoke) it is not
reachable. It is accepted as a known limitation; no automatic retry, reconnect
or extra paid `response.create` is ever involved.

- **singleTurn transcript wait, stray `output_audio_buffer.started`.** While a
  `singleTurn` session (with `transcriptsEnabled: true`) is waiting for the
  first reply's asynchronous user transcript after its response has completed, an
  out-of-order `output_audio_buffer.started` for that same, already-finished
  response — followed by a further progress event — can re-arm the idle watchdog
  in place of the transcript-wait deadline. The turn then ends as a
  `responseTimeout` **failure** instead of a normal `ended`. It still terminates
  (no hang); only the terminal category is wrong.

## Optional local audio recording (iOS only)

Local recording is **off by default** (`recordingEnabled: false`). It reuses the
SAME existing WebRTC local (user) and remote (assistant) audio tracks — there is
**no second microphone**, no extra mint, no extra signaling, no new network
request, and no retry/reconnect.

Contract:

- **Opt-in.** `recordingEnabled` defaults to `false`. When it is `true`,
  `recordingDirectoryPath` is **required** and must be a non-empty **absolute**
  path (validated synchronously before any mint; the validation error is
  sanitized and never contains the path). When recording is off the path is
  ignored and behaviour is unchanged.
- **Format.** Each file is `.m4a` / **AAC-LC**, **16 kHz**, **mono**, target
  **32 kbit/s** — the same profile as `record_transcribe`'s
  `RecordingProfile.speechDefault()`. The device PCM is really resampled,
  down-mixed and AAC-encoded on the iOS side (ExtAudioFile), never renamed; the
  finished file is validated (format / rate / channels / non-zero frames) before
  it is handed over.
- **One file per reply.** Separate **user** and **assistant** files, one per
  spoken reply — never a single mixed session file. Works in `singleTurn` and
  `conversation`.
- **Streams.** Finished files arrive on `recordings`
  (`OpenAIRealtimeVoiceRecording` — role, `filePath`, optional `transcript`,
  `interrupted`); a per-side failure arrives on `recordingFailures`
  (`OpenAIRealtimeVoiceRecordingFailure` — role only). A recording failure is a
  pure **side channel**: it never ends the voice session, never cancels a
  Response and never triggers retry/reconnect/mint.
- **Transcript may be null.** Recording and transcripts are independent. The
  `transcript` is `null` when transcripts are off, when transcription
  failed/timed out, or when no valid transcript for that exact reply arrived; a
  successfully-received empty transcript is the empty string.
- **`interrupted`.** `true` for the actually-captured partial fragment saved on a
  stop, cancel or barge-in; `false` for a naturally completed reply.
- **Event-driven boundaries (not sample-accurate).** A user reply spans a
  validated `input_audio_buffer.speech_started` → `speech_stopped` pair; the
  assistant reply spans `output_audio_buffer.started` → `stopped` of the active
  response. A bounded pre-roll is prepended so onset is not clipped by event
  latency. The OpenAI `audio_start_ms` / `audio_end_ms` are used **only** for
  validation, item matching and dedup — **not** as sample-accurate PCM offsets:
  the WebRTC audio-renderer tap delivers device PCM with no server timestamp, so
  no OpenAI↔PCM timeline mapping exists over `flutter_webrtc` and **no
  sample-accurate boundary is claimed**.
- **Ownership.** After a file is delivered on `recordings` it belongs to the
  application; the package never deletes, overwrites, plays back, uploads or
  logs it. Every file gets a collision-resistant unique name and a finished file
  is never replaced. Only this package's own unfinished temporary files are
  deleted.
- **`record_transcribe` is not used**; no upload, database, history or retention.
- **iOS only.** Android recording is **not** implemented and not claimed as
  ready; with `recordingEnabled: false` (or on Android) the voice behaviour is
  entirely unchanged.
- **Physical recording smoke has NOT been run yet** — recording is not claimed
  production-ready.

## Not in this increment

Playback, waveform, transcript **history/accumulation**, transcript persistence,
uploads, an **on-device classifier** and UI are **not** implemented, and there is
**no** reconnect / retry / re-mint. There is **no persistence, database or
history inside this package** — the initial history is read once from the
`Conversation` you pass and never stored; transcripts, deltas, recordings and
guardrail events exist only on their broadcast streams for as long as you listen.

**Initial history**, universal **tools/function calling**, an optional output
**guardrail** and unified local **`turnId`s** ARE implemented in this increment
(see above), alongside the previously-shipped assistant transcript **deltas** (now
a typed `Stream<OpenAIRealtimeVoiceTranscriptDelta>`), the **programmatic
interrupt** and the iOS local **recording** (its iOS-native writer is the only
native code in this package, exercised only when `recordingEnabled` is `true`).
The `maxToolTurns = 5` cap and the guardrail's fixed 250 ms check interval are
limits of **this package**, not of the OpenAI Realtime API.
