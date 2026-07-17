# Changelog

## 0.2.0

- **Transport replaced: WebRTC → direct OpenAI Realtime WebSocket.** The
  backend now opens one `wss://api.openai.com/v1/realtime?model=<model>`
  session per `send()` leg over `dart:io WebSocket.connect`, carrying the
  ephemeral secret only as the `Authorization: Bearer` header. The
  `flutter_webrtc` dependency and all WebRTC/SDP/ICE/data-channel code are
  removed; there is **no microphone/camera permission and no native audio
  dependency** (the WebRTC path required a microphone usage description on
  iOS even for data-channel-only use).
- **New optional constructor parameter `model`** (default `gpt-realtime-2.1`)
  — the only public-API addition; existing `clientSecretProvider:`-only code
  still compiles. A whitespace-only model is rejected before any token
  request or network I/O. The app must keep this in sync with what its mint
  endpoint binds to the ephemeral credential; the client secret is not a
  secure model pin.
- Unchanged: `ClientSecretProvider`, the `ChatRequest` → `response.create`
  translation (`conversation: "none"`, stateless input, text output, images
  as `input_image`, tools/results, `ProviderOpaquePart` skip), the server
  event handling, `Accepted` only after `response.created`, usage/failure
  mapping, the never-throws stream contract, and the money-safe commit
  boundary (no retries; `network` before dispatch, `upstream` after).

## 0.1.0

- Initial version: `OpenAIRealtimeChatBackend` — an OpenAI Realtime (WebRTC)
  `ChatBackend` for `chat_ai`. One WebRTC session per `send()` leg, exactly
  one out-of-band `response.create` (`conversation: "none"`, stateless
  input, text output), ephemeral client secrets via the app-implemented
  `ClientSecretProvider`, money-safe commit boundary (no retries; `network`
  only before dispatch, `upstream` after), wire-cancel with best-effort
  `response.cancel`. iOS/Android only.
