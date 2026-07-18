// A one-shot cancellation token for the single voice connect/session. Mirrors
// the accepted feasibility probe's cancellation idea, kept package-local (that
// probe type lives in the example harness and is not touched here). Cancelling
// is idempotent.
import 'dart:async';

/// One connect/session owns exactly one of these. `stop()`/`dispose()` cancel
/// it; every setup await-boundary consults it so a cancel unwinds fast.
class RealtimeVoiceCancellation {
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
