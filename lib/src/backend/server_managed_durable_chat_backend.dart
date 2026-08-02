import '../models/conversation.dart';
import 'backend_event.dart';
import 'chat_backend.dart';
import 'chat_request.dart';
import 'durable_chat_backend.dart';

/// The OPTIONAL server-managed variant of the durable lifecycle: the server
/// owns the WHOLE logical reply — its admission, its tool loop and every
/// provider leg included — and a `ChatSession` only admits, observes,
/// re-attaches and cancels it.
///
/// It is the second, independent opt-in mode of the durable lifecycle, and it
/// is NOT a sub-type of [DurableChatBackend] — the two are separate contracts
/// with separate entry points:
/// - [DurableChatBackend] — the reply is durable, but the **tool loop is
///   client-owned**: the Core persists through its own `checkpoint`, resolves
///   each `tool_call` through `onToolCall` and starts the next billable leg
///   itself (`startReply`), so admission stays TWO steps — checkpoint, then
///   start;
/// - [ServerManagedDurableChatBackend] — the **whole reply is server-owned**:
///   the Core neither sees nor answers tool calls, never starts a second
///   provider leg of the same reply, and admits the reply in ONE call
///   ([admitReply]) that carries the snapshot to persist, so there is no
///   crash-gap between "Messages saved" and "Job created".
///
/// The two modes are never mixed: a backend declares one of them, and the
/// declared interface alone decides which owns the reply.
///
/// The three identities are unchanged and never mixed: `replyId` (the whole
/// logical reply — the assistant `Message.id`), `attemptKey`
/// (`ChatRequest.idempotencyKey`, ONE billable provider leg) and `toolCallId`
/// (one tool call, invisible to this session).
///
/// [ChatBackend.send] stays inherited for type compatibility only — in this
/// mode a `ChatSession` never calls it.
///
/// The package ships no implementation: the atomic admission (Messages + Job),
/// the Job itself, the remote generation, its tool execution, its storage and
/// its host are the Consuming App's.
abstract interface class ServerManagedDurableChatBackend
    implements ChatBackend {
  /// Admits the WHOLE logical reply [replyId] exactly once — ONE atomic
  /// server operation that both persists the conversation and creates the Job
  /// — and streams the observation of that reply.
  ///
  /// The three arguments are the complete admission payload:
  /// - [replyId] — the id of the empty assistant `Message` this reply will
  ///   fill; it is the whole logical reply's identity;
  /// - [request] — the frozen first-leg request; its `idempotencyKey` is the
  ///   `attemptKey` of the FIRST provider leg. Every following leg — its key,
  ///   its dispatch and the tools between them — belongs to the server;
  /// - [snapshot] — the exact frozen `Conversation` the Core holds at this
  ///   moment: it contains the user `Message` of this turn and the empty
  ///   `streaming` assistant `Message` whose `id` is [replyId]. It is a value
  ///   taken before any event of this reply is applied and never follows the
  ///   session's later local updates.
  ///
  /// The app's backend MUST, in ONE server transaction:
  /// - persist that [snapshot];
  /// - create — or safely join — the single Job of this [replyId].
  ///
  /// No provider call may start before that transaction has committed. There
  /// is no separate Dart `checkpoint` in this mode: passing one to a
  /// `ChatSession` is a configuration error (`ArgumentError`), because the
  /// two-step "persist, then start" is exactly the crash-gap this call
  /// removes.
  ///
  /// The stream carries exactly four event kinds: `accepted`, `delta`, `done`
  /// and `error`. Server-owned `tool_call`s, their results and the provider
  /// continuity state stay server-side and never reach this session; a `409`
  /// or `410` cannot legally arrive either, because the Core mints no second
  /// key for this reply.
  ///
  /// `accepted` is the admission receipt: it MUST be the first successful
  /// event of this stream and means the Messages + Job transaction has
  /// COMMITTED. Its contract in this mode:
  /// - a repeated transport delivery of the SAME admission must join the
  ///   existing Job, never create a second one;
  /// - an error BEFORE `accepted` is legal only as a PROVEN admission
  ///   refusal: no Job was created and no provider call ran. The Core ends the
  ///   attempt as one local failure and never re-admits it;
  /// - an UNDETERMINED network outcome is not such a refusal: the app's
  ///   backend must first resolve it by [replyId] (was the Job committed?) and
  ///   may never report it as a confirmed refusal.
  ///
  /// The two ways a second admission can appear are therefore never confused,
  /// and the backend does not have to tell them apart:
  /// - **the same [replyId] again** is always a transport duplicate of ONE
  ///   admission — join the existing Job, never create a second one, never run
  ///   the provider twice;
  /// - **an explicit user recovery** (`ChatSession.regenerate`) is a NEW
  ///   logical reply: the Core mints a new `attemptKey` AND a new [replyId]
  ///   for it, and never re-admits a [replyId] that was already admitted.
  ///
  /// Cancelling the subscription means **DETACH only**: the remote reply keeps
  /// running.
  Stream<BackendEvent> admitReply(
    String replyId,
    ChatRequest request,
    Conversation snapshot,
  );

  /// Atomically tries to attach to the already running reply [replyId]; it
  /// never admits a reply and never starts a new provider call.
  ///
  /// - a `Stream` — the reply exists; the replay starts the reply's VISIBLE
  ///   TEXT from the beginning (the whole server-owned reply so far, not the
  ///   current provider leg);
  /// - `null` — the backend has PROVEN there is no active reply;
  /// - a throw — the reply status could not be determined; this is not
  ///   equivalent to `null` and never normalises the history.
  Future<Stream<BackendEvent>?> attachReply(String replyId);

  /// Explicit best-effort remote cancellation of the whole logical reply.
  ///
  /// The Core calls this at most once per LOGICAL REPLY, and only after an
  /// [admitReply] actually happened or an [attachReply] succeeded; a later
  /// reply of the same `ChatSession` can be cancelled in turn, and `dispose()`
  /// never calls it.
  ///
  /// It MUST be idempotent and race-safe with an admission still in flight:
  /// the Core may cancel after [admitReply] was called but BEFORE its
  /// `accepted` arrived, and such a cancel may neither be lost nor allow a
  /// later provider dispatch of that reply.
  Future<void> cancelReply(String replyId);
}
