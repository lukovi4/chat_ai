import 'backend_event.dart';
import 'chat_request.dart';
import 'durable_chat_backend.dart';

/// The OPTIONAL server-managed variant of the durable capability: the server
/// owns the WHOLE logical reply — its tool loop and every provider leg
/// included — and a `ChatSession` only starts, observes, re-attaches and
/// cancels it.
///
/// It is the second, independent opt-in mode of the durable lifecycle:
/// - [DurableChatBackend] — the reply is durable, but the **tool loop is
///   client-owned**: the Core resolves each `tool_call` through `onToolCall`
///   and starts the next billable leg itself;
/// - [ServerManagedDurableChatBackend] — the **tool loop is server-owned**:
///   the Core neither sees nor answers tool calls, and never starts a second
///   provider leg of the same reply.
///
/// The two modes are never mixed: a backend declares one of them, and the
/// declared interface alone decides which owns the tool loop.
///
/// The three identities are unchanged and never mixed: `replyId` (the whole
/// logical reply — the assistant `Message.id`), `attemptKey`
/// (`ChatRequest.idempotencyKey`, ONE billable provider leg) and `toolCallId`
/// (one tool call, invisible to this session).
///
/// The package ships no implementation: the remote generation, its tool
/// execution, its storage and its host are the Consuming App's.
abstract interface class ServerManagedDurableChatBackend
    implements DurableChatBackend {
  /// Starts the WHOLE logical reply [replyId] exactly once and streams the
  /// observation of it — not one provider leg.
  ///
  /// [request] is the frozen first-leg request; its `idempotencyKey` is the
  /// `attemptKey` the Core has ALREADY persisted (through the session's
  /// checkpoint) for the first provider leg. Every following leg — its key,
  /// its dispatch and the tools between them — belongs to the server.
  ///
  /// The stream carries exactly four event kinds: `accepted`, `delta`, `done`
  /// and `error`. Server-owned `tool_call`s, their results and the provider
  /// continuity state stay server-side and never reach this session; a `409`
  /// or `410` cannot legally arrive either, because the Core mints no second
  /// key for this reply.
  ///
  /// Cancelling the subscription means **DETACH only**: the remote reply keeps
  /// running.
  @override
  Stream<BackendEvent> startReply(String replyId, ChatRequest request);

  /// Atomically tries to attach to the already running reply [replyId]; it
  /// never starts a new provider call.
  ///
  /// - a `Stream` — the reply exists; the replay starts the reply's VISIBLE
  ///   TEXT from the beginning (the whole server-owned reply so far, not the
  ///   current provider leg);
  /// - `null` — the backend has PROVEN there is no active reply;
  /// - a throw — the reply status could not be determined; this is not
  ///   equivalent to `null` and never normalises the history.
  @override
  Future<Stream<BackendEvent>?> attachReply(String replyId);

  /// Explicit best-effort remote cancellation of the whole logical reply.
  ///
  /// The Core calls this at most once per LOGICAL REPLY, and only after a
  /// `startReply` actually happened or an `attachReply` succeeded; a later
  /// reply of the same `ChatSession` can be cancelled in turn, and `dispose()`
  /// never calls it.
  @override
  Future<void> cancelReply(String replyId);
}
