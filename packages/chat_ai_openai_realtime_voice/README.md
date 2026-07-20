# chat_ai_openai_realtime_voice

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

Exactly seven declarations are exported: `OpenAIRealtimeVoiceSession`,
`OpenAIRealtimeVoiceMode`, `OpenAIRealtimeVoicePhase`,
`OpenAIRealtimeVoiceState`, `OpenAIRealtimeVoiceFailure`, and the two
optional-transcript declarations `OpenAIRealtimeVoiceTranscriptRole` and
`OpenAIRealtimeVoiceTranscript`.

```dart
final session = OpenAIRealtimeVoiceSession(
  clientSecretProvider: myProvider, // mints one ephemeral secret
  botProfile: myBotProfile,         // systemPrompt only; tools must be empty
  mode: OpenAIRealtimeVoiceMode.singleTurn, // or conversation
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

The **same** `transcriptsEnabled` opt-in also drives a `Stream<String>` of the
assistant's transcript **deltas** for the current response — there is no separate
option:

```dart
session.assistantTranscriptDeltas.listen((delta) {
  // Append `delta` yourself to build the live text. Nothing else is emitted.
});
```

- Each event is the raw `delta` of a `response.output_audio_transcript.delta`,
  **verbatim and in order** — never trimmed, normalized, merged, deduplicated or
  accumulated (two identical adjacent fragments are **both** emitted). The
  application assembles any displayed text itself.
- **Current response only**, strictly attributed to the active `response_id`;
  deltas before `response.created`, foreign, malformed, or after an
  interrupt/barge-in/terminal/`dispose()` are dropped.
- It carries **no** id, index, usage, and never the final `.done` (that stays on
  `transcripts`). Broadcast, in-memory only, no history; closed by `dispose()`.

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
uploads, tools/function calling and UI are **not** implemented. Assistant
transcript **deltas** (a raw `Stream<String>`, no accumulation) and a
**programmatic interrupt** ARE implemented (see above). Local audio recording IS
implemented for iOS (see above); its iOS-native writer is the only native code
in this package, and it is exercised only when `recordingEnabled` is `true`.
