// The two new increments: the assistant transcript-DELTA side channel
// ([OpenAIRealtimeVoiceSession.assistantTranscriptDeltas]) and the programmatic
// [OpenAIRealtimeVoiceSession.interruptResponse]. Driven by the package-internal
// fake transport / recorder / watchdog — no native WebRTC, no real clock.
import 'dart:async';

import 'package:chat_ai_openai_realtime_voice/chat_ai_openai_realtime_voice.dart';
import 'package:chat_ai_openai_realtime_voice/src/voice_session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

// ---- Event literals -------------------------------------------------------

Map<String, Object?> _created = <String, Object?>{'type': 'session.created'};
Map<String, Object?> _updated = <String, Object?>{'type': 'session.updated'};

Map<String, Object?> _responseCreated(String id) => <String, Object?>{
  'type': 'response.created',
  'response': <String, Object?>{'id': id},
};

Map<String, Object?> _outputStarted(String id) => <String, Object?>{
  'type': 'output_audio_buffer.started',
  'response_id': id,
};

Map<String, Object?> _outputStopped(String id) => <String, Object?>{
  'type': 'output_audio_buffer.stopped',
  'response_id': id,
};

Map<String, Object?> _responseDone(String id, {String? status = 'completed'}) =>
    <String, Object?>{
      'type': 'response.done',
      'response': <String, Object?>{'id': id, 'status': ?status},
    };

Map<String, Object?> _speechStarted(String itemId, {int startMs = 0}) =>
    <String, Object?>{
      'type': 'input_audio_buffer.speech_started',
      'item_id': itemId,
      'audio_start_ms': startMs,
    };

Map<String, Object?> _speechStopped(String itemId, {int endMs = 200}) =>
    <String, Object?>{
      'type': 'input_audio_buffer.speech_stopped',
      'item_id': itemId,
      'audio_end_ms': endMs,
    };

Map<String, Object?> _delta(
  String id, {
  String item = 'item_1',
  int outputIndex = 0,
  int contentIndex = 0,
  Object? delta = 'x',
}) => <String, Object?>{
  'type': 'response.output_audio_transcript.delta',
  'response_id': id,
  'item_id': item,
  'output_index': outputIndex,
  'content_index': contentIndex,
  'delta': delta,
};

Map<String, Object?> _assistantDone(String id, String text) =>
    <String, Object?>{
      'type': 'response.output_audio_transcript.done',
      'response_id': id,
      'item_id': 'item_$id',
      'output_index': 0,
      'content_index': 0,
      'transcript': text,
    };

int _countSent(FakeRealtimeVoiceTransport t, String type) =>
    t.sent.where((e) => e['type'] == type).length;

void main() {
  late FakeClientSecretProvider provider;
  late FakeRealtimeVoiceTransport transport;

  setUp(() {
    provider = FakeClientSecretProvider();
    transport = FakeRealtimeVoiceTransport();
  });

  OpenAIRealtimeVoiceSession build({
    OpenAIRealtimeVoiceMode mode = OpenAIRealtimeVoiceMode.conversation,
    bool transcriptsEnabled = true,
    bool recordingEnabled = false,
    FakeRecorderFactory? recorders,
    FakeRealtimeVoiceTransport? t,
  }) {
    return voiceSessionForTesting(
      clientSecretProvider: provider,
      botProfile: botProfile(),
      transportFactory: () => t ?? transport,
      mode: mode,
      transcriptsEnabled: transcriptsEnabled,
      recordingEnabled: recordingEnabled,
      recordingDirectoryPath: recordingEnabled ? '/rec' : null,
      recorderFactory: recordingEnabled ? recorders?.call : null,
    );
  }

  Future<void> reachListening(
    OpenAIRealtimeVoiceSession s,
    FakeRealtimeVoiceTransport t, {
    bool remote = false,
  }) async {
    await s.start();
    if (remote) {
      t.completeRemoteTrack();
    }
    t.emit(_created);
    await pumpEventLoop();
    t.emit(_updated);
    await pumpEventLoop();
  }

  // ======================================================================
  // Assistant transcript deltas
  // ======================================================================
  group('assistantTranscriptDeltas', () {
    test('1. delta is ignored when transcriptsEnabled is false', () async {
      final s = build(transcriptsEnabled: false);
      addTearDown(s.dispose);
      final got = <String>[];
      s.assistantTranscriptDeltas.listen((d) => got.add(d.delta));
      await reachListening(s, transport);
      transport.emit(_responseCreated('r1'));
      await pumpEventLoop();
      transport.emit(_delta('r1', delta: 'hi'));
      await pumpEventLoop();
      expect(got, isEmpty);
    });

    test(
      '2. valid deltas of the current response emit exactly + in order',
      () async {
        final s = build();
        addTearDown(s.dispose);
        final got = <String>[];
        s.assistantTranscriptDeltas.listen((d) => got.add(d.delta));
        await reachListening(s, transport);
        transport.emit(_responseCreated('r1'));
        await pumpEventLoop();
        for (final frag in <String>['Hel', 'lo', ' wo', 'rld']) {
          transport.emit(_delta('r1', delta: frag));
        }
        await pumpEventLoop();
        expect(got, <String>['Hel', 'lo', ' wo', 'rld']);
      },
    );

    test('3. two identical consecutive deltas emit twice (no dedup)', () async {
      final s = build();
      addTearDown(s.dispose);
      final got = <String>[];
      s.assistantTranscriptDeltas.listen((d) => got.add(d.delta));
      await reachListening(s, transport);
      transport.emit(_responseCreated('r1'));
      await pumpEventLoop();
      transport.emit(_delta('r1', delta: 'na'));
      transport.emit(_delta('r1', delta: 'na'));
      await pumpEventLoop();
      expect(got, <String>['na', 'na']);
    });

    test('4. a delta before response.created is ignored', () async {
      final s = build();
      addTearDown(s.dispose);
      final got = <String>[];
      s.assistantTranscriptDeltas.listen((d) => got.add(d.delta));
      await reachListening(s, transport);
      transport.emit(_delta('r1', delta: 'early'));
      await pumpEventLoop();
      expect(got, isEmpty);
      transport.emit(_responseCreated('r1'));
      await pumpEventLoop();
      transport.emit(_delta('r1', delta: 'now'));
      await pumpEventLoop();
      expect(got, <String>['now']);
    });

    test('5. a foreign response_id is ignored', () async {
      final s = build();
      addTearDown(s.dispose);
      final got = <String>[];
      s.assistantTranscriptDeltas.listen((d) => got.add(d.delta));
      await reachListening(s, transport);
      transport.emit(_responseCreated('r1'));
      await pumpEventLoop();
      transport.emit(_delta('r2', delta: 'foreign'));
      await pumpEventLoop();
      expect(got, isEmpty);
      transport.emit(_delta('r1', delta: 'mine'));
      await pumpEventLoop();
      expect(got, <String>['mine']);
    });

    test('6. malformed item/index/delta are ignored', () async {
      final s = build();
      addTearDown(s.dispose);
      final got = <String>[];
      s.assistantTranscriptDeltas.listen((d) => got.add(d.delta));
      await reachListening(s, transport);
      transport.emit(_responseCreated('r1'));
      await pumpEventLoop();
      // empty item_id
      transport.emit(_delta('r1', item: '', delta: 'a'));
      // negative output_index
      transport.emit(_delta('r1', outputIndex: -1, delta: 'b'));
      // missing content_index
      transport.emit(<String, Object?>{
        'type': 'response.output_audio_transcript.delta',
        'response_id': 'r1',
        'item_id': 'i',
        'output_index': 0,
        'delta': 'c',
      });
      // non-String delta
      transport.emit(_delta('r1', delta: 123));
      // missing response_id
      transport.emit(<String, Object?>{
        'type': 'response.output_audio_transcript.delta',
        'item_id': 'i',
        'output_index': 0,
        'content_index': 0,
        'delta': 'd',
      });
      await pumpEventLoop();
      expect(got, isEmpty);
      // A minimal valid one still emits.
      transport.emit(_delta('r1', delta: 'ok'));
      await pumpEventLoop();
      expect(got, <String>['ok']);
    });

    test('7a. deltas after interruptResponse are not emitted', () async {
      final s = build();
      addTearDown(s.dispose);
      final got = <String>[];
      s.assistantTranscriptDeltas.listen((d) => got.add(d.delta));
      await reachListening(s, transport);
      transport.emit(_responseCreated('r1'));
      await pumpEventLoop();
      transport.emit(_delta('r1', delta: 'before'));
      await pumpEventLoop();
      await s.interruptResponse();
      await pumpEventLoop();
      transport.emit(_delta('r1', delta: 'after'));
      await pumpEventLoop();
      expect(got, <String>['before']);
    });

    test('7b. deltas after barge-in are not emitted', () async {
      final s = build();
      addTearDown(s.dispose);
      final got = <String>[];
      s.assistantTranscriptDeltas.listen((d) => got.add(d.delta));
      await reachListening(s, transport);
      transport.emit(_responseCreated('r1'));
      await pumpEventLoop();
      transport.emit(_delta('r1', delta: 'before'));
      await pumpEventLoop();
      transport.emit(_speechStarted('u2')); // barge-in abandons r1
      await pumpEventLoop();
      transport.emit(_delta('r1', delta: 'after'));
      await pumpEventLoop();
      expect(got, <String>['before']);
    });

    test('7c. deltas after dispose are not emitted (stream closed)', () async {
      final s = build();
      final got = <String>[];
      var closed = false;
      s.assistantTranscriptDeltas.listen(
        (d) => got.add(d.delta),
        onDone: () => closed = true,
      );
      await reachListening(s, transport);
      transport.emit(_responseCreated('r1'));
      await pumpEventLoop();
      await s.dispose();
      await pumpEventLoop();
      expect(closed, isTrue); // (test 10) closed by dispose
      transport.emit(_delta('r1', delta: 'after'));
      await pumpEventLoop();
      expect(got, isEmpty);
    });

    test(
      '8. the final .done stays only on transcripts, not on deltas',
      () async {
        final s = build();
        addTearDown(s.dispose);
        final deltas = <String>[];
        final finals = <OpenAIRealtimeVoiceTranscript>[];
        s.assistantTranscriptDeltas.listen((d) => deltas.add(d.delta));
        s.transcripts.listen(finals.add);
        await reachListening(s, transport);
        transport.emit(_responseCreated('r1'));
        await pumpEventLoop();
        transport.emit(_delta('r1', delta: 'Hel'));
        transport.emit(_delta('r1', delta: 'lo'));
        await pumpEventLoop();
        transport.emit(_assistantDone('r1', 'Hello'));
        // The held final publishes once on the clean completion (not on deltas).
        transport.emit(_responseDone('r1'));
        transport.emit(_outputStopped('r1'));
        await pumpEventLoop();
        expect(deltas, <String>['Hel', 'lo']); // .done NOT duplicated here
        expect(finals.length, 1);
        expect(finals.single.role, OpenAIRealtimeVoiceTranscriptRole.assistant);
        expect(finals.single.text, 'Hello');
      },
    );

    test('9. deltas do not change recording transcript pairing', () async {
      final recorders = FakeRecorderFactory();
      final s = build(recordingEnabled: true, recorders: recorders);
      addTearDown(s.dispose);
      final recordings = <OpenAIRealtimeVoiceRecording>[];
      s.recordings.listen(recordings.add);
      await reachListening(s, transport, remote: true);
      transport.emit(_responseCreated('r1'));
      transport.emit(_outputStarted('r1'));
      await pumpEventLoop();
      // Deltas arrive during the response...
      transport.emit(_delta('r1', delta: 'Hel'));
      transport.emit(_delta('r1', delta: 'lo'));
      await pumpEventLoop();
      // ...the segment ends and the FINAL transcript pairs the recording.
      transport.emit(_outputStopped('r1'));
      transport.emit(_assistantDone('r1', 'Hello final'));
      await pumpEventLoop();
      final assistant = recordings.firstWhere(
        (r) => r.role == OpenAIRealtimeVoiceRecordingRole.assistant,
      );
      // The recording is paired with the FINAL transcript, never the deltas.
      expect(assistant.transcript, 'Hello final');
    });
  });

  // ======================================================================
  // Programmatic interrupt
  // ======================================================================
  group('interruptResponse', () {
    test('1. no active response -> no-op, zero sends', () async {
      final s = build();
      addTearDown(s.dispose);
      await reachListening(s, transport);
      final sentBefore = transport.sent.length;
      await s.interruptResponse();
      await pumpEventLoop();
      expect(transport.sent.length, sentBefore);
      expect(_countSent(transport, 'response.cancel'), 0);
      expect(_countSent(transport, 'output_audio_buffer.clear'), 0);
      expect(transport.closeCalls, 0);
      expect(s.state.phase, OpenAIRealtimeVoicePhase.listening);
    });

    test(
      '2. conversation: one cancel then one clear, stays live, listening',
      () async {
        final s = build();
        addTearDown(s.dispose);
        await reachListening(s, transport);
        transport.emit(_responseCreated('r1'));
        await pumpEventLoop();
        expect(s.state.phase, OpenAIRealtimeVoicePhase.assistantSpeaking);

        await s.interruptResponse();
        await pumpEventLoop();
        expect(_countSent(transport, 'response.cancel'), 1);
        expect(_countSent(transport, 'output_audio_buffer.clear'), 1);
        // Exact order: cancel immediately before clear.
        final types = transport.sent.map((e) => e['type']).toList();
        final ci = types.indexOf('response.cancel');
        final cl = types.indexOf('output_audio_buffer.clear');
        expect(ci >= 0 && cl == ci + 1, isTrue);
        expect(transport.closeCalls, 0); // transport NOT closed
        expect(s.state.phase, OpenAIRealtimeVoicePhase.listening);

        // The next response is handled normally.
        transport.emit(_responseCreated('r2'));
        await pumpEventLoop();
        expect(s.state.phase, OpenAIRealtimeVoicePhase.assistantSpeaking);
        transport.emit(_responseDone('r2'));
        transport.emit(_outputStopped('r2'));
        await pumpEventLoop();
        expect(s.state.phase, OpenAIRealtimeVoicePhase.listening);
        expect(transport.closeCalls, 0);
      },
    );

    test('3. concurrent/repeat calls produce only one event pair', () async {
      final s = build();
      addTearDown(s.dispose);
      await reachListening(s, transport);
      transport.emit(_responseCreated('r1'));
      await pumpEventLoop();
      await Future.wait(<Future<void>>[
        s.interruptResponse(),
        s.interruptResponse(),
        s.interruptResponse(),
      ]);
      await s.interruptResponse();
      await pumpEventLoop();
      expect(_countSent(transport, 'response.cancel'), 1);
      expect(_countSent(transport, 'output_audio_buffer.clear'), 1);
    });

    test(
      '4. an open assistant recording is finalized interrupted=true',
      () async {
        final recorders = FakeRecorderFactory();
        // transcripts off so the interrupted recording emits immediately (with a
        // null transcript) rather than waiting on the pairing deadline.
        final s = build(
          recordingEnabled: true,
          recorders: recorders,
          transcriptsEnabled: false,
        );
        addTearDown(s.dispose);
        final recordings = <OpenAIRealtimeVoiceRecording>[];
        s.recordings.listen(recordings.add);
        await reachListening(s, transport, remote: true);
        transport.emit(_responseCreated('r1'));
        transport.emit(_outputStarted('r1')); // opens the assistant segment
        await pumpEventLoop();

        await s.interruptResponse();
        await pumpEventLoop();
        final assistant = recordings.firstWhere(
          (r) => r.role == OpenAIRealtimeVoiceRecordingRole.assistant,
        );
        expect(assistant.interrupted, isTrue);
      },
    );

    test(
      '5. late cancelled/done/audio/delta of the interrupted response are inert',
      () async {
        final s = build();
        addTearDown(s.dispose);
        final deltas = <String>[];
        s.assistantTranscriptDeltas.listen((d) => deltas.add(d.delta));
        await reachListening(s, transport);
        transport.emit(_responseCreated('r1'));
        await pumpEventLoop();
        await s.interruptResponse();
        await pumpEventLoop();
        // Late events of r1 must not fail the session or re-emit.
        transport.emit(_responseDone('r1', status: 'cancelled'));
        transport.emit(_outputStopped('r1'));
        transport.emit(_delta('r1', delta: 'late'));
        await pumpEventLoop();
        expect(s.state.phase, OpenAIRealtimeVoicePhase.listening);
        expect(s.state.failure, isNull);
        expect(transport.closeCalls, 0);
        expect(deltas, isEmpty);
      },
    );

    test(
      '6. singleTurn: after one cancel+clear -> ended, one transport close',
      () async {
        final s = build(mode: OpenAIRealtimeVoiceMode.singleTurn);
        addTearDown(s.dispose);
        await reachListening(s, transport);
        // The one user turn closes, then the assistant response is active.
        transport.emit(_speechStarted('u1'));
        await pumpEventLoop();
        transport.emit(_speechStopped('u1'));
        await pumpEventLoop();
        transport.emit(_responseCreated('r1'));
        await pumpEventLoop();

        await s.interruptResponse();
        await pumpEventLoop();
        expect(_countSent(transport, 'response.cancel'), 1);
        expect(_countSent(transport, 'output_audio_buffer.clear'), 1);
        expect(s.state.phase, OpenAIRealtimeVoicePhase.ended);
        expect(transport.closeCalls, 1);

        // A stop() afterwards is idempotent — no second cancel/clear/close.
        await s.stop();
        await pumpEventLoop();
        expect(_countSent(transport, 'response.cancel'), 1);
        expect(_countSent(transport, 'output_audio_buffer.clear'), 1);
        expect(transport.closeCalls, 1);
      },
    );

    test(
      '7. cancel send error: clear still attempted once, then transport fail',
      () async {
        final s = build();
        addTearDown(s.dispose);
        await reachListening(s, transport);
        transport.emit(_responseCreated('r1'));
        await pumpEventLoop();
        transport.failSendTypes = <String>{'response.cancel'};

        await s.interruptResponse();
        await pumpEventLoop();
        // Both were ATTEMPTED exactly once (cancel threw, clear still tried).
        expect(
          transport.sendAttempts.where((t) => t == 'response.cancel').length,
          1,
        );
        expect(
          transport.sendAttempts
              .where((t) => t == 'output_audio_buffer.clear')
              .length,
          1,
        );
        // One coarse transport failure + one teardown; no retry.
        expect(s.state.phase, OpenAIRealtimeVoicePhase.failed);
        expect(s.state.failure, OpenAIRealtimeVoiceFailure.transport);
        expect(transport.closeCalls, 1);
      },
    );

    test(
      '8. clear send error: no retry, one transport failure + teardown',
      () async {
        final s = build();
        addTearDown(s.dispose);
        await reachListening(s, transport);
        transport.emit(_responseCreated('r1'));
        await pumpEventLoop();
        transport.failSendTypes = <String>{'output_audio_buffer.clear'};

        await s.interruptResponse();
        await pumpEventLoop();
        expect(_countSent(transport, 'response.cancel'), 1); // cancel succeeded
        expect(
          transport.sendAttempts
              .where((t) => t == 'output_audio_buffer.clear')
              .length,
          1, // attempted exactly once, no retry
        );
        expect(s.state.phase, OpenAIRealtimeVoicePhase.failed);
        expect(s.state.failure, OpenAIRealtimeVoiceFailure.transport);
        expect(transport.closeCalls, 1);
      },
    );

    test('9a. race with stop(): single event pair and one teardown', () async {
      final s = build();
      addTearDown(s.dispose);
      await reachListening(s, transport);
      transport.emit(_responseCreated('r1'));
      await pumpEventLoop();
      await Future.wait(<Future<void>>[s.interruptResponse(), s.stop()]);
      await pumpEventLoop();
      expect(_countSent(transport, 'response.cancel'), 1);
      expect(_countSent(transport, 'output_audio_buffer.clear'), 1);
      expect(transport.closeCalls, 1);
    });

    test(
      '9b. race with a natural response.done is inert / no double teardown',
      () async {
        final s = build();
        addTearDown(s.dispose);
        await reachListening(s, transport);
        transport.emit(_responseCreated('r1'));
        await pumpEventLoop();
        final f = s.interruptResponse();
        // A natural completion of the same response races in.
        transport.emit(_responseDone('r1'));
        transport.emit(_outputStopped('r1'));
        await f;
        await pumpEventLoop();
        expect(_countSent(transport, 'response.cancel'), 1);
        expect(_countSent(transport, 'output_audio_buffer.clear'), 1);
        expect(transport.closeCalls, 0); // conversation stays live
        expect(s.state.failure, isNull);
      },
    );

    test(
      '10. no scenario mints, reconnects or sends response.create',
      () async {
        final s = build();
        addTearDown(s.dispose);
        await reachListening(s, transport);
        transport.emit(_responseCreated('r1'));
        await pumpEventLoop();
        await s.interruptResponse();
        await pumpEventLoop();
        transport.emit(_responseCreated('r2'));
        await pumpEventLoop();
        await s.interruptResponse();
        await pumpEventLoop();
        expect(provider.calls, 1); // one mint only
        expect(transport.connectCalls, 1); // one connect, no reconnect
        expect(_countSent(transport, 'response.create'), 0);
      },
    );
  });

  // ======================================================================
  // interruptResponse P1 audit fixes: captured response_id + gated race +
  // recoverable cancel-error correlation.
  // ======================================================================
  group('interruptResponse P1 fixes (task_2)', () {
    Map<String, Object?> cancelPayload(FakeRealtimeVoiceTransport t) =>
        t.sent.firstWhere((e) => e['type'] == 'response.cancel');

    // task 1
    test('response.cancel carries the captured response_id', () async {
      final s = build();
      addTearDown(s.dispose);
      await reachListening(s, transport);
      transport.emit(_responseCreated('r1'));
      await pumpEventLoop();
      await s.interruptResponse();
      await pumpEventLoop();
      expect(cancelPayload(transport)['response_id'], 'r1');
    });

    // task 2
    test(
      'cancel then clear are queued (in order) before the cancel gate opens',
      () async {
        final s = build();
        addTearDown(s.dispose);
        await reachListening(s, transport);
        transport.emit(_responseCreated('r1'));
        await pumpEventLoop();
        // Isolate from the session.update sent during setup.
        transport.sent.clear();
        transport.sendAttempts.clear();
        final gate = Completer<void>();
        transport.sendGate = gate;
        final f = s.interruptResponse();
        // Both were queued SYNCHRONOUSLY, in order, while the gate is still closed.
        expect(transport.sendAttempts, <String>[
          'response.cancel',
          'output_audio_buffer.clear',
        ]);
        expect(transport.sent.map((e) => e['type']).toList(), <String>[
          'response.cancel',
          'output_audio_buffer.clear',
        ]);
        gate.complete();
        await f;
        await pumpEventLoop();
      },
    );

    // task 3
    test('gated interrupt then speech_started -> stays userSpeaking', () async {
      final s = build();
      addTearDown(s.dispose);
      await reachListening(s, transport);
      transport.emit(_responseCreated('r1'));
      await pumpEventLoop();
      final gate = Completer<void>();
      transport.sendGate = gate;
      final f = s.interruptResponse();
      // A new user turn begins while the cancel/clear are in flight.
      transport.emit(_speechStarted('u2'));
      await pumpEventLoop();
      expect(s.state.phase, OpenAIRealtimeVoicePhase.userSpeaking);
      gate.complete();
      await f;
      await pumpEventLoop();
      // The old interrupt must NOT overwrite the newer userSpeaking with listening.
      expect(s.state.phase, OpenAIRealtimeVoicePhase.userSpeaking);
    });

    // task 4
    test(
      'gated interrupt then new response.created(r2): r2 untouched',
      () async {
        final s = build();
        addTearDown(s.dispose);
        final deltas = <String>[];
        s.assistantTranscriptDeltas.listen((d) => deltas.add(d.delta));
        await reachListening(s, transport);
        transport.emit(_responseCreated('r1'));
        await pumpEventLoop();
        final gate = Completer<void>();
        transport.sendGate = gate;
        final f = s.interruptResponse();
        // r2 binds while r1's interrupt is in flight.
        transport.emit(_responseCreated('r2'));
        await pumpEventLoop();
        gate.complete();
        await f;
        await pumpEventLoop();
        // r1's completion does not cancel/reset r2.
        expect(s.state.phase, OpenAIRealtimeVoicePhase.assistantSpeaking);
        expect(_countSent(transport, 'response.cancel'), 1); // only r1's
        // r2 accepts its own deltas...
        transport.emit(_delta('r2', delta: 'r2-delta'));
        await pumpEventLoop();
        expect(deltas, contains('r2-delta'));
        transport.sendGate = null;
        // ...and is independently interruptible with exactly one new pair.
        await s.interruptResponse();
        await pumpEventLoop();
        expect(_countSent(transport, 'response.cancel'), 2);
        expect(_countSent(transport, 'output_audio_buffer.clear'), 2);
        expect(cancelPayload(transport)['response_id'], 'r1'); // first cancel
        final secondCancel = transport.sent
            .where((e) => e['type'] == 'response.cancel')
            .toList()[1];
        expect(secondCancel['response_id'], 'r2'); // second targets r2 (task 5)
      },
    );

    // task 6
    test(
      'response.done(completed) but audio not stopped -> clear is sent',
      () async {
        final s = build();
        addTearDown(s.dispose);
        await reachListening(s, transport);
        transport.emit(_responseCreated('r1'));
        transport.emit(_responseDone('r1')); // completed, but no output stopped
        await pumpEventLoop();
        await s.interruptResponse();
        await pumpEventLoop();
        expect(_countSent(transport, 'response.cancel'), 1);
        expect(_countSent(transport, 'output_audio_buffer.clear'), 1);
      },
    );

    // task 7
    test(
      'a correlated cancel error is recoverable (conversation stays live)',
      () async {
        final s = build();
        addTearDown(s.dispose);
        await reachListening(s, transport);
        transport.emit(_responseCreated('r1'));
        await pumpEventLoop();
        await s.interruptResponse();
        await pumpEventLoop();
        final cancelId = cancelPayload(transport)['event_id'] as String;
        transport.emit(<String, Object?>{
          'type': 'error',
          'error': <String, Object?>{
            'event_id': cancelId,
            'message': 'nothing to cancel',
            'code': 'response_cancel_not_active',
          },
        });
        await pumpEventLoop();
        expect(s.state.phase, isNot(OpenAIRealtimeVoicePhase.failed));
        expect(s.state.failure, isNull);
        expect(transport.closeCalls, 0);
        expect(provider.calls, 1);
        expect(transport.connectCalls, 1);
        expect(_countSent(transport, 'response.create'), 0);
      },
    );

    // task 8
    test(
      'a correlated CLEAR error stays a terminal transport failure',
      () async {
        final s = build();
        addTearDown(s.dispose);
        await reachListening(s, transport);
        transport.emit(_responseCreated('r1'));
        await pumpEventLoop();
        await s.interruptResponse();
        await pumpEventLoop();
        final clearId =
            transport.sent.firstWhere(
                  (e) => e['type'] == 'output_audio_buffer.clear',
                )['event_id']
                as String;
        transport.emit(<String, Object?>{
          'type': 'error',
          'error': <String, Object?>{'event_id': clearId},
        });
        await pumpEventLoop();
        expect(s.state.phase, OpenAIRealtimeVoicePhase.failed);
        expect(s.state.failure, OpenAIRealtimeVoiceFailure.transport);
        expect(transport.closeCalls, 1);
      },
    );

    // task 9
    test(
      'a foreign/unrelated error stays terminal by the existing contract',
      () async {
        final s = build();
        addTearDown(s.dispose);
        await reachListening(s, transport);
        transport.emit(_responseCreated('r1'));
        await pumpEventLoop();
        await s.interruptResponse();
        await pumpEventLoop();
        transport.emit(<String, Object?>{
          'type': 'error',
          'error': <String, Object?>{'event_id': 'foreign_evt_999'},
        });
        await pumpEventLoop();
        expect(s.state.phase, OpenAIRealtimeVoicePhase.failed);
        expect(s.state.failure, OpenAIRealtimeVoiceFailure.transport);
      },
    );

    // task 10
    test(
      'a repeated correlated cancel error causes no second transition',
      () async {
        final s = build();
        addTearDown(s.dispose);
        await reachListening(s, transport);
        transport.emit(_responseCreated('r1'));
        await pumpEventLoop();
        await s.interruptResponse();
        await pumpEventLoop();
        final cancelId = cancelPayload(transport)['event_id'] as String;
        final err = <String, Object?>{
          'type': 'error',
          'error': <String, Object?>{'event_id': cancelId},
        };
        transport.emit(err);
        transport.emit(err);
        await pumpEventLoop();
        expect(s.state.phase, OpenAIRealtimeVoicePhase.listening);
        expect(s.state.failure, isNull);
        expect(transport.closeCalls, 0);
      },
    );

    // task 11
    test('race with stop() at gated sends: one pair, one teardown', () async {
      final s = build();
      await reachListening(s, transport);
      transport.emit(_responseCreated('r1'));
      await pumpEventLoop();
      final gate = Completer<void>();
      transport.sendGate = gate;
      final fi = s.interruptResponse();
      final fs = s.stop();
      gate.complete();
      await Future.wait(<Future<void>>[fi, fs]);
      await pumpEventLoop();
      expect(_countSent(transport, 'response.cancel'), 1);
      expect(_countSent(transport, 'output_audio_buffer.clear'), 1);
      expect(transport.closeCalls, 1);
      await s.dispose(); // idempotent, no unhandled errors
    });

    // task 12: a gated (not instant) barge-in / new user turn during interrupt.
    test(
      'gated interrupt then a full new user turn -> newer state kept',
      () async {
        final s = build();
        addTearDown(s.dispose);
        await reachListening(s, transport);
        transport.emit(_responseCreated('r1'));
        await pumpEventLoop();
        final gate = Completer<void>();
        transport.sendGate = gate;
        final f = s.interruptResponse();
        // A full new user turn (speech_started + speech_stopped) races the in-flight
        // interrupt; the session is now awaiting the NEXT response.
        transport.emit(_speechStarted('u2'));
        await pumpEventLoop();
        transport.emit(_speechStopped('u2'));
        await pumpEventLoop();
        expect(s.state.phase, OpenAIRealtimeVoicePhase.assistantSpeaking);
        gate.complete();
        await f;
        await pumpEventLoop();
        // The old interrupt does not force `listening` over the newer state.
        expect(s.state.phase, OpenAIRealtimeVoicePhase.assistantSpeaking);
        expect(_countSent(transport, 'response.cancel'), 1);
      },
    );

    // A SAFE late server error for a PREVIOUS response's programmatic cancel,
    // arriving AFTER a new response was created, must stay inert and never
    // terminate the new, live response. (Regression: the correlation set must
    // NOT be cleared on response.created.)
    test(
      'a late correlated cancel error for r1 never fails the new r2',
      () async {
        final timers = FakeWatchdogTimerFactory();
        final s = voiceSessionForTesting(
          clientSecretProvider: provider,
          botProfile: botProfile(),
          transportFactory: () => transport,
          mode: OpenAIRealtimeVoiceMode.conversation,
          transcriptsEnabled: true,
          timerFactory: timers.call,
        );
        addTearDown(s.dispose);
        final deltas = <String>[];
        s.assistantTranscriptDeltas.listen((d) => deltas.add(d.delta));
        await reachListening(s, transport);
        // r1 → interrupt(r1) → remember its cancel event id.
        transport.emit(_responseCreated('r1'));
        await pumpEventLoop();
        await s.interruptResponse();
        await pumpEventLoop();
        final r1CancelId = cancelPayload(transport)['event_id'] as String;
        // A new r2 binds after the interrupt.
        transport.emit(_responseCreated('r2'));
        await pumpEventLoop();
        expect(s.state.phase, OpenAIRealtimeVoicePhase.assistantSpeaking);
        final r2Watchdog = timers.active;
        expect(r2Watchdog, isNotNull); // r2's watchdog is armed
        // The safe late error for r1's cancel arrives AFTER r2 was created.
        transport.emit(<String, Object?>{
          'type': 'error',
          'error': <String, Object?>{'event_id': r1CancelId},
        });
        await pumpEventLoop();
        // r2 is untouched: still assistantSpeaking, no failure, transport open,
        // and its watchdog was NOT reset by the error.
        expect(s.state.phase, OpenAIRealtimeVoicePhase.assistantSpeaking);
        expect(s.state.failure, isNull);
        expect(transport.closeCalls, 0);
        expect(identical(timers.active, r2Watchdog), isTrue);
        // r2 still accepts its own transcript deltas.
        transport.emit(_delta('r2', delta: 'r2-live'));
        await pumpEventLoop();
        expect(deltas, contains('r2-live'));
        // No new mint/connect/retry/response.create.
        expect(provider.calls, 1);
        expect(transport.connectCalls, 1);
        expect(_countSent(transport, 'response.create'), 0);
      },
    );
  });
}
