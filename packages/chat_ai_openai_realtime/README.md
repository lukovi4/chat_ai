# chat_ai_openai_realtime

An OpenAI Realtime (WebRTC) transport for the
[`chat_ai`](../../README.md) package. **This package contains only a
Realtime `ChatBackend`** — nothing else: no Core changes, no widgets, no
server code.

```dart
final backend = OpenAIRealtimeChatBackend(
  clientSecretProvider: MyAppSecretProvider(), // implemented by the app
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
  the Bearer credential of one WebRTC signaling exchange.
- **This package implements no Auth, App Check, entitlement, quota or
  server endpoint.** Token issuance, limits and spend protection belong
  entirely to the app and its backend.

## Transport semantics

- **One WebRTC session per `send()`.** Every leg creates a fresh peer
  connection and an `oai-events` data channel, sends exactly one
  `response.create`, and tears the session down at the terminal event. No
  persistent connection, no session reuse.
- **The default Realtime Conversation is not used.** Each response is
  out-of-band (`conversation: "none"`) with the full stateless history in
  `response.input`; history is never replayed via `conversation.item.create`.
- Sessions are data-channel-only: no microphone permission, no audio/media
  tracks; output is text-only (`output_modalities: ["text"]`).
- `ProviderOpaquePart` is skipped entirely (regardless of provider): OpenAI
  Realtime has no encrypted-reasoning continuity input.

## Money safety

- **This backend performs no retries and there is no server replay /
  idempotency layer.** Before the `response.create` dispatch, transport
  failures end as `network` — the `chat_ai` Core may silently retry them,
  which is safe because inference was never requested. From the instant the
  serialized `response.create` is handed to the data channel, every failure
  is terminal `upstream`, so the Core never re-runs a possibly-billed call.
- **An explicit resend/regenerate may be a new billable call.** The wire
  `idempotencyKey` is not sent to OpenAI and deduplicates nothing here.
- Cancelling the reply is a wire-cancel: best-effort `response.cancel`,
  then full session teardown.

## Platforms & limits

- iOS and Android only (via `flutter_webrtc` data channels). No web/desktop
  implementation.
- **The current adapter version is tested against `gpt-realtime-2.1`.** The
  app's backend chooses the session configuration — including the model —
  when it mints the ephemeral credential
  (`POST /v1/realtime/client_secrets`).
- **The client secret is not a secure model-pinning mechanism.** The
  configuration attached to it can be overridden by the client connection,
  so the backend-chosen model is a default, not an enforced guarantee.
- **Image support depends on the Realtime model actually in use** —
  `gpt-realtime-2.1` supports image input. Images ride as
  `data:image/jpeg;base64,...` `input_image` parts.
- **Unit tests do not prove the maximum image payload over a real mobile
  RTCDataChannel** — they run against a fake transport.
- **A physical-device smoke test (iOS/Android against real OpenAI) is
  required before production use.** The shared iOS smoke harness lives at
  [`../chat_ai_firebase/example/`](../chat_ai_firebase/example/README.md)
  (`SMOKE_BACKEND=realtime`). Status: the physical smoke of this adapter has
  **not been performed yet** — until it passes on a real device, this
  package is not release-ready.
