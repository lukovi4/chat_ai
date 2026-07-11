/// Testing-only entry for chat_ai — kept out of production builds.
///
/// Will provide the fake `ChatBackend` (`FakeChatBackend`, V1_SPEC §10) so an
/// app's tests can drive the chat path with no network and no paid calls. The
/// fake is NOT part of the foundation increment, so this entry intentionally
/// exports nothing yet. Never exported from the main
/// `package:chat_ai/chat_ai.dart` barrel.
library;
