/// Testing-only entry for chat_ai — kept out of production builds.
///
/// Provides the scriptable fake `ChatBackend` (`FakeChatBackend`, V1_SPEC
/// §10) and its durable counterpart (`FakeDurableChatBackend`, the optional
/// long-running-reply capability) so an app's tests can drive both chat paths
/// with no network and no paid calls. Exactly the two classes — the
/// package-internal request-capture seam is deliberately not exported. Never
/// exported from the main `package:chat_ai/chat_ai.dart` barrel.
library;

export 'src/testing/fake_chat_backend.dart'
    show FakeChatBackend, FakeDurableChatBackend;
