// The production RealtimeTransport: one direct OpenAI Realtime WebSocket per
// `connect()` leg — `wss://api.openai.com/v1/realtime?model=<model>` opened
// with `dart:io WebSocket.connect`, the ephemeral secret carried ONLY as the
// `Authorization: Bearer <secret>` HTTP header of the upgrade request. No
// WebRTC, no SDP/ICE, no data channel, no microphone/camera, no native
// audio/video dependency.
//
// One session per send: nothing is pooled, reused, reconnected or retried.
// The WebSocket and WebRTC transports speak the SAME Realtime client/server
// events, so the request translator and the server-event handling are shared
// unchanged.
//
// Cancellation & ownership: every resource of one connect attempt is owned by
// a RealtimeSetupRelease coordinator the instant it exists — including a
// socket whose handshake Future completes only AFTER cancellation already
// swept (it is then closed immediately on adoption). A wire-cancel force-
// closes the pending-handshake HttpClient, which actively aborts an in-flight
// `WebSocket.connect`. Release is memoized and exactly-once per resource; the
// closers are shared with the connection wrapper so no path closes a socket
// or client twice. A cancelled connect fails as `RealtimeConnectCancelled`,
// which the send operation swallows.
//
// No secret, URL or provider frame ever leaves this file through an exception
// message that could reach an event `detail` — the send operation maps any
// throw here to a sanitized marker anyway, and a binary frame surfaces only a
// content-free marker.

// The transport constructors below deliberately assign their named parameters
// to private fields — the initializing-formal shorthand would make the
// parameter names private (the same audit finding as the public backend
// constructor).
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:io';

import 'realtime_setup_release.dart';
import 'realtime_transport.dart';

/// The fixed Realtime WebSocket base URL (the model rides as a query param).
const String realtimeWebSocketBaseUrl = 'wss://api.openai.com/v1/realtime';

/// A content-free marker for a non-text (binary) WebSocket frame — a protocol
/// violation for this text-only transport. Never carries the bytes.
class RealtimeBinaryFrameException implements Exception {
  const RealtimeBinaryFrameException();
}

/// A content-free marker for a WebSocket stream error — never the raw error.
class RealtimeSocketException implements Exception {
  const RealtimeSocketException();
}

/// The minimal WebSocket surface this transport needs — satisfied by
/// `dart:io WebSocket` in production and by a fake in tests. Never exported.
abstract interface class RealtimeWebSocket {
  /// One frame per event: a `String` for a text frame, anything else for a
  /// binary frame (its bytes are never forwarded downstream).
  Stream<dynamic> get frames;

  /// Enqueues one text frame.
  void add(String message);

  /// Closes the socket. Idempotent at this layer's callers.
  Future<void> close();
}

/// Opens one Realtime WebSocket to [url] authorized by [clientSecret], using
/// [client] as the customClient so a wire-cancel can force-close the pending
/// handshake. Injected for tests.
typedef RealtimeWebSocketOpener =
    Future<RealtimeWebSocket> Function(
      Uri url,
      String clientSecret,
      HttpClient client,
    );

/// Builds the exact Realtime WebSocket URL for [model]: the fixed base with
/// the URL-encoded model as the single `model` query parameter. The secret is
/// NEVER placed in the URL.
Uri buildRealtimeWebSocketUrl(String model) => Uri.parse(
  realtimeWebSocketBaseUrl,
).replace(queryParameters: <String, String>{'model': model});

/// The production opener: `dart:io WebSocket.connect` with the ephemeral
/// secret as the ONLY credential header. The secret is never logged, never in
/// the URL, never a subprotocol. Package-internal (directly exercised by the
/// transport's regression tests); NOT exported from the barrel.
Future<RealtimeWebSocket> openRealtimeWebSocket(
  Uri url,
  String clientSecret,
  HttpClient client,
) async {
  final socket = await WebSocket.connect(
    url.toString(),
    headers: <String, dynamic>{
      HttpHeaders.authorizationHeader: 'Bearer $clientSecret',
    },
    customClient: client,
  );
  return _IoRealtimeWebSocket(socket);
}

/// The production wrapper over a `dart:io WebSocket`.
class _IoRealtimeWebSocket implements RealtimeWebSocket {
  _IoRealtimeWebSocket(this._socket);

  final WebSocket _socket;

  @override
  Stream<dynamic> get frames => _socket;

  @override
  void add(String message) => _socket.add(message);

  @override
  Future<void> close() async {
    await _socket.close();
  }
}

/// One WebSocket session per [connect] call; nothing is shared or pooled.
class WebSocketRealtimeTransport implements RealtimeTransport {
  WebSocketRealtimeTransport({required String model})
    : _url = buildRealtimeWebSocketUrl(model),
      _open = openRealtimeWebSocket,
      _createHttpClient = HttpClient.new;

  /// Package-internal seam for deterministic orchestration tests: injects the
  /// WebSocket opener and the HttpClient factory. Never exported.
  WebSocketRealtimeTransport.forTesting({
    required String model,
    required RealtimeWebSocketOpener open,
    HttpClient Function()? createHttpClient,
  }) : _url = buildRealtimeWebSocketUrl(model),
       _open = open,
       _createHttpClient = createHttpClient ?? HttpClient.new;

  final Uri _url;
  final RealtimeWebSocketOpener _open;
  final HttpClient Function() _createHttpClient;

  @override
  Future<RealtimeConnection> connect(
    String clientSecret,
    RealtimeCancellation cancellation,
  ) async {
    final resources = RealtimeSetupRelease();
    // Active interruption: the sweep force-closes the handshake client (and
    // with it the pending upgrade request), the socket and the connection
    // wrapper, which makes every await below fail fast. The catch awaits the
    // memoized sweep, and a LATE socket — one that materialized only after the
    // sweep — is held by its own adopt(): this connect future never resolves
    // before every materialized resource has actually finished closing.
    unawaited(cancellation.whenCancelled.then((_) => resources.releaseAll()));

    try {
      _throwIfCancelled(cancellation);
      final client = _createHttpClient();
      // Force-closing the client aborts an in-flight WebSocket handshake.
      final closeClient = RealtimeSetupRelease.once(
        () async => client.close(force: true),
      );
      await resources.register(closeClient);
      _throwIfCancelled(cancellation);
      // Adopted the instant the handshake completes: a socket that
      // materializes only after cancellation swept is closed right there, and
      // adopt() resolves only once that close has finished.
      final socket = await resources.adopt(
        _open(_url, clientSecret, client),
        (RealtimeWebSocket resource) => resource.close(),
      );
      _throwIfCancelled(cancellation);
      // The wrapper shares the exactly-once closers with the coordinator:
      // whichever path closes first wins, none closes twice.
      final connection = WebSocketRealtimeConnection(
        socket.resource,
        closeSocket: socket.close,
        closeClient: closeClient,
      );
      // Awaited for the same reason adopt() awaits: should this registration
      // lose a race against the sweep, connect may not resolve before the
      // wrapper has actually finished closing.
      await resources.register(RealtimeSetupRelease.once(connection.close));
      _throwIfCancelled(cancellation);
      return connection;
    } catch (_) {
      await resources.releaseAll();
      // Canonicalize the cancelled outcome: an abort that surfaced as a raw
      // transport error (e.g. the force-closed handshake throwing
      // SocketException) becomes the internal RealtimeConnectCancelled the
      // send operation expects. A genuine network handshake failure (not
      // cancelled) keeps its original error via rethrow.
      if (cancellation.isCancelled) {
        throw const RealtimeConnectCancelled();
      }
      rethrow;
    }
  }
}

void _throwIfCancelled(RealtimeCancellation cancellation) {
  if (cancellation.isCancelled) {
    throw const RealtimeConnectCancelled();
  }
}

/// Package-internal wrapper that owns one live WebSocket session's frame
/// subscription. Directly instantiable by the transport's tests; never
/// exported — not public API.
class WebSocketRealtimeConnection implements RealtimeConnection {
  /// [closeSocket]/[closeClient] are the transport's exactly-once closers so
  /// the coordinator and this wrapper can never double-close the socket or
  /// the handshake client.
  WebSocketRealtimeConnection(
    this._socket, {
    required Future<void> Function() closeSocket,
    required Future<void> Function() closeClient,
  }) : _closeSocket = closeSocket,
       _closeClient = closeClient {
    _subscription = _socket.frames.listen(
      _onFrame,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: false,
    );
  }

  final RealtimeWebSocket _socket;
  final Future<void> Function() _closeSocket;
  final Future<void> Function() _closeClient;
  final StreamController<String> _events = StreamController<String>();
  StreamSubscription<dynamic>? _subscription;
  Future<void>? _closing;

  void _onFrame(dynamic frame) {
    if (_events.isClosed) {
      return;
    }
    if (frame is String) {
      // Transparent passthrough: one JSON string per server event, verbatim.
      _events.add(frame);
    } else {
      // A binary frame is a controlled protocol failure: only a content-free
      // marker reaches the stream (never the bytes); the send operation maps
      // it by its commit boundary.
      _events.addError(const RealtimeBinaryFrameException());
    }
  }

  void _onError(Object _) {
    // Sanitized: the raw socket error is never forwarded.
    if (!_events.isClosed) {
      _events.addError(const RealtimeSocketException());
    }
  }

  void _onDone() {
    // EOF: the send operation classifies it by its commit boundary.
    if (!_events.isClosed) {
      unawaited(_events.close());
    }
  }

  @override
  Stream<String> get events => _events.stream;

  @override
  Future<void> send(String message) async {
    // One text frame, unchanged; a closed socket throws and the caller maps
    // it by the commit boundary.
    _socket.add(message);
  }

  @override
  Future<void> close() => _closing ??= _closeOnce();

  Future<void> _closeOnce() async {
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) {
      try {
        await subscription.cancel();
      } catch (_) {}
    }
    await _closeSocket();
    await _closeClient();
    if (!_events.isClosed) {
      // Fire-and-forget: `close()` on a single-subscription controller only
      // completes once its `done` reaches a subscriber, and teardown must not
      // block on whether anyone is still listening.
      unawaited(_events.close());
    }
  }
}
