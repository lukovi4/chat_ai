// One `ChatBackend.send()` leg over one OpenAI Realtime WebSocket session.
//
// The stream contract of the base package holds here: the returned stream is
// cold, single-subscription, NEVER throws, ends with exactly one terminal
// event (unless cancelled — the Core sets `Cancelled` itself) and ignores
// duplicate/late provider events after the terminal.
//
// Money-safe commit boundary (the critical contract): this backend performs
// NO retry at any stage. `_dispatchMayHaveReachedProvider` is monotonic and
// set immediately BEFORE handing the serialized `response.create` to the
// transport — even a synchronous send exception counts as an ambiguous
// possible dispatch. Before the flag: transport failures end as
// `FailureCause.network` (safe for the Core's pre-token silent retry —
// inference was never requested). After the flag: every failure ends as
// `FailureCause.upstream` (never `network|rate|overloaded`, never
// Conflict/Gone), so the Core can never re-run a possibly-billed call.
//
// No raw OpenAI error message, secret, prompt or stack trace ever reaches an
// event `detail` — details are stable machine markers only.

import 'dart:async';
import 'dart:convert';

import 'package:chat_ai/chat_ai.dart';

import 'client_secret_provider.dart';
import 'realtime_request_translator.dart';
import 'realtime_transport.dart';

/// Runs one backend leg. Package-internal seam: the public backend passes
/// the production WebSocket transport; tests pass a fake. [maxOutputTokens]
/// rides inside the single `response.create`; [responseIdleTimeout] arms the
/// post-commit idle watchdog. Both are validated by the public backend before
/// this is ever called.
Stream<BackendEvent> runRealtimeSend({
  required ClientSecretProvider clientSecretProvider,
  required RealtimeTransport transport,
  required ChatRequest request,
  required int maxOutputTokens,
  required Duration responseIdleTimeout,
}) {
  return _RealtimeSendOperation(
    clientSecretProvider,
    transport,
    request,
    maxOutputTokens,
    responseIdleTimeout,
  ).stream;
}

/// Accumulated state of the (at most one) function call on a leg, keyed by
/// `output_index` so a genuinely second call is detectable and fails closed
/// — mirrors the base package's server stream translator.
class _CallState {
  String? callId;
  String? name;
  String deltaArgs = ''; // buffered argument fragments
  String? finalArgs; // authoritative arguments once the call closes
}

class _RealtimeSendOperation {
  _RealtimeSendOperation(
    this._provider,
    this._transport,
    this._request,
    this._maxOutputTokens,
    this._idleTimeout,
  ) {
    _controller = StreamController<BackendEvent>(
      onListen: () => unawaited(_run()),
      onCancel: _onSubscriptionCancel,
    );
  }

  final ClientSecretProvider _provider;
  final RealtimeTransport _transport;
  final ChatRequest _request;
  final int _maxOutputTokens;
  final Duration _idleTimeout;

  /// The post-commit idle watchdog. Armed exactly at the money-safe commit
  /// point (before the `response.create` send), reset only on real Response
  /// progress, and cancelled by any terminal/cancel. Null before the commit
  /// boundary and after any terminal.
  Timer? _idleTimer;

  late final StreamController<BackendEvent> _controller;

  Stream<BackendEvent> get stream => _controller.stream;

  /// Monotonic: set immediately before the `response.create` transport send.
  bool _dispatchMayHaveReachedProvider = false;

  /// The subscriber cancelled — no event may be delivered anymore.
  bool _cancelled = false;

  /// Fired by the wire-cancel: actively interrupts any pending setup wait
  /// (secret, connect) and tells the transport to abort and release its
  /// partial resources.
  final RealtimeCancellation _cancellation = RealtimeCancellation();

  /// The one terminal event has been emitted.
  bool _finished = false;

  bool _acceptedEmitted = false;
  String? _responseId;

  RealtimeConnection? _connection;
  StreamSubscription<String>? _events;
  Future<void>? _teardownFuture;

  final Map<int, _CallState> _calls = <int, _CallState>{};
  int? _firstCallIndex;

  // --- the one leg -----------------------------------------------------------

  Future<void> _run() async {
    // 1. Ephemeral secret — only the opaque bot id crosses this boundary.
    // A provider exception or an empty secret is one sanitized upstream
    // terminal; it never escapes the stream as a throw. The wait itself is
    // interruptible: a wire-cancel stops it immediately, and the provider's
    // late result/error is observed and ignored (never an unhandled zone
    // error, never a connect).
    final String? secret;
    try {
      secret = await _guardSetup(
        Future<String>.sync(
          () => _provider.getClientSecret(botId: _request.botId),
        ),
      );
    } catch (_) {
      if (_cancelled || _finished) {
        return;
      }
      _finishError(FailureCause.upstream, 'client-secret-failed');
      return;
    }
    if (secret == null || _cancelled || _finished) {
      return; // cancelled: silent — the Core sets Cancelled itself
    }
    if (secret.isEmpty) {
      _finishError(FailureCause.upstream, 'client-secret-empty');
      return;
    }

    // 2. One fresh Realtime WebSocket session (handshake authorized by the
    // ephemeral secret). All of it is before the
    // commit boundary — a failure is `network` and safe to silently retry.
    // The cancellation signal is handed INTO the transport so a wire-cancel
    // actively aborts the pending setup and releases its partial resources;
    // a connect that still wins the race is closed on the spot.
    final RealtimeConnection? connection;
    try {
      connection = await _guardSetup(
        _transport.connect(secret, _cancellation),
        onLateValue: _closeLateConnection,
      );
    } catch (_) {
      if (_cancelled || _finished) {
        return;
      }
      _finishError(FailureCause.network, 'transport-connect-failed');
      return;
    }
    if (connection == null) {
      return; // cancelled while waiting: the transport aborts itself
    }
    if (_cancelled || _finished) {
      // Cancel slipped in between the guard resolving and this
      // continuation: this fresh connection was never published, so the
      // (possibly already completed) teardown could not close it.
      _closeLateConnection(connection);
      return;
    }
    _connection = connection;
    _events = connection.events.listen(
      _handleServerEvent,
      onError: _handleTransportError,
      onDone: _handleTransportDone,
    );

    // 8. Exactly one `response.create` (carrying the finite max_output_tokens).
    // A local build defect never dispatches.
    final String payload;
    try {
      payload = jsonEncode(
        buildResponseCreateEvent(_request, _maxOutputTokens),
      );
    } catch (_) {
      _finishError(FailureCause.upstream, 'request-build-failed');
      return;
    }
    // ---- MONEY-SAFE COMMIT BOUNDARY ----------------------------------------
    // Set BEFORE the transport send, not after its success: even a
    // synchronous exception below is an ambiguous possible dispatch. The idle
    // watchdog is armed HERE, before the send, so it also fires the leg to a
    // terminal if the `response.create` send Future itself hangs forever.
    _dispatchMayHaveReachedProvider = true;
    _armIdleWatchdog();
    try {
      await connection.send(payload);
    } catch (_) {
      if (_cancelled || _finished) {
        return;
      }
      _finishError(FailureCause.upstream, 'transport-send-failed');
      return;
    }
    // From here the leg is driven by server events, transport death or the
    // idle watchdog.
  }

  /// Arms the idle watchdog at the commit boundary. A no-op if a terminal
  /// already fired (e.g. a very fast provider error), so it never re-arms.
  void _armIdleWatchdog() {
    if (_finished || _cancelled) {
      return;
    }
    _idleTimer = Timer(_idleTimeout, _onIdleTimeout);
  }

  /// Real Response progress: cancel the running countdown and start a fresh
  /// one. A no-op before the watchdog is armed or after any terminal/cancel —
  /// so non-progress and late signals never revive a finished leg.
  void _noteProgress() {
    if (_idleTimer == null || _finished || _cancelled) {
      return;
    }
    _idleTimer!.cancel();
    _idleTimer = Timer(_idleTimeout, _onIdleTimeout);
  }

  /// The idle deadline elapsed with no Response progress. Post-commit by
  /// construction (the timer only exists after the commit boundary): a
  /// best-effort, non-blocking `response.cancel`, then exactly one terminal
  /// `upstream` — never `network`/`rate`/`overloaded` — and the existing
  /// memoized teardown. No new secret, no new connection, no second
  /// `response.create`.
  void _onIdleTimeout() {
    if (_finished || _cancelled) {
      return;
    }
    _bestEffortResponseCancel();
    _finishError(FailureCause.upstream, 'response-idle-timeout');
  }

  /// One best-effort `response.cancel` (NOT a `response.create`): fired without
  /// awaiting, its sync/async error swallowed so it never becomes an unhandled
  /// zone error and never delays the terminal.
  void _bestEffortResponseCancel() {
    final connection = _connection;
    if (connection == null) {
      return;
    }
    try {
      unawaited(
        connection
            .send(
              jsonEncode(<String, dynamic>{
                'type': 'response.cancel',
                if (_responseId != null) 'response_id': _responseId,
              }),
            )
            .then<void>((_) {}, onError: (Object _) {}),
      );
    } catch (_) {
      // A synchronous send failure is swallowed too.
    }
  }

  /// Awaits one setup step, abandoning the wait the instant the operation
  /// is cancelled (resolves to `null`). The step's late outcome is still
  /// observed: a late error is swallowed here — it must never surface as an
  /// unhandled zone error — and a late value is handed to [onLateValue] for
  /// immediate release.
  Future<T?> _guardSetup<T extends Object>(
    Future<T> step, {
    void Function(T value)? onLateValue,
  }) {
    final completer = Completer<T?>();
    step.then<void>(
      (value) {
        if (completer.isCompleted) {
          onLateValue?.call(value);
          return;
        }
        completer.complete(value);
      },
      onError: (Object error) {
        if (!completer.isCompleted) {
          completer.completeError(error);
        }
        // A late failure of an abandoned setup step is observed and dropped.
      },
    );
    unawaited(
      _cancellation.whenCancelled.then((_) {
        if (!completer.isCompleted) {
          completer.complete(null);
        }
      }),
    );
    return completer.future;
  }

  /// Releases a connection that lost the race against cancellation: closed
  /// immediately and exactly once (it was never published, so the memoized
  /// teardown does not know it); `response.create` is never sent on it.
  void _closeLateConnection(RealtimeConnection connection) {
    try {
      unawaited(connection.close().then<void>((_) {}, onError: (Object _) {}));
    } catch (_) {}
  }

  // --- Realtime server events → BackendEvent ---------------------------------

  void _handleServerEvent(String message) {
    if (_finished || _cancelled) {
      return; // late/duplicate events are ignored
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(message);
    } catch (_) {
      _finishError(FailureCause.upstream, 'malformed-event');
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      _finishError(FailureCause.upstream, 'malformed-event');
      return;
    }
    switch (decoded['type']) {
      case 'response.created':
        // The FIRST response.created is progress (see _handleResponseCreated);
        // a repeat is not, so the reset is guarded there by _acceptedEmitted.
        _handleResponseCreated(decoded);
      case 'response.output_text.delta':
        final Object? delta = decoded['delta'];
        if (delta is! String) {
          _finishError(FailureCause.upstream, 'malformed-event');
        } else if (delta.isNotEmpty) {
          // The event→BackendEvent mapping is unchanged: a non-empty delta is
          // emitted transparently. The watchdog reset is separate and only
          // fires when the event is real progress of the CURRENT Response.
          if (_isRealProgress('response.output_text.delta', decoded)) {
            _noteProgress();
          }
          _emit(BackendEvent.delta(delta));
        }
      case 'response.output_text.done':
      case 'response.content_part.added':
      case 'response.content_part.done':
        // Signal-only progress markers: reset the countdown (only when they
        // are real progress of the current Response) but produce no
        // BackendEvent.
        if (_isRealProgress(decoded['type'] as String, decoded)) {
          _noteProgress();
        }
      case 'response.output_item.added':
        if (_isRealProgress('response.output_item.added', decoded)) {
          _noteProgress();
        }
        _handleOutputItem(decoded, itemClosed: false);
      case 'response.output_item.done':
        if (_isRealProgress('response.output_item.done', decoded)) {
          _noteProgress();
        }
        _handleOutputItem(decoded, itemClosed: true);
      case 'response.function_call_arguments.delta':
        final call = _calls[decoded['output_index']];
        final Object? delta = decoded['delta'];
        if (call != null && delta is String) {
          if (_isRealProgress(
            'response.function_call_arguments.delta',
            decoded,
          )) {
            _noteProgress();
          }
          call.deltaArgs += delta;
        }
      case 'response.function_call_arguments.done':
        final call = _calls[decoded['output_index']];
        final Object? arguments = decoded['arguments'];
        if (call != null && arguments is String) {
          if (_isRealProgress(
            'response.function_call_arguments.done',
            decoded,
          )) {
            _noteProgress();
          }
          call.finalArgs = arguments;
        }
      case 'error':
        _handleErrorEvent(decoded);
      case 'response.done':
        _handleResponseDone(decoded);
      default:
        break; // every other event is non-terminal and ignored
    }
  }

  /// The watchdog attribution: is [event] of [type] real progress of the
  /// CURRENT Response? Deliberately NOT a full JSON-Schema parser — only the
  /// minimal structure needed to reject malformed and foreign events.
  ///
  /// Two gates apply to every progress event: (1) the current Response id must
  /// already be known (from the first valid `response.created`), and (2) the
  /// event's `response_id` must be that exact id. Until a valid Response id is
  /// known, nothing counts as progress. Each type then adds its own minimum
  /// structure.
  bool _isRealProgress(String type, Map<String, dynamic> event) {
    final currentId = _responseId;
    if (currentId == null) {
      return false;
    }
    final Object? responseId = event['response_id'];
    if (responseId is! String || responseId != currentId) {
      return false;
    }
    switch (type) {
      case 'response.output_text.delta':
        return _nonNegativeInt(event['output_index']) &&
            _nonNegativeInt(event['content_index']) &&
            event['item_id'] is String &&
            event['delta'] is String &&
            (event['delta'] as String).isNotEmpty;
      case 'response.output_text.done':
        return _nonNegativeInt(event['output_index']) &&
            _nonNegativeInt(event['content_index']) &&
            event['item_id'] is String &&
            event['text'] is String;
      case 'response.content_part.added':
      case 'response.content_part.done':
        return _nonNegativeInt(event['output_index']) &&
            _nonNegativeInt(event['content_index']) &&
            event['item_id'] is String &&
            event['part'] is Map<String, dynamic>;
      case 'response.output_item.added':
      case 'response.output_item.done':
        final Object? item = event['item'];
        return _nonNegativeInt(event['output_index']) &&
            item is Map<String, dynamic> &&
            item['type'] is String &&
            (item['type'] as String).isNotEmpty;
      case 'response.function_call_arguments.delta':
        final Object? index = event['output_index'];
        return index is int &&
            _calls.containsKey(index) &&
            event['delta'] is String &&
            (event['delta'] as String).isNotEmpty;
      case 'response.function_call_arguments.done':
        final Object? index = event['output_index'];
        return index is int &&
            _calls.containsKey(index) &&
            event['arguments'] is String;
      default:
        return false;
    }
  }

  static bool _nonNegativeInt(Object? value) => value is int && value >= 0;

  /// `Accepted` means exactly one thing: the server event `response.created`
  /// arrived. It is never emitted for the secret, the WebSocket handshake or
  /// the local dispatch.
  void _handleResponseCreated(Map<String, dynamic> event) {
    final Object? response = event['response'];
    final Object? id = response is Map<String, dynamic> ? response['id'] : null;
    final bool firstValidId =
        _responseId == null && id is String && id.isNotEmpty;
    if (firstValidId) {
      // Only the FIRST response.created carrying a non-empty response.id binds
      // the current Response and counts as progress; a repeat (or an id-less
      // event) resets nothing.
      _responseId = id;
      _noteProgress();
    }
    // The event→BackendEvent mapping is unchanged: Accepted is emitted once on
    // the first response.created regardless of the id.
    if (!_acceptedEmitted) {
      _acceptedEmitted = true;
      _emit(const BackendEvent.accepted());
    }
  }

  /// Registers the (at most one) function call of the leg from
  /// `response.output_item.added/done`; a second distinct call fails closed.
  /// Like the base package's server translator, the item's `arguments`
  /// become authoritative only when the item CLOSES — the `added` event
  /// carries an empty placeholder that must not shadow buffered deltas.
  void _handleOutputItem(
    Map<String, dynamic> event, {
    required bool itemClosed,
  }) {
    final Object? item = event['item'];
    if (item is! Map<String, dynamic> || item['type'] != 'function_call') {
      return;
    }
    final Object? index = event['output_index'];
    if (index is! int) {
      _finishError(FailureCause.upstream, 'malformed-event');
      return;
    }
    var call = _calls[index];
    if (call == null) {
      if (_firstCallIndex != null && _firstCallIndex != index) {
        _finishError(FailureCause.upstream, 'second-function-call');
        return;
      }
      _firstCallIndex = index;
      call = _CallState();
      _calls[index] = call;
    }
    final Object? callId = item['call_id'];
    if (callId is String) {
      call.callId = callId;
    }
    final Object? name = item['name'];
    if (name is String) {
      call.name = name;
    }
    final Object? arguments = item['arguments'];
    if (itemClosed && arguments is String) {
      call.finalArgs = arguments;
    }
  }

  /// A stream-level provider error event. The documented context overflow
  /// code maps to `contextTooLong` (mirroring the base package's server
  /// classifier); everything else is `upstream`. Raw code/message never
  /// relayed.
  void _handleErrorEvent(Map<String, dynamic> event) {
    final Object? error = event['error'];
    final Object? code = error is Map<String, dynamic> ? error['code'] : null;
    if (code == 'context_length_exceeded') {
      _finishError(FailureCause.contextTooLong, 'context-length-exceeded');
      return;
    }
    _finishError(FailureCause.upstream, 'server-error');
  }

  /// The terminal `response.done`: completed → `done`/`toolCall` (usage
  /// mandatory — absent or malformed usage is `upstream`, never faked
  /// zeros); documented content filter → `contentFilter`; documented context
  /// overflow → `contextTooLong`; every other outcome → `upstream`, with
  /// best-effort usage attached when it is valid.
  void _handleResponseDone(Map<String, dynamic> event) {
    final Object? response = event['response'];
    if (response is! Map<String, dynamic>) {
      _finishError(FailureCause.upstream, 'malformed-event');
      return;
    }
    final usage = _normalizeUsage(response['usage']);
    final Object? details = response['status_details'];
    switch (response['status']) {
      case 'completed':
        if (_calls.isNotEmpty) {
          _finishToolCall(usage);
          return;
        }
        if (usage == null) {
          _finishError(FailureCause.upstream, 'missing-usage');
          return;
        }
        _finish(BackendEvent.done(usage: usage));
      case 'incomplete':
        final Object? reason = details is Map<String, dynamic>
            ? details['reason']
            : null;
        _finishError(
          reason == 'content_filter'
              ? FailureCause.contentFilter
              : FailureCause.upstream,
          'response-incomplete',
          usage: usage,
        );
      case 'failed':
        final Object? error = details is Map<String, dynamic>
            ? details['error']
            : null;
        final Object? code = error is Map<String, dynamic>
            ? error['code']
            : null;
        _finishError(
          code == 'context_length_exceeded'
              ? FailureCause.contextTooLong
              : FailureCause.upstream,
          'response-failed',
          usage: usage,
        );
      default:
        // 'cancelled' (never legitimate for an uncancelled subscriber) or an
        // unknown terminal outcome.
        _finishError(FailureCause.upstream, 'unknown-terminal', usage: usage);
    }
  }

  /// The terminal `ToolCallEvent` is emitted only when the full arguments
  /// (a JSON object), call id, name and the leg usage are all present —
  /// anything less is one `upstream`.
  void _finishToolCall(Usage? usage) {
    if (_calls.length > 1) {
      _finishError(FailureCause.upstream, 'second-function-call');
      return;
    }
    final call = _calls.values.first;
    final argsText = call.finalArgs ?? call.deltaArgs;
    final Object? parsed;
    try {
      parsed = jsonDecode(argsText);
    } catch (_) {
      _finishError(FailureCause.upstream, 'malformed-function-call');
      return;
    }
    if (parsed is! Map<String, dynamic>) {
      _finishError(FailureCause.upstream, 'malformed-function-call');
      return;
    }
    final callId = call.callId;
    final name = call.name;
    if (callId == null || callId.isEmpty || name == null || name.isEmpty) {
      _finishError(FailureCause.upstream, 'malformed-function-call');
      return;
    }
    if (usage == null) {
      _finishError(FailureCause.upstream, 'missing-usage');
      return;
    }
    _finish(
      BackendEvent.toolCall(
        ToolCall(id: callId, name: name, args: parsed),
        usage: usage,
      ),
    );
  }

  /// `input_tokens`/`output_tokens` are accepted only as non-negative
  /// integers; anything else (or an absent usage object) yields `null`.
  /// `usageRaw` carries only the provider usage object.
  Usage? _normalizeUsage(Object? usage) {
    if (usage is! Map<String, dynamic>) {
      return null;
    }
    final Object? inputTokens = usage['input_tokens'];
    final Object? outputTokens = usage['output_tokens'];
    if (inputTokens is! int ||
        inputTokens < 0 ||
        outputTokens is! int ||
        outputTokens < 0) {
      return null;
    }
    return Usage(
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      usageRaw: usage,
    );
  }

  // --- transport death --------------------------------------------------------

  void _handleTransportError(Object error) {
    if (_finished || _cancelled) {
      return;
    }
    _finishError(
      _dispatchMayHaveReachedProvider
          ? FailureCause.upstream
          : FailureCause.network,
      'transport-error',
    );
  }

  /// EOF without a terminal event: post-dispatch ambiguity is `upstream`;
  /// before the commit boundary it is a plain transport failure.
  void _handleTransportDone() {
    if (_finished || _cancelled) {
      return;
    }
    _finishError(
      _dispatchMayHaveReachedProvider
          ? FailureCause.upstream
          : FailureCause.network,
      'transport-closed',
    );
  }

  // --- emission & terminal discipline ------------------------------------------

  void _emit(BackendEvent event) {
    if (_finished || _cancelled) {
      return;
    }
    _controller.add(event);
  }

  /// Exactly one terminal event, first-terminal-wins; after it the stream
  /// closes and all resources are released.
  void _finish(BackendEvent terminal) {
    if (_finished || _cancelled) {
      return;
    }
    _finished = true;
    // Any terminal (provider done/error, transport death, idle timeout)
    // disarms the watchdog so a late timer callback can never emit.
    _cancelIdleWatchdog();
    _controller.add(terminal);
    unawaited(_controller.close());
    unawaited(_teardown());
  }

  void _cancelIdleWatchdog() {
    _idleTimer?.cancel();
    _idleTimer = null;
  }

  void _finishError(FailureCause cause, String detail, {Usage? usage}) {
    _finish(BackendEvent.error(cause, detail: detail, usage: usage));
  }

  // --- cancellation & teardown ---------------------------------------------------

  /// Wire-cancel (subscription cancellation): synchronously mark the
  /// operation cancelled, best-effort send `response.cancel` when the
  /// dispatch may have reached the provider, fire the cancellation signal
  /// (actively interrupting any pending setup wait and telling the
  /// transport to abort and release partial resources), then release
  /// everything. Also invoked by the controller after a normal terminal
  /// close — then it only awaits the already-running teardown. Teardown
  /// defects never become a stream error.
  ///
  /// Pre-dispatch there is nothing in flight to cancel remotely, so no
  /// `response.cancel` is sent; the signal fires without any await before
  /// it. Post-dispatch no setup can still be pending, so keeping the
  /// existing best-effort `response.cancel` ahead of the signal preserves
  /// its delivery chance.
  Future<void> _onSubscriptionCancel() async {
    _cancelled = true;
    // The subscriber cancel disarms the watchdog: no late idle-timeout
    // terminal after the user has cancelled.
    _cancelIdleWatchdog();
    if (_dispatchMayHaveReachedProvider && !_finished) {
      final connection = _connection;
      if (connection != null) {
        try {
          await connection.send(
            jsonEncode(<String, dynamic>{
              'type': 'response.cancel',
              if (_responseId != null) 'response_id': _responseId,
            }),
          );
        } catch (_) {
          // Best-effort only.
        }
      }
    }
    _cancellation.cancel();
    await _teardown();
  }

  /// Idempotent: every trigger (terminal, cancellation, both) awaits the
  /// same single release.
  Future<void> _teardown() => _teardownFuture ??= _releaseResources();

  Future<void> _releaseResources() async {
    final events = _events;
    _events = null;
    if (events != null) {
      try {
        await events.cancel();
      } catch (_) {}
    }
    final connection = _connection;
    _connection = null;
    if (connection != null) {
      try {
        await connection.close();
      } catch (_) {}
    }
  }
}
