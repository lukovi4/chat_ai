# chat_ai_openai_realtime

An OpenAI Realtime (WebSocket) transport for the
[`chat_ai`](../../README.md) package. **This package contains only a
Realtime `ChatBackend`** — nothing else: no Core changes, no widgets, no
server code.

```dart
final backend = OpenAIRealtimeChatBackend(
  clientSecretProvider: MyAppSecretProvider(), // implemented by the app
  // model: 'gpt-realtime-2.1',                // optional; this is the default
);
final session = ChatSession(backend: backend, botProfile: profile);
```

## What the app owns

- **The app itself implements `ClientSecretProvider`.** The provider is
  called anew for every `send()` leg, receives only the opaque `botId`, and
  must return a fresh non-empty ephemeral OpenAI client secret (minted
  server-side via `POST /v1/realtime/client_secrets`).
- **The standard OpenAI API key is never on the device.** Only short-lived
  ephemeral client secrets ever reach the phone, and each is used once as
  the `Authorization: Bearer` credential of one WebSocket handshake.
- **This package implements no Auth, App Check, entitlement, quota or
  server endpoint.** Token issuance, limits and spend protection belong
  entirely to the app and its backend.

## Transport semantics

- **One WebSocket session per `send()`.** Every leg opens a fresh
  `wss://api.openai.com/v1/realtime?model=<model>` connection (via
  `dart:io WebSocket.connect`), sends exactly one `response.create`, and
  tears the session down at the terminal event. No persistent connection, no
  session reuse, no reconnect, no retry, no message replay.
- **The default Realtime Conversation is not used.** Each response is
  out-of-band (`conversation: "none"`) with the full stateless history in
  `response.input`; history is never replayed via `conversation.item.create`.
- Output is text-only (`output_modalities: ["text"]`). **No WebRTC, no
  microphone/camera permission, no audio/media tracks, no native audio
  dependency** — the transport is a plain text WebSocket. Only text frames
  are accepted; a binary frame is a controlled protocol failure.
- `ProviderOpaquePart` is skipped entirely (regardless of provider): OpenAI
  Realtime has no encrypted-reasoning continuity input.

## Money safety

- **This backend performs no retries and there is no server replay /
  idempotency layer.** Before the `response.create` dispatch, transport
  failures end as `network` — the `chat_ai` Core may silently retry them,
  which is safe because inference was never requested. From the instant the
  serialized `response.create` is handed to the socket, every failure is
  terminal `upstream`, so the Core never re-runs a possibly-billed call.
- **An explicit resend/regenerate may be a new billable call.** The wire
  `idempotencyKey` is not sent to OpenAI and deduplicates nothing here.
- Cancelling the reply is a wire-cancel: best-effort `response.cancel`,
  then full session teardown.

## Model & auth

- The Realtime model is the optional constructor parameter `model` (default
  `gpt-realtime-2.1`); it is URL-encoded into the WebSocket `model` query
  parameter. A whitespace-only model is rejected before any token request or
  network I/O. Existing `clientSecretProvider:`-only code keeps compiling.
- The ephemeral secret is carried **only** as the `Authorization: Bearer`
  header of the WebSocket handshake — never in the URL, a subprotocol, an
  event, an exception or a log.
- **The app must keep the constructor `model` in sync with the model its
  mint endpoint binds to the ephemeral credential.** The client secret is
  not a secure model-pinning mechanism — the model the app requests here is
  a default the session may not enforce.

## Platforms & limits

- iOS and Android only. No web/desktop implementation.
- **The current adapter version is tested against `gpt-realtime-2.1`**, which
  supports image input. Images ride as `data:image/jpeg;base64,...`
  `input_image` parts.
- **Unit tests do not prove the maximum image payload over a real mobile
  WebSocket** — they run against a fake transport.
- **iOS physical smoke: PASSED 2026-07-17** against real OpenAI via the shared
  harness at
  [`../chat_ai_firebase/example/`](../chat_ai_firebase/example/README.md)
  (`SMOKE_BACKEND=realtime`) — streaming/Done, image, tool, cancel and offline
  failure mapping, with no microphone permission prompt and no microphone TCC
  access.
- **Android physical smoke has NOT been performed** and remains a release gate
  **only before an Android release** (it does not gate the iOS release).
