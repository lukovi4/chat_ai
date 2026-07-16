// One `ChatBackend.send()` leg over one OpenAI Realtime WebRTC session.
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
// No raw OpenAI error message, SDP, secret, prompt or stack trace ever
// reaches an event `detail` — details are stable machine markers only.

import 'dart:async';
import 'dart:convert';

import 'package:chat_ai/chat_ai.dart';

import 'client_secret_provider.dart';
import 'realtime_request_translator.dart';
import 'realtime_transport.dart';

/// Runs one backend leg. Package-internal seam: the public backend passes
/// the production WebRTC transport; tests pass a fake.
Stream<BackendEvent> runRealtimeSend({
  required ClientSecretProvider clientSecretProvider,
  required RealtimeTransport transport,
  required ChatRequest request,
}) {
  return _RealtimeSendOperation(
    clientSecretProvider,
    transport,
    request,
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
  _RealtimeSendOperation(this._provider, this._transport, this._request) {
    _controller = StreamController<BackendEvent>(
      onListen: () => unawaited(_run()),
      onCancel: _onSubscriptionCancel,
    );
  }

  final ClientSecretProvider _provider;
  final RealtimeTransport _transport;
  final ChatRequest _request;

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

    // 2–7. One fresh WebRTC session: peer connection, `oai-events` data
    // channel, official SDP signaling, channel open. All of it is before the
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

    // 8. Exactly one `response.create`. A local build defect never dispatches.
    final String payload;
    try {
      payload = jsonEncode(buildResponseCreateEvent(_request));
    } catch (_) {
      _finishError(FailureCause.upstream, 'request-build-failed');
      return;
    }
    // ---- MONEY-SAFE COMMIT BOUNDARY ----------------------------------------
    // Set BEFORE the transport send, not after its success: even a
    // synchronous exception below is an ambiguous possible dispatch.
    _dispatchMayHaveReachedProvider = true;
    try {
      await connection.send(payload);
    } catch (_) {
      if (_cancelled || _finished) {
        return;
      }
      _finishError(FailureCause.upstream, 'transport-send-failed');
      return;
    }
    // From here the leg is driven by server events (or transport death).
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
        _handleResponseCreated(decoded);
      case 'response.output_text.delta':
        final Object? delta = decoded['delta'];
        if (delta is! String) {
          _finishError(FailureCause.upstream, 'malformed-event');
        } else if (delta.isNotEmpty) {
          // Transparent passthrough: never merge, split or reorder; drop
          // empties.
          _emit(BackendEvent.delta(delta));
        }
      case 'response.output_item.added':
        _handleOutputItem(decoded, itemClosed: false);
      case 'response.output_item.done':
        _handleOutputItem(decoded, itemClosed: true);
      case 'response.function_call_arguments.delta':
        final call = _calls[decoded['output_index']];
        final Object? delta = decoded['delta'];
        if (call != null && delta is String) {
          call.deltaArgs += delta;
        }
      case 'response.function_call_arguments.done':
        final call = _calls[decoded['output_index']];
        final Object? arguments = decoded['arguments'];
        if (call != null && arguments is String) {
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

  /// `Accepted` means exactly one thing: the server event `response.created`
  /// arrived. It is never emitted for the secret, the peer connection, the
  /// SDP exchange, the channel opening or the local dispatch.
  void _handleResponseCreated(Map<String, dynamic> event) {
    final Object? response = event['response'];
    if (response is Map<String, dynamic>) {
      final Object? id = response['id'];
      if (_responseId == null && id is String && id.isNotEmpty) {
        _responseId = id;
      }
    }
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
    _controller.add(terminal);
    unawaited(_controller.close());
    unawaited(_teardown());
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
