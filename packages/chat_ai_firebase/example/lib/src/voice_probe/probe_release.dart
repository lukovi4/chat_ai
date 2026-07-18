// A memoized, exactly-once teardown coordinator for one probe session
// (Increment-0 spike). Adapted from the removed WebRTC transport's
// RealtimeSetupRelease idea, re-implemented probe-locally (that type is
// package-private to chat_ai_openai_realtime and is not touched here).
//
// Guarantees:
// - every registered closer runs at most once, even across concurrent
//   release + late registration;
// - a resource whose creation completes only AFTER release already swept is
//   adopted and closed immediately (cancel-during-signaling safety);
// - one closer throwing never stops the others and never escapes as an
//   unhandled async error.
import 'dart:async';

/// Wraps a closer so it runs at most once; concurrent callers await the same
/// run.
Future<void> Function() _once(Future<void> Function() close) {
  Future<void>? running;
  return () => running ??= close();
}

class ProbeRelease {
  final List<Future<void> Function()> _closers = <Future<void> Function()>[];
  Future<void>? _releasing;

  bool get isReleased => _releasing != null;

  /// Registers an exactly-once [close]. If release already started, the closer
  /// is invoked immediately (and its completion is awaited by the caller).
  Future<void> register(Future<void> Function() close) async {
    final closer = _once(close);
    if (isReleased) {
      await _guard(closer);
      return;
    }
    _closers.add(closer);
  }

  /// Awaits [resource]; registers [close] for it. If the coordinator released
  /// while the resource was materializing, the resource is closed right here
  /// and the returned future completes only once that close has finished.
  Future<T> adopt<T>(
    Future<T> resource,
    Future<void> Function(T resource) close,
  ) async {
    final value = await resource;
    final closer = _once(() => close(value));
    if (isReleased) {
      await _guard(closer);
      return value;
    }
    _closers.add(closer);
    return value;
  }

  /// Runs every closer exactly once in LIFO order (newest first): the
  /// DataChannel closes before its PeerConnection, a track before its
  /// MediaStream. Memoized: repeated calls await the same sweep. A closer's
  /// failure is swallowed so the rest still close.
  Future<void> releaseAll() => _releasing ??= _releaseAllOnce();

  Future<void> _releaseAllOnce() async {
    // Snapshot then clear: a closer registered during the sweep is handled by
    // register()/adopt()'s immediate path, never left dangling.
    final closers = List<Future<void> Function()>.of(_closers);
    _closers.clear();
    for (final closer in closers.reversed) {
      await _guard(closer);
    }
  }

  static Future<void> _guard(Future<void> Function() closer) async {
    try {
      await closer();
    } catch (_) {
      // Deliberately swallowed: teardown of one resource must not block the
      // others, and no native/transport detail is surfaced.
    }
  }
}
