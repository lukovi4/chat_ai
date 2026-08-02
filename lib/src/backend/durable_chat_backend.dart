import 'backend_event.dart';
import 'chat_backend.dart';
import 'chat_request.dart';

/// The OPTIONAL durable capability of a transport, declared alongside the
/// unchanged [ChatBackend].
///
/// The model is a long-running operation, not a connection:
/// - `replyId` identifies the whole logical reply — it is the assistant
///   `Message.id`, minted and checkpointed by the Core BEFORE the first
///   provider dispatch;
/// - `attemptKey` (`ChatRequest.idempotencyKey`) identifies ONE billable
///   provider leg;
/// - `toolCallId` identifies one tool call.
///
/// The three identities are never mixed or reused for one another.
///
/// A `ChatSession` takes THIS durable path only when its backend implements
/// this interface; a plain [ChatBackend] keeps the v1 connection-bound
/// semantics unchanged (cancelling the subscription is a wire-cancel).
///
/// This is the **client-owned** durable mode: the Core owns the tool loop and
/// every billable leg, persists through the app's `checkpoint` and only then
/// calls [startReply] — a two-step admission — and its recover-before-rebill
/// rules are unchanged. The server-owned mode is the separate
/// `ServerManagedDurableChatBackend`, which does NOT implement this interface:
/// it has no [startReply] and no `checkpoint`, admitting the whole reply in one
/// atomic `admitReply` instead.
///
/// The package ships no durable backend implementation: the remote generation,
/// its storage and its host are the Consuming App's.
abstract interface class DurableChatBackend implements ChatBackend {
  /// Starts a new billable provider leg of the logical reply [replyId] and
  /// streams its events.
  ///
  /// [replyId] exists and was persisted by the app (through the session's
  /// checkpoint) before this call. Cancelling the subscription of the returned
  /// stream means **DETACH only**: the remote generation keeps running.
  Stream<BackendEvent> startReply(String replyId, ChatRequest request);

  /// Atomically tries to attach to an already running reply.
  ///
  /// - a `Stream` — the reply exists; the stream replays the CURRENT provider
  ///   leg from its beginning and never creates a new provider call;
  /// - `null` — the backend has PROVEN there is no active reply;
  /// - a throw — the reply status could not be determined; this is not
  ///   equivalent to `null` and never normalises the history.
  Future<Stream<BackendEvent>?> attachReply(String replyId);

  /// Explicit best-effort remote cancellation of the logical reply.
  ///
  /// The Core calls this at most once per LOGICAL REPLY, and only after a
  /// `startReply` actually happened or an `attachReply` succeeded; a later
  /// reply of the same `ChatSession` can be cancelled in turn.
  Future<void> cancelReply(String replyId);
}
