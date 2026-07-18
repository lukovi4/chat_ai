import 'dart:async';

import 'package:example/src/voice_probe/native_audio_writer.dart';
import 'package:example/src/voice_probe/probe_state.dart';
import 'package:example/src/voice_probe/voice_probe_session.dart';
import 'package:example/src/voice_probe/voice_probe_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late MockWriterChannel mock;
  late FakeClientSecretProvider provider;
  late FakeVoiceProbeTransport transport;
  late VoiceProbeSession session;

  setUp(() {
    mock = MockWriterChannel(kVoiceProbeWriterChannel);
    provider = FakeClientSecretProvider();
    transport = FakeVoiceProbeTransport();
    session = VoiceProbeSession(
      clientSecretProvider: provider,
      botId: 'bot',
      transportFactory: () => transport,
      writerFactory: NativeAudioWriterFactory(),
    );
  });

  tearDown(() => mock.dispose());

  // Drives one probe up to (but not including) Stop: session ready to `speak`,
  // one user turn ended, the single response delivered.
  Future<void> reachRespondingThenDone() async {
    await session.start();
    transport.completeRemote();
    transport.emit(<String, Object?>{'type': 'session.created'});
    await pumpEventLoop();
    transport.emit(<String, Object?>{'type': 'session.updated'});
    await pumpEventLoop();
    transport.emit(<String, Object?>{'type': 'response.created'});
    transport.emit(<String, Object?>{
      'type': 'input_audio_buffer.speech_stopped',
    });
    await pumpEventLoop();
    transport.emit(<String, Object?>{'type': 'response.done'});
    await pumpEventLoop();
  }

  // Required test 2: one Start → exactly one client-secret mint.
  test('one Start mints exactly once', () async {
    await reachRespondingThenDone();
    await session.stop();
    await pumpEventLoop();
    expect(provider.calls, 1);
    expect(transport.connectCalls, 1);
  });

  // Required test 3: a concurrent/repeat Start while active is rejected BEFORE
  // the provider is ever called.
  test('a second Start while active never reaches the provider', () async {
    final first = session.start();
    final second = session.start();
    await Future.wait(<Future<void>>[first, second]);
    expect(provider.calls, 1);
    expect(transport.connectCalls, 1);
  });

  // Required test 5 (wire half): exactly one session.update is sent, right
  // after session.created.
  test('exactly one session.update is sent after session.created', () async {
    await session.start();
    transport.completeRemote();
    transport.emit(<String, Object?>{'type': 'session.created'});
    // A stray duplicate created event must not double the update.
    transport.emit(<String, Object?>{'type': 'session.created'});
    await pumpEventLoop();
    final updates = transport.sent
        .where((e) => e['type'] == 'session.update')
        .toList();
    expect(updates.length, 1);
  });

  // Required test 6: the probe never sends response.create.
  test('the probe never sends response.create', () async {
    await reachRespondingThenDone();
    await session.stop();
    await pumpEventLoop();
    expect(transport.sent.any((e) => e['type'] == 'response.create'), isFalse);
  });

  // Required test 7: the first speech_stopped disables the local track.
  test('first speech_stopped disables the local track', () async {
    await session.start();
    transport.completeRemote();
    transport.emit(<String, Object?>{'type': 'session.created'});
    await pumpEventLoop();
    transport.emit(<String, Object?>{'type': 'session.updated'});
    await pumpEventLoop();
    // Armed → enabled true once.
    expect(transport.enabledCalls.where((e) => e).length, 1);
    transport.emit(<String, Object?>{
      'type': 'input_audio_buffer.speech_stopped',
    });
    await pumpEventLoop();
    expect(transport.enabledCalls.contains(false), isTrue);
  });

  // Required test 8: no second user turn is possible within one probe session.
  test('a second speech_stopped cannot re-open the mic', () async {
    await session.start();
    transport.completeRemote();
    transport.emit(<String, Object?>{'type': 'session.created'});
    await pumpEventLoop();
    transport.emit(<String, Object?>{'type': 'session.updated'});
    await pumpEventLoop();
    transport.emit(<String, Object?>{
      'type': 'input_audio_buffer.speech_stopped',
    });
    transport.emit(<String, Object?>{
      'type': 'input_audio_buffer.speech_stopped',
    });
    await pumpEventLoop();
    // Exactly one enable (arming), and it is never re-enabled after disable.
    expect(transport.enabledCalls.where((e) => e).length, 1);
    expect(transport.enabledCalls.last, isFalse);
  });

  // Required test 12: artifacts are published only after a successful finalize.
  test('artifacts appear only after a successful finalize', () async {
    await reachRespondingThenDone();
    // Not ready before Stop/finalize.
    expect(session.state.phase, isNot(VoiceProbePhase.ready));
    expect(session.state.artifacts, isNull);

    await session.stop();
    await pumpEventLoop();
    expect(session.state.phase, VoiceProbePhase.ready);
    expect(session.state.artifacts, isNotNull);
    expect(session.state.canPlay, isTrue);
    expect(mock.callsFor('finalize').length, 2);
  });

  // Required test 13: a zero-duration/invalid file never becomes a ready
  // artifact.
  test('an invalid finalize yields failure, not a ready artifact', () async {
    mock.finalizeOk = false;
    await reachRespondingThenDone();
    await session.stop();
    await pumpEventLoop();
    expect(session.state.phase, VoiceProbePhase.failed);
    expect(session.state.errorCode, VoiceProbeErrorCode.writerFailed);
    expect(session.state.artifacts, isNull);
  });

  // Required test 15: Close is exactly-once across writers/transport.
  test('Close is exactly-once even if invoked twice', () async {
    await reachRespondingThenDone();
    await session.stop();
    await session.stop();
    await pumpEventLoop();
    expect(transport.closeCalls, 1);
    // Two writers, each finalized exactly once.
    expect(mock.callsFor('finalize').length, 2);
    expect(session.state.phase, VoiceProbePhase.ready);
  });

  // Required test 16: a cancel while signaling is in flight closes the late
  // resources and never arms writers or sends the update.
  test('cancel during signaling tears down without arming', () async {
    transport.connectGate = Completer<void>();
    final startFuture = session.start();
    await pumpEventLoop();
    // Stop while connect is still gated (signaling in flight).
    final stopFuture = session.stop();
    // The late connect now resolves.
    transport.connectGate!.complete();
    await startFuture;
    await stopFuture;
    await pumpEventLoop();

    expect(provider.calls, 1);
    expect(mock.callsFor('start'), isEmpty); // no writer ever armed
    expect(transport.sent.any((e) => e['type'] == 'session.update'), isFalse);
    expect(transport.closeCalls, 1);
    expect(session.state.phase, VoiceProbePhase.closed);
  });

  // Required test 17: a transport failure triggers no new mint / connect /
  // response, and discards the writers.
  test('transport loss is terminal — no retry, writers discarded', () async {
    await session.start();
    transport.completeRemote();
    transport.emit(<String, Object?>{'type': 'session.created'});
    await pumpEventLoop();
    transport.emit(<String, Object?>{'type': 'session.updated'});
    await pumpEventLoop();
    transport.emit(<String, Object?>{'type': 'response.created'});
    transport.emit(<String, Object?>{
      'type': 'input_audio_buffer.speech_stopped',
    });
    await pumpEventLoop();

    // Session dies mid-response.
    transport.endEvents();
    await pumpEventLoop();

    expect(session.state.phase, VoiceProbePhase.failed);
    expect(session.state.errorCode, VoiceProbeErrorCode.transportLost);
    expect(provider.calls, 1);
    expect(transport.connectCalls, 1);
    expect(transport.sent.any((e) => e['type'] == 'response.create'), isFalse);
    // Both armed writers were closed (discarded), not left dangling.
    expect(mock.callsFor('close').length, 2);
  });

  // Required test 18: no secret / raw event / path is reachable from state; the
  // failure surface is a coarse enum only.
  test('failure state exposes only coarse, non-sensitive fields', () async {
    provider.throwError = Exception('secret-value leaked here /private/tmp');
    await session.start();
    await pumpEventLoop();

    expect(session.state.phase, VoiceProbePhase.failed);
    expect(session.state.errorCode, VoiceProbeErrorCode.mintFailed);
    expect(session.state.artifacts, isNull);
    expect(session.state.errorCode, isA<VoiceProbeErrorCode>());
  });

  test('a connect failure is terminal with no retry', () async {
    transport.connectError = const VoiceProbeConnectException();
    await session.start();
    await pumpEventLoop();
    expect(session.state.phase, VoiceProbePhase.failed);
    expect(session.state.errorCode, VoiceProbeErrorCode.connectFailed);
    expect(transport.connectCalls, 1);
    expect(provider.calls, 1);
  });

  // Defect 1: an early session.created delivered from INSIDE connect() (before
  // connect's Future completes) must not be lost — the subscription is attached
  // before connect, so it still yields exactly one session.update.
  test(
    'an early session.created inside connect still sends one update',
    () async {
      transport.emitDuringConnect.add(<String, Object?>{
        'type': 'session.created',
      });
      await session.start();
      await pumpEventLoop();
      final updates = transport.sent
          .where((e) => e['type'] == 'session.update')
          .toList();
      expect(updates.length, 1);
      // Not stuck in configuring with the update never sent.
      expect(session.state.phase, VoiceProbePhase.configuring);
    },
  );

  // Defect 2: Stop while still awaiting the remote track ends `closed` (not
  // writerFailed), finalizes nothing, and a late remote completion is inert.
  test('cancel while awaiting the remote track ends closed', () async {
    await session.start();
    // remote track intentionally left pending.
    transport.emit(<String, Object?>{'type': 'session.created'});
    await pumpEventLoop();
    transport.emit(<String, Object?>{'type': 'session.updated'});
    await pumpEventLoop();
    // Arming is blocked on the remote track; no writer created yet.
    expect(mock.callsFor('start'), isEmpty);

    await session.stop();
    await pumpEventLoop();
    expect(session.state.phase, VoiceProbePhase.closed);
    expect(mock.callsFor('finalize'), isEmpty);
    expect(transport.closeCalls, 1);

    // A late remote track after cancel arms nothing and changes no state.
    transport.completeRemote();
    await pumpEventLoop();
    expect(session.state.phase, VoiceProbePhase.closed);
    expect(mock.callsFor('start'), isEmpty);
  });

  // Defect 7a: an error during setup is a terminal, sanitized sessionFailed.
  test('an error event during setup is a terminal sessionFailed', () async {
    await session.start();
    transport.emit(<String, Object?>{
      'type': 'error',
      'error': <String, Object?>{
        'message': 'super-secret-native-detail',
        'code': 'x',
        'event_id': 'evt_123',
      },
    });
    await pumpEventLoop();
    expect(session.state.phase, VoiceProbePhase.failed);
    expect(session.state.errorCode, VoiceProbeErrorCode.sessionFailed);
    // Privacy: nothing from the raw event is reachable from state.
    expect(session.state.errorCode!.name.contains('secret'), isFalse);
    expect(session.state.artifacts, isNull);
    expect(transport.connectCalls, 1); // no reconnect
  });

  // Defect 7b: an error after the response may have started is transportLost.
  test(
    'an error event during the response is a terminal transportLost',
    () async {
      await session.start();
      transport.completeRemote();
      transport.emit(<String, Object?>{'type': 'session.created'});
      await pumpEventLoop();
      transport.emit(<String, Object?>{'type': 'session.updated'});
      await pumpEventLoop();
      transport.emit(<String, Object?>{'type': 'response.created'});
      await pumpEventLoop();

      transport.emit(<String, Object?>{
        'type': 'error',
        'error': <String, Object?>{'message': 'secret'},
      });
      await pumpEventLoop();
      expect(session.state.phase, VoiceProbePhase.failed);
      expect(session.state.errorCode, VoiceProbeErrorCode.transportLost);
    },
  );

  // Defect 4A: a new Start releases the previous ready result's writers before
  // the second mint, and clears the old artifacts.
  test('a new Start releases held writers before the next mint', () async {
    final provider2 = FakeClientSecretProvider();
    final t1 = FakeVoiceProbeTransport();
    final t2 = FakeVoiceProbeTransport();
    final queue = <FakeVoiceProbeTransport>[t1, t2];
    final s = VoiceProbeSession(
      clientSecretProvider: provider2,
      botId: 'bot',
      transportFactory: () => queue.removeAt(0),
      writerFactory: NativeAudioWriterFactory(),
    );
    addTearDown(s.dispose);

    await s.start();
    t1.completeRemote();
    t1.emit(<String, Object?>{'type': 'session.created'});
    await pumpEventLoop();
    t1.emit(<String, Object?>{'type': 'session.updated'});
    await pumpEventLoop();
    t1.emit(<String, Object?>{'type': 'response.created'});
    t1.emit(<String, Object?>{'type': 'input_audio_buffer.speech_stopped'});
    await pumpEventLoop();
    t1.emit(<String, Object?>{'type': 'response.done'});
    await pumpEventLoop();
    await s.stop();
    await pumpEventLoop();
    expect(s.state.phase, VoiceProbePhase.ready);
    expect(provider2.calls, 1);
    expect(mock.callsFor('close'), isEmpty); // ready keeps writers open

    await s.start();
    await pumpEventLoop();
    // Both held writers closed, and the second mint happened.
    expect(mock.callsFor('close').length, 2);
    expect(provider2.calls, 2);
    expect(s.state.artifacts, isNull); // old artifacts cleared from state
  });

  // Defect 4B: dispose closes a held ready result's writers exactly once.
  test('dispose closes held ready writers exactly once', () async {
    await reachRespondingThenDone();
    await session.stop();
    await pumpEventLoop();
    expect(session.state.phase, VoiceProbePhase.ready);
    expect(mock.callsFor('close'), isEmpty);

    await session.dispose();
    expect(mock.callsFor('close').length, 2);
    await session.dispose(); // repeat must not double-close
    expect(mock.callsFor('close').length, 2);
  });

  // Defect 5: a stale first attempt (stopped mid-connect) cannot mint or mutate
  // a newer attempt, and a Start during unfinished cleanup does not mint.
  test('a stale attempt cannot mint or mutate a newer attempt', () async {
    final provider2 = FakeClientSecretProvider();
    final t1 = FakeVoiceProbeTransport()..connectGate = Completer<void>();
    final t2 = FakeVoiceProbeTransport();
    final queue = <FakeVoiceProbeTransport>[t1, t2];
    final s = VoiceProbeSession(
      clientSecretProvider: provider2,
      botId: 'bot',
      transportFactory: () => queue.removeAt(0),
      writerFactory: NativeAudioWriterFactory(),
    );
    addTearDown(s.dispose);

    final f1 = s.start(); // t1, connect gated
    await pumpEventLoop();
    expect(provider2.calls, 1);

    final stopF = s.stop(); // begins teardown
    final f2 = s.start(); // during cleanup → rejected, no mint
    await f2;
    expect(provider2.calls, 1);
    await stopF;
    await pumpEventLoop();
    expect(s.state.phase, VoiceProbePhase.closed);

    // Release the gated (stale) first connect — it must change nothing.
    t1.connectGate!.complete();
    await f1;
    await pumpEventLoop();
    expect(s.state.phase, VoiceProbePhase.closed);
    expect(provider2.calls, 1);

    // A fresh Start is now allowed and mints once on the new transport.
    await s.start();
    await pumpEventLoop();
    expect(provider2.calls, 2);
    expect(t2.connectCalls, 1);
  });

  // P1 settlement barrier (pending connect): after Stop completes `closed`, a
  // new Start is refused — no second mint, no second transport — until the
  // still-pending connect of the previous attempt actually settles.
  test('a new Start is refused until a pending connect settles', () async {
    final provider2 = FakeClientSecretProvider();
    final t1 = FakeVoiceProbeTransport()..connectGate = Completer<void>();
    final t2 = FakeVoiceProbeTransport();
    final queue = <FakeVoiceProbeTransport>[t1, t2];
    final s = VoiceProbeSession(
      clientSecretProvider: provider2,
      botId: 'bot',
      transportFactory: () => queue.removeAt(0),
      writerFactory: NativeAudioWriterFactory(),
    );
    addTearDown(s.dispose);

    final f1 = s.start(); // t1, connect gated
    await pumpEventLoop();
    expect(provider2.calls, 1);

    // Stop completes closed even though connect is still gated (responsive).
    await s.stop();
    await pumpEventLoop();
    expect(s.state.phase, VoiceProbePhase.closed);

    // The window: connect not yet settled → new Start refused.
    await s.start();
    await pumpEventLoop();
    expect(provider2.calls, 1); // no second mint
    expect(queue.length, 1); // t2 was never taken
    expect(t2.connectCalls, 0);

    // The pending connect finally settles.
    t1.connectGate!.complete();
    await f1;
    await pumpEventLoop();
    expect(t1.closeCalls, 1); // the late resource closed exactly once
    expect(
      s.state.phase,
      VoiceProbePhase.closed,
    ); // late success changed nothing

    // Only now is a fresh Start allowed, minting exactly once more.
    await s.start();
    await pumpEventLoop();
    expect(provider2.calls, 2);
    expect(t2.connectCalls, 1);
  });

  // P1 settlement barrier (pending arming): a new Start is refused while the
  // previous attempt's _armAndSpeak is still in flight, and a stale arming
  // finally never resets the newer attempt's flags nor double-arms it.
  test('a new Start is refused until pending arming settles', () async {
    mock.startGate = Completer<void>();
    final provider2 = FakeClientSecretProvider();
    final t1 = FakeVoiceProbeTransport();
    final t2 = FakeVoiceProbeTransport();
    final queue = <FakeVoiceProbeTransport>[t1, t2];
    final s = VoiceProbeSession(
      clientSecretProvider: provider2,
      botId: 'bot',
      transportFactory: () => queue.removeAt(0),
      writerFactory: NativeAudioWriterFactory(),
    );
    addTearDown(s.dispose);

    await s.start();
    t1.completeRemote();
    t1.emit(<String, Object?>{'type': 'session.created'});
    await pumpEventLoop();
    t1.emit(<String, Object?>{'type': 'session.updated'});
    await pumpEventLoop();
    // Arming dispatched the user-writer start, which is now gated (in-flight).
    expect(mock.callsFor('start').length, 1);

    await s.stop();
    await pumpEventLoop();
    expect(s.state.phase, VoiceProbePhase.closed);

    // The window: arming not yet settled → new Start refused.
    await s.start();
    await pumpEventLoop();
    expect(provider2.calls, 1);
    expect(t2.connectCalls, 0);

    // Release the gated writer start → the stale arming bails and settles;
    // its finally must not touch a newer attempt (there is none yet).
    mock.startGate!.complete();
    await pumpEventLoop();

    // Now a fresh Start is allowed and mints exactly once more.
    await s.start();
    await pumpEventLoop();
    expect(provider2.calls, 2);
    expect(t2.connectCalls, 1);

    // The second attempt arms once; a duplicate session.updated does not
    // double-arm (the stale first attempt did not corrupt _arming/_armed).
    t2.completeRemote();
    t2.emit(<String, Object?>{'type': 'session.created'});
    await pumpEventLoop();
    t2.emit(<String, Object?>{'type': 'session.updated'});
    await pumpEventLoop();
    t2.emit(<String, Object?>{'type': 'session.updated'});
    await pumpEventLoop();
    expect(t2.enabledCalls.where((e) => e).length, 1);
    expect(s.state.phase, VoiceProbePhase.speak);
  });

  // Independent finalize 1: a user-writer failure must NOT skip the assistant
  // writer — both are finalized.
  test('a user finalize failure still finalizes the assistant', () async {
    mock.failFinalizeContaining = 'user';
    await reachRespondingThenDone();
    await session.stop();
    await pumpEventLoop();

    final finalizedIds = mock
        .callsFor('finalize')
        .map((c) => (c.arguments as Map)['writerId'].toString())
        .toList();
    expect(finalizedIds.any((id) => id.contains('user')), isTrue);
    expect(finalizedIds.any((id) => id.contains('assistant')), isTrue);
    expect(session.state.phase, VoiceProbePhase.failed);
    expect(session.state.errorCode, VoiceProbeErrorCode.writerFailed);
  });

  // Independent finalize 2: ready requires BOTH writers valid.
  test('ready requires both writers to be valid', () async {
    mock.failFinalizeContaining = 'assistant';
    await reachRespondingThenDone();
    await session.stop();
    await pumpEventLoop();
    expect(session.state.phase, VoiceProbePhase.failed);
    expect(session.state.artifacts, isNull);
    // The valid user writer is diagnosed ok; the assistant one is not.
    expect(session.state.diagnostics?.user?.status, WriterStatus.ok);
    expect(
      session.state.diagnostics?.assistant?.status,
      isNot(WriterStatus.ok),
    );
  });

  // Independent finalize 3: one failed writer → failed, and BOTH writers are
  // closed exactly once.
  test('one failed writer closes both writers exactly once', () async {
    mock.failFinalizeContaining = 'user';
    await reachRespondingThenDone();
    await session.stop();
    await pumpEventLoop();
    expect(session.state.phase, VoiceProbePhase.failed);
    expect(mock.callsFor('close').length, 2);
  });

  // Events 4: response.created and output_audio_buffer.started are distinct
  // booleans — the former does not imply audio actually started.
  test(
    'response.created and output_audio_buffer.started are distinct',
    () async {
      await session.start();
      transport.completeRemote();
      transport.emit(<String, Object?>{'type': 'session.created'});
      await pumpEventLoop();
      transport.emit(<String, Object?>{'type': 'session.updated'});
      await pumpEventLoop();

      transport.emit(<String, Object?>{'type': 'response.created'});
      await pumpEventLoop();
      expect(session.state.diagnostics?.responseCreated, isTrue);
      expect(session.state.diagnostics?.outputAudioStarted, isFalse);

      transport.emit(<String, Object?>{'type': 'output_audio_buffer.started'});
      await pumpEventLoop();
      expect(session.state.diagnostics?.outputAudioStarted, isTrue);
    },
  );

  // Events 5: output_audio_buffer.stopped / response.done mark the response as
  // finished (the UI may invite Stop; Stop is never automatic).
  test(
    'output_audio_buffer.stopped and response.done mark completion',
    () async {
      await session.start();
      transport.completeRemote();
      transport.emit(<String, Object?>{'type': 'session.created'});
      await pumpEventLoop();
      transport.emit(<String, Object?>{'type': 'session.updated'});
      await pumpEventLoop();
      transport.emit(<String, Object?>{'type': 'output_audio_buffer.started'});
      await pumpEventLoop();
      expect(session.state.diagnostics?.responseFinished, isFalse);

      transport.emit(<String, Object?>{'type': 'output_audio_buffer.stopped'});
      await pumpEventLoop();
      expect(session.state.diagnostics?.outputAudioStopped, isTrue);
      expect(session.state.diagnostics?.responseFinished, isTrue);

      transport.emit(<String, Object?>{'type': 'response.done'});
      await pumpEventLoop();
      expect(session.state.diagnostics?.responseDone, isTrue);
    },
  );

  // Diagnostics 6: the diagnostic snapshot exposes only counters / bool /
  // stable enum — never a raw string content field.
  test('diagnostics carry only counters, bools and stable enums', () async {
    mock.failFinalizeContaining = 'assistant';
    await reachRespondingThenDone();
    await session.stop();
    await pumpEventLoop();

    final d = session.state.diagnostics!;
    expect(d.user, isA<WriterDiagnostics>());
    expect(d.assistant, isA<WriterDiagnostics>());
    expect(d.user!.callbackCount, isA<int>());
    expect(d.user!.writtenFrames, isA<int>());
    expect(d.user!.status, isA<WriterStatus>());
    expect(d.responseCreated, isA<bool>());
    expect(d.outputAudioStarted, isA<bool>());
    expect(d.outputAudioStopped, isA<bool>());
    expect(d.responseDone, isA<bool>());
  });

  // The audio session is configured (before the local track is enabled), and a
  // configuration failure is a safe coarse error.
  test('a failed audio-session configuration is a coarse failure', () async {
    transport.audioSessionError = const VoiceProbeAudioSessionException();
    await session.start();
    transport.completeRemote();
    transport.emit(<String, Object?>{'type': 'session.created'});
    await pumpEventLoop();
    transport.emit(<String, Object?>{'type': 'session.updated'});
    await pumpEventLoop();
    expect(session.state.phase, VoiceProbePhase.failed);
    expect(session.state.errorCode, VoiceProbeErrorCode.audioSessionFailed);
    // The local track is never enabled when the session config fails.
    expect(transport.enabledCalls.where((e) => e).isEmpty, isTrue);
  });

  test(
    'the audio session is configured before the local track is enabled',
    () async {
      await session.start();
      transport.completeRemote();
      transport.emit(<String, Object?>{'type': 'session.created'});
      await pumpEventLoop();
      transport.emit(<String, Object?>{'type': 'session.updated'});
      await pumpEventLoop();
      expect(transport.audioSessionCalls, 1);
      expect(transport.enabledCalls, contains(true));
    },
  );
}
