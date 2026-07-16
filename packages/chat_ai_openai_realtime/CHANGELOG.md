# Changelog

## 0.1.0

- Initial version: `OpenAIRealtimeChatBackend` — an OpenAI Realtime (WebRTC)
  `ChatBackend` for `chat_ai`. One WebRTC session per `send()` leg, exactly
  one out-of-band `response.create` (`conversation: "none"`, stateless
  input, text output), ephemeral client secrets via the app-implemented
  `ClientSecretProvider`, money-safe commit boundary (no retries; `network`
  only before dispatch, `upstream` after), wire-cancel with best-effort
  `response.cancel`. iOS/Android only.
