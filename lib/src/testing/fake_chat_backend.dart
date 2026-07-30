import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../backend/backend_event.dart';
import '../backend/chat_backend.dart';
import '../backend/chat_request.dart';
import '../backend/durable_chat_backend.dart';
import '../models/failure.dart';
import '../models/tool.dart';
import '../models/usage.dart';

/// The scriptable fake [ChatBackend] of V1_SPEC §10 — no network, no money.
///
/// Builder-style configuration: each scripting call enqueues **one backend
/// response**; each [send] consumes the next one (an exhausted script behaves
/// like [emptyReply] — a valid empty `done`). [replayOnSameKey] is the one
/// mode toggle: with it on, a repeated [send] under an Idempotency-Key whose
/// response already ended in `done`/`tool_call` replays the recorded outcome
/// instead of consuming the script — the recover-before-rebill path
/// (the chat_ai_firebase SERVER-CONTRACT §6). A key that ended in `error`
/// stays unknown (the §6
/// release/expiry side), so its repeat consumes the next scripted response.
///
/// Event order is normative (V1_SPEC §8): `Accepted` first (pre-stream
/// failures — [respondGone410]/[respondConflict409]/`failWith(afterTokens:
/// 0)` — yield none), then data events, then exactly one terminal.
/// Cancelling the subscription stops the emission immediately, including a
/// pending `tokenDelay` gap — that is the wire-cancel.
///
/// Deliberately NOT a mock framework: no matchers, no expectations, no
/// request inspectors on the public surface (the package-internal capture
/// seam is [capturedRequestsOf], never exported from
/// `package:chat_ai/testing.dart`).
class FakeChatBackend implements ChatBackend {
  final List<_FakeResponse> _script = [];
  final Map<String, List<BackendEvent>> _completedByKey = {};
  final Map<String, String> _effectiveByKey = {};
  final List<ChatRequest> _requests = [];
  bool _replayOnSameKey = false;
  int _toolCallCounter = 0;

  /// Streams [text] token-by-token ([tokenDelay] before every delta), then a
  /// `done` whose usage counts the deltas and carries a raw payload (so the
  /// single-leg `usageRaw` rule is observable).
  void reply(String text, {Duration tokenDelay = Duration.zero}) {
    _script.add(_FakeResponse.reply(text: text, tokenDelay: tokenDelay));
  }

  /// Fails with [cause]: `afterTokens == 0` is a pre-stream failure (no
  /// `Accepted`, mirroring a non-200 HTTP response); `afterTokens > 0` emits
  /// that many synthetic deltas first — the post-token side of the Retry
  /// Boundary. Exactly the V1_SPEC §10 surface; a wire-level `detail`/
  /// `Retry-After` is a package-internal concern scripted through
  /// [scriptFailureResponse].
  void failWith(FailureCause cause, {int afterTokens = 0}) {
    _script.add(_FakeResponse.failure(cause: cause, afterTokens: afterTokens));
  }

  /// One delta, then a mid-stream break (`error(upstream)` after the first
  /// token — the keep-partial rule, CONTEXT §Cancel/§Retry Boundary).
  void breakAfterFirstToken() {
    _script.add(const _FakeResponse.breakAfterFirstToken());
  }

  /// Ends the response with a `tool_call` terminal for [name]/[args] under a
  /// deterministic fresh `toolCallId` (`call_1`, `call_2`, …).
  void requestTool(String name, {Map<String, dynamic> args = const {}}) {
    _script.add(_FakeResponse.tool(name: name, args: args));
  }

  /// A valid empty reply: `Accepted` + `done` with zero output tokens.
  void emptyReply() {
    _script.add(const _FakeResponse.empty());
  }

  /// Turns on terminal replay: a repeated key whose recorded response ended
  /// in `done`/`tool_call` is replayed as-is, never re-generated.
  void replayOnSameKey() {
    _replayOnSameKey = true;
  }

  /// One `410 Gone` response — the attempt was recorded as aborted
  /// server-side (SERVER-CONTRACT §6).
  void respondGone410() {
    _script.add(const _FakeResponse.gone());
  }

  /// One `409 Conflict` response — same key, mismatched params
  /// (SERVER-CONTRACT §6).
  void respondConflict409() {
    _script.add(const _FakeResponse.conflict());
  }

  @override
  Stream<BackendEvent> send(ChatRequest request) {
    _requests.add(request);
    return _respondTo(request);
  }

  /// The scripted response of one dispatch: replay bookkeeping, script
  /// consumption and emission — everything [send] does except capturing the
  /// request. Shared with the durable fake, whose `attachReply` replays a leg
  /// without any request at all.
  Stream<BackendEvent> _respondTo(ChatRequest request) {
    final List<BackendEvent> replayed;
    final Duration tokenDelay;
    final replayable = _replayOnSameKey
        ? _completedByKey[request.idempotencyKey]
        : null;
    if (replayable != null) {
      // A retained key answers per SERVER-CONTRACT §6: a byte-identical
      // provider-effective repeat replays the stored outcome immediately (a
      // paid reply is never re-billed); mismatched params under the same key
      // are an honest 409 Conflict — a mismatch must never be masked by a
      // successful replay.
      final signature = _providerEffectiveSignature(request);
      replayed = signature == _effectiveByKey[request.idempotencyKey]
          ? replayable
          : const [BackendEvent.conflict()];
      tokenDelay = Duration.zero;
    } else {
      final response = _script.isEmpty
          ? const _FakeResponse.empty()
          : _script.removeAt(0);
      replayed = response.events(this);
      tokenDelay = response.tokenDelay;
      final last = replayed.isEmpty ? null : replayed.last;
      if (last is ToolCallEvent || last is DoneEvent) {
        _completedByKey[request.idempotencyKey] = replayed;
        _effectiveByKey[request.idempotencyKey] = _providerEffectiveSignature(
          request,
        );
      }
    }
    return _emit(replayed, tokenDelay);
  }

  /// Emits [replayed] as a live subscription.
  ///
  /// Manual timer chain instead of async*: cancelling the subscription must
  /// stop a pending tokenDelay immediately (async* would finish the await
  /// first), and no timer may outlive the subscription.
  Stream<BackendEvent> _emit(List<BackendEvent> replayed, Duration tokenDelay) {
    late final StreamController<BackendEvent> controller;
    Timer? pending;
    var index = 0;
    void emitNext() {
      while (index < replayed.length && !controller.isClosed) {
        final event = replayed[index];
        if (event is Delta && tokenDelay > Duration.zero) {
          index++;
          pending = Timer(tokenDelay, () {
            if (!controller.isClosed) {
              controller.add(event);
              emitNext();
            }
          });
          return;
        }
        index++;
        controller.add(event);
      }
      if (!controller.isClosed) {
        controller.close();
      }
    }

    controller = StreamController<BackendEvent>(
      onListen: () {
        // Asynchronous like a real transport: nothing arrives before the
        // caller's dispatch decision returns.
        pending = Timer(Duration.zero, emitNext);
      },
      onCancel: () {
        pending?.cancel();
      },
    );
    return controller.stream;
  }

  String _nextToolCallId() => 'call_${++_toolCallCounter}';

  /// The provider-effective projection of a request (SERVER-CONTRACT §6):
  /// `wireVersion` and the client-only Message bookkeeping (`id`, `status`,
  /// `createdAt`, `attemptKey`) are stripped, and the result is canonical
  /// JSON — map keys sorted lexicographically at every level, list order
  /// preserved, scalar values untouched — exactly the shape the proxy
  /// hashes for its 409 comparison. A semantically identical repeat whose
  /// maps merely re-serialised in another key order must compare equal.
  static String _providerEffectiveSignature(ChatRequest request) => jsonEncode(
    _canonical({
      'botId': request.botId,
      'system': request.system,
      'messages': [
        for (final message in request.messages)
          {
            'role': message.role.name,
            'parts': [for (final part in message.parts) part.toJson()],
          },
      ],
      'tools': [
        for (final tool in request.tools)
          {
            'name': tool.name,
            'description': tool.description,
            'parameters': tool.parameters,
          },
      ],
    }),
  );

  /// Canonical form: recursively key-sorted maps, order-preserving lists,
  /// scalars as-is. Internal to the replay comparator only.
  static Object? _canonical(Object? value) => switch (value) {
    final Map<Object?, Object?> map => {
      for (final key in map.keys.map((k) => k.toString()).toList()..sort())
        key: _canonical(map[key]),
    },
    final List<Object?> list => [for (final item in list) _canonical(item)],
    _ => value,
  };
}

/// The scriptable fake [DurableChatBackend]: the same scripted responses as
/// [FakeChatBackend], driven through the durable long-running-reply surface.
///
/// It lives in this library on purpose — attach must consume the SAME private
/// script as `send`/`startReply` without a request and without a fake `send()`
/// call.
///
/// - `startReply` is a REAL dispatch: it consumes the next scripted response
///   and captures the request, exactly like `send`;
/// - `attachReplays()` makes the next `attachReply` return a stream that
///   replays the next scripted response — no `send`, no captured request, no
///   `startedReplyIds` entry;
/// - `attachAbsent()` (the default when attach is not scripted) proves there
///   is no active reply and returns `null`;
/// - `attachFails()` throws — the status is unknown;
/// - only `cancelReply` increments [cancelReplyCount]; cancelling a stream
///   subscription is a detach and never does.
class FakeDurableChatBackend extends FakeChatBackend
    implements DurableChatBackend {
  final List<String> _startedReplyIds = [];
  final List<String> _attachedReplyIds = [];
  final List<_FakeAttach> _attachScript = [];
  int _cancelReplyCount = 0;

  /// The next `attachReply` finds the reply and replays its current leg from
  /// the next scripted response.
  void attachReplays() {
    _attachScript.add(const _FakeAttach.replays());
  }

  /// The next `attachReply` proves there is no active reply (`null`).
  void attachAbsent() {
    _attachScript.add(const _FakeAttach.absent());
  }

  /// The next `attachReply` cannot determine the reply status and throws.
  void attachFails([Object error = 'attach-status-unknown']) {
    _attachScript.add(_FakeAttach.fails(error));
  }

  /// Every `startReply` id, in dispatch order.
  List<String> get startedReplyIds => List.unmodifiable(_startedReplyIds);

  /// Every `attachReply` id, in call order.
  List<String> get attachedReplyIds => List.unmodifiable(_attachedReplyIds);

  /// Explicit remote cancels — detach never counts here.
  int get cancelReplyCount => _cancelReplyCount;

  @override
  Stream<BackendEvent> startReply(String replyId, ChatRequest request) {
    _startedReplyIds.add(replyId);
    return send(request);
  }

  @override
  Future<Stream<BackendEvent>?> attachReply(String replyId) async {
    _attachedReplyIds.add(replyId);
    final outcome = _attachScript.isEmpty
        ? const _FakeAttach.absent()
        : _attachScript.removeAt(0);
    switch (outcome.kind) {
      case _FakeAttachKind.absent:
        return null;
      case _FakeAttachKind.fails:
        throw outcome.error!;
      case _FakeAttachKind.replays:
        final response = _script.isEmpty
            ? const _FakeResponse.empty()
            : _script.removeAt(0);
        return _emit(response.events(this), response.tokenDelay);
    }
  }

  @override
  Future<void> cancelReply(String replyId) async {
    _cancelReplyCount++;
  }
}

/// One scripted answer of [FakeDurableChatBackend.attachReply].
class _FakeAttach {
  const _FakeAttach.replays() : kind = _FakeAttachKind.replays, error = null;

  const _FakeAttach.absent() : kind = _FakeAttachKind.absent, error = null;

  const _FakeAttach.fails(this.error) : kind = _FakeAttachKind.fails;

  final _FakeAttachKind kind;
  final Object? error;
}

enum _FakeAttachKind { replays, absent, fails }

/// Package-internal scripting seam for the wire-level failure fields the
/// public V1_SPEC §10 surface deliberately omits: a logs-only `detail` and a
/// `Retry-After` duration. Used by the Core retry tests; never exported from
/// `package:chat_ai/testing.dart`.
@visibleForTesting
void scriptFailureResponse(
  FakeChatBackend fake,
  FailureCause cause, {
  int afterTokens = 0,
  String? detail,
  Duration? retryAfter,
}) {
  fake._script.add(
    _FakeResponse.failure(
      cause: cause,
      afterTokens: afterTokens,
      detail: detail,
      retryAfter: retryAfter,
    ),
  );
}

/// Package-internal capture seam: every [ChatRequest] the fake received, in
/// dispatch order. Used by the Core tests to pin frozen-request/key
/// discipline; deliberately NOT exported from `package:chat_ai/testing.dart`
/// (the fake's public surface stays exactly V1_SPEC §10).
@visibleForTesting
List<ChatRequest> capturedRequestsOf(FakeChatBackend fake) =>
    List.unmodifiable(fake._requests);

/// One scripted backend response, expanded to its event list at [send] time.
class _FakeResponse {
  const _FakeResponse._(
    this._kind, {
    this.text = '',
    this.tokenDelay = Duration.zero,
    this.cause = FailureCause.upstream,
    this.afterTokens = 0,
    this.detail,
    this.retryAfter,
    this.toolName = '',
    this.toolArgs = const {},
  });

  const _FakeResponse.reply({
    required String text,
    required Duration tokenDelay,
  }) : this._(_FakeKind.reply, text: text, tokenDelay: tokenDelay);

  const _FakeResponse.failure({
    required FailureCause cause,
    required int afterTokens,
    String? detail,
    Duration? retryAfter,
  }) : this._(
         _FakeKind.failure,
         cause: cause,
         afterTokens: afterTokens,
         detail: detail,
         retryAfter: retryAfter,
       );

  const _FakeResponse.breakAfterFirstToken()
    : this._(_FakeKind.breakAfterFirstToken);

  const _FakeResponse.tool({
    required String name,
    required Map<String, dynamic> args,
  }) : this._(_FakeKind.tool, toolName: name, toolArgs: args);

  const _FakeResponse.empty() : this._(_FakeKind.empty);

  const _FakeResponse.gone() : this._(_FakeKind.gone);

  const _FakeResponse.conflict() : this._(_FakeKind.conflict);

  final _FakeKind _kind;
  final String text;
  final Duration tokenDelay;
  final FailureCause cause;
  final int afterTokens;
  final String? detail;
  final Duration? retryAfter;
  final String toolName;
  final Map<String, dynamic> toolArgs;

  List<BackendEvent> events(FakeChatBackend backend) => switch (_kind) {
    _FakeKind.reply => [
      const BackendEvent.accepted(),
      for (final chunk in _tokenize(text)) BackendEvent.delta(chunk),
      BackendEvent.done(
        usage: Usage(
          inputTokens: 1,
          outputTokens: _tokenize(text).length,
          usageRaw: const {'fake': 'raw'},
        ),
      ),
    ],
    _FakeKind.failure => [
      if (afterTokens > 0) const BackendEvent.accepted(),
      for (var i = 0; i < afterTokens; i++) BackendEvent.delta('tok$i '),
      BackendEvent.error(cause, detail: detail, retryAfter: retryAfter),
    ],
    _FakeKind.breakAfterFirstToken => const [
      BackendEvent.accepted(),
      BackendEvent.delta('partial'),
      BackendEvent.error(FailureCause.upstream, detail: 'stream-break'),
    ],
    _FakeKind.tool => [
      const BackendEvent.accepted(),
      BackendEvent.toolCall(
        ToolCall(id: backend._nextToolCallId(), name: toolName, args: toolArgs),
        usage: const Usage(inputTokens: 1, outputTokens: 1),
      ),
    ],
    _FakeKind.empty => const [
      BackendEvent.accepted(),
      BackendEvent.done(
        usage: Usage(
          inputTokens: 1,
          outputTokens: 0,
          usageRaw: {'fake': 'raw'},
        ),
      ),
    ],
    _FakeKind.gone => const [BackendEvent.gone()],
    _FakeKind.conflict => const [BackendEvent.conflict()],
  };

  /// Word-ish chunks whose concatenation is exactly [text] (whitespace-only
  /// replies included).
  static List<String> _tokenize(String text) => [
    for (final match in RegExp(r'\S+\s*|\s+').allMatches(text)) match[0]!,
  ];
}

enum _FakeKind {
  reply,
  failure,
  breakAfterFirstToken,
  tool,
  empty,
  gone,
  conflict,
}
