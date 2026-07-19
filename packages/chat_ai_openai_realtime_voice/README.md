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

- **Final transcripts only** — no deltas, no partials. The stream carries only
  successfully-received final text; a *missing* user event can simply mean the
  input ASR never produced a transcript.
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

### Privacy

`OpenAIRealtimeVoiceState` carries only a coarse `phase` and an optional coarse
`failure`. The ephemeral secret, SDP, Authorization header, system prompt,
audio, raw Realtime events, response bodies, provider errors, ids, usage and
track ids never reach state, logs or exceptions.

The **only** content the package ever surfaces is the optional `transcripts`
stream, and only when the app opted in: it carries the final transcript text
alone — never ids, usage, deltas or a failure. Input audio and transcripts are
handled directly inside the device → OpenAI Realtime session; the app's backend
still receives only the mint request, never audio or a transcript. The package
never logs or stores a transcript, not even in debug/test.

## Physical smoke status

Physical **iOS** transcript smoke of this package has been **run successfully**:
both `singleTurn` and `conversation` were exercised on a physical iPhone against
the production `OpenAIRealtimeVoiceSession`, and the final **user** and
**assistant** transcripts were confirmed. Physical **Android** transcript smoke
has **not** been run yet — Android is not claimed as ready.

## Not in this increment

Audio recording, playback, waveform, transcript deltas/partials/history,
persistence, tools/function calling and UI are **not** implemented. There is
no native code in this package.
