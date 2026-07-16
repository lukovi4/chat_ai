/// Mints one ephemeral OpenAI Realtime client secret for one backend leg.
///
/// Implemented by the consuming app — token issuance, entitlement, quota and
/// spend protection all live behind the app's own endpoint, never in this
/// package. The standard OpenAI API key must never be on the device.
///
/// Contract:
/// - receives ONLY the opaque bot id — never the `ChatRequest`, system
///   prompt, messages, images, tools, tool results or any conversation
///   snapshot;
/// - is called anew for every `send()`;
/// - must return a non-empty ephemeral client secret.
///
/// A thrown exception or an empty result never escapes the backend stream:
/// the leg ends as one sanitized `ErrorEvent(upstream)`.
abstract interface class ClientSecretProvider {
  /// Returns a fresh ephemeral OpenAI client secret for the bot [botId].
  Future<String> getClientSecret({required String botId});
}
