// The strict VAD-pair contract (P1 defect 4): one package-private VAD state that
// works identically with recording ON or OFF. A valid speech_started requires a
// non-empty item_id, a non-negative audio_start_ms, no already-open segment and a
// not-yet-used item_id; a valid speech_stopped requires the same item_id, a
// non-negative audio_end_ms and audio_end_ms >= audio_start_ms. Malformed,
// duplicate, overlapping, reused and foreign VAD events are FULLY INERT.
import 'package:chat_ai/chat_ai.dart' show BotProfile;
import 'package:chat_ai_openai_realtime_voice/chat_ai_openai_realtime_voice.dart';
import 'package:chat_ai_openai_realtime_voice/src/voice_recorder.dart';
import 'package:chat_ai_openai_realtime_voice/src/voice_session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

final RegExp _uuidV4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

Map<String, Object?> _created = <String, Object?>{'type': 'session.created'};
Map<String, Object?> _updated = <String, Object?>{'type': 'session.updated'};

Map<String, Object?> _start(String? itemId, {Object? startMs = 0}) =>
    <String, Object?>{
      'type': 'input_audio_buffer.speech_started',
      'item_id': ?itemId,
      'audio_start_ms': ?startMs,
    };
Map<String, Object?> _stop(String? itemId, {Object? endMs = 100}) =>
    <String, Object?>{
      'type': 'input_audio_buffer.speech_stopped',
      'item_id': ?itemId,
      'audio_end_ms': ?endMs,
    };
Map<String, Object?> _responseCreated(String id) => <String, Object?>{
  'type': 'response.created',
  'response': <String, Object?>{'id': id},
};
Map<String, Object?> _outputStarted(String id) => <String, Object?>{
  'type': 'output_audio_buffer.started',
  'response_id': id,
};
Map<String, Object?> _delta(String id, String d) => <String, Object?>{
  'type': 'response.output_audio_transcript.delta',
  'response_id': id,
  'item_id': 'i',
  'output_index': 0,
  'content_index': 0,
  'delta': d,
};
Map<String, Object?> _assistantDone(String id, String t) => <String, Object?>{
  'type': 'response.output_audio_transcript.done',
  'response_id': id,
  'item_id': 'i',
  'output_index': 0,
  'content_index': 0,
  'transcript': t,
};
Map<String, Object?> _userCompleted(String itemId, String t) =>
    <String, Object?>{
      'type': 'conversation.item.input_audio_transcription.completed',
      'item_id': itemId,
      'content_index': 0,
      'transcript': t,
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
    bool recordingEnabled = false,
    bool transcriptsEnabled = false,
    FakeRecorderFactory? recorders,
  }) => voiceSessionForTesting(
    clientSecretProvider: provider,
    botProfile: botProfile(),
    transportFactory: () => transport,
    mode: mode,
    transcriptsEnabled: transcriptsEnabled,
    recordingEnabled: recordingEnabled,
    recordingDirectoryPath: recordingEnabled ? '/rec' : null,
    recorderFactory: recordingEnabled ? recorders?.call : null,
  );

  Future<void> reachListening(
    OpenAIRealtimeVoiceSession s, {
    bool remote = false,
  }) async {
    await s.start();
    if (remote) {
      transport.completeRemoteTrack();
    }
    transport.emit(_created);
    await pumpEventLoop();
    transport.emit(_updated);
    await pumpEventLoop();
  }

  // ---- Inertness of malformed / foreign events (recording OFF) -----------
  test('a malformed speech_started is fully inert (recording OFF)', () async {
    final s = build();
    addTearDown(s.dispose);
    await reachListening(s);
    for (final bad in <Map<String, Object?>>[
      _start(''), // empty item_id
      _start(null), // missing item_id
      _start('u1', startMs: null), // missing audio_start_ms
      _start('u1', startMs: -1), // negative audio_start_ms
      _start('u1', startMs: 'x'), // non-int
    ]) {
      transport.emit(bad);
      await pumpEventLoop();
      // No user turn began: phase never moved off listening.
      expect(s.state.phase, OpenAIRealtimeVoicePhase.listening, reason: '$bad');
    }
    // A subsequent well-formed pair still works.
    transport.emit(_start('u1'));
    await pumpEventLoop();
    expect(s.state.phase, OpenAIRealtimeVoicePhase.userSpeaking);
  });

  test('a speech_stopped with no open start is fully inert', () async {
    final s = build();
    addTearDown(s.dispose);
    await reachListening(s);
    transport.emit(_stop('u1'));
    await pumpEventLoop();
    expect(s.state.phase, OpenAIRealtimeVoicePhase.listening);
  });

  test(
    'duplicate / overlapping speech_started open only one turn (recording ON)',
    () async {
      final recorders = FakeRecorderFactory();
      final s = build(recordingEnabled: true, recorders: recorders);
      addTearDown(s.dispose);
      await reachListening(s, remote: true);
      transport.emit(_start('u1'));
      await pumpEventLoop();
      expect(s.state.phase, OpenAIRealtimeVoicePhase.userSpeaking);
      // A duplicate and an overlapping start are inert.
      transport.emit(_start('u1'));
      transport.emit(_start('u2'));
      await pumpEventLoop();
      expect(recorders.user!.begun.length, 1);
      transport.emit(_stop('u1'));
      await pumpEventLoop();
      expect(recorders.user!.ended.length, 1);
      // The overlapping u2 never opened, so a late stop for it is inert.
      transport.emit(_stop('u2'));
      await pumpEventLoop();
      expect(recorders.user!.ended.length, 1);
    },
  );

  test('a reused item_id after a completed pair is inert', () async {
    final recorders = FakeRecorderFactory();
    final s = build(recordingEnabled: true, recorders: recorders);
    addTearDown(s.dispose);
    await reachListening(s, remote: true);
    transport.emit(_start('u1'));
    await pumpEventLoop();
    transport.emit(_stop('u1'));
    await pumpEventLoop();
    expect(recorders.user!.begun.length, 1);
    expect(s.state.phase, OpenAIRealtimeVoicePhase.assistantSpeaking);
    // Reusing u1 must NOT open a second turn.
    transport.emit(_start('u1'));
    await pumpEventLoop();
    expect(recorders.user!.begun.length, 1);
    expect(s.state.phase, OpenAIRealtimeVoicePhase.assistantSpeaking);
  });

  test('a foreign / malformed stop never cuts the open segment', () async {
    final recorders = FakeRecorderFactory();
    final s = build(recordingEnabled: true, recorders: recorders);
    addTearDown(s.dispose);
    await reachListening(s, remote: true);
    transport.emit(_start('u1', startMs: 100));
    await pumpEventLoop();
    // Foreign item id, missing/negative end, end < start — all inert.
    transport.emit(_stop('other', endMs: 200));
    transport.emit(_stop('u1', endMs: null));
    transport.emit(_stop('u1', endMs: -1));
    transport.emit(_stop('u1', endMs: 50));
    await pumpEventLoop();
    expect(s.state.phase, OpenAIRealtimeVoicePhase.userSpeaking);
    expect(recorders.user!.ended, isEmpty);
    // A well-formed stop finally closes it.
    transport.emit(_stop('u1', endMs: 300));
    await pumpEventLoop();
    expect(s.state.phase, OpenAIRealtimeVoicePhase.assistantSpeaking);
    expect(recorders.user!.ended.length, 1);
  });

  test(
    'a well-formed pair mints exactly one turnId shared by transcript & recording & failure',
    () async {
      // The user recorder finalize fails → a coarse per-side failure carrying the
      // SAME reply turnId as the transcript.
      final recorders = FakeRecorderFactory(
        configure: (r) {
          if (!r.isRemote) {
            r.resultFor = (_) => const VoiceRecordingSegmentResult.failed();
          }
        },
      );
      final transcripts = <OpenAIRealtimeVoiceTranscript>[];
      final failures = <OpenAIRealtimeVoiceRecordingFailure>[];
      final s = build(
        recordingEnabled: true,
        transcriptsEnabled: true,
        recorders: recorders,
      );
      addTearDown(s.dispose);
      s.transcripts.listen(transcripts.add);
      s.recordingFailures.listen(failures.add);
      await reachListening(s, remote: true);

      transport.emit(_start('u1'));
      await pumpEventLoop();
      transport.emit(_stop('u1'));
      await pumpEventLoop();
      transport.emit(_userCompleted('u1', 'hi'));
      await pumpEventLoop();

      final userTranscript = transcripts.firstWhere(
        (t) => t.role == OpenAIRealtimeVoiceTranscriptRole.user,
      );
      final userFailure = failures.firstWhere(
        (f) => f.role == OpenAIRealtimeVoiceRecordingRole.user,
      );
      expect(_uuidV4.hasMatch(userTranscript.turnId), isTrue);
      expect(userFailure.turnId, userTranscript.turnId);
    },
  );

  test(
    'an invalid stop in singleTurn does not close the turn or disable the mic',
    () async {
      final s = build(mode: OpenAIRealtimeVoiceMode.singleTurn);
      addTearDown(s.dispose);
      await reachListening(s);
      transport.emit(_start('u1'));
      await pumpEventLoop();
      expect(s.state.phase, OpenAIRealtimeVoicePhase.userSpeaking);
      // A foreign / malformed stop must not close singleTurn or disable the mic.
      transport.emit(_stop('other'));
      transport.emit(_stop('u1', endMs: -1));
      await pumpEventLoop();
      expect(s.state.phase, OpenAIRealtimeVoicePhase.userSpeaking);
      expect(transport.enabledCalls, <bool>[true]); // never disabled
      // A valid stop closes it and disables the mic.
      transport.emit(_stop('u1'));
      await pumpEventLoop();
      expect(s.state.phase, OpenAIRealtimeVoicePhase.assistantSpeaking);
      expect(transport.enabledCalls, <bool>[true, false]);
    },
  );

  test(
    'a malformed speech_started during a guardrail replacement does not barge in or reset the budget',
    () async {
      // Block whenever the checked text contains BLOCK; allow otherwise.
      final s = voiceSessionForTesting(
        clientSecretProvider: provider,
        botProfile: const BotProfile(
          id: 'bot',
          systemPrompt: 'x',
          tools: <Never>[],
        ),
        transportFactory: () => transport,
        mode: OpenAIRealtimeVoiceMode.conversation,
        transcriptsEnabled: true,
        outputGuardrail: ({required turnId, required accumulatedText}) async =>
            accumulatedText.contains('BLOCK')
            ? OpenAIRealtimeVoiceGuardrailDecision.block
            : OpenAIRealtimeVoiceGuardrailDecision.allow,
        safeReplacementInstructions: 'safe',
      );
      addTearDown(s.dispose);
      await reachListening(s);

      // Original r1 blocks → the one replacement r2 is created.
      transport.emit(_responseCreated('r1'));
      transport.emit(_outputStarted('r1'));
      await pumpEventLoop();
      transport.emit(_delta('r1', 'BLOCK'));
      await pumpEventLoop();
      expect(_countSent(transport, 'response.create'), 1);

      transport.emit(_responseCreated('r2'));
      transport.emit(_outputStarted('r2'));
      await pumpEventLoop();

      // A malformed speech_started during the replacement must be inert: no
      // barge-in and no replacement-budget reset.
      transport.emit(_start('')); // malformed
      transport.emit(_start(null));
      await pumpEventLoop();
      expect(s.state.phase, OpenAIRealtimeVoicePhase.assistantSpeaking);

      // r2's exact-final blocks. Because the budget was NOT reset, this is terminal
      // (no second replacement is created).
      transport.emit(_assistantDone('r2', 'BLOCK final'));
      await pumpEventLoop();
      expect(s.state.phase, OpenAIRealtimeVoicePhase.failed);
      expect(s.state.failure, OpenAIRealtimeVoiceFailure.guardrail);
      expect(_countSent(transport, 'response.create'), 1);
    },
  );
}
