// The unified local turnId contract: UUID v4 + per-reply uniqueness, the SAME
// turnId across a reply's delta / final transcript / recording / recording
// failure, distinct user vs assistant ids, an interrupted late final transcript,
// the typed delta stream, and privacy-safe toString().
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
Map<String, Object?> _speechStarted(String itemId) => <String, Object?>{
  'type': 'input_audio_buffer.speech_started',
  'item_id': itemId,
  'audio_start_ms': 0,
};
Map<String, Object?> _speechStopped(String itemId) => <String, Object?>{
  'type': 'input_audio_buffer.speech_stopped',
  'item_id': itemId,
  'audio_end_ms': 100,
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
Map<String, Object?> _delta(String id, String delta) => <String, Object?>{
  'type': 'response.output_audio_transcript.delta',
  'response_id': id,
  'item_id': 'i',
  'output_index': 0,
  'content_index': 0,
  'delta': delta,
};
Map<String, Object?> _assistantDone(String id, String text) =>
    <String, Object?>{
      'type': 'response.output_audio_transcript.done',
      'response_id': id,
      'item_id': 'i',
      'output_index': 0,
      'content_index': 0,
      'transcript': text,
    };
Map<String, Object?> _userDone(String itemId, String text) => <String, Object?>{
  'type': 'conversation.item.input_audio_transcription.completed',
  'item_id': itemId,
  'content_index': 0,
  'transcript': text,
};

void main() {
  late FakeClientSecretProvider provider;
  late FakeRealtimeVoiceTransport transport;

  setUp(() {
    provider = FakeClientSecretProvider();
    transport = FakeRealtimeVoiceTransport();
  });

  OpenAIRealtimeVoiceSession build({
    FakeRecorderFactory? recorders,
    bool recordingEnabled = true,
  }) => voiceSessionForTesting(
    clientSecretProvider: provider,
    botProfile: botProfile(),
    transportFactory: () => transport,
    mode: OpenAIRealtimeVoiceMode.conversation,
    transcriptsEnabled: true,
    recordingEnabled: recordingEnabled,
    recordingDirectoryPath: recordingEnabled ? '/rec' : null,
    recorderFactory: recordingEnabled ? recorders?.call : null,
  );

  Future<void> reachListening(OpenAIRealtimeVoiceSession s) async {
    await s.start();
    transport.completeRemoteTrack();
    transport.emit(_created);
    await pumpEventLoop();
    transport.emit(_updated);
    await pumpEventLoop();
  }

  test(
    'one turnId links a reply\'s delta, transcript, recording; UUID v4',
    () async {
      final recorders = FakeRecorderFactory();
      final s = build(recorders: recorders);
      addTearDown(s.dispose);
      final deltas = <OpenAIRealtimeVoiceTranscriptDelta>[];
      final transcripts = <OpenAIRealtimeVoiceTranscript>[];
      final recordings = <OpenAIRealtimeVoiceRecording>[];
      s.assistantTranscriptDeltas.listen(deltas.add);
      s.transcripts.listen(transcripts.add);
      s.recordings.listen(recordings.add);
      await reachListening(s);

      // User reply u1.
      transport.emit(_speechStarted('u1'));
      await pumpEventLoop();
      transport.emit(_speechStopped('u1'));
      await pumpEventLoop();
      transport.emit(_userDone('u1', 'hello'));
      await pumpEventLoop();

      // Assistant reply r1.
      transport.emit(_responseCreated('r1'));
      transport.emit(_outputStarted('r1'));
      await pumpEventLoop();
      transport.emit(_delta('r1', 'A'));
      await pumpEventLoop();
      transport.emit(_outputStopped('r1'));
      transport.emit(_assistantDone('r1', 'answer'));
      transport.emit(_responseDone('r1'));
      await pumpEventLoop();

      // User side: final transcript + recording share ONE turnId.
      final userTranscript = transcripts.firstWhere(
        (t) => t.role == OpenAIRealtimeVoiceTranscriptRole.user,
      );
      final userRec = recordings.firstWhere(
        (r) => r.role == OpenAIRealtimeVoiceRecordingRole.user,
      );
      expect(userTranscript.turnId, userRec.turnId);
      expect(_uuidV4.hasMatch(userTranscript.turnId), isTrue);

      // Assistant side: delta + final transcript + recording share ONE turnId.
      final assistantDelta = deltas.single;
      final assistantTranscript = transcripts.firstWhere(
        (t) => t.role == OpenAIRealtimeVoiceTranscriptRole.assistant,
      );
      final assistantRec = recordings.firstWhere(
        (r) => r.role == OpenAIRealtimeVoiceRecordingRole.assistant,
      );
      expect(assistantDelta.turnId, assistantTranscript.turnId);
      expect(assistantTranscript.turnId, assistantRec.turnId);
      expect(_uuidV4.hasMatch(assistantDelta.turnId), isTrue);

      // User and assistant ids are distinct.
      expect(userTranscript.turnId, isNot(assistantTranscript.turnId));

      // A clean reply's transcript is not interrupted.
      expect(assistantTranscript.interrupted, isFalse);
      expect(userTranscript.interrupted, isFalse);
    },
  );

  test('each new reply gets a fresh, unique turnId', () async {
    final s = build(recordingEnabled: false);
    addTearDown(s.dispose);
    final deltas = <OpenAIRealtimeVoiceTranscriptDelta>[];
    s.assistantTranscriptDeltas.listen(deltas.add);
    await reachListening(s);

    transport.emit(_responseCreated('r1'));
    await pumpEventLoop();
    transport.emit(_delta('r1', 'A'));
    await pumpEventLoop();
    transport.emit(_responseDone('r1'));
    transport.emit(_outputStopped('r1'));
    await pumpEventLoop();

    transport.emit(_speechStarted('u2'));
    await pumpEventLoop();
    transport.emit(_speechStopped('u2'));
    await pumpEventLoop();
    transport.emit(_responseCreated('r2'));
    await pumpEventLoop();
    transport.emit(_delta('r2', 'B'));
    await pumpEventLoop();

    final ids = deltas.map((d) => d.turnId).toSet();
    expect(ids.length, 2, reason: 'two replies → two distinct turnIds');
    expect(deltas.every((d) => _uuidV4.hasMatch(d.turnId)), isTrue);
  });

  test(
    'a late final transcript of an interrupted assistant turn is interrupted:true',
    () async {
      final s = build(recordingEnabled: false);
      addTearDown(s.dispose);
      final deltas = <OpenAIRealtimeVoiceTranscriptDelta>[];
      final transcripts = <OpenAIRealtimeVoiceTranscript>[];
      s.assistantTranscriptDeltas.listen(deltas.add);
      s.transcripts.listen(transcripts.add);
      await reachListening(s);

      transport.emit(_responseCreated('r1'));
      transport.emit(_outputStarted('r1'));
      await pumpEventLoop();
      transport.emit(_delta('r1', 'A'));
      await pumpEventLoop();
      // Barge-in abandons r1.
      transport.emit(_speechStarted('u2'));
      await pumpEventLoop();
      // A late final transcript for the interrupted r1.
      transport.emit(_assistantDone('r1', 'partial answer'));
      await pumpEventLoop();

      final assistantFinal = transcripts.firstWhere(
        (t) => t.role == OpenAIRealtimeVoiceTranscriptRole.assistant,
      );
      expect(assistantFinal.interrupted, isTrue);
      // The late final still carries the SAME turnId as its delta.
      expect(assistantFinal.turnId, deltas.single.turnId);
    },
  );

  test(
    'a recording failure carries the reply turnId (never anonymous)',
    () async {
      final recorders = FakeRecorderFactory(
        configure: (r) {
          if (!r.isRemote) {
            r.resultFor = (_) => const VoiceRecordingSegmentResult.failed();
          }
        },
      );
      final s = build(recorders: recorders);
      addTearDown(s.dispose);
      final transcripts = <OpenAIRealtimeVoiceTranscript>[];
      final failures = <OpenAIRealtimeVoiceRecordingFailure>[];
      s.transcripts.listen(transcripts.add);
      s.recordingFailures.listen(failures.add);
      await reachListening(s);

      transport.emit(_speechStarted('u1'));
      await pumpEventLoop();
      transport.emit(_speechStopped('u1'));
      await pumpEventLoop();
      transport.emit(_userDone('u1', 'hi'));
      await pumpEventLoop();

      final userFailure = failures.firstWhere(
        (f) => f.role == OpenAIRealtimeVoiceRecordingRole.user,
      );
      final userTranscript = transcripts.firstWhere(
        (t) => t.role == OpenAIRealtimeVoiceTranscriptRole.user,
      );
      // The failure's turnId matches the same reply's transcript turnId, and is a
      // valid UUID v4 (never empty / anonymous).
      expect(userFailure.turnId, isNotEmpty);
      expect(userFailure.turnId, userTranscript.turnId);
      expect(_uuidV4.hasMatch(userFailure.turnId), isTrue);
    },
  );

  test(
    'the delta stream is typed (OpenAIRealtimeVoiceTranscriptDelta)',
    () async {
      final s = build(recordingEnabled: false);
      addTearDown(s.dispose);
      expect(
        s.assistantTranscriptDeltas,
        isA<Stream<OpenAIRealtimeVoiceTranscriptDelta>>(),
      );
      OpenAIRealtimeVoiceTranscriptDelta? got;
      s.assistantTranscriptDeltas.listen((d) => got = d);
      await reachListening(s);
      transport.emit(_responseCreated('r1'));
      await pumpEventLoop();
      transport.emit(_delta('r1', 'frag'));
      await pumpEventLoop();
      expect(got, isNotNull);
      expect(got!.delta, 'frag');
      expect(_uuidV4.hasMatch(got!.turnId), isTrue);
    },
  );

  test('the new models\' toString stays privacy-safe', () {
    const transcript = OpenAIRealtimeVoiceTranscript(
      role: OpenAIRealtimeVoiceTranscriptRole.assistant,
      turnId: 'turn-x',
      text: 'SENSITIVE SPOKEN TEXT',
      interrupted: true,
    );
    expect(transcript.toString().contains('SENSITIVE'), isFalse);
    expect(transcript.toString().contains('turn-x'), isTrue);

    const delta = OpenAIRealtimeVoiceTranscriptDelta(
      turnId: 'turn-y',
      delta: 'SECRET FRAGMENT',
    );
    expect(delta.toString().contains('SECRET'), isFalse);
    expect(delta.toString().contains('turn-y'), isTrue);

    const event = OpenAIRealtimeVoiceGuardrailEvent(turnId: 'turn-z');
    expect(event.toString(), contains('turn-z'));
  });
}
