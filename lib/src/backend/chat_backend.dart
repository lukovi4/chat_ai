import 'backend_event.dart';
import 'chat_request.dart';

/// The transport boundary: where one frozen [ChatRequest] leg is sent and the
/// reply streams back as [BackendEvent]s (CONTEXT.md §AI Backend, V1_SPEC §8,
/// ADR 0001).
///
/// The Core depends only on this abstraction — never on Firebase/dio/SSE.
/// It is a **dumb pipe**: the money-aware silent-retry loop lives in the Core
/// (so the fake exercises it too), not here.
///
/// Cancelling the subscription = wire-cancel: the transport MUST close the
/// connection; any upstream abort is BEST-EFFORT (observed disconnect /
/// write failure) and the orphan is bounded.
///
/// The returned stream **never throws**: every outcome, transport failure
/// included, is a [BackendEvent] — see the event contract on [BackendEvent].
///
/// Implementations:
/// - production transports live in the companion adapter packages of this
///   repository — `FirebaseChatBackend` (`chat_ai_firebase`) and
///   `OpenAIRealtimeChatBackend` (`chat_ai_openai_realtime`);
/// - `FakeChatBackend` (tests, `package:chat_ai/testing.dart`).
abstract interface class ChatBackend {
  /// Perform one backend request and stream its events.
  Stream<BackendEvent> send(ChatRequest request);
}
