// The optional-recording behaviour (required tests 1, 3–13), driven by the
// private fake transport, a Dart-only fake recorder and a deterministic fake
// watchdog timer — no native WebRTC, no real writer, no real clock.
//
// The coordinator turns the session's VALIDATED VAD / output-audio boundaries
// into one file per reply, pairs each with the matching transcript, and treats
// recording failures as a pure side channel. These tests assert exactly that.
import 'dart:async';

import 'package:chat_ai_openai_realtime_voice/chat_ai_openai_realtime_voice.dart';
import 'package:chat_ai_openai_realtime_voice/src/voice_recorder.dart';
import 'package:chat_ai_openai_realtime_voice/src/voice_session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

// ---- Event literals -------------------------------------------------------

Map<String, Object?> _created = <String, Object?>{'type': 'session.created'};
Map<String, Object?> _updated = <String, Object?>{'type': 'session.updated'};

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

Map<String, Object?> _responseDone(String id) => <String, Object?>{
  'type': 'response.done',
  'response': <String, Object?>{'id': id, 'status': 'completed'},
};

Map<String, Object?> _userTranscriptDone(String itemId, String text) =>
    <String, Object?>{
      'type': 'conversation.item.input_audio_transcription.completed',
      'item_id': itemId,
      'content_index': 0,
      'transcript': text,
    };

Map<String, Object?> _userTranscriptFailed(String itemId) => <String, Object?>{
  'type': 'conversation.item.input_audio_transcription.failed',
  'item_id': itemId,
  'content_index': 0,
  'error': <String, Object?>{'type': 'x'},
};

Map<String, Object?> _assistantTranscriptDone(String responseId, String text) =>
    <String, Object?>{
      'type': 'response.output_audio_transcript.done',
      'response_id': responseId,
      'item_id': 'item_$responseId',
      'output_index': 0,
      'content_index': 0,
      'transcript': text,
    };

int _countSent(FakeRealtimeVoiceTransport t, String type) =>
    t.sent.where((e) => e['type'] == type).length;

void main() {
  late FakeClientSecretProvider provider;
  late FakeRealtimeVoiceTransport transport;
  late FakeRecorderFactory recorders;
  late List<OpenAIRealtimeVoiceRecording> recordings;
  late List<OpenAIRealtimeVoiceRecordingFailure> failures;

  setUp(() {
    provider = FakeClientSecretProvider();
    transport = FakeRealtimeVoiceTransport();
    recorders = FakeRecorderFactory();
    recordings = <OpenAIRealtimeVoiceRecording>[];
    failures = <OpenAIRealtimeVoiceRecordingFailure>[];
  });

  OpenAIRealtimeVoiceSession build({
    OpenAIRealtimeVoiceMode mode = OpenAIRealtimeVoiceMode.singleTurn,
    bool recordingEnabled = true,
    bool transcriptsEnabled = false,
    FakeRecorderFactory? factory,
    FakeRealtimeVoiceTransport? t,
    Timer Function(Duration, void Function())? timerFactory,
  }) {
    final f = factory ?? recorders;
    final tr = t ?? transport;
    final session = voiceSessionForTesting(
      clientSecretProvider: provider,
      botProfile: botProfile(),
      transportFactory: () => tr,
      mode: mode,
      transcriptsEnabled: transcriptsEnabled,
      recordingEnabled: recordingEnabled,
      recordingDirectoryPath: '/rec',
      recorderFactory: recordingEnabled ? f.call : null,
      timerFactory: timerFactory ?? _realTimer,
    );
    session.recordings.listen(recordings.add);
    session.recordingFailures.listen(failures.add);
    return session;
  }

  Future<void> reachListening(
    OpenAIRealtimeVoiceSession s,
    FakeRealtimeVoiceTransport t, {
    bool remote = true,
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

  OpenAIRealtimeVoiceRecording userRec() => recordings.firstWhere(
    (r) => r.role == OpenAIRealtimeVoiceRecordingRole.user,
  );
  OpenAIRealtimeVoiceRecording assistantRec() => recordings.firstWhere(
    (r) => r.role == OpenAIRealtimeVoiceRecordingRole.assistant,
  );

  // ---- Required test 1: recording off leaves the path unchanged ----------
  test(
    'recordingEnabled=false makes no recorder calls and no events',
    () async {
      final session = build(recordingEnabled: false);
      addTearDown(session.dispose);

      await reachListening(session, transport);
      // Existing path: the mic is enabled exactly once, phase listening.
      expect(transport.enabledCalls, <bool>[true]);
      expect(session.state.phase, OpenAIRealtimeVoicePhase.listening);

      transport.emit(_speechStarted('u1'));
      transport.emit(_speechStopped('u1'));
      transport.emit(_responseCreated('r1'));
      transport.emit(_outputStarted('r1'));
      transport.emit(_outputStopped('r1'));
      transport.emit(_responseDone('r1'));
      await pumpEventLoop();

      // No recorder was ever created and nothing crossed the recording streams.
      expect(recorders.created, isEmpty);
      expect(recordings, isEmpty);
      expect(failures, isEmpty);
      expect(session.state.phase, OpenAIRealtimeVoicePhase.ended);
    },
  );

  // ---- Required test 3: singleTurn = one user + one assistant file --------
  test('singleTurn produces exactly one user and one assistant file', () async {
    final session = build();
    addTearDown(session.dispose);

    await reachListening(session, transport);
    // Both taps attached BEFORE the mic went live (user) / once remote arrived.
    expect(recorders.user, isNotNull);
    expect(recorders.assistant, isNotNull);
    expect(recorders.user!.attachedTrackId, 'local-track-1');
    expect(recorders.assistant!.attachedTrackId, 'remote-track-1');
    // The user tap attached before the mic was enabled.
    expect(recorders.user!.attachCalls, 1);

    transport.emit(_speechStarted('u1'));
    await pumpEventLoop();
    transport.emit(_speechStopped('u1'));
    await pumpEventLoop();
    transport.emit(_responseCreated('r1'));
    transport.emit(_outputStarted('r1'));
    await pumpEventLoop();
    transport.emit(_outputStopped('r1'));
    transport.emit(_responseDone('r1'));
    await pumpEventLoop();

    expect(session.state.phase, OpenAIRealtimeVoicePhase.ended);
    expect(recordings.length, 2);
    expect(failures, isEmpty);
    expect(userRec().interrupted, isFalse);
    expect(assistantRec().interrupted, isFalse);
    expect(userRec().filePath.contains('user'), isTrue);
    expect(assistantRec().filePath.contains('assistant'), isTrue);
  });

  // ---- Required test 4: conversation = separate files per turn ------------
  test('conversation produces separate files for several turns', () async {
    final session = build(mode: OpenAIRealtimeVoiceMode.conversation);
    addTearDown(session.dispose);
    await reachListening(session, transport);

    Future<void> turn(String u, String r) async {
      transport.emit(_speechStarted(u));
      await pumpEventLoop();
      transport.emit(_speechStopped(u));
      await pumpEventLoop();
      transport.emit(_responseCreated(r));
      transport.emit(_outputStarted(r));
      await pumpEventLoop();
      transport.emit(_outputStopped(r));
      transport.emit(_responseDone(r));
      await pumpEventLoop();
    }

    await turn('u1', 'r1');
    expect(session.state.phase, OpenAIRealtimeVoicePhase.listening);
    await turn('u2', 'r2');

    final userFiles = recordings
        .where((r) => r.role == OpenAIRealtimeVoiceRecordingRole.user)
        .map((r) => r.filePath)
        .toList();
    final assistantFiles = recordings
        .where((r) => r.role == OpenAIRealtimeVoiceRecordingRole.assistant)
        .map((r) => r.filePath)
        .toList();
    expect(userFiles.length, 2);
    expect(assistantFiles.length, 2);
    // Every file is a distinct path (never one mixed session file).
    expect(recordings.map((r) => r.filePath).toSet().length, 4);
    expect(recordings.every((r) => !r.interrupted), isTrue);
    expect(failures, isEmpty);
  });

  // ---- Required test 5: exact role / path / interrupted / transcript ------
  test(
    'each recording carries the exact role, path, flag and transcript',
    () async {
      final session = build(transcriptsEnabled: true);
      addTearDown(session.dispose);
      await reachListening(session, transport);

      transport.emit(_speechStarted('u1'));
      await pumpEventLoop();
      transport.emit(_speechStopped('u1'));
      await pumpEventLoop();
      transport.emit(_userTranscriptDone('u1', 'hello world'));
      await pumpEventLoop();

      final u = userRec();
      expect(u.role, OpenAIRealtimeVoiceRecordingRole.user);
      expect(u.filePath, '/rec/${recorders.user!.ended.single}.m4a');
      expect(u.interrupted, isFalse);
      expect(u.transcript, 'hello world');
    },
  );

  // ---- Required test 6: transcripts off/on, both audio/transcript orders --
  group('transcript pairing (required test 6)', () {
    test('transcripts OFF -> file with a null transcript', () async {
      final session = build(transcriptsEnabled: false);
      addTearDown(session.dispose);
      await reachListening(session, transport);
      transport.emit(_speechStarted('u1'));
      await pumpEventLoop();
      transport.emit(_speechStopped('u1'));
      await pumpEventLoop();
      expect(userRec().transcript, isNull);
    });

    test('audio-then-transcript: the file waits and pairs', () async {
      final session = build(
        mode: OpenAIRealtimeVoiceMode.conversation,
        transcriptsEnabled: true,
      );
      addTearDown(session.dispose);
      await reachListening(session, transport);

      transport.emit(_speechStarted('u1'));
      await pumpEventLoop();
      transport.emit(_speechStopped('u1'));
      await pumpEventLoop();
      // Audio finalized, transcript not yet here: NOTHING is emitted.
      expect(recordings, isEmpty);
      // The transcript arrives -> the file is emitted, paired.
      transport.emit(_userTranscriptDone('u1', 'paired later'));
      await pumpEventLoop();
      expect(recordings.length, 1);
      expect(userRec().transcript, 'paired later');
    });

    test('transcript-then-audio-end (assistant): pairs immediately', () async {
      final session = build(
        mode: OpenAIRealtimeVoiceMode.conversation,
        transcriptsEnabled: true,
      );
      addTearDown(session.dispose);
      await reachListening(session, transport);

      transport.emit(_responseCreated('r1'));
      transport.emit(_outputStarted('r1'));
      await pumpEventLoop();
      // Transcript arrives BEFORE the output audio stops.
      transport.emit(_assistantTranscriptDone('r1', 'assistant said this'));
      await pumpEventLoop();
      expect(recordings, isEmpty); // segment not finalized yet
      transport.emit(_outputStopped('r1'));
      await pumpEventLoop();
      expect(assistantRec().transcript, 'assistant said this');
    });

    test('an empty final transcript is the empty string, not null', () async {
      final session = build(
        mode: OpenAIRealtimeVoiceMode.conversation,
        transcriptsEnabled: true,
      );
      addTearDown(session.dispose);
      await reachListening(session, transport);
      transport.emit(_speechStarted('u1'));
      await pumpEventLoop();
      transport.emit(_speechStopped('u1'));
      await pumpEventLoop();
      transport.emit(_userTranscriptDone('u1', ''));
      await pumpEventLoop();
      expect(userRec().transcript, '');
      expect(userRec().transcript, isNotNull);
    });
  });

  // ---- Required test 7: transcript failure / timeout -> null --------------
  group('transcript failure and timeout (required test 7)', () {
    test(
      'a transcription failure emits the file with a null transcript',
      () async {
        final session = build(
          mode: OpenAIRealtimeVoiceMode.conversation,
          transcriptsEnabled: true,
        );
        addTearDown(session.dispose);
        await reachListening(session, transport);
        transport.emit(_speechStarted('u1'));
        await pumpEventLoop();
        transport.emit(_speechStopped('u1'));
        await pumpEventLoop();
        expect(recordings, isEmpty);
        transport.emit(_userTranscriptFailed('u1'));
        await pumpEventLoop();
        expect(recordings.length, 1);
        expect(userRec().transcript, isNull);
      },
    );

    test('a bounded timeout emits the file with a null transcript', () async {
      final timers = FakeWatchdogTimerFactory();
      final session = build(
        mode: OpenAIRealtimeVoiceMode.conversation,
        transcriptsEnabled: true,
        timerFactory: timers.call,
      );
      addTearDown(session.dispose);
      await reachListening(session, transport);
      transport.emit(_speechStarted('u1'));
      await pumpEventLoop();
      transport.emit(_speechStopped('u1'));
      await pumpEventLoop();
      // The file is finalized and awaiting the transcript behind a deadline.
      expect(recordings, isEmpty);
      expect(timers.active, isNotNull);
      // The transcript never arrives; the deadline fires -> null transcript.
      timers.active!.fire();
      await pumpEventLoop();
      expect(recordings.length, 1);
      expect(userRec().transcript, isNull);
    });
  });

  // ---- Required test 8: malformed / foreign / duplicate events ------------
  group('malformed / foreign / duplicate events (required test 8)', () {
    test('a malformed speech_started never opens a segment', () async {
      final session = build(mode: OpenAIRealtimeVoiceMode.conversation);
      addTearDown(session.dispose);
      await reachListening(session, transport);
      // Empty item id, and missing/negative audio_start_ms.
      transport.emit(<String, Object?>{
        'type': 'input_audio_buffer.speech_started',
        'item_id': '',
        'audio_start_ms': 0,
      });
      transport.emit(<String, Object?>{
        'type': 'input_audio_buffer.speech_started',
        'item_id': 'u1',
        'audio_start_ms': -1,
      });
      await pumpEventLoop();
      expect(recorders.user!.begun, isEmpty);
      transport.emit(_speechStopped('u1'));
      await pumpEventLoop();
      expect(recordings, isEmpty);
      expect(failures, isEmpty);
    });

    test('a duplicate speech_started opens only one segment', () async {
      final session = build(mode: OpenAIRealtimeVoiceMode.conversation);
      addTearDown(session.dispose);
      await reachListening(session, transport);
      transport.emit(_speechStarted('u1'));
      transport.emit(_speechStarted('u1'));
      await pumpEventLoop();
      expect(recorders.user!.begun.length, 1);
    });

    test(
      'a foreign / out-of-order stop does not cut the open segment',
      () async {
        final session = build(mode: OpenAIRealtimeVoiceMode.conversation);
        addTearDown(session.dispose);
        await reachListening(session, transport);
        transport.emit(_speechStarted('u1', startMs: 100));
        await pumpEventLoop();
        // Foreign item id, then audio_end_ms < audio_start_ms.
        transport.emit(_speechStopped('other'));
        transport.emit(_speechStopped('u1', endMs: 10));
        await pumpEventLoop();
        expect(recordings, isEmpty);
        // A well-formed stop finally closes it.
        transport.emit(_speechStopped('u1', endMs: 300));
        await pumpEventLoop();
        expect(recordings.length, 1);
        expect(recorders.user!.ended.length, 1);
      },
    );

    test('a foreign / duplicate transcript is never paired', () async {
      final session = build(
        mode: OpenAIRealtimeVoiceMode.conversation,
        transcriptsEnabled: true,
      );
      addTearDown(session.dispose);
      await reachListening(session, transport);
      transport.emit(_speechStarted('u1'));
      await pumpEventLoop();
      transport.emit(_speechStopped('u1'));
      await pumpEventLoop();
      // A transcript for a DIFFERENT item never resolves this file.
      transport.emit(_userTranscriptDone('other', 'foreign'));
      await pumpEventLoop();
      expect(recordings, isEmpty);
      // The real one pairs; a duplicate afterwards changes nothing.
      transport.emit(_userTranscriptDone('u1', 'real'));
      transport.emit(_userTranscriptDone('u1', 'dup'));
      await pumpEventLoop();
      expect(recordings.length, 1);
      expect(userRec().transcript, 'real');
    });
  });

  // ---- Required test 9: barge-in -> partial interrupted assistant file ----
  test('barge-in finalizes the assistant file as interrupted', () async {
    final session = build(mode: OpenAIRealtimeVoiceMode.conversation);
    addTearDown(session.dispose);
    await reachListening(session, transport);

    transport.emit(_responseCreated('r1'));
    transport.emit(_outputStarted('r1'));
    await pumpEventLoop();
    // The user barges in over the assistant's response.
    transport.emit(_speechStarted('u2'));
    await pumpEventLoop();

    final assistant = assistantRec();
    expect(assistant.interrupted, isTrue);
    // No redundant cancel/truncate/clear was sent (server owns the barge-in).
    expect(_countSent(transport, 'response.cancel'), 0);
    expect(_countSent(transport, 'output_audio_buffer.clear'), 0);
    // The barge-in opened the next user segment.
    expect(recorders.user!.begun.length, 1);
  });

  // ---- Required test 10: stop/cancel during user or assistant audio -------
  group('stop during audio -> valid partial or failure, exactly once', () {
    test(
      'stop while the user is speaking saves an interrupted user file',
      () async {
        final session = build();
        addTearDown(session.dispose);
        await reachListening(session, transport);
        transport.emit(_speechStarted('u1'));
        await pumpEventLoop();
        // Stop mid-user-speech (no speech_stopped yet).
        await session.stop();
        await pumpEventLoop();
        final user = userRec();
        expect(user.interrupted, isTrue);
        // Exactly once.
        expect(
          recordings
              .where((r) => r.role == OpenAIRealtimeVoiceRecordingRole.user)
              .length,
          1,
        );
      },
    );

    test(
      'stop during the assistant response saves an interrupted file',
      () async {
        final session = build(mode: OpenAIRealtimeVoiceMode.conversation);
        addTearDown(session.dispose);
        await reachListening(session, transport);
        transport.emit(_responseCreated('r1'));
        transport.emit(_outputStarted('r1'));
        await pumpEventLoop();
        await session.stop();
        await pumpEventLoop();
        expect(assistantRec().interrupted, isTrue);
        expect(session.state.phase, OpenAIRealtimeVoicePhase.ended);
        // Idempotent: a second stop adds no further recording.
        final before = recordings.length;
        await session.stop();
        await pumpEventLoop();
        expect(recordings.length, before);
      },
    );

    test('an empty interrupted fragment becomes a single failure', () async {
      final factory = FakeRecorderFactory(
        configure: (r) {
          if (!r.isRemote) {
            r.resultFor = (_) => const VoiceRecordingSegmentResult.failed();
          }
        },
      );
      final session = build(factory: factory);
      addTearDown(session.dispose);
      await reachListening(session, transport);
      transport.emit(_speechStarted('u1'));
      await pumpEventLoop();
      await session.stop();
      await pumpEventLoop();
      // No user file, exactly one user failure.
      expect(
        recordings.where(
          (r) => r.role == OpenAIRealtimeVoiceRecordingRole.user,
        ),
        isEmpty,
      );
      expect(
        failures
            .where((f) => f.role == OpenAIRealtimeVoiceRecordingRole.user)
            .length,
        1,
      );
    });
  });

  // ---- Required test 11: one writer's error never breaks the session ------
  group('a writer error is isolated (required test 11)', () {
    test('a user finalize failure still yields the assistant file', () async {
      final factory = FakeRecorderFactory(
        configure: (r) {
          if (!r.isRemote) {
            r.resultFor = (_) => const VoiceRecordingSegmentResult.failed();
          }
        },
      );
      final session = build(factory: factory);
      addTearDown(session.dispose);
      await reachListening(session, transport);

      transport.emit(_speechStarted('u1'));
      await pumpEventLoop();
      transport.emit(_speechStopped('u1'));
      await pumpEventLoop();
      transport.emit(_responseCreated('r1'));
      transport.emit(_outputStarted('r1'));
      await pumpEventLoop();
      transport.emit(_outputStopped('r1'));
      transport.emit(_responseDone('r1'));
      await pumpEventLoop();

      // The user side failed; the assistant side still produced its file. The
      // voice session ended normally (a recording failure is a side channel).
      expect(
        failures
            .where((f) => f.role == OpenAIRealtimeVoiceRecordingRole.user)
            .length,
        1,
      );
      expect(recordings.length, 1);
      expect(
        recordings.single.role,
        OpenAIRealtimeVoiceRecordingRole.assistant,
      );
      expect(session.state.phase, OpenAIRealtimeVoicePhase.ended);
      expect(session.state.failure, isNull);
    });

    test(
      'a user attach failure never blocks the mic or the assistant',
      () async {
        final factory = FakeRecorderFactory(
          configure: (r) {
            if (!r.isRemote) {
              r.attachThrows = true;
            }
          },
        );
        final session = build(
          mode: OpenAIRealtimeVoiceMode.conversation,
          factory: factory,
        );
        addTearDown(session.dispose);
        await reachListening(session, transport);

        // The mic still went live and the session reached listening.
        expect(transport.enabledCalls.where((e) => e).length, 1);
        expect(session.state.phase, OpenAIRealtimeVoicePhase.listening);
        // Exactly one user (attach) failure.
        expect(
          failures
              .where((f) => f.role == OpenAIRealtimeVoiceRecordingRole.user)
              .length,
          1,
        );
        // The assistant side is unaffected.
        transport.emit(_responseCreated('r1'));
        transport.emit(_outputStarted('r1'));
        await pumpEventLoop();
        transport.emit(_outputStopped('r1'));
        await pumpEventLoop();
        expect(assistantRec().role, OpenAIRealtimeVoiceRecordingRole.assistant);
      },
    );
  });

  // ---- Required test 12: recording adds no network / mint / Response ------
  test(
    'recording adds no extra mint / signaling / Response / reconnect',
    () async {
      final session = build();
      addTearDown(session.dispose);
      await reachListening(session, transport);
      transport.emit(_speechStarted('u1'));
      await pumpEventLoop();
      transport.emit(_speechStopped('u1'));
      await pumpEventLoop();
      transport.emit(_responseCreated('r1'));
      transport.emit(_outputStarted('r1'));
      await pumpEventLoop();
      transport.emit(_outputStopped('r1'));
      transport.emit(_responseDone('r1'));
      await pumpEventLoop();

      expect(provider.calls, 1); // exactly one mint
      expect(transport.connectCalls, 1); // exactly one signaling/connect
      expect(_countSent(transport, 'response.create'), 0); // server VAD owns it
      expect(_countSent(transport, 'session.update'), 1);
      expect(transport.closeCalls, 1); // one teardown, no reconnect
    },
  );

  // ---- Required test 13: cleanup + late native outcomes ------------------
  group('cleanup and late outcomes (required test 13)', () {
    test('dispose closes both native recorders exactly once', () async {
      final session = build(mode: OpenAIRealtimeVoiceMode.conversation);
      await reachListening(session, transport);
      transport.emit(_speechStarted('u1'));
      await pumpEventLoop();
      transport.emit(_speechStopped('u1'));
      await pumpEventLoop();
      await session.dispose();
      await pumpEventLoop();
      expect(recorders.user!.closeCalls, 1);
      expect(recorders.assistant!.closeCalls, 1);
    });

    test('events after teardown emit nothing more', () async {
      final session = build(mode: OpenAIRealtimeVoiceMode.conversation);
      addTearDown(session.dispose);
      await reachListening(session, transport);
      transport.emit(_speechStarted('u1'));
      await pumpEventLoop();
      transport.emit(_speechStopped('u1'));
      await pumpEventLoop();
      final produced = recordings.length;
      await session.stop();
      await pumpEventLoop();
      final afterStop = recordings.length;
      // A late boundary after teardown is inert.
      transport.emit(_speechStarted('u2'));
      transport.emit(_speechStopped('u2'));
      await pumpEventLoop();
      expect(recordings.length, afterStop);
      expect(afterStop, greaterThanOrEqualTo(produced));
    });

    test('a late deadline after dispose never emits', () async {
      final timers = FakeWatchdogTimerFactory();
      final session = build(
        mode: OpenAIRealtimeVoiceMode.conversation,
        transcriptsEnabled: true,
        timerFactory: timers.call,
      );
      await reachListening(session, transport);
      transport.emit(_speechStarted('u1'));
      await pumpEventLoop();
      transport.emit(_speechStopped('u1'));
      await pumpEventLoop();
      // A deadline is pending (awaiting the transcript).
      final deadline = timers.active;
      expect(deadline, isNotNull);
      await session.dispose();
      await pumpEventLoop();
      final count = recordings.length;
      // Firing the now-cancelled deadline does nothing.
      deadline!.fire();
      await pumpEventLoop();
      expect(recordings.length, count);
    });
  });

  // ---- task_2 audit fixes: event-driven boundary lifecycle ---------------
  group('event-driven boundary lifecycle (task_2)', () {
    // task_2 test 1: the verified audio_start_ms/audio_end_ms are APPLIED as
    // boundary validation (item match + non-negative + end>=start), not simply
    // discarded. (They are NOT used as sample-accurate PCM offsets — no such
    // mapping exists over flutter_webrtc; see the package docs.)
    test(
      'audio_start_ms/audio_end_ms are applied to gate the boundary',
      () async {
        final session = build(mode: OpenAIRealtimeVoiceMode.conversation);
        addTearDown(session.dispose);
        await reachListening(session, transport);

        // Open with a non-zero start.
        transport.emit(_speechStarted('u1', startMs: 500));
        await pumpEventLoop();
        // A stop whose audio_end_ms < audio_start_ms is NOT a valid pair.
        transport.emit(_speechStopped('u1', endMs: 100));
        await pumpEventLoop();
        expect(recordings, isEmpty);
        // A stop missing audio_end_ms is also not a valid pair.
        transport.emit(<String, Object?>{
          'type': 'input_audio_buffer.speech_stopped',
          'item_id': 'u1',
        });
        await pumpEventLoop();
        expect(recordings, isEmpty);
        // A well-formed pair (end >= start) closes the one segment.
        transport.emit(_speechStopped('u1', endMs: 900));
        await pumpEventLoop();
        expect(recordings.length, 1);
        expect(recorders.user!.begun.length, 1);
        expect(recorders.user!.ended.length, 1);
      },
    );

    // task_2 tests 2 & 3: an overlapping / out-of-order speech_started never
    // replaces or destroys the active segment (no second begin is issued, so
    // the previous in-progress temp is never dropped).
    test(
      'overlapping speech_started never replaces the active segment',
      () async {
        final session = build(mode: OpenAIRealtimeVoiceMode.conversation);
        addTearDown(session.dispose);
        await reachListening(session, transport);

        transport.emit(_speechStarted('u1', startMs: 0));
        await pumpEventLoop();
        // Overlap: a different item id arrives before u1 stops. It must be ignored
        // — no second begin, the u1 segment stays intact.
        transport.emit(_speechStarted('u2', startMs: 10));
        transport.emit(_speechStarted('u1', startMs: 20)); // duplicate too
        await pumpEventLoop();
        expect(recorders.user!.begun.length, 1);
        // u1 still closes normally and is the recording that is produced.
        transport.emit(_speechStopped('u1', endMs: 300));
        await pumpEventLoop();
        expect(recordings.length, 1);
        expect(recorders.user!.begun.single, recorders.user!.ended.single);
        // A late stop for the ignored overlap does nothing.
        transport.emit(_speechStopped('u2', endMs: 400));
        await pumpEventLoop();
        expect(recordings.length, 1);
      },
    );

    // task_2 test 4 (Dart-observable half): two sequential sessions never mint
    // the same opaque segment id, so their native file names cannot collide via
    // a per-session counter reset. (The authoritative on-disk uniqueness is the
    // native per-segment UUID — a physical-smoke / native property, not faked
    // here by returning different paths from a fake.)
    test('two sequential sessions never reuse a segment id', () async {
      final recordersA = FakeRecorderFactory();
      final tA = FakeRealtimeVoiceTransport();
      final sessionA = build(factory: recordersA, t: tA);
      await reachListening(sessionA, tA);
      tA.emit(_speechStarted('u1'));
      await pumpEventLoop();
      tA.emit(_speechStopped('u1'));
      await pumpEventLoop();
      await sessionA.dispose();

      final recordersB = FakeRecorderFactory();
      final tB = FakeRealtimeVoiceTransport();
      final sessionB = build(factory: recordersB, t: tB);
      addTearDown(sessionB.dispose);
      await reachListening(sessionB, tB);
      tB.emit(_speechStarted('u1'));
      await pumpEventLoop();
      tB.emit(_speechStopped('u1'));
      await pumpEventLoop();

      final idA = recordersA.user!.begun.single;
      final idB = recordersB.user!.begun.single;
      expect(idA, isNot(idB), reason: 'segment ids must be process-unique');
    });

    // task_2 test 6: an encoder/write/finalize failure publishes NO recording
    // and emits exactly one coarse failure for that role; the session is
    // unaffected.
    test(
      'an encoder/finalize failure publishes no recording, one failure',
      () async {
        final factory = FakeRecorderFactory(
          configure: (r) {
            if (!r.isRemote) {
              r.resultFor = (_) => const VoiceRecordingSegmentResult.failed();
            }
          },
        );
        final session = build(
          mode: OpenAIRealtimeVoiceMode.conversation,
          factory: factory,
        );
        addTearDown(session.dispose);
        await reachListening(session, transport);
        transport.emit(_speechStarted('u1'));
        await pumpEventLoop();
        transport.emit(_speechStopped('u1'));
        await pumpEventLoop();

        expect(
          recordings.where(
            (r) => r.role == OpenAIRealtimeVoiceRecordingRole.user,
          ),
          isEmpty,
        );
        expect(
          failures
              .where((f) => f.role == OpenAIRealtimeVoiceRecordingRole.user)
              .length,
          1,
        );
        // The voice session keeps running (a recording failure is a side channel):
        // it never becomes a terminal `failed` state.
        expect(session.state.phase, isNot(OpenAIRealtimeVoicePhase.failed));
        expect(session.state.failure, isNull);
      },
    );

    // task_2 test 7: a missing/late remote track plus a normal close resolves
    // the assistant track waiter with NO pending Future and NO late event, and
    // never emits a false failure for a role that simply never spoke.
    test(
      'a never-arriving remote track leaves no pending waiter or event',
      () async {
        final session = build(mode: OpenAIRealtimeVoiceMode.conversation);
        // NB: reachListening(remote:false) never completes the remote track.
        await reachListening(session, transport, remote: false);

        // A full user turn still records; the assistant side simply never armed.
        transport.emit(_speechStarted('u1'));
        await pumpEventLoop();
        transport.emit(_speechStopped('u1'));
        await pumpEventLoop();
        expect(recorders.assistant, isNull); // never attached
        expect(userRec().role, OpenAIRealtimeVoiceRecordingRole.user);

        // Closing must not hang (the waiter resolves via the terminal signal) and
        // must not emit a false assistant failure.
        await session.dispose();
        await pumpEventLoop();
        expect(recorders.assistant, isNull);
        expect(
          failures.where(
            (f) => f.role == OpenAIRealtimeVoiceRecordingRole.assistant,
          ),
          isEmpty,
        );
      },
    );
  });
}

Timer _realTimer(Duration d, void Function() cb) => Timer(d, cb);
