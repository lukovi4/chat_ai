// Narrow test seams for the voice probe (probe-only; no production package is
// touched). A fake transport and provider drive the controller's money-safe /
// lifecycle behaviour with no native WebRTC, and a mock method channel records
// exactly what the native audio-writer facade sends.
import 'dart:async';

import 'package:chat_ai_openai_realtime/chat_ai_openai_realtime.dart'
    show ClientSecretProvider;
import 'package:example/src/voice_probe/probe_cancellation.dart';
import 'package:example/src/voice_probe/voice_probe_transport.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Counts mints and can be made to fail. One call per Start is the invariant.
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

/// A fully controllable [VoiceProbeTransport]: the test pushes events, sets the
/// track ids, and records every command the controller issues.
class FakeVoiceProbeTransport implements VoiceProbeTransport {
  final StreamController<Map<String, Object?>> _events =
      StreamController<Map<String, Object?>>.broadcast();
  final Completer<String> _remote = Completer<String>();

  String localId = 'local-track';
  int connectCalls = 0;
  Object? connectError;

  /// When set, connect awaits this before returning — lets a test cancel while
  /// signaling is in flight.
  Completer<void>? connectGate;

  /// Events the transport emits from INSIDE connect() (before its Future
  /// completes) — models an early DataChannel message such as session.created
  /// arriving the instant the channel opens.
  final List<Map<String, Object?>> emitDuringConnect = <Map<String, Object?>>[];

  final List<Map<String, Object?>> sent = <Map<String, Object?>>[];
  final List<bool> enabledCalls = <bool>[];
  int closeCalls = 0;
  int audioSessionCalls = 0;
  Object? audioSessionError;

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

  void completeRemote([String id = 'remote-track']) {
    if (!_remote.isCompleted) {
      _remote.complete(id);
    }
  }

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  String get localAudioTrackId => localId;

  @override
  Future<String> get remoteAudioTrackId => _remote.future;

  @override
  Future<void> connect(
    String clientSecret,
    ProbeCancellation cancellation,
  ) async {
    connectCalls++;
    final gate = connectGate;
    if (gate != null) {
      await gate.future;
    }
    // Emit early events (e.g. session.created) BEFORE completing, to prove the
    // controller's subscription is already attached and nothing is dropped.
    for (final event in emitDuringConnect) {
      emit(event);
    }
    if (connectError != null) {
      throw connectError!;
    }
  }

  @override
  Future<void> configureAudioSession() async {
    audioSessionCalls++;
    if (audioSessionError != null) {
      throw audioSessionError!;
    }
  }

  @override
  void setLocalTrackEnabled(bool enabled) => enabledCalls.add(enabled);

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

/// Records every native-writer method call and returns configurable results,
/// so a test can assert the exact commands (and that NO audio bytes) cross the
/// channel.
class MockWriterChannel {
  MockWriterChannel(this.channelName) {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannel(channelName), _handle);
  }

  final String channelName;
  final List<MethodCall> calls = <MethodCall>[];

  /// finalize → durationMs; > 0 (with [finalizeOk]) means a valid artifact.
  int finalizeDurationMs = 1000;
  bool finalizeOk = true;
  int finalizeCallbackCount = 12;
  int finalizeWrittenFrames = 4800;
  String finalizeFailStatus = 'noFrames';

  /// When set, only the writer whose id contains this substring fails finalize
  /// — lets a test fail exactly one of the two writers.
  String? failFinalizeContaining;

  /// If set, `start` for a writer whose id contains this substring throws.
  String? failStartContaining;
  String failStartCode = 'track_not_found';

  /// When set, `start` awaits this before returning — lets a test hold the
  /// controller's arming step in-flight to probe the settlement barrier.
  Completer<void>? startGate;

  Future<Object?> _handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'start':
        final id = (call.arguments as Map)['writerId'] as String;
        final fail = failStartContaining;
        if (fail != null && id.contains(fail)) {
          throw PlatformException(
            code: failStartCode,
            message: 'native detail that must never surface',
            details: <String, Object?>{'path': '/private/tmp/secret.wav'},
          );
        }
        final gate = startGate;
        if (gate != null) {
          await gate.future;
        }
        return null;
      case 'finalize':
        final id = (call.arguments as Map)['writerId'] as String;
        final singled = failFinalizeContaining;
        final singledOut = singled != null && id.contains(singled);
        final ok = finalizeOk && finalizeDurationMs > 0 && !singledOut;
        return <Object?, Object?>{
          'ok': ok,
          'durationMs': finalizeDurationMs,
          'callbackCount': finalizeCallbackCount,
          'writtenFrames': finalizeWrittenFrames,
          'status': ok ? 'ok' : finalizeFailStatus,
        };
      case 'play':
        return null;
      case 'close':
        return null;
    }
    return null;
  }

  List<MethodCall> callsFor(String method) =>
      calls.where((c) => c.method == method).toList();

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannel(channelName), null);
  }
}

/// Advances the event loop enough for the controller's async event handlers to
/// settle (they are not awaited by the stream subscription; arming now chains
/// a remote-track wait plus two method-channel writer starts).
Future<void> pumpEventLoop([int rounds = 12]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
