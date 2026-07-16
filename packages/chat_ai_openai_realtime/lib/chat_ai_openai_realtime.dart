/// chat_ai_openai_realtime — an OpenAI Realtime (WebRTC) `ChatBackend` for
/// `chat_ai`.
///
/// The public surface is exactly two declarations: [ClientSecretProvider]
/// (implemented by the consuming app; mints one ephemeral OpenAI client
/// secret per `send()` leg) and [OpenAIRealtimeChatBackend] (one WebRTC
/// session per `send()`, `response.create` with `conversation: "none"` and
/// stateless input, text output). Transport, translators and test seams are
/// package-internal and never exported.
library;

export 'src/client_secret_provider.dart' show ClientSecretProvider;
export 'src/openai_realtime_chat_backend.dart' show OpenAIRealtimeChatBackend;
