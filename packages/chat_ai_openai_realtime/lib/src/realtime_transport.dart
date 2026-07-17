import 'dart:async';

/// Package-internal cancellation signal of one send operation. Monotonic:
/// once cancelled it stays cancelled. The send operation cancels it from the
/// subscription's wire-cancel; setup code observes it either by polling
/// [isCancelled] between steps or by listening to [whenCancelled] to abort a
/// pending wait actively. Never exported — not public API.
class RealtimeCancellation {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  /// Completes when (and only if) the operation is cancelled.
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) {
      _cancelled.complete();
    }
  }
}

/// Thrown by a transport that abandons setup because the operation was
/// cancelled. The send operation swallows it — it never surfaces as a
/// stream error nor as a `BackendEvent`.
class RealtimeConnectCancelled implements Exception {
  const RealtimeConnectCancelled();
}

/// Package-internal transport seam: establishes one OpenAI Realtime session
/// per `send()` leg. Production uses `WebSocketRealtimeTransport` (a direct
/// `wss://api.openai.com/v1/realtime` connection); tests use a fake. Never
/// exported — not public API.
abstract interface class RealtimeTransport {
  /// Establishes one connection authorized by [clientSecret] as the Bearer
  /// credential. The returned connection is live and ready (for a WebSocket
  /// that is the moment the handshake completes).
  ///
  /// A throw here is a pre-dispatch transport failure (`network` by the
  /// money-safe commit boundary). When [cancellation] fires, the transport
  /// must actively abort the pending setup, release every partial resource
  /// it created (HTTP client / pending handshake, socket, listeners) and
  /// fail — [RealtimeConnectCancelled] by convention; the caller ignores the
  /// outcome of a cancelled connect either way.
  Future<RealtimeConnection> connect(
    String clientSecret,
    RealtimeCancellation cancellation,
  );
}

/// One live Realtime session owned by a single send operation.
abstract interface class RealtimeConnection {
  /// Server events, one JSON string per event. Closes (or errors) when the
  /// connection dies; single-subscription. A non-text (binary) frame is a
  /// controlled protocol failure surfaced as a stream error, never its
  /// bytes.
  Stream<String> get events;

  /// Sends one serialized client event as a single text message. May throw —
  /// the caller maps the failure by the commit boundary.
  Future<void> send(String message);

  /// Tears down the connection. Idempotent; never throws meaningfully
  /// (callers swallow teardown errors regardless).
  Future<void> close();
}
