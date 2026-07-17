import 'dart:async';

/// Package-internal owner of one connect attempt's resources (the transport's
/// socket/connection wrapper and the handshake HttpClient). A transport-
/// neutral coordinator — no WebSocket or WebRTC specifics leak in here. Never
/// exported — not public API.
///
/// The problem it solves: a resource whose creation Future is still pending
/// when cancellation sweeps would otherwise be orphaned — the sweep sees
/// nothing to close, and the resource materializes afterwards with no owner.
/// Here every resource is adopted the instant its Future completes — before
/// any awaiter's continuation runs. A registration that arrives after
/// release began runs the closer right there, and [adopt] AWAITS that late
/// close: the adopter's continuation (and with it the transport's connect
/// future) cannot resolve before the late resource is actually released.
///
/// Release is memoized: every trigger — concurrent ones included — awaits
/// the SAME actual cleanup, and none of them completes before it does.
/// Closers are exactly-once and swallow their own errors, so no teardown
/// defect ever reaches a stream or the Zone.
class RealtimeSetupRelease {
  final List<Future<void> Function()> _closers = <Future<void> Function()>[];
  Future<void>? _releasing;

  /// Wraps a native close so it runs at most once, swallows its errors, and
  /// every caller awaits the same completion — safe to share between this
  /// coordinator and any other owner of the same underlying resource.
  static Future<void> Function() once(Future<void> Function() close) {
    Future<void>? closing;
    return () => closing ??= _swallow(close);
  }

  static Future<void> _swallow(Future<void> Function() close) async {
    try {
      await close();
    } catch (_) {}
  }

  /// Adopts the resource created by [pending] the instant it completes, so
  /// even a resource that materializes after release began is owned. In
  /// that late case the returned future does not resolve until the
  /// resource's actual close has finished — the adopter can never run ahead
  /// of the real release. Returns the resource paired with its exactly-once
  /// closer. A failed [pending] simply rethrows — there is nothing to own.
  Future<RealtimeOwnedResource<T>> adopt<T extends Object>(
    Future<T> pending,
    Future<void> Function(T resource) close,
  ) {
    return pending.then((resource) async {
      final closer = once(() => close(resource));
      await register(closer);
      return RealtimeOwnedResource<T>(resource, closer);
    });
  }

  /// Registers an idempotent [closer]. Before release begins the closer
  /// simply joins the sweep and the returned future is already complete.
  /// When release has already begun the resource missed the sweep — the
  /// closer runs right here, and the returned future completes only once
  /// the resource is actually released (errors swallowed here too, so a
  /// raw closer cannot leak an unhandled error).
  Future<void> register(Future<void> Function() closer) {
    if (_releasing != null) {
      return _swallow(closer);
    }
    _closers.add(closer);
    return Future<void>.value();
  }

  /// Releases everything registered so far, newest first. Memoized: every
  /// trigger awaits the same actual cleanup; a repeated call never returns
  /// ahead of the cleanup already in flight.
  Future<void> releaseAll() => _releasing ??= _releaseEverything();

  Future<void> _releaseEverything() async {
    for (final closer in _closers.reversed.toList(growable: false)) {
      await _swallow(closer);
    }
  }
}

/// A live resource paired with its exactly-once, error-swallowing closer.
class RealtimeOwnedResource<T extends Object> {
  RealtimeOwnedResource(this.resource, this.close);

  final T resource;
  final Future<void> Function() close;
}
