# chat_ai smoke harness

A minimal **physical-device smoke** for the `chat_ai` package: it drives the
**real** package widgets (`ChatMessageList`, `ChatInputBar`) and Core
(`ChatSession`) against a live backend. It is **not** a production sample
app — no router, no state framework, no persistence, no analytics, no fake
mode.

One and the same UI runs in **two mutually exclusive backend modes**, chosen
at compile time by the `SMOKE_BACKEND` define:

| `SMOKE_BACKEND` | Transport under test | Wire |
|---|---|---|
| `firebase` | `FirebaseChatBackend` (`chat_ai_firebase`) | deployed proxy endpoint (HTTP + SSE) |
| `realtime` | `OpenAIRealtimeChatBackend` (`chat_ai_openai_realtime`) | direct OpenAI Realtime WebSocket with app-minted ephemeral client secrets |

One launch tests exactly one backend: there is **no runtime switching** inside
a live session and **no default mode** — a missing or unknown `SMOKE_BACKEND`
shows the setup screen and never opens a session. The active mode is shown in
the app bar.

No provider key is ever on the device. The Firebase mode holds a Firebase
id-token + App Check token; the Realtime mode additionally holds only
short-lived ephemeral client secrets minted by the app's own endpoint.

## Prerequisites

- Both modes: the smoke Firebase project with **Anonymous** Auth and
  **App Check** enabled.
- `firebase` mode: a deployed smoke `chat` function (see
  `../server/firebase-chat-template/DEPLOY_SMOKE.md`).
- `realtime` mode: a deployed **client-secret mint endpoint** (external smoke
  infrastructure — deliberately not part of this repository). It must verify
  Firebase Auth + App Check, check entitlement/limits, call OpenAI
  `POST /v1/realtime/client_secrets` with the server-side standard API key
  for **`gpt-realtime-2.1`**, return the official response (top-level
  `value`), and never receive or log user content.

### Realtime mint contract (exact)

The in-app provider sends exactly this — nothing else ever rides along
(no prompt, messages, images, tools, conversation state, `ChatRequest`,
idempotency key or OpenAI API key):

```http
POST <REALTIME_CLIENT_SECRET_ENDPOINT>
Authorization: Bearer <Firebase ID token>
X-Firebase-AppCheck: <App Check token>
Content-Type: application/json

{"botId":"<opaque bot id>"}
```

Accepted reply: HTTP `200` with a JSON object whose non-empty top-level
string `value` is the ephemeral client secret (the official
`client_secrets` passthrough shape). Anything else — non-200, malformed
JSON, a missing/empty `value` — fails the leg with a stable sanitized error;
the provider performs exactly one request per call and never retries.

## Fixed identifiers

- iOS bundle id / Android application id: **`com.chataismoke.example`**
  (register both in the smoke Firebase project).
- iOS deployment target: **18.0**. Android `minSdk`: **34**.
- The dual-backend smoke scenario below is **iOS-only**; Android files stay
  in the harness but are not part of this scenario.

## Configuration — compile-time defines only (config-free)

This harness bundles **no** `google-services.json` /
`GoogleService-Info.plist` and no `firebase_options.dart`. Everything is
injected via compile-time defines.

Required in **both** modes: `SMOKE_BACKEND`, `CHAT_BOT_ID`,
`FIREBASE_API_KEY`, `FIREBASE_APP_ID`, `FIREBASE_MESSAGING_SENDER_ID`,
`FIREBASE_PROJECT_ID` (the Realtime mode also authenticates with Firebase to
call the mint endpoint).

Additionally required per mode:

- `firebase` → `CHAT_ENDPOINT`;
- `realtime` → `REALTIME_CLIENT_SECRET_ENDPOINT`.

Put them in **local, gitignored** files, one per mode. `FIREBASE_API_KEY` is
a Firebase *client* config value (not the provider secret), but is still kept
only in these local files.

`smoke.firebase.ios.local.json` (placeholder — fill with your smoke project's
iOS app values):

```json
{
  "SMOKE_BACKEND": "firebase",
  "CHAT_ENDPOINT": "https://<function-region>-<project-id>.cloudfunctions.net/chat",
  "CHAT_BOT_ID": "<your-CHAT_BOT_ID>",
  "FIREBASE_API_KEY": "<ios-firebase-api-key>",
  "FIREBASE_APP_ID": "<ios-firebase-app-id>",
  "FIREBASE_MESSAGING_SENDER_ID": "<messaging-sender-id>",
  "FIREBASE_PROJECT_ID": "<project-id>"
}
```

`smoke.realtime.ios.local.json` (placeholder):

```json
{
  "SMOKE_BACKEND": "realtime",
  "REALTIME_CLIENT_SECRET_ENDPOINT": "https://<your-mint-endpoint>",
  "CHAT_BOT_ID": "<your-CHAT_BOT_ID>",
  "FIREBASE_API_KEY": "<ios-firebase-api-key>",
  "FIREBASE_APP_ID": "<ios-firebase-app-id>",
  "FIREBASE_MESSAGING_SENDER_ID": "<messaging-sender-id>",
  "FIREBASE_PROJECT_ID": "<project-id>"
}
```

Both files are gitignored. `CHAT_BOT_ID` must equal the server-side bot/tier
id. Never commit real values.

## Run (physical iPhone)

```sh
flutter run --dart-define-from-file=smoke.firebase.ios.local.json
flutter run --dart-define-from-file=smoke.realtime.ios.local.json
```

If any required define is missing (or `SMOKE_BACKEND` is empty/unknown), the
app shows a **setup screen** listing the missing define **names** (never
their values) and never opens a live session.

## Android — Firebase mode only (legacy path)

The pre-dual-backend Firebase-only Android smoke path is kept:
`firebase.android.local.json` holds the smoke project's **Android** app
values (same keys as the iOS firebase config) and must now also include
`"SMOKE_BACKEND": "firebase"`.

```sh
flutter run --dart-define-from-file=firebase.android.local.json
```

Android was **not** verified in the current increment and is **not** a
release gate for the current iOS release. There is no Realtime Android
configuration.

## App Check debug token

On first launch the App Check **debug provider** prints a debug token to the
device log. Register it in the Firebase console (App Check → your app →
Manage debug tokens). Debug attestation is for the smoke only, never
production.

## Manual smoke scenarios (run per mode, iOS)

Run each against the live backend and record the result (form below),
separately for `firebase` and `realtime`:

1. **Streaming** — send a Unicode prompt; the reply streams incrementally,
   then `Done` with a usage line.
2. **Image** — attach an image (📎), send a prompt about it, get a reply.
3. **Tool loop** — ask "what time is it?"; the bot calls `get_device_time`,
   the app returns the ISO-8601 timestamp, and the reply finishes with `Done`.
4. **Cancel** — send, then stop mid-stream: state becomes `Cancelled`, the
   partial is kept, and late tokens never mutate the UI.
5. **Done** — a normal completion lands on `Done`.
6. **Failure mapping** — break the endpoint/network: the failure shows as the
   existing localized `FailureCause` text, never a technical detail.

`firebase` mode additionally:

7. **No leakage** — check the server logs
   (`firebase functions:log --only chat`): no payload, key or token appears.

`realtime` mode additionally:

8. **Mint privacy** — the mint endpoint received only Auth/App Check headers
   and `{"botId": …}`; its logs contain no prompt/messages/images/tools,
   no Firebase token and no client secret.
9. **Direct path** — user content flows from the phone straight to OpenAI
   over the Realtime WebSocket (the app backend sees none of it). No
   microphone permission prompt appears (the transport uses no audio).
10. **Single dispatch** — one send leg emits exactly one `response.create`.
    Note: the physical smoke is NOT the proof of the ambiguous-failure
    money-safe boundary — that guarantee stays pinned by the Realtime
    adapter's automated tests.

## Result log

| Date (UTC) | Device / OS | App build | Mode | Scenario | Pass/Fail | Notes |
|---|---|---|---|---|---|---|
|  |  |  |  |  |  |  |

## Voice feasibility probe (Increment-0, iOS only)

A **separate entrypoint** — `lib/voice_probe_main.dart` — proves ONE
speech-to-speech WebRTC turn device → OpenAI Realtime, saving the user reply
and the assistant reply as two locally-playable audio files. It is a
**feasibility spike**, not a production voice API and not part of any package.

```
flutter run \
  -t lib/voice_probe_main.dart \
  --dart-define-from-file=smoke.realtime.ios.local.json
```

It reuses this harness's Firebase init and `SmokeClientSecretProvider`
(`REALTIME_CLIENT_SECRET_ENDPOINT`, `CHAT_BOT_ID`, `FIREBASE_*` defines; no
`SMOKE_BACKEND`). One microphone owner (`flutter_webrtc`), no camera, no video,
no second recorder. The two files are written **entirely on the iOS side** by
an app-local native writer that attaches to the existing WebRTC audio tracks as
a public `RTCAudioRenderer` (`addRenderer:` / `removeRenderer:`) — **no PCM/audio
bytes ever cross the Flutter channel**.

Flow: **Start** (one client-secret mint) → speak one short phrase → hear one
assistant response → **Stop/Close** → **Play user** / **Play assistant**. The
UI shows only coarse state; it never shows a path, transcript, secret or raw
event. Money-safe: one mint, one server-VAD response, no retry/reconnect, no
extra `response.create`.

## Voice transcript smoke (production `OpenAIRealtimeVoiceSession`, iOS only)

A **separate entrypoint** — `lib/voice_transcript_smoke_main.dart` — physically
tests the **production** public `OpenAIRealtimeVoiceSession` of
`chat_ai_openai_realtime_voice` with the **optional final transcripts** turned
on (`transcriptsEnabled: true`, default `inputTranscriptionModel`
`gpt-4o-mini-transcribe`). It is **iOS only** and is not the feasibility probe
above — it uses no `VoiceProbeSession`, no `record_transcribe`, writes no audio
file and adds no native code.

Exactly one mode per launch — **no default and no runtime switch**. Pass the
mandatory `VOICE_SMOKE_MODE` define (an unknown/empty value shows the setup
screen and creates no session):

```
flutter run \
  -t lib/voice_transcript_smoke_main.dart \
  --dart-define-from-file=smoke.realtime.ios.local.json \
  --dart-define=VOICE_SMOKE_MODE=singleTurn
```

```
flutter run \
  -t lib/voice_transcript_smoke_main.dart \
  --dart-define-from-file=smoke.realtime.ios.local.json \
  --dart-define=VOICE_SMOKE_MODE=conversation
```

It reuses this harness's Firebase init and `SmokeClientSecretProvider`
(`REALTIME_CLIENT_SECRET_ENDPOINT`, `CHAT_BOT_ID`, `FIREBASE_*` defines; no
`SMOKE_BACKEND`), the existing Realtime mint endpoint and the direct
device → OpenAI Realtime WebRTC session.

The UI is minimal: coarse `OpenAIRealtimeVoicePhase`, coarse failure (if any),
**Start**, **Stop**, and two separate lists — **User transcripts** and
**Assistant transcripts**. Transcripts are **intentionally shown in the UI**,
verbatim (no trim); this is the deliberate content channel of this smoke. The UI
never shows and never logs the ephemeral secret, Firebase tokens, endpoint, SDP,
raw Realtime events, provider errors, item/response/event ids, usage or track
ids. One session per launch; **Start** runs exactly once.

This smoke tests transcripts only — **audio recording and saving are not
exercised here**; the old audio-recording feasibility probe remains a separate
entrypoint (`lib/voice_probe_main.dart`).

### Voice recording smoke

A further entrypoint — `lib/voice_recording_smoke_main.dart` — physically tests
the **production** `OpenAIRealtimeVoiceSession` with **local recording**
(`recordingEnabled: true`, into an app-writable tmp sub-folder), **final
transcripts** and the **assistant transcript deltas**, plus the **programmatic
interrupt**. iOS only; no new dependency beyond a test-harness-only local audio
player for the on-device "is it playable" check; no native code and no second
microphone. Same `VOICE_SMOKE_MODE` (`singleTurn` | `conversation`) contract:

```
flutter run \
  -t lib/voice_recording_smoke_main.dart \
  --dart-define-from-file=smoke.realtime.ios.local.json \
  --dart-define=VOICE_SMOKE_MODE=conversation
```

The minimal UI adds: an **Assistant deltas** panel (fragment count + the text
assembled in arrival order), an **Interrupt response** button (enabled only while
the assistant is speaking; it calls only the public `interruptResponse()`), a
per-reply **Recordings** list (role / interrupted / whether a transcript is
present / whether the file exists / basename, with a Play button), a
**Directory files** list (size + Play, the no-overwrite check) and the
**Transcripts** list. It never shows or logs the ephemeral secret, tokens,
endpoint, SDP, raw events, the transcript text off-screen, or a full file path.

## Build without a config

`flutter build ios --no-codesign` builds without any local config: with no
defines the runtime shows the setup screen. Never commit real values or
native config files.
