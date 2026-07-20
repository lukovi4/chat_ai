// Narrow, package-local test seams. A fake transport, provider and watchdog
// timer drive the session's money-safe / lifecycle behaviour with no native
// WebRTC and no real clock. Not a networking framework or a mock OpenAI SDK.
import 'dart:async';

import 'package:chat_ai/chat_ai.dart' show BotProfile, Tool;
import 'package:chat_ai_openai_realtime/chat_ai_openai_realtime.dart'
    show ClientSecretProvider;
import 'package:chat_ai_openai_realtime_voice/src/voice_cancellation.dart';
import 'package:chat_ai_openai_realtime_voice/src/voice_recorder.dart';
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
  // Every client-event type the session ATTEMPTED to send, in order — including
  // ones whose send threw (so a test can assert an event was attempted exactly
  // once even on a send failure). `sent` holds only the successful ones.
  final List<String> sendAttempts = <String>[];
  // Client-event types whose send() should throw (interrupt send-failure tests).
  Set<String> failSendTypes = <String>{};
  // Optional send GATE: when set, send() records + queues the event synchronously
  // (so a test can inspect the queued payload immediately) but its Future only
  // completes once this gate is completed — letting a test inject events while
  // programmatic cancel/clear are still in flight. Null by default → send()
  // behaves byte-for-byte as before.
  Completer<void>? sendGate;
  final List<bool> enabledCalls = <bool>[];
  int closeCalls = 0;

  /// The local track id the recording tap would attach to (recording tests).
  String? localTrackId = 'local-track-1';
  final Completer<String> _remoteId = Completer<String>();

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

  /// Simulates the remote (assistant) audio track arriving (recording tests).
  void completeRemoteTrack([String id = 'remote-track-1']) {
    if (!_remoteId.isCompleted) {
      _remoteId.complete(id);
    }
  }

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  String? get localAudioTrackId => localTrackId;

  @override
  Future<String> get remoteAudioTrackId => _remoteId.future;

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
  Future<void> send(Map<String, Object?> event) async {
    final type = event['type'];
    if (type is String) {
      sendAttempts.add(type);
      if (failSendTypes.contains(type)) {
        throw StateError('fake send failure: $type');
      }
    }
    sent.add(event);
    // Default (no gate): completes immediately — identical to the old behaviour.
    final gate = sendGate;
    if (gate != null) {
      await gate.future;
    }
  }

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

/// A Dart-only fake recorder: it records exactly which commands the coordinator
/// issues (and, crucially, that NO audio/PCM/base64 ever crosses) and lets a
/// test drive per-segment finalize outcomes deterministically. It never touches
/// a real MethodChannel or native writer.
class FakeRecorder implements RealtimeVoiceRecorder {
  FakeRecorder({required this.isRemote, this.pathPrefix = '/rec'});

  final bool isRemote;
  final String pathPrefix;

  /// Every command in order, as `attach:<trackId>` / `begin:<seg>` /
  /// `end:<seg>` / `close`.
  final List<String> commands = <String>[];
  final List<String> begun = <String>[];
  final List<String> ended = <String>[];
  String? attachedTrackId;
  int attachCalls = 0;
  int closeCalls = 0;

  /// Failure injection.
  bool attachThrows = false;
  bool beginThrows = false;
  bool endThrows = false;

  /// Per-segment finalize overrides; otherwise a valid `.m4a` path is returned.
  final Map<String, VoiceRecordingSegmentResult> results =
      <String, VoiceRecordingSegmentResult>{};

  /// When set, the endSegment result is computed on demand (e.g. always-fail).
  VoiceRecordingSegmentResult Function(String segmentId)? resultFor;

  @override
  Future<void> attach({required String trackId}) async {
    attachCalls++;
    attachedTrackId = trackId;
    commands.add('attach:$trackId');
    if (attachThrows) {
      throw const RealtimeVoiceRecorderException();
    }
  }

  @override
  Future<void> beginSegment(String segmentId) async {
    begun.add(segmentId);
    commands.add('begin:$segmentId');
    if (beginThrows) {
      throw const RealtimeVoiceRecorderException();
    }
  }

  @override
  Future<VoiceRecordingSegmentResult> endSegment(String segmentId) async {
    ended.add(segmentId);
    commands.add('end:$segmentId');
    if (endThrows) {
      throw const RealtimeVoiceRecorderException();
    }
    final override = results[segmentId] ?? resultFor?.call(segmentId);
    return override ??
        VoiceRecordingSegmentResult(
          ok: true,
          filePath: '$pathPrefix/$segmentId.m4a',
        );
  }

  @override
  Future<void> close() async {
    closeCalls++;
    commands.add('close');
  }
}

/// Builds [FakeRecorder]s and keeps a handle to each side so a test can assert
/// commands and inject failures.
class FakeRecorderFactory {
  FakeRecorderFactory({this.configure});

  /// Optional per-recorder setup applied at creation (failure injection etc.).
  final void Function(FakeRecorder recorder)? configure;

  final List<FakeRecorder> created = <FakeRecorder>[];
  FakeRecorder? user;
  FakeRecorder? assistant;

  RealtimeVoiceRecorder call({required bool isRemote}) {
    final recorder = FakeRecorder(isRemote: isRemote);
    created.add(recorder);
    if (isRemote) {
      assistant = recorder;
    } else {
      user = recorder;
    }
    configure?.call(recorder);
    return recorder;
  }
}

/// Advances the event loop enough for the session's async event handlers to
/// settle (they are dispatched unawaited from the stream subscription).
Future<void> pumpEventLoop([int rounds = 12]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
