// A one-shot cancellation token for one probe connect/session (Increment-0
// spike). Mirrors the removed WebRTC transport's cancellation idea, kept
// probe-local. Cancelling is idempotent.
import 'dart:async';

class ProbeCancellation {
  final Completer<void> _completer = Completer<void>();

  bool get isCancelled => _completer.isCompleted;

  /// Resolves when cancellation is requested. Deliberately a value future
  /// (never an error) so an unawaited listener cannot park an unhandled error.
  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (!_completer.isCompleted) {
      _completer.complete();
    }
  }
}
