# Changelog

## 0.1.0

- Initial version: the production `FirebaseChatBackend` transport extracted
  unchanged from `chat_ai 1.0.0` — the same request bytes, headers, SSE
  parsing, event ordering, cancel and error mapping (V1_SPEC §8,
  SERVER-CONTRACT). Apps now import it from
  `package:chat_ai_firebase/chat_ai_firebase.dart`.
