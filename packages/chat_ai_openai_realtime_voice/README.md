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

Exactly five declarations are exported: `OpenAIRealtimeVoiceSession`,
`OpenAIRealtimeVoiceMode`, `OpenAIRealtimeVoicePhase`,
`OpenAIRealtimeVoiceState`, `OpenAIRealtimeVoiceFailure`.

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

### Privacy

`OpenAIRealtimeVoiceState` carries only a coarse `phase` and an optional coarse
`failure`. The ephemeral secret, SDP, Authorization header, system prompt,
audio, raw Realtime events, response bodies, track ids and provider messages
never reach state, logs or exceptions.

## Not in this increment

Tools, transcripts, audio recording, playback, persistence, waveform and UI are
**not** implemented. Physical iOS/Android smoke of this package has **not** been
run yet. There is no native code in this package.
