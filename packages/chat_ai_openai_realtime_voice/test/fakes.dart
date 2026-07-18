// Narrow, package-local test seams. A fake transport, provider and watchdog
// timer drive the session's money-safe / lifecycle behaviour with no native
// WebRTC and no real clock. Not a networking framework or a mock OpenAI SDK.
import 'dart:async';

import 'package:chat_ai/chat_ai.dart' show BotProfile, Tool;
import 'package:chat_ai_openai_realtime/chat_ai_openai_realtime.dart'
    show ClientSecretProvider;
import 'package:chat_ai_openai_realtime_voice/src/voice_cancellation.dart';
import 'package:chat_ai_openai_realtime_voice/src/voice_transport.dart';

/// A minimal bot profile for the session tests. [tools] defaults to empty
/// (the only shape this increment accepts).
BotProfile botProfile({List<Tool> tools = const <Tool>[]}) =>
    BotProfile(id: 'bot', systemPrompt: 'be brief', tools: tools);

/// Counts mints and can be made to fail. Exactly one call per Start is the
/// invariant.
class FakeClientSecretProvider implements ClientSecretProvider {
  FakeClientSecretProvider({this.secret = 'secret-value'});

  final String secret;
  int calls = 0;
  Object? throwError;

  @override
  Future<String> getClientSecret({required String botId}) async {
    calls++;
    if (throwError != null) {
      throw throwError!;
    }
    return secret;
  }
}

/// A fully controllable [RealtimeVoiceTransport]: the test pushes events and
/// records every command the session issues.
class FakeRealtimeVoiceTransport implements RealtimeVoiceTransport {
  final StreamController<Map<String, Object?>> _events =
      StreamController<Map<String, Object?>>.broadcast();

  int connectCalls = 0;
  Object? connectError;

  /// When set, connect awaits this before returning — lets a test cancel while
  /// signaling is in flight.
  Completer<void>? connectGate;

  /// Events the transport emits from INSIDE connect() (before its Future
  /// completes) — models an early DataChannel message such as session.created.
  final List<Map<String, Object?>> emitDuringConnect = <Map<String, Object?>>[];

  final List<Map<String, Object?>> sent = <Map<String, Object?>>[];
  final List<bool> enabledCalls = <bool>[];
  int closeCalls = 0;

  void emit(Map<String, Object?> event) {
    if (!_events.isClosed) {
      _events.add(event);
    }
  }

  void endEvents() {
    if (!_events.isClosed) {
      _events.close();
    }
  }

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<void> connect(
    String clientSecret,
    RealtimeVoiceCancellation cancellation,
  ) async {
    connectCalls++;
    final gate = connectGate;
    if (gate != null) {
      await gate.future;
    }
    for (final event in emitDuringConnect) {
      emit(event);
    }
    if (connectError != null) {
      throw connectError!;
    }
  }

  @override
  void setMicrophoneEnabled(bool enabled) => enabledCalls.add(enabled);

  @override
  Future<void> send(Map<String, Object?> event) async => sent.add(event);

  @override
  Future<void> close() async {
    closeCalls++;
    if (!_events.isClosed) {
      await _events.close();
    }
  }
}

/// A deterministic [Timer] the test fires by hand — no real clock, no
/// fake_async. Each kick cancels the previous and creates a new one.
class FakeWatchdogTimer implements Timer {
  FakeWatchdogTimer(this.duration, this.callback);

  final Duration duration;
  final void Function() callback;
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  @override
  bool get isActive => !_cancelled;

  @override
  int get tick => 0;

  @override
  void cancel() => _cancelled = true;

  void fire() {
    if (!_cancelled) {
      callback();
    }
  }
}

/// Records every watchdog timer the session creates so a test can assert which
/// events kicked (recreated) it and fire the live one.
class FakeWatchdogTimerFactory {
  final List<FakeWatchdogTimer> created = <FakeWatchdogTimer>[];

  Timer call(Duration duration, void Function() onTimeout) {
    final timer = FakeWatchdogTimer(duration, onTimeout);
    created.add(timer);
    return timer;
  }

  /// The most recently created, not-yet-cancelled timer (the live watchdog).
  FakeWatchdogTimer? get active {
    for (final timer in created.reversed) {
      if (!timer.isCancelled) {
        return timer;
      }
    }
    return null;
  }
}

/// Advances the event loop enough for the session's async event handlers to
/// settle (they are dispatched unawaited from the stream subscription).
Future<void> pumpEventLoop([int rounds = 12]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
