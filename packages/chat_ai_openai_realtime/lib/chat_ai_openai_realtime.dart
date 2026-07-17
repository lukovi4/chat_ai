/// chat_ai_openai_realtime — an OpenAI Realtime (WebSocket) `ChatBackend` for
/// `chat_ai`.
///
/// The public surface is exactly two declarations: [ClientSecretProvider]
/// (implemented by the consuming app; mints one ephemeral OpenAI client
/// secret per `send()` leg) and [OpenAIRealtimeChatBackend] (one direct OpenAI
/// Realtime WebSocket per `send()`, `response.create` with
/// `conversation: "none"` and stateless input, text output; no WebRTC, no
/// microphone/camera, no native audio dependency). Transport, translators and
/// test seams are package-internal and never exported.
library;

export 'src/client_secret_provider.dart' show ClientSecretProvider;
export 'src/openai_realtime_chat_backend.dart' show OpenAIRealtimeChatBackend;
