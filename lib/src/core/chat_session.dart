import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:uuid/uuid.dart';

import '../backend/backend_event.dart';
import '../backend/chat_backend.dart';
import '../backend/chat_request.dart';
import '../backend/chat_request_wire.dart';
import '../backend/durable_chat_backend.dart';
import '../models/bot_profile.dart';
import '../models/content_part.dart';
import '../models/conversation.dart';
import '../models/conversation_invariants.dart';
import '../models/failure.dart';
import '../models/image_send_options.dart';
import '../models/message.dart';
import '../models/tool.dart';
import '../models/usage.dart';
import '../state/conversation_state.dart';
import 'context_assembly.dart';
import 'image_processing.dart';
import 'tool_schema_v1.dart';

/// The app-supplied persistence checkpoint (V1_SPEC §3/§4): awaited after the
/// relevant Message and `attemptKey` are in the snapshot and before **every
/// billable provider dispatch**. `null` is valid only when the Consuming App
/// intentionally has no cross-launch conversation persistence.
typedef ConversationCheckpoint = Future<void> Function(Conversation snapshot);

/// Logs-only developer details of the pinned internal failures (V1_SPEC §4).
const String _checkpointFailedDetail = 'checkpoint-failed';
const String _malformedImageDetail = 'malformed-image';
const String _payloadTooLargeDetail = 'payload-too-large';

/// The proxy's request payload ceiling (V1_SPEC §11: 10 MB → `413`/
/// `context-too-long`); an image send whose post-resize body exceeds it is
/// rejected client-side before any Message/key/backend work.
const int _maxRequestBodyBytes = 10 * 1024 * 1024;

/// Token Stream UI throttle: ~15 emissions/s (V1_SPEC §11). Emissions only —
/// the internal accumulator is always complete.
const Duration _tokenThrottle = Duration(milliseconds: 66);

/// Silent-retry backoff shape (code defaults, deliberately not public API —
/// V1_SPEC §3): jittered exponential, `base * 2^(attempt-1) * [0.5..1.0)`,
/// capped. `Retry-After` overrides it when present and fitting the deadline.
const Duration _backoffBase = Duration(milliseconds: 250);
const Duration _backoffCap = Duration(seconds: 5);

/// Fixed-size placeholders used ONLY to measure the prospective payload of an
/// image send (the 10 MB gate) before any real Message/id/key exists.
const String _probeId = '00000000-0000-4000-8000-000000000000';

/// The sanitised `is_error` tool-result contents (V1_SPEC §4): stable
/// machine-ish markers — never an exception text, stack trace or secret.
const String _unknownToolResult = 'unknown-tool';
const String _invalidToolArgsResult = 'invalid-tool-arguments';
const String _toolExecutionFailedResult = 'tool-execution-failed';

/// The package-internal command disposition (V1_SPEC §3): what a command
/// actually did — dispatched, rejected during preprocessing/checkpoint, or
/// dropped as a no-op. The package Input Bar clears its draft only on
/// [accepted]. NOT public product API — never exported from
/// `package:chat_ai/chat_ai.dart`; unrelated to transport
/// `BackendEvent.Accepted`.
enum ChatCommandDisposition { accepted, rejected, noOp }

/// The package-internal recovery target of the CURRENT `Failed` (V1_SPEC §7):
/// what — if anything — the widgets' error row re-runs. Computed by the Core
/// at the failing terminal from what THIS reply actually did, never inferred
/// by widgets from history: [resend] only when this command's anchor user
/// Message actually became `failed` (its id in the bridge), [regenerate] only
/// when this reply's assistant actually became `interrupted`, and [none] for
/// a pre-Message rejection (malformed image / oversized payload) or any other
/// `Failed` with no valid recovery. NOT public product API — never exported
/// from `package:chat_ai/chat_ai.dart`.
enum ChatErrorRecovery { none, resend, regenerate }

/// The v1 Core façade (V1_SPEC §3/§4): **one instance = one open
/// Conversation**. Constructing a session is the domain operation
/// `open(history)` — in-flight statuses are normalised (`sending → failed`,
/// `streaming → interrupted`), invariants are checked, and the session starts
/// in `Idle`. Switching conversations = dispose + construct a new session.
///
/// Commands never throw on operational outcomes — those travel through
/// [states] as data. The two loud exceptions are programming/configuration
/// bugs: any command except a repeated [dispose] after disposal throws
/// [StateError] (as does a checkpoint callback reentering a command), and
/// invalid session/tool configuration throws [ArgumentError].
class ChatSession {
  /// Opens one Conversation (V1_SPEC §3). [history] omitted/empty = a new
  /// conversation. Throws [ArgumentError] on invalid numeric configuration or
  /// tool configuration (tools without [onToolCall], duplicate/invalid names,
  /// a schema outside Chat AI Tool Schema v1), and [FormatException] when
  /// [history] violates the Conversation invariants beyond the normative
  /// stale-status normalisation.
  ChatSession({
    required ChatBackend backend,
    required BotProfile botProfile,
    OnToolCall? onToolCall,
    Conversation? history,
    int? trimBudget,
    int maxToolTurns = 5,
    Duration retryDeadline = const Duration(seconds: 30),
    ImageSendOptions imageOptions = const ImageSendOptions(),
    ConversationCheckpoint? checkpoint,
  }) : this._(
         backend: backend,
         botProfile: botProfile,
         onToolCall: onToolCall,
         history: history,
         trimBudget: trimBudget,
         maxToolTurns: maxToolTurns,
         retryDeadline: retryDeadline,
         imageOptions: imageOptions,
         checkpoint: checkpoint,
         now: null,
         newUuid: null,
         delay: null,
         random: null,
         processImage: null,
       );

  /// Opens one Conversation asynchronously, additionally recovering a durable
  /// reply that is still running remotely (V1_SPEC §3, durable extension).
  ///
  /// Parameters and defaults are exactly those of the constructor. With a
  /// plain [ChatBackend] this is equivalent to `ChatSession(...)`.
  ///
  /// With a [DurableChatBackend] and a persisted trailing `streaming`
  /// assistant Message, `attachReply` is consulted ONCE:
  /// - a stream — that reply is still running: it stays `streaming`, the user
  ///   Message right before it moves `sending → sent`, and the session attaches
  ///   to the returned stream without any assembly, checkpoint, key or
  ///   dispatch;
  /// - `null` — no active reply: the legacy restart normalisation applies;
  /// - a throw — the status is unknown: the error propagates, no session is
  ///   created, the passed [history] is not normalised and nothing is
  ///   dispatched.
  ///
  /// Every local check of the constructor (numeric configuration, image
  /// options, Bot Profile/tools/resolver, `history.schemaVersion` and the
  /// Conversation invariants) runs BEFORE the backend is called: invalid local
  /// configuration or history never reaches the transport.
  static Future<ChatSession> open({
    required ChatBackend backend,
    required BotProfile botProfile,
    OnToolCall? onToolCall,
    Conversation? history,
    int? trimBudget,
    int maxToolTurns = 5,
    Duration retryDeadline = const Duration(seconds: 30),
    ImageSendOptions imageOptions = const ImageSendOptions(),
    ConversationCheckpoint? checkpoint,
  }) async {
    _preflightSessionConfig(
      botProfile: botProfile,
      onToolCall: onToolCall,
      history: history,
      trimBudget: trimBudget,
      maxToolTurns: maxToolTurns,
      retryDeadline: retryDeadline,
      imageOptions: imageOptions,
    );
    ChatSession build({String? attachedReplyId}) => ChatSession._(
      backend: backend,
      botProfile: botProfile,
      onToolCall: onToolCall,
      history: history,
      trimBudget: trimBudget,
      maxToolTurns: maxToolTurns,
      retryDeadline: retryDeadline,
      imageOptions: imageOptions,
      checkpoint: checkpoint,
      now: null,
      newUuid: null,
      delay: null,
      random: null,
      processImage: null,
      preflighted: true,
      attachedReplyId: attachedReplyId,
    );

    if (backend is! DurableChatBackend) {
      return build();
    }
    final messages = history?.messages ?? const <Message>[];
    final candidate = messages.isEmpty ? null : messages.last;
    if (candidate == null ||
        candidate.role != MessageRole.assistant ||
        candidate.status != MessageStatus.streaming) {
      return build();
    }
    // One atomic attempt: no separate liveness probe, so there is no
    // "checked, then attached" race. A throw propagates untouched.
    final attached = await backend.attachReply(candidate.id);
    if (attached == null) {
      return build();
    }
    final session = build(attachedReplyId: candidate.id);
    session._startAttachedReply(candidate, attached);
    return session;
  }

  ChatSession._({
    required ChatBackend backend,
    required BotProfile botProfile,
    required this._onToolCall,
    required Conversation? history,
    required this._trimBudget,
    required this._maxToolTurns,
    required this._retryDeadline,
    required this._imageOptions,
    required this._checkpoint,
    required DateTime Function()? now,
    required String Function()? newUuid,
    required Future<void> Function(Duration duration)? delay,
    required double Function()? random,
    required Future<Uint8List> Function(
      Uint8List raw,
      ImageSendOptions options,
    )?
    processImage,
    bool preflighted = false,
    String? attachedReplyId,
  }) : _backend = backend,
       _durableBackend = backend is DurableChatBackend ? backend : null,
       _now = now ?? DateTime.now,
       _newUuid = newUuid ?? const Uuid().v4,
       _delayOverride = delay,
       _random = random ?? Random().nextDouble,
       _processImage = processImage ?? processChatImage,
       _botProfile = botProfile {
    if (!preflighted) {
      // The one shared validation — `open()` has already run it before
      // touching the backend, so it never runs twice for the same session.
      _preflightSessionConfig(
        botProfile: botProfile,
        onToolCall: _onToolCall,
        history: history,
        trimBudget: _trimBudget,
        maxToolTurns: _maxToolTurns,
        retryDeadline: _retryDeadline,
        imageOptions: _imageOptions,
      );
    }

    // Open normalisation (CONTEXT §Message Status): no in-flight status
    // survives a restart — EXCEPT the one durable reply `open()` has just
    // attached to: it is provably still running, so it stays `streaming` and
    // the user Message right before it becomes `sent` (its send provably
    // reached the provider). Then every V1_SPEC §5 invariant is checked;
    // invalid history is never repaired beyond this normative normalisation.
    final source = history?.messages ?? const <Message>[];
    final attachedIndex = attachedReplyId == null
        ? -1
        : source.indexWhere((message) => message.id == attachedReplyId);
    for (var i = 0; i < source.length; i++) {
      final message = source[i];
      if (i == attachedIndex) {
        _messages.add(message);
        continue;
      }
      if (attachedIndex > 0 &&
          i == attachedIndex - 1 &&
          message.role == MessageRole.user &&
          message.status == MessageStatus.sending) {
        _messages.add(message.copyWith(status: MessageStatus.sent));
        continue;
      }
      _messages.add(switch ((message.role, message.status)) {
        (MessageRole.user, MessageStatus.sending) => message.copyWith(
          status: MessageStatus.failed,
        ),
        (MessageRole.assistant, MessageStatus.streaming) => message.copyWith(
          status: MessageStatus.interrupted,
        ),
        _ => message,
      });
    }
    checkConversationInvariants(Conversation(messages: _messages));
  }

  // --- configuration --------------------------------------------------------

  final ChatBackend _backend;

  /// The same backend when it declares the durable capability — the ONLY
  /// switch between the v1 connection-bound path and the durable
  /// start/attach/detach/remote-cancel path. `null` for a legacy backend.
  final DurableChatBackend? _durableBackend;

  final OnToolCall? _onToolCall;
  final int? _trimBudget;
  final int _maxToolTurns;
  final Duration _retryDeadline;
  final ImageSendOptions _imageOptions;
  final ConversationCheckpoint? _checkpoint;

  // Deterministic seams (test-only injection through [chatSessionForTesting];
  // never public API — V1_SPEC §3).
  final DateTime Function() _now;
  final String Function() _newUuid;

  /// Test-only delay override. In production a backoff wait is a real
  /// [Timer] owned by [_waitBackoff], so cancel/terminal/dispose can stop it
  /// immediately instead of letting a Retry-After sleep run out.
  final Future<void> Function(Duration duration)? _delayOverride;
  final double Function() _random;
  final Future<Uint8List> Function(Uint8List raw, ImageSendOptions options)
  _processImage;

  BotProfile _botProfile;

  /// The bot the NEXT command runs against. The setter validates the new
  /// profile first (tool guards, [ArgumentError]) and only then replaces the
  /// old one; a reply in flight keeps the profile snapshotted at its send.
  BotProfile get botProfile => _botProfile;
  set botProfile(BotProfile value) {
    _validateProfile(value);
    _botProfile = value;
  }

  // --- state ----------------------------------------------------------------

  final List<Message> _messages = [];
  final StreamController<ConversationState> _states =
      StreamController<ConversationState>.broadcast();
  final StreamController<String> _tokens = StreamController<String>.broadcast();
  ConversationState _state = const ConversationState.idle();

  /// The recovery target of the current `Failed` (V1_SPEC §7), set at every
  /// terminal (default [ChatErrorRecovery.none]) and read only through
  /// [errorRecoveryForWidgets]. Meaningful only while [state] is `Failed`.
  ChatErrorRecovery _recovery = ChatErrorRecovery.none;
  String? _recoveryMessageId;

  bool _disposed = false;

  /// The durable remote cancel is a once-per-session command: an explicit
  /// `cancel()` fires it exactly once, `dispose()` never does.
  bool _remoteCancelSent = false;

  /// The private command gate (V1_SPEC §4): held from a command's synchronous
  /// start until the reply's terminal (or its no-op/rejection). While held,
  /// another command is a no-op — never queued. Not a public phase.
  bool _busy = false;

  /// The command epoch: bumped on every terminal, cancel and dispose. Every
  /// suspended continuation (preprocessing, checkpoint, backend events, tool
  /// resolver, backoff waits) re-checks it and abandons itself when stale —
  /// no late completion may dispatch or mutate a terminal/disposed session.
  int _epoch = 0;

  _Reply? _reply;
  StreamIterator<BackendEvent>? _activeEvents;

  /// The one cached teardown Future: a repeated dispose() awaits the SAME
  /// teardown, never a second one.
  Future<void>? _teardownFuture;

  /// Every initiated wire-cancel (subscription cancellation), chained: the
  /// teardown completes only after the LAST of them has actually finished —
  /// including one started earlier by a terminal whose transport onCancel is
  /// asynchronous. Errors are swallowed here; teardown defects never
  /// surface.
  Future<void>? _wireCancellation;

  /// The currently awaited preprocessing/checkpoint operation, tracked so
  /// dispose() completes only after it has settled. Never the app's tool
  /// resolver.
  Future<void>? _pendingSettlement;

  // The one active silent-retry backoff wait: cancel(), any terminal and
  // dispose() stop it immediately; the epoch check after the wait then drops
  // the retry, so no new backend attempt is dispatched.
  Timer? _backoffTimer;
  Completer<void>? _backoffWaiter;

  // Token Stream throttling (emissions only; the accumulator is the assistant
  // Message itself and is always complete).
  Timer? _throttleTimer;
  String? _pendingTokenText;
  DateTime? _lastTokenEmitAt;

  /// Marks the zone a checkpoint callback runs in, so a reentrant command on
  /// the same session is detected exactly (an unrelated command racing the
  /// awaited checkpoint stays an ordinary busy no-op).
  static final Object _checkpointZoneKey = Object();

  // --- observation (V1_SPEC §3) ----------------------------------------------

  /// Coarse phase changes (broadcast). Fast token text is deliberately not
  /// on this stream.
  Stream<ConversationState> get states => _states.stream;

  /// The current phase, synchronously.
  ConversationState get state => _state;

  /// The accumulated visible bot text of the reply in flight, throttled to
  /// ~15 emissions/s. Provider-opaque parts never appear here.
  Stream<String> get tokens => _tokens.stream;

  /// The current Conversation value — serialize & store (ADR 0002).
  Conversation get snapshot =>
      Conversation(messages: List<Message>.unmodifiable(List.of(_messages)));

  // --- commands (V1_SPEC §3) --------------------------------------------------

  /// Sends one user Message (fresh Idempotency-Key). No-op when [text] is
  /// empty AND [images] is empty; [images] are raw picker bytes — the Core
  /// resizes off the UI isolate. The Future completes at the no-op/rejection
  /// or dispatch decision — never waits for the provider's terminal response.
  Future<void> send(String text, {List<Uint8List> images = const []}) async {
    await _send(text, images);
  }

  /// Re-runs the last reply (CONTEXT §Regenerate/Edit): an `interrupted`
  /// reply, or the final `sent` user Message with no assistant after it,
  /// first recovers under the persisted key (fresh key only as the one
  /// explicit `409`/`410` fallback); a `complete` reply starts a fresh
  /// billable Attempt immediately.
  Future<void> regenerate() async {
    await _regenerate();
  }

  /// Re-sends a `failed` **user** Message — only while it is the **last**
  /// Message of the conversation. An older `failed` user Message with later
  /// history after it is a full no-op: resend never truncates history,
  /// changes state, mints a key or calls the checkpoint/backend. The legal
  /// case runs under the Message's persisted `attemptKey` (the safe side of
  /// the Retry Boundary); an explicit `409`/`410` gets its single automatic
  /// fresh-key re-run.
  Future<void> resend(String messageId) async {
    await _resend(messageId);
  }

  /// Truncates the conversation after the user Message [messageId], replaces
  /// its text parts with [newText] (processed ImageParts are kept untouched —
  /// no re-resize) and re-sends under a fresh key. No confirmation UI: loss
  /// protection is the app's copy-before-truncate.
  Future<void> editAndResend(String messageId, String newText) async {
    await _editAndResend(messageId, newText);
  }

  /// Stop generating: wire-cancel, `Cancelled` terminal, partial kept. Active
  /// in public `Sending` (its awaited checkpoint included), `AwaitingTool`
  /// and `Streaming`; a no-op elsewhere — Done wins the race.
  void cancel() {
    _throwIfDisposed('cancel');
    _throwIfCheckpointReentrant('cancel');
    final reply = _reply;
    if (reply == null ||
        switch (_state) {
          Sending() || AwaitingTool() || Streaming() => false,
          _ => true,
        }) {
      _debugNoOp('cancel', 'no reply in flight');
      return;
    }
    // The user keeps the committed turn: a first-leg user Message still
    // `sending` becomes `sent`, even if its checkpoint is pending. A
    // pre-Delta cancel has nothing visible to keep: a technical opaque-only
    // assistant of this command is removed, never left interrupted; a real
    // partial (recovery or visible text) is kept as usual.
    _markAnchorUserSent(reply);
    if (!_removeTechnicalAssistant(reply)) {
      _interruptAssistant(reply);
    }
    // Durable: the ONE explicit remote cancel of this reply, fired before the
    // terminal detaches the listener. A legacy backend keeps the plain
    // wire-cancel of `_terminal`.
    _requestRemoteCancel(reply);
    _terminal(const ConversationState.cancelled());
  }

  /// Fires the durable remote cancel at most once per session, and only when
  /// this reply actually reached the backend (a `startReply` happened or an
  /// `attachReply` succeeded). Uses the retained `replyId`, so a removed
  /// technical assistant Message does not lose the remote reply. The Future is
  /// tracked by the teardown chain (errors swallowed there) — a failing remote
  /// cancel never changes the local terminal and never goes unhandled.
  void _requestRemoteCancel(_Reply reply) {
    final durable = _durableBackend;
    final replyId = reply.durableReplyId;
    if (durable == null ||
        replyId == null ||
        !reply.remoteStarted ||
        _remoteCancelSent) {
      return;
    }
    _remoteCancelSent = true;
    _trackWireCancel(durable.cancelReply(replyId));
  }

  /// Frees the session. The returned Future completes only when the
  /// resources are actually freed: the backend subscription cancellation
  /// (the wire-cancel) has finished, the in-flight preprocessing/checkpoint
  /// work has settled (its result is ignored and can no longer dispatch or
  /// mutate), and both public streams are closed. The app's tool resolver is
  /// deliberately NOT awaited — its side effect is not cancellable and its
  /// late result is ignored. Idempotent: a repeated call returns (and
  /// awaits) the same teardown Future.
  Future<void> dispose() {
    final existing = _teardownFuture;
    if (existing != null) {
      return existing;
    }
    _throwIfCheckpointReentrant('dispose');
    final teardown = _teardown();
    _teardownFuture = teardown;
    return teardown;
  }

  Future<void> _teardown() async {
    // The synchronous prefix invalidates everything first: no late
    // completion observed below may dispatch or mutate.
    _disposed = true;
    _epoch++;
    _reply = null;
    _busy = false;
    _cancelBackoff();
    _throttleTimer?.cancel();
    _throttleTimer = null;
    _pendingTokenText = null;
    final events = _activeEvents;
    _activeEvents = null;
    if (events != null) {
      _trackWireCancel(events.cancel());
    }
    // Awaited: EVERY initiated wire-cancel — the one above and any started
    // earlier by a terminal (`_activeEvents == null` by then) whose
    // asynchronous transport onCancel is still pending — must have finished
    // before dispose() reports the session freed. Errors were swallowed at
    // the tracking site.
    final wireCancellation = _wireCancellation;
    if (wireCancellation != null) {
      await wireCancellation;
    }
    // Await the settlement of the in-flight preprocessing/checkpoint job,
    // then yield once so its (epoch-guarded) continuation has run and
    // provably ignored its result.
    final pending = _pendingSettlement;
    if (pending != null) {
      await pending;
      await Future<void>.delayed(Duration.zero);
    }
    await _states.close();
    await _tokens.close();
  }

  // --- send pipeline ----------------------------------------------------------

  Future<ChatCommandDisposition> _send(
    String text,
    List<Uint8List> images,
  ) async {
    _throwIfDisposed('send');
    _throwIfCheckpointReentrant('send');
    if (!_atRest) {
      _debugNoOp('send', 'a reply or preprocessing is in flight');
      return ChatCommandDisposition.noOp;
    }
    if (text.isEmpty && images.isEmpty) {
      _debugNoOp('send', 'nothing to send');
      return ChatCommandDisposition.noOp;
    }
    // The private gate is acquired synchronously, before the first await:
    // two sends racing an async resize produce one preprocessing job.
    _busy = true;
    final epoch = _epoch;
    // The logical reply's snapshots are taken at the command, BEFORE any
    // asynchronous preprocessing: the frozen Bot Profile serves the payload
    // probe and every leg of the reply (a `botProfile =` during the resize
    // affects only the next command), and the retry deadline clock starts
    // here — image preprocessing time counts against it.
    final profile = _botProfile;
    final startedAt = _now();

    // 1. Validate/count/resize images and check the prospective payload —
    // all before any Message/key/checkpoint/backend work (V1_SPEC §4).
    if (images.length > _imageOptions.maxImagesPerMessage) {
      // Over the session cap: internally rejected, no public phase change.
      _busy = false;
      _debugNoOp('send', 'image count exceeds maxImagesPerMessage');
      return ChatCommandDisposition.rejected;
    }
    final processed = <Uint8List>[];
    for (final raw in images) {
      final Uint8List jpeg;
      try {
        final settling = _processImage(raw, _imageOptions);
        _registerSettlement(settling);
        jpeg = await settling;
      } catch (_) {
        if (_epoch != epoch || _disposed) {
          _releaseGateIfCurrent(epoch);
          return ChatCommandDisposition.rejected;
        }
        // Malformed input: no Message/key/checkpoint/backend; surfaced as
        // data with the logs-only marker (the raw error is dropped).
        _busy = false;
        _terminal(
          const ConversationState.failed(
            FailureCause.upstream,
            FailurePhase.sending,
            developerDetail: _malformedImageDetail,
          ),
        );
        return ChatCommandDisposition.rejected;
      }
      if (_epoch != epoch || _disposed) {
        // A dispose during preprocessing makes the result stale: no dispatch,
        // no mutation.
        _releaseGateIfCurrent(epoch);
        return ChatCommandDisposition.rejected;
      }
      processed.add(jpeg);
    }

    final parts = <ContentPart>[
      if (text.isNotEmpty) ContentPart.text(text),
      for (final jpeg in processed) ContentPart.image(jpeg),
    ];

    if (processed.isNotEmpty && _payloadTooLarge(parts, profile)) {
      _busy = false;
      _terminal(
        const ConversationState.failed(
          FailureCause.contextTooLong,
          FailurePhase.sending,
          developerDetail: _payloadTooLargeDetail,
        ),
      );
      return ChatCommandDisposition.rejected;
    }

    // 2. Create the user Message + fresh attemptKey (ADR 0004), then the
    // shared Sending → assemble → checkpoint → dispatch tail.
    final message = Message(
      id: _newUuid(),
      role: MessageRole.user,
      parts: parts,
      status: MessageStatus.sending,
      attemptKey: _newUuid(),
      createdAt: _now(),
    );
    _messages.add(message);
    return _beginAttempt(
      _Reply(
        epoch: epoch,
        profile: profile,
        startedAt: startedAt,
        anchorUserId: message.id,
        freshKeyFallbackArmed: false,
      ),
    );
  }

  // --- recovery commands --------------------------------------------------------

  Future<ChatCommandDisposition> _regenerate() async {
    _throwIfDisposed('regenerate');
    _throwIfCheckpointReentrant('regenerate');
    if (!_atRest) {
      _debugNoOp('regenerate', 'a reply or preprocessing is in flight');
      return ChatCommandDisposition.noOp;
    }
    if (_messages.isEmpty) {
      _debugNoOp('regenerate', 'empty conversation');
      return ChatCommandDisposition.noOp;
    }
    final last = _messages.last;

    if (last.role == MessageRole.assistant &&
        last.status == MessageStatus.interrupted) {
      // Recover-before-rebill: repeat the interrupted leg under its
      // persisted key; only an explicit 409/410 falls back to a fresh key.
      _busy = true;
      _updateMessage(
        last.id,
        (message) => message.copyWith(status: MessageStatus.streaming),
      );
      return _beginAttempt(
        _Reply(
          epoch: _epoch,
          profile: _botProfile,
          startedAt: _now(),
          assistantId: last.id,
          assistantPreexisting: true,
          freshKeyFallbackArmed: true,
          legBaselineParts: _legBaseline(last),
          needsLegReset: true,
          // The loop guard survives a restart: every completed tool exchange
          // of the recovered logical reply counts as a used billable tool
          // leg; an unmatched trailing toolCall was never executed and does
          // not count.
          toolTurnsUsed: last.parts.whereType<ToolResultPart>().length,
        ),
      );
    }

    if (last.role == MessageRole.assistant &&
        last.status == MessageStatus.complete) {
      // A complete reply regenerates as a new billable Attempt immediately:
      // truncate the reply away and re-run from its user Message under a
      // fresh key (truncate-and-resend, no confirmation — CONTEXT
      // §Regenerate/Edit).
      final anchorIndex = _messages.lastIndexWhere(
        (message) => message.role == MessageRole.user,
        _messages.length - 2,
      );
      if (anchorIndex < 0) {
        _debugNoOp('regenerate', 'no user Message to regenerate from');
        return ChatCommandDisposition.noOp;
      }
      _busy = true;
      final epoch = _epoch;
      _messages.removeLast();
      final anchor = _messages[anchorIndex];
      _updateMessage(
        anchor.id,
        (message) => message.copyWith(
          status: MessageStatus.sending,
          attemptKey: _newUuid(),
        ),
      );
      return _beginAttempt(
        _Reply(
          epoch: epoch,
          profile: _botProfile,
          startedAt: _now(),
          anchorUserId: anchor.id,
          freshKeyFallbackArmed: false,
        ),
      );
    }

    if (last.role == MessageRole.user && last.status == MessageStatus.sent) {
      // The final `sent` user Message with no assistant after it: pre-token
      // recovery under that Message's persisted key.
      _busy = true;
      _updateMessage(
        last.id,
        (message) => message.copyWith(status: MessageStatus.sending),
      );
      return _beginAttempt(
        _Reply(
          epoch: _epoch,
          profile: _botProfile,
          startedAt: _now(),
          anchorUserId: last.id,
          freshKeyFallbackArmed: true,
        ),
      );
    }

    _debugNoOp('regenerate', 'nothing to regenerate');
    return ChatCommandDisposition.noOp;
  }

  Future<ChatCommandDisposition> _resend(String messageId) async {
    _throwIfDisposed('resend');
    _throwIfCheckpointReentrant('resend');
    if (!_atRest) {
      _debugNoOp('resend', 'a reply or preprocessing is in flight');
      return ChatCommandDisposition.noOp;
    }
    final index = _messages.indexWhere((message) => message.id == messageId);
    if (index < 0 ||
        _messages[index].role != MessageRole.user ||
        _messages[index].status != MessageStatus.failed) {
      _debugNoOp('resend', 'not a failed user Message');
      return ChatCommandDisposition.noOp;
    }
    if (index != _messages.length - 1) {
      // Confirmed product rule (V1_SPEC §3/§4, ADR 0004 amendment): resend
      // applies only while the failed user Message is the LAST Message of
      // the conversation. An older failed user with later history is a full
      // no-op — resend never truncates, changes state, mints a key or calls
      // checkpoint/backend; restarting from an earlier point is the explicit
      // truncate-and-resend mechanism (editAndResend).
      _debugNoOp('resend', 'not the last Message of the conversation');
      return ChatCommandDisposition.noOp;
    }
    _busy = true;
    // The SAME persisted attemptKey (the safe side of the Retry Boundary): a
    // resent Message that did quietly arrive is not processed twice.
    _updateMessage(
      messageId,
      (message) => message.copyWith(status: MessageStatus.sending),
    );
    return _beginAttempt(
      _Reply(
        epoch: _epoch,
        profile: _botProfile,
        startedAt: _now(),
        anchorUserId: messageId,
        freshKeyFallbackArmed: true,
      ),
    );
  }

  Future<ChatCommandDisposition> _editAndResend(
    String messageId,
    String newText,
  ) async {
    _throwIfDisposed('editAndResend');
    _throwIfCheckpointReentrant('editAndResend');
    if (!_atRest) {
      _debugNoOp('editAndResend', 'a reply or preprocessing is in flight');
      return ChatCommandDisposition.noOp;
    }
    final index = _messages.indexWhere((message) => message.id == messageId);
    if (index < 0 || _messages[index].role != MessageRole.user) {
      _debugNoOp('editAndResend', 'not a user Message');
      return ChatCommandDisposition.noOp;
    }
    final images = [
      for (final part in _messages[index].parts)
        if (part is ImagePart) part,
    ];
    if (newText.isEmpty && images.isEmpty) {
      _debugNoOp('editAndResend', 'empty text and no kept images');
      return ChatCommandDisposition.noOp;
    }
    _busy = true;
    final epoch = _epoch;
    // Truncate after the edited Message; replace its text parts, keep the
    // already-processed ImageParts untouched (no re-resize); fresh key.
    _messages.removeRange(index + 1, _messages.length);
    _updateMessage(
      messageId,
      (message) => message.copyWith(
        parts: <ContentPart>[
          if (newText.isNotEmpty) ContentPart.text(newText),
          ...images,
        ],
        status: MessageStatus.sending,
        attemptKey: _newUuid(),
      ),
    );
    return _beginAttempt(
      _Reply(
        epoch: epoch,
        profile: _botProfile,
        startedAt: _now(),
        anchorUserId: messageId,
        freshKeyFallbackArmed: false,
      ),
    );
  }

  // --- the shared attempt pipeline ---------------------------------------------

  /// Steps 3–6 of the first-leg sequence (V1_SPEC §4): enter public
  /// `Sending`, assemble/trim, await the checkpoint, dispatch the frozen
  /// request, and drive the reply in the background. The command Future ends
  /// at the dispatch decision.
  Future<ChatCommandDisposition> _beginAttempt(_Reply reply) async {
    _reply = reply;
    _resetTokenStream();
    _setState(const ConversationState.sending());

    final assembled = assembleContext(
      history: _dispatchHistory(reply),
      profile: reply.profile,
      trimBudget: _trimBudget,
    );
    if (assembled.contextTooLong) {
      _failOperational(reply, FailureCause.contextTooLong, detail: null);
      return ChatCommandDisposition.rejected;
    }
    reply.request = ChatRequest(
      botId: reply.profile.id,
      system: reply.profile.systemPrompt,
      messages: assembled.messages,
      tools: reply.profile.tools,
      idempotencyKey: _anchorKey(reply),
    );
    _createEarlyDurableAssistant(reply);
    if (!await _checkpointBeforeDispatch(reply)) {
      return ChatCommandDisposition.rejected;
    }
    unawaited(_driveReply(reply));
    return ChatCommandDisposition.accepted;
  }

  /// The durable reply identity (`replyId`): the assistant Message is created
  /// EMPTY and `streaming` right after the request is frozen and BEFORE the
  /// checkpoint that precedes the first billable dispatch, so the app owns a
  /// stable id (and this leg's `attemptKey`) in its own storage before any
  /// provider work. Legacy backends keep creating the assistant at the first
  /// content event.
  ///
  /// The frozen request was built above, from the anchor Message's key and
  /// without this assistant; with `legBaselineParts == 0` the reply's own
  /// assistant is excluded from `_dispatchHistory`, so the provider-effective
  /// first leg stays byte-identical to v1.
  void _createEarlyDurableAssistant(_Reply reply) {
    if (_durableBackend == null || reply.assistantId != null) {
      return;
    }
    final message = Message(
      id: _newUuid(),
      role: MessageRole.assistant,
      parts: const [],
      status: MessageStatus.streaming,
      attemptKey: reply.request!.idempotencyKey,
      createdAt: _now(),
    );
    _messages.add(message);
    reply.assistantId = message.id;
    reply.durableReplyId = message.id;
    reply.legBaselineParts = 0;
    reply.earlyAssistant = true;
  }

  /// Resumes the reply `open()` attached to: no assembly, no checkpoint, no
  /// key minting and no provider dispatch — the already-obtained stream (which
  /// replays the current leg from its beginning) is simply consumed.
  void _startAttachedReply(Message assistant, Stream<BackendEvent> attached) {
    _busy = true;
    final reply = _Reply(
      epoch: _epoch,
      profile: _botProfile,
      startedAt: _now(),
      assistantId: assistant.id,
      assistantPreexisting: true,
      freshKeyFallbackArmed: false,
      legBaselineParts: _legBaseline(assistant),
      needsLegReset: true,
      // The loop guard survives the restart exactly as in `regenerate`: every
      // completed tool exchange counts as a used billable tool leg.
      toolTurnsUsed: assistant.parts.whereType<ToolResultPart>().length,
    );
    reply.durableReplyId = assistant.id;
    reply.remoteStarted = true;
    reply.attachedStream = attached;
    _reply = reply;
    _resetTokenStream();
    _setState(const ConversationState.sending());
    unawaited(_driveReply(reply));
  }

  /// Runs legs until the reply lands on a terminal. Every leg owns its own
  /// silent-retry loop; a `tool_call` terminal starts the next leg.
  Future<void> _driveReply(_Reply reply) async {
    while (true) {
      final outcome = await _runLegWithRetries(reply);
      if (_epoch != reply.epoch) {
        return;
      }
      switch (outcome) {
        case _LegHandled():
          return;
        case _LegToolCall(:final call):
          if (!await _handleToolCall(reply, call)) {
            return;
          }
      }
    }
  }

  /// One leg: dispatch the frozen request, consume its events; pre-token
  /// `rate|overloaded|network` retry silently under the same key within the
  /// wall-clock deadline (checked only at decision points — a live stream is
  /// never cut); an armed explicit `409`/`410` performs its one checkpointed
  /// fresh-key fallback.
  Future<_LegOutcome> _runLegWithRetries(_Reply reply) async {
    var attempt = 0;
    while (true) {
      final outcome = await _consumeOneRequest(reply);
      if (_epoch != reply.epoch) {
        return const _LegHandled();
      }
      switch (outcome) {
        case _RequestHandled():
          return const _LegHandled();
        case _RequestToolCall(:final call):
          return _LegToolCall(call);
        case _RequestFallbackKey():
          // Exactly one automatic fresh-key re-run per explicit command
          // (V1_SPEC §6): update the anchor's persisted key, checkpoint,
          // dispatch. Disarmed by the request that consumed it.
          final freshKey = _newUuid();
          _updateAnchorKey(reply, freshKey);
          reply.request = reply.request!.copyWith(idempotencyKey: freshKey);
          if (!await _checkpointBeforeDispatch(reply)) {
            return const _LegHandled();
          }
          continue;
        case _RequestRetry(:final cause, :final detail, :final retryAfter):
          if (!reply.hasFrozenRequest) {
            // The attach path has no frozen request: repeating this leg would
            // mean assembling and dispatching a NEW provider call, which
            // recovery must never do. Any retryable outcome of the attached
            // leg is therefore terminal for this session; the user recovers
            // with an explicit command.
            _failOperational(reply, cause, detail: detail);
            return const _LegHandled();
          }
          // A silent retry never gets a fresh-key fallback.
          reply.freshKeyFallbackArmed = false;
          attempt++;
          // Decision point 1: before the backoff wait.
          final remaining = _retryDeadline - _elapsed(reply);
          if (remaining <= Duration.zero) {
            _failOperational(reply, cause, detail: detail);
            return const _LegHandled();
          }
          Duration wait;
          if (retryAfter != null) {
            // Retry-After is honoured only if it fully fits the remaining
            // deadline.
            if (retryAfter > remaining) {
              _failOperational(reply, cause, detail: detail);
              return const _LegHandled();
            }
            wait = retryAfter;
          } else {
            wait = _jitteredBackoff(attempt);
            if (wait > remaining) {
              wait = remaining;
            }
          }
          await _waitBackoff(wait);
          if (_epoch != reply.epoch) {
            return const _LegHandled();
          }
          // Decision point 2: before starting the next attempt.
          if (_elapsed(reply) >= _retryDeadline) {
            _failOperational(reply, cause, detail: detail);
            return const _LegHandled();
          }
          // The retry re-arms the leg reset so a pre-token partial (opaque
          // provider state) of the failed attempt is replaced, then re-sends
          // the SAME frozen request under the SAME key.
          reply.needsLegReset = true;
          continue;
      }
    }
  }

  /// Dispatches [reply.request] once and consumes its event stream. Never
  /// throws; every exit is an [_RequestOutcome], with terminals already
  /// applied.
  Future<_RequestOutcome> _consumeOneRequest(_Reply reply) async {
    final events = StreamIterator<BackendEvent>(_dispatchStream(reply));
    _activeEvents = events;
    try {
      while (true) {
        final bool hasNext;
        try {
          hasNext = await events.moveNext();
        } catch (_) {
          // A backend stream must never throw (V1_SPEC §8); treat a contract
          // violation as one upstream failure.
          if (_epoch != reply.epoch) {
            return const _RequestHandled();
          }
          _failOperational(
            reply,
            FailureCause.upstream,
            detail: 'backend-threw',
          );
          return const _RequestHandled();
        }
        if (_epoch != reply.epoch) {
          return const _RequestHandled();
        }
        if (!hasNext) {
          // EOF without a terminal event — a backend contract violation,
          // surfaced defensively as upstream.
          _failOperational(
            reply,
            FailureCause.upstream,
            detail: 'missing-terminal',
          );
          return const _RequestHandled();
        }
        switch (events.current) {
          case Accepted():
            _markAnchorUserSent(reply);
          case Delta(:final text):
            _applyLegResetIfNeeded(reply);
            _ensureAssistant(reply);
            reply.tokenSeenThisLeg = true;
            _markAnchorUserSent(reply);
            _appendAssistantText(reply, text);
            _setState(const ConversationState.streaming());
            _emitTokensThrottled(_assistantVisibleText(reply));
          case ProviderStateEvent(:final part):
            _applyLegResetIfNeeded(reply);
            _ensureAssistant(reply);
            _appendAssistantPart(reply, part);
          case ToolCallEvent(:final call, :final usage):
            _applyLegResetIfNeeded(reply);
            _ensureAssistant(reply);
            _markAnchorUserSent(reply);
            if (usage != null) {
              reply.legUsages.add(usage);
            }
            return _RequestToolCall(call);
          case DoneEvent(:final usage):
            _applyLegResetIfNeeded(reply);
            _markAnchorUserSent(reply);
            _completeReply(reply, usage);
            return const _RequestHandled();
          case ErrorEvent(:final cause, :final detail, :final retryAfter):
            if (reply.tokenSeenThisLeg) {
              // Past the Retry Boundary (the first Delta of this leg): keep
              // the partial and normalise ANY cause to upstream — a break
              // after visible output is one thing to the user, whatever the
              // wire said. The original cause survives as a logs-only detail.
              _failOperational(
                reply,
                FailureCause.upstream,
                detail:
                    detail ??
                    (cause == FailureCause.upstream ? null : cause.name),
              );
              return const _RequestHandled();
            }
            if (cause == FailureCause.rate ||
                cause == FailureCause.overloaded ||
                cause == FailureCause.network) {
              return _RequestRetry(
                cause: cause,
                detail: detail,
                retryAfter: retryAfter,
              );
            }
            _failOperational(reply, cause, detail: detail);
            return const _RequestHandled();
          case ConflictEvent():
            assert(() {
              if (!reply.freshKeyFallbackArmed) {
                debugPrint(
                  'chat_ai: 409 Conflict inside a silent retry — the frozen '
                  'request cannot legally conflict (client bug)',
                );
              }
              return true;
            }());
            if (reply.freshKeyFallbackArmed && !reply.tokenSeenThisLeg) {
              reply.freshKeyFallbackArmed = false;
              return const _RequestFallbackKey();
            }
            _failOperational(reply, FailureCause.upstream, detail: 'conflict');
            return const _RequestHandled();
          case GoneEvent():
            if (reply.freshKeyFallbackArmed && !reply.tokenSeenThisLeg) {
              reply.freshKeyFallbackArmed = false;
              return const _RequestFallbackKey();
            }
            _failOperational(reply, FailureCause.upstream, detail: 'gone');
            return const _RequestHandled();
        }
      }
    } finally {
      if (identical(_activeEvents, events)) {
        _activeEvents = null;
      }
      // Always release the request's subscription: every return above is
      // either past the terminal event or abandoning the request. Tracked,
      // so dispose() waits for the transport teardown too.
      _trackWireCancel(events.cancel());
    }
  }

  /// The event source of one request: the attached stream `open()` already
  /// obtained (consumed once, no backend call), the durable `startReply` of
  /// this reply, or the legacy `send`.
  Stream<BackendEvent> _dispatchStream(_Reply reply) {
    final attached = reply.takeAttachedStream();
    if (attached != null) {
      return attached;
    }
    final durable = _durableBackend;
    if (durable == null) {
      return _backend.send(reply.request!);
    }
    final replyId = reply.assistantId!;
    reply.durableReplyId = replyId;
    reply.remoteStarted = true;
    return durable.startReply(replyId, reply.request!);
  }

  // --- Tool Use Cycle -------------------------------------------------------------

  /// Handles one `tool_call` terminal: appends the call part, runs the loop
  /// guard, resolves (or refuses) the call, appends the result, and prepares
  /// the next billable leg (fresh key → checkpoint → frozen request).
  /// Returns `true` when the next leg may dispatch.
  Future<bool> _handleToolCall(_Reply reply, ToolCall call) async {
    final assistantId = reply.assistantId!;
    final assistant = _messageById(assistantId);
    // At-least-once delivery: a recovery repeat re-emits the same call with
    // the same toolCallId — never append it twice.
    final alreadyCalled = assistant.parts.any(
      (part) => part is ToolCallPart && part.toolCallId == call.id,
    );
    if (!alreadyCalled) {
      _appendAssistantPart(
        reply,
        ContentPart.toolCall(call.id, call.name, call.args),
      );
    }

    // Loop guard (CONTEXT §Tool Use Cycle): cap the billable tool legs of one
    // reply; accumulated text is kept as usual.
    if (reply.toolTurnsUsed >= _maxToolTurns) {
      _interruptAssistant(reply);
      _terminal(
        const ConversationState.failed(
          FailureCause.toolLoopLimit,
          FailurePhase.streaming,
        ),
        recovery: ChatErrorRecovery.regenerate,
      );
      return false;
    }

    _setState(ConversationState.awaitingTool(call));

    final existingResult = assistant.parts.any(
      (part) => part is ToolResultPart && part.toolCallId == call.id,
    );
    if (!existingResult) {
      final ToolResult result;
      final declared = reply.profile.tools.where(
        (tool) => tool.name == call.name,
      );
      if (declared.isEmpty) {
        // Unknown tool: the resolver is never invoked; the bot decides how
        // to react to the sanitised error result.
        result = const ToolResult(content: _unknownToolResult, isError: true);
      } else if (!toolArgsMatchSchema(declared.single.parameters, call.args)) {
        result = const ToolResult(
          content: _invalidToolArgsResult,
          isError: true,
        );
      } else {
        ToolResult resolved;
        try {
          resolved = await _onToolCall!(call);
        } catch (_) {
          // A resolver exception is converted to a sanitised is_error result:
          // no exception text, stack trace or secret ever reaches the wire.
          resolved = const ToolResult(
            content: _toolExecutionFailedResult,
            isError: true,
          );
        }
        if (_epoch != reply.epoch) {
          // Late resolver completion after cancel/dispose/terminal: the
          // result is silently ignored (result-only — app side effects have
          // happened and cannot be undone).
          return false;
        }
        result = resolved;
      }
      _appendAssistantPart(
        reply,
        ContentPart.toolResult(call.id, result.content, result.isError),
      );
    }
    if (_epoch != reply.epoch) {
      return false;
    }

    // Next billable leg: fresh key on the assistant Message (ADR 0004),
    // re-entered `Sending`, assembled under the reply's frozen profile,
    // checkpointed, then dispatched.
    reply.toolTurnsUsed++;
    final legKey = _newUuid();
    _updateMessage(
      assistantId,
      (message) => message.copyWith(attemptKey: legKey),
    );
    _setState(const ConversationState.sending());
    // The new leg's baseline is set BEFORE assembly: the dispatched wire
    // shape is exactly the completed exchanges up to this point.
    reply.tokenSeenThisLeg = false;
    reply.needsLegReset = false;
    reply.legBaselineParts = _messageById(assistantId).parts.length;
    final assembled = assembleContext(
      history: _dispatchHistory(reply),
      profile: reply.profile,
      trimBudget: _trimBudget,
    );
    if (assembled.contextTooLong) {
      _failOperational(reply, FailureCause.contextTooLong, detail: null);
      return false;
    }
    reply.request = ChatRequest(
      botId: reply.profile.id,
      system: reply.profile.systemPrompt,
      messages: assembled.messages,
      tools: reply.profile.tools,
      idempotencyKey: legKey,
    );
    if (!await _checkpointBeforeDispatch(reply)) {
      return false;
    }
    return true;
  }

  // --- terminal & failure helpers ----------------------------------------------

  /// Applies a `done` terminal: the assistant Message becomes `complete`
  /// (created empty when the bot said nothing — a valid empty reply, not a
  /// Failure), leg usages are summed (`usageRaw` survives only a single-leg
  /// reply), and the reply lands on `Done`.
  void _completeReply(_Reply reply, Usage? doneUsage) {
    if (reply.assistantId == null) {
      final message = Message(
        id: _newUuid(),
        role: MessageRole.assistant,
        parts: const [],
        status: MessageStatus.complete,
        attemptKey: reply.request!.idempotencyKey,
        createdAt: _now(),
      );
      _messages.add(message);
      reply.assistantId = message.id;
    } else {
      _updateMessage(
        reply.assistantId!,
        (message) => message.copyWith(status: MessageStatus.complete),
      );
    }
    final Usage? usage;
    if (reply.toolTurnsUsed == 0) {
      usage = doneUsage; // single leg: keep usageRaw as delivered
    } else {
      final legs = [...reply.legUsages, ?doneUsage];
      usage = legs.isEmpty
          ? null
          : Usage(
              inputTokens: legs.fold(0, (sum, leg) => sum + leg.inputTokens),
              outputTokens: legs.fold(0, (sum, leg) => sum + leg.outputTokens),
            );
    }
    _terminal(ConversationState.done(usage: usage));
  }

  /// A terminal operational failure of the current leg, anchored per
  /// V1_SPEC §4: with an in-progress assistant Message the reply visibly
  /// began — the assistant becomes `interrupted` and the phase is
  /// `streaming`; before that the anchor user Message becomes `failed` and
  /// the phase is `sending`. A purely technical assistant — created by THIS
  /// command and holding only hidden provider-opaque parts, no visible
  /// output — is removed instead of being left behind as an interrupted
  /// reply the user never saw; a recovery's pre-existing partial is always
  /// kept.
  void _failOperational(_Reply reply, FailureCause cause, {String? detail}) {
    if (reply.assistantId != null && !_removeTechnicalAssistant(reply)) {
      _interruptAssistant(reply);
      // This reply's assistant Message actually became `interrupted`:
      // regenerate is the valid recovery of THIS reply.
      _terminal(
        ConversationState.failed(
          cause,
          FailurePhase.streaming,
          developerDetail: detail,
        ),
        recovery: ChatErrorRecovery.regenerate,
      );
      return;
    }
    _failAnchorUser(reply);
    // The anchor user Message actually became `failed` (and is the last
    // Message): resend targets exactly it. With no anchor (a first-leg
    // recovery whose technical assistant was removed) there is nothing valid
    // to resend — `none`.
    final anchorId = reply.anchorUserId;
    _terminal(
      ConversationState.failed(
        cause,
        FailurePhase.sending,
        developerDetail: detail,
      ),
      recovery: anchorId == null
          ? ChatErrorRecovery.none
          : ChatErrorRecovery.resend,
      recoveryMessageId: anchorId,
    );
  }

  void _terminal(
    ConversationState terminalState, {
    ChatErrorRecovery recovery = ChatErrorRecovery.none,
    String? recoveryMessageId,
  }) {
    _epoch++;
    _reply = null;
    _busy = false;
    // The error-row recovery target of this terminal (V1_SPEC §7): non-`none`
    // only when the failing site proved a valid recovery; every non-failure
    // terminal (and every pre-Message rejection, which keeps the default) is
    // `none`.
    _recovery = recovery;
    _recoveryMessageId = recoveryMessageId;
    _cancelBackoff();
    final events = _activeEvents;
    _activeEvents = null;
    if (events != null) {
      _trackWireCancel(events.cancel());
    }
    _flushTokens();
    _setState(terminalState);
  }

  /// Chains one initiated subscription cancellation into the teardown
  /// discipline (see [_wireCancellation]).
  void _trackWireCancel(Future<void> cancellation) {
    final tracked = cancellation.then<void>((_) {}, onError: (Object _) {});
    final previous = _wireCancellation;
    _wireCancellation = previous == null
        ? tracked
        : previous.then((_) => tracked);
  }

  // --- checkpoint -------------------------------------------------------------------

  /// Awaits the persistence checkpoint between Message/key mutation and the
  /// billable dispatch. Returns `false` when the dispatch must not happen —
  /// checkpoint failure (with its pinned terminal) or a cancel/dispose that
  /// won the race (their terminal decision beats any late callback outcome).
  Future<bool> _checkpointBeforeDispatch(_Reply reply) async {
    final checkpoint = _checkpoint;
    if (checkpoint == null) {
      return _epoch == reply.epoch && !_disposed;
    }
    try {
      final settling = runZoned(
        () => checkpoint(snapshot),
        zoneValues: {_checkpointZoneKey: this},
      );
      _registerSettlement(settling);
      await settling;
    } catch (_) {
      if (_epoch != reply.epoch || _disposed) {
        return false;
      }
      _failOperational(
        reply,
        FailureCause.upstream,
        detail: _checkpointFailedDetail,
      );
      return false;
    }
    return _epoch == reply.epoch && !_disposed;
  }

  // --- message mutation helpers ---------------------------------------------------

  Message _messageById(String id) =>
      _messages[_messages.indexWhere((message) => message.id == id)];

  void _updateMessage(String id, Message Function(Message message) change) {
    final index = _messages.indexWhere((message) => message.id == id);
    assert(index >= 0, 'unknown Message id "$id"');
    _messages[index] = change(_messages[index]);
  }

  /// `Accepted` (or any data event, defensively) makes the anchor user
  /// Message `sent`; so does an explicit cancel during public `Sending`.
  void _markAnchorUserSent(_Reply reply) {
    final anchorId = reply.anchorUserId;
    if (anchorId == null) {
      return;
    }
    final anchor = _messageById(anchorId);
    if (anchor.status == MessageStatus.sending) {
      _updateMessage(
        anchorId,
        (message) => message.copyWith(status: MessageStatus.sent),
      );
    }
  }

  void _failAnchorUser(_Reply reply) {
    final anchorId = reply.anchorUserId;
    if (anchorId == null) {
      return;
    }
    _updateMessage(
      anchorId,
      (message) => message.copyWith(status: MessageStatus.failed),
    );
  }

  /// The one technical-assistant rule (shared by pre-token failures and a
  /// cancel in `Sending`): an assistant created by THIS command that holds
  /// only hidden provider-opaque parts — no visible output — is removed from
  /// the snapshot instead of surviving as an interrupted reply the user
  /// never saw. A recovery's pre-existing partial, any visible text and
  /// completed tool exchanges are never touched. Returns whether the
  /// Message was removed.
  bool _removeTechnicalAssistant(_Reply reply) {
    final assistantId = reply.assistantId;
    if (assistantId == null) {
      return true; // nothing to keep
    }
    final assistant = _messageById(assistantId);
    final technical =
        !reply.assistantPreexisting &&
        assistant.parts.every((part) => part is ProviderOpaquePart);
    if (!technical) {
      return false;
    }
    _messages.removeWhere((message) => message.id == assistantId);
    reply.assistantId = null;
    return true;
  }

  void _interruptAssistant(_Reply reply) {
    final assistantId = reply.assistantId;
    if (assistantId == null) {
      return;
    }
    _updateMessage(assistantId, (message) {
      if (message.status != MessageStatus.streaming) {
        return message;
      }
      return message.copyWith(status: MessageStatus.interrupted);
    });
  }

  /// Moves the reply's persisted key to [freshKey] (the one automatic
  /// fresh-key fallback, V1_SPEC §6).
  ///
  /// On the FIRST leg of a durable reply the key is written to BOTH anchors —
  /// the early assistant and the anchor user Message — and the checkpoint that
  /// follows persists both before the re-dispatch: if the empty technical
  /// assistant is later removed (pre-token failure / cancel), the fresh key
  /// must survive on the user Message for the existing resend/recovery path.
  /// Later tool legs (and any pre-existing assistant) keep the current
  /// behaviour: the key lives on the assistant Message only.
  void _updateAnchorKey(_Reply reply, String freshKey) {
    final anchorUserId = reply.anchorUserId;
    if (reply.isEarlyDurableFirstLeg && anchorUserId != null) {
      _updateMessage(
        anchorUserId,
        (message) => message.copyWith(attemptKey: freshKey),
      );
      _updateMessage(
        reply.assistantId!,
        (message) => message.copyWith(attemptKey: freshKey),
      );
      return;
    }
    final id = reply.assistantId ?? anchorUserId;
    if (id == null) {
      return;
    }
    _updateMessage(id, (message) => message.copyWith(attemptKey: freshKey));
  }

  String _anchorKey(_Reply reply) {
    final id = reply.assistantId ?? reply.anchorUserId;
    return _messageById(id!).attemptKey!;
  }

  /// Creates the assistant Message of the reply at the first content event
  /// (delta, provider state or tool call): `streaming`, carrying the current
  /// leg's key (V1_SPEC §5: an assistant Message's `attemptKey` is its
  /// current/last leg's key).
  void _ensureAssistant(_Reply reply) {
    if (reply.assistantId != null) {
      return;
    }
    final message = Message(
      id: _newUuid(),
      role: MessageRole.assistant,
      parts: const [],
      status: MessageStatus.streaming,
      attemptKey: reply.request!.idempotencyKey,
      createdAt: _now(),
    );
    _messages.add(message);
    reply.assistantId = message.id;
    reply.legBaselineParts = 0;
  }

  /// The keep-partial-until-replaced rule of recovery and silent retry: the
  /// current leg's stale partial parts are dropped only when the re-run leg's
  /// first content event arrives, never on a failure.
  void _applyLegResetIfNeeded(_Reply reply) {
    if (!reply.needsLegReset) {
      return;
    }
    reply.needsLegReset = false;
    final assistantId = reply.assistantId;
    final baseline = reply.legBaselineParts;
    if (assistantId == null || baseline == null) {
      return;
    }
    _updateMessage(assistantId, (message) {
      if (message.parts.length <= baseline) {
        return message;
      }
      return message.copyWith(parts: message.parts.sublist(0, baseline));
    });
  }

  void _appendAssistantPart(_Reply reply, ContentPart part) {
    _updateMessage(
      reply.assistantId!,
      (message) => message.copyWith(parts: [...message.parts, part]),
    );
  }

  void _appendAssistantText(_Reply reply, String text) {
    _updateMessage(reply.assistantId!, (message) {
      final parts = List<ContentPart>.of(message.parts);
      final last = parts.isEmpty ? null : parts.last;
      if (last is TextPart) {
        parts[parts.length - 1] = ContentPart.text(last.text + text);
      } else {
        parts.add(ContentPart.text(text));
      }
      return message.copyWith(parts: parts);
    });
  }

  /// The visible text of the reply's assistant Message — all text parts, in
  /// order; provider-opaque parts never contribute.
  String _assistantVisibleText(_Reply reply) {
    final assistantId = reply.assistantId;
    if (assistantId == null) {
      return '';
    }
    final buffer = StringBuffer();
    for (final part in _messageById(assistantId).parts) {
      if (part is TextPart) {
        buffer.write(part.text);
      }
    }
    return buffer.toString();
  }

  /// The index right after the last complete tool exchange: everything after
  /// it is the interrupted leg's partial output, replaced when a recovery
  /// re-run delivers that leg again.
  static int _legBaseline(Message assistant) {
    var baseline = 0;
    for (var i = 0; i < assistant.parts.length; i++) {
      if (assistant.parts[i] is ToolResultPart) {
        baseline = i + 1;
      }
    }
    return baseline;
  }

  // --- token stream ------------------------------------------------------------------

  void _resetTokenStream() {
    _throttleTimer?.cancel();
    _throttleTimer = null;
    _pendingTokenText = null;
    _lastTokenEmitAt = null;
  }

  void _emitTokensThrottled(String text) {
    _pendingTokenText = text;
    if (_throttleTimer != null) {
      return; // an emission is already scheduled; it picks up the latest text
    }
    final now = _now();
    final lastEmitAt = _lastTokenEmitAt;
    final sinceLast = lastEmitAt == null ? null : now.difference(lastEmitAt);
    if (sinceLast == null || sinceLast >= _tokenThrottle) {
      _emitPendingTokens();
      return;
    }
    _throttleTimer = Timer(_tokenThrottle - sinceLast, () {
      _throttleTimer = null;
      _emitPendingTokens();
    });
  }

  void _emitPendingTokens() {
    final text = _pendingTokenText;
    _pendingTokenText = null;
    if (text == null || _tokens.isClosed) {
      return;
    }
    _lastTokenEmitAt = _now();
    _tokens.add(text);
  }

  /// A terminal always flushes the complete accumulated text — whatever is
  /// kept on a cancel or a break is the full accumulator, never the last
  /// throttled emission.
  void _flushTokens() {
    _throttleTimer?.cancel();
    _throttleTimer = null;
    _emitPendingTokens();
  }

  // --- misc helpers -------------------------------------------------------------------

  bool get _atRest =>
      !_busy &&
      switch (_state) {
        Idle() || Done() || Failed() || Cancelled() => true,
        _ => false,
      };

  void _setState(ConversationState next) {
    if (next == _state) {
      return;
    }
    _state = next;
    if (!_states.isClosed) {
      _states.add(next);
    }
  }

  Duration _elapsed(_Reply reply) => _now().difference(reply.startedAt);

  /// One cancellable backoff wait. Production: a plain [Timer] stopped by
  /// [_cancelBackoff]; tests: the injected delay seam, whose completion is
  /// simply ignored once the wait has been interrupted.
  Future<void> _waitBackoff(Duration duration) {
    final waiter = Completer<void>();
    _backoffWaiter = waiter;
    final delayOverride = _delayOverride;
    if (delayOverride == null) {
      _backoffTimer = Timer(duration, () => _finishBackoff(waiter));
    } else {
      unawaited(
        delayOverride(duration).then(
          (_) => _finishBackoff(waiter),
          onError: (Object _) => _finishBackoff(waiter),
        ),
      );
    }
    return waiter.future;
  }

  void _finishBackoff(Completer<void> waiter) {
    if (identical(_backoffWaiter, waiter)) {
      _backoffWaiter = null;
      _backoffTimer?.cancel();
      _backoffTimer = null;
    }
    if (!waiter.isCompleted) {
      waiter.complete();
    }
  }

  /// Stops the active backoff wait at once. The interrupted waiter completes
  /// immediately; the retry loop's epoch check then abandons the attempt, so
  /// neither a cancel/terminal nor dispose ever waits out a Retry-After.
  void _cancelBackoff() {
    _backoffTimer?.cancel();
    _backoffTimer = null;
    final waiter = _backoffWaiter;
    _backoffWaiter = null;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
  }

  Duration _jitteredBackoff(int attempt) {
    final exponent = attempt < 1 ? 0 : attempt - 1;
    final baseMicros = _backoffBase.inMicroseconds * pow(2, exponent);
    final capped = min(
      baseMicros.toDouble(),
      _backoffCap.inMicroseconds.toDouble(),
    );
    return Duration(microseconds: (capped * (0.5 + _random() * 0.5)).round());
  }

  /// The prospective-payload gate of an image send (V1_SPEC §4): the exact
  /// wire body of the would-be request, measured with fixed-size placeholder
  /// bookkeeping — no Message, id or attemptKey is minted for the probe.
  bool _payloadTooLarge(List<ContentPart> parts, BotProfile profile) {
    final probe = Message(
      id: _probeId,
      role: MessageRole.user,
      parts: parts,
      status: MessageStatus.sending,
      attemptKey: _probeId,
      createdAt: _now(),
    );
    final assembled = assembleContext(
      history: [..._messages, probe],
      profile: profile,
      trimBudget: _trimBudget,
    );
    if (assembled.contextTooLong) {
      // The degenerate trim outcome is produced by the real pipeline (with
      // its Message/key discipline), not by the probe.
      return false;
    }
    final body = encodeChatRequestBody(
      ChatRequest(
        botId: profile.id,
        system: profile.systemPrompt,
        messages: assembled.messages,
        tools: profile.tools,
        idempotencyKey: _probeId,
      ),
    );
    return utf8.encode(body).length > _maxRequestBodyBytes;
  }

  /// Tracks one awaited preprocessing/checkpoint future for the dispose
  /// teardown contract. Errors are swallowed on this tracking branch — the
  /// pipeline's own await observes and handles them.
  void _registerSettlement(Future<Object?> settling) {
    late final Future<void> tracked;
    tracked = settling.then<void>((_) {}, onError: (Object _) {}).whenComplete(
      () {
        if (identical(_pendingSettlement, tracked)) {
          _pendingSettlement = null;
        }
      },
    );
    _pendingSettlement = tracked;
  }

  /// The provider-effective history of the NEXT dispatch (V1_SPEC §6/§8,
  /// SERVER-CONTRACT §6): the reply's own assistant Message never carries
  /// the output of the leg being (re-)run — a recovery repeat must be
  /// byte-identical to the original leg's request, so the current leg's
  /// partial text/opaque state/unmatched trailing toolCall are excluded and
  /// only the completed toolCall+toolResult exchanges of earlier legs ride
  /// along. With no completed exchange (a first-leg recovery) the assistant
  /// is absent from the wire entirely. The snapshot keeps the partial — this
  /// is a wire projection, not a second storage model.
  List<Message> _dispatchHistory(_Reply reply) {
    final assistantId = reply.assistantId;
    if (assistantId == null) {
      return _messages;
    }
    final baseline = reply.legBaselineParts ?? 0;
    return [
      for (final message in _messages)
        if (message.id != assistantId)
          message
        else if (baseline > 0)
          message.parts.length > baseline
              ? message.copyWith(parts: message.parts.sublist(0, baseline))
              : message,
    ];
  }

  void _releaseGateIfCurrent(int epoch) {
    if (_epoch == epoch) {
      _busy = false;
    }
  }

  void _validateProfile(BotProfile profile) =>
      _validateProfileConfig(profile, _onToolCall);

  void _throwIfDisposed(String command) {
    if (_disposed) {
      throw StateError(
        'ChatSession.$command called after dispose() — a disposed session '
        'accepts only a repeated dispose()',
      );
    }
  }

  void _throwIfCheckpointReentrant(String command) {
    if (identical(Zone.current[_checkpointZoneKey], this)) {
      throw StateError(
        'ChatSession.$command called reentrantly from the checkpoint '
        'callback of the same session (V1_SPEC §4)',
      );
    }
  }

  void _debugNoOp(String command, String reason) {
    assert(() {
      debugPrint('chat_ai: $command is a no-op — $reason');
      return true;
    }());
  }
}

/// The ONE local validation of a session's configuration and history
/// (V1_SPEC §3/§5), shared by the synchronous constructor and
/// [ChatSession.open]. Checks run in the constructor's original order, so the
/// thrown error of an invalid configuration is unchanged.
///
/// [ChatSession.open] runs it BEFORE consulting a durable backend: invalid
/// local configuration or history never reaches the transport. The invariants
/// are checked on the history as passed; the open normalisation only maps
/// statuses onto other statuses that are equally legal for that role, so the
/// verdict is the same before and after it.
void _preflightSessionConfig({
  required BotProfile botProfile,
  required OnToolCall? onToolCall,
  required Conversation? history,
  required int? trimBudget,
  required int maxToolTurns,
  required Duration retryDeadline,
  required ImageSendOptions imageOptions,
}) {
  _checkPositiveConfig(maxToolTurns, 'maxToolTurns');
  if (retryDeadline <= Duration.zero) {
    throw ArgumentError.value(
      retryDeadline,
      'retryDeadline',
      'must be positive',
    );
  }
  if (trimBudget != null) {
    _checkPositiveConfig(trimBudget, 'trimBudget');
  }
  _checkPositiveConfig(imageOptions.maxLongEdge, 'imageOptions.maxLongEdge');
  _checkPositiveConfig(
    imageOptions.maxImagesPerMessage,
    'imageOptions.maxImagesPerMessage',
  );
  if (imageOptions.jpegQuality < 1 || imageOptions.jpegQuality > 100) {
    throw ArgumentError.value(
      imageOptions.jpegQuality,
      'imageOptions.jpegQuality',
      'must be within 1..100',
    );
  }
  _validateProfileConfig(botProfile, onToolCall);
  if (history == null) {
    return;
  }
  if (history.schemaVersion != 1) {
    throw ArgumentError.value(
      history.schemaVersion,
      'history',
      'the v1 Core accepts Conversation schemaVersion 1 only',
    );
  }
  checkConversationInvariants(history);
}

void _validateProfileConfig(BotProfile profile, OnToolCall? onToolCall) {
  if (profile.tools.isNotEmpty && onToolCall == null) {
    throw ArgumentError.value(
      profile,
      'botProfile',
      'a Bot Profile with tools requires an onToolCall resolver',
    );
  }
  validateToolDeclarations(profile.tools);
}

void _checkPositiveConfig(int value, String name) {
  if (value < 1) {
    throw ArgumentError.value(value, name, 'must be positive');
  }
}

/// Package-internal command bridge (V1_SPEC §3): the package Input Bar clears
/// its draft only on [ChatCommandDisposition.accepted]. Deliberately a
/// top-level function excluded from the `chat_ai.dart` barrel — the public
/// command type stays `Future<void>`.
Future<ChatCommandDisposition> sendWithDisposition(
  ChatSession session,
  String text, {
  List<Uint8List> images = const [],
}) => session._send(text, images);

/// Package-internal read of the session's image-send configuration
/// (V1_SPEC §7): the Input Bar's effective attachment cap is
/// `min(maxAttachments, session.imageOptions.maxImagesPerMessage)`, so the
/// package widgets need the session-specific limit. Deliberately a top-level
/// function excluded from the `chat_ai.dart` barrel — the public façade
/// stays exactly V1_SPEC §3.
ImageSendOptions imageOptionsForWidgets(ChatSession session) =>
    session._imageOptions;

/// Package-internal recovery target of the session's current `Failed`
/// (V1_SPEC §7): the widgets' error row draws its one action from THIS,
/// computed by the Core from what the failing reply actually did — never
/// inferred from history. [kind] `none` ⇒ the row shows no action and any
/// `errorBuilder` receives a `null` retry. Deliberately a top-level function
/// excluded from the `chat_ai.dart` barrel — the public façade stays exactly
/// V1_SPEC §3.
({ChatErrorRecovery kind, String? messageId}) errorRecoveryForWidgets(
  ChatSession session,
) => (kind: session._recovery, messageId: session._recoveryMessageId);

/// Internal test seam — NOT exported from `package:chat_ai/chat_ai.dart`.
///
/// The same production [ChatSession] with its nondeterministic inputs
/// replaced: clock, UUID source, backoff delay/jitter and the image
/// processor. Exists so the Core contract (deadline mechanics, key
/// discipline, preprocessing races) is testable deterministically without
/// real time, randomness or isolates; deliberately not a public constructor
/// or DI surface — the public shape stays exactly V1_SPEC §3.
@visibleForTesting
ChatSession chatSessionForTesting({
  required ChatBackend backend,
  required BotProfile botProfile,
  OnToolCall? onToolCall,
  Conversation? history,
  int? trimBudget,
  int maxToolTurns = 5,
  Duration retryDeadline = const Duration(seconds: 30),
  ImageSendOptions imageOptions = const ImageSendOptions(),
  ConversationCheckpoint? checkpoint,
  DateTime Function()? now,
  String Function()? newUuid,
  Future<void> Function(Duration duration)? delay,
  double Function()? random,
  Future<Uint8List> Function(Uint8List raw, ImageSendOptions options)?
  processImage,
}) => ChatSession._(
  backend: backend,
  botProfile: botProfile,
  onToolCall: onToolCall,
  history: history,
  trimBudget: trimBudget,
  maxToolTurns: maxToolTurns,
  retryDeadline: retryDeadline,
  imageOptions: imageOptions,
  checkpoint: checkpoint,
  now: now,
  newUuid: newUuid,
  delay: delay,
  random: random,
  processImage: processImage,
);

/// One logical reply in flight: the frozen profile, the anchor Message ids,
/// the frozen per-attempt request, retry/fallback bookkeeping and the leg
/// usage accumulator.
class _Reply {
  _Reply({
    required this.epoch,
    required this.profile,
    required this.startedAt,
    this.anchorUserId,
    this.assistantId,
    this.assistantPreexisting = false,
    required this.freshKeyFallbackArmed,
    this.legBaselineParts,
    this.needsLegReset = false,
    this.toolTurnsUsed = 0,
  });

  final int epoch;

  /// The Bot Profile snapshot of the logical reply: every leg uses it; a
  /// `session.botProfile =` during the reply affects only the next command.
  final BotProfile profile;

  final DateTime startedAt;
  final String? anchorUserId;
  String? assistantId;

  /// True when the assistant Message existed before this command (an
  /// interrupted-reply recovery): its partial is never removed as
  /// "technical" on a pre-token failure.
  final bool assistantPreexisting;

  /// Armed only for the first backend request of an explicit same-key
  /// recovery command (resend / interrupted regenerate / sent-user
  /// regenerate); consumed by its one `409`/`410` fresh-key fallback and
  /// disarmed by any silent retry.
  bool freshKeyFallbackArmed;

  ChatRequest? request;
  bool tokenSeenThisLeg = false;

  /// The durable reply identity (the assistant `Message.id`), retained even
  /// after a removed technical assistant clears [assistantId] — the remote
  /// cancel still addresses the right reply.
  String? durableReplyId;

  /// Whether this reply actually reached the durable backend (a `startReply`
  /// happened or an `attachReply` succeeded): the precondition of the one
  /// explicit remote cancel.
  bool remoteStarted = false;

  /// True once the durable assistant Message was created BEFORE the first
  /// dispatch (never for a pre-existing assistant of a recovery command).
  bool earlyAssistant = false;

  /// The stream `ChatSession.open()` attached to, consumed exactly once by the
  /// first leg of a recovered reply.
  Stream<BackendEvent>? attachedStream;

  /// The attach leg carries no frozen request: a silent retry, a fresh-key
  /// fallback or any other re-dispatch of it is impossible by contract.
  bool get hasFrozenRequest => request != null;

  /// The first leg of a durable reply whose assistant Message was created
  /// early: the one case where the fresh-key fallback writes the key to both
  /// the assistant and the anchor user Message.
  bool get isEarlyDurableFirstLeg =>
      earlyAssistant &&
      !assistantPreexisting &&
      toolTurnsUsed == 0 &&
      (legBaselineParts ?? 0) == 0;

  Stream<BackendEvent>? takeAttachedStream() {
    final stream = attachedStream;
    attachedStream = null;
    return stream;
  }

  /// Billable tool legs already used by this logical reply — pre-seeded on
  /// a recovery from the completed tool exchanges, so the loop cap survives
  /// a restart.
  int toolTurnsUsed;
  final List<Usage> legUsages = [];
  int? legBaselineParts;
  bool needsLegReset;
}

sealed class _LegOutcome {
  const _LegOutcome();
}

class _LegHandled extends _LegOutcome {
  const _LegHandled();
}

class _LegToolCall extends _LegOutcome {
  const _LegToolCall(this.call);

  final ToolCall call;
}

sealed class _RequestOutcome {
  const _RequestOutcome();
}

class _RequestHandled extends _RequestOutcome {
  const _RequestHandled();
}

class _RequestToolCall extends _RequestOutcome {
  const _RequestToolCall(this.call);

  final ToolCall call;
}

class _RequestFallbackKey extends _RequestOutcome {
  const _RequestFallbackKey();
}

class _RequestRetry extends _RequestOutcome {
  const _RequestRetry({
    required this.cause,
    required this.detail,
    required this.retryAfter,
  });

  final FailureCause cause;
  final String? detail;
  final Duration? retryAfter;
}
