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

/// Package-internal transport seam: establishes one OpenAI Realtime WebRTC
/// session (peer connection + `oai-events` data channel + SDP signaling)
/// per `send()` leg. Production uses `WebRtcRealtimeTransport`; tests use a
/// fake. Never exported — not public API.
abstract interface class RealtimeTransport {
  /// Establishes one connection: a new peer connection, the `oai-events`
  /// data channel, the official SDP exchange authorized by [clientSecret]
  /// as the Bearer credential, and waits for the channel to open.
  ///
  /// A throw here is a pre-dispatch transport failure (`network` by the
  /// money-safe commit boundary). When [cancellation] fires, the transport
  /// must actively abort the pending setup, release every partial resource
  /// it created (HTTP client/pending signaling request, data channel, peer
  /// connection, listeners) and fail — [RealtimeConnectCancelled] by
  /// convention; the caller ignores the outcome of a cancelled connect
  /// either way.
  Future<RealtimeConnection> connect(
    String clientSecret,
    RealtimeCancellation cancellation,
  );
}

/// One live Realtime session owned by a single send operation.
abstract interface class RealtimeConnection {
  /// Server events from the `oai-events` data channel, one JSON string per
  /// event. Closes (or errors) when the data channel or peer connection
  /// dies; single-subscription.
  Stream<String> get events;

  /// Sends one serialized client event over the data channel. May throw —
  /// the caller maps the failure by the commit boundary.
  Future<void> send(String message);

  /// Tears down the data channel and peer connection. Idempotent; never
  /// throws meaningfully (callers swallow teardown errors regardless).
  Future<void> close();
}
