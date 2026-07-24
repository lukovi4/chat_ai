// The OPTIONAL final-transcript side channel (required tests 1 session-half,
// 3–11) driven by the private fake transport and a deterministic fake watchdog
// timer — no native WebRTC, no real clock. Verifies emission, strict
// attribution, dedup, the failure side channel, the singleTurn transcript wait,
// conversation non-blocking and dispose lifecycle.
import 'dart:async';

import 'package:chat_ai_openai_realtime_voice/chat_ai_openai_realtime_voice.dart';
import 'package:chat_ai_openai_realtime_voice/src/voice_session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

// ---- Event literals -------------------------------------------------------
Map<String, Object?> _created = <String, Object?>{'type': 'session.created'};
Map<String, Object?> _updated = <String, Object?>{'type': 'session.updated'};
// Full, well-formed VAD pair (the strict VAD-pair contract requires item_id +
// the ms boundary, so transcript attribution needs a real start→stop pair).
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
Map<String, Object?> _responseDone(String id) => <String, Object?>{
  'type': 'response.done',
  'response': <String, Object?>{'id': id, 'status': 'completed'},
};
Map<String, Object?> _outputStopped(String id) => <String, Object?>{
  'type': 'output_audio_buffer.stopped',
  'response_id': id,
};

// A valid final USER transcript for [itemId].
Map<String, Object?> _userCompleted(
  String itemId,
  String transcript, {
  int contentIndex = 0,
}) => <String, Object?>{
  'type': 'conversation.item.input_audio_transcription.completed',
  'item_id': itemId,
  'content_index': contentIndex,
  'transcript': transcript,
};

// A USER transcription failure for [itemId] — carries a raw error that must
// never leak or fail the voice session.
Map<String, Object?> _userFailed(String itemId) => <String, Object?>{
  'type': 'conversation.item.input_audio_transcription.failed',
  'item_id': itemId,
  'content_index': 0,
  'error': <String, Object?>{'message': 'super-secret-asr-detail', 'code': 'x'},
};

// A user transcript DELTA (never emitted on the stream).
Map<String, Object?> _userDelta(String itemId) => <String, Object?>{
  'type': 'conversation.item.input_audio_transcription.delta',
  'item_id': itemId,
  'content_index': 0,
  'delta': 'he',
};

// A valid final ASSISTANT transcript for [responseId].
Map<String, Object?> _assistantDone(
  String responseId,
  String transcript, {
  String itemId = 'it',
  int outputIndex = 0,
  int contentIndex = 0,
}) => <String, Object?>{
  'type': 'response.output_audio_transcript.done',
  'response_id': responseId,
  'item_id': itemId,
  'output_index': outputIndex,
  'content_index': contentIndex,
  'transcript': transcript,
};

// An assistant transcript DELTA (never emitted on the stream).
Map<String, Object?> _assistantDelta(String responseId) => <String, Object?>{
  'type': 'response.output_audio_transcript.delta',
  'response_id': responseId,
  'item_id': 'it',
  'output_index': 0,
  'content_index': 0,
  'delta': 'sp',
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
    OpenAIRealtimeVoiceMode mode = OpenAIRealtimeVoiceMode.singleTurn,
    bool transcriptsEnabled = true,
    FakeRealtimeVoiceTransport? t,
    Timer Function(Duration, void Function())? timerFactory,
  }) {
    final transport0 = t ?? transport;
    return voiceSessionForTesting(
      clientSecretProvider: provider,
      botProfile: botProfile(),
      transportFactory: () => transport0,
      mode: mode,
      transcriptsEnabled: transcriptsEnabled,
      timerFactory: timerFactory ?? FakeWatchdogTimerFactory().call,
    );
  }

  Future<void> reachListening(
    OpenAIRealtimeVoiceSession s,
    FakeRealtimeVoiceTransport t,
  ) async {
    await s.start();
    t.emit(_created);
    await pumpEventLoop();
    t.emit(_updated);
    await pumpEventLoop();
  }

  List<OpenAIRealtimeVoiceTranscript> collect(OpenAIRealtimeVoiceSession s) {
    final out = <OpenAIRealtimeVoiceTranscript>[];
    final sub = s.transcripts.listen(out.add);
    addTearDown(sub.cancel);
    return out;
  }

  // Emits one valid VAD pair (start→stop) so [itemId] becomes a known user reply.
  Future<void> userTurn(String itemId) async {
    transport.emit(_speechStarted(itemId));
    await pumpEventLoop();
    transport.emit(_speechStopped(itemId));
    await pumpEventLoop();
  }

  // ---- Required test 1 (session half) ------------------------------------
  test(
    'transcriptsEnabled false: no transcription key and events ignored',
    () async {
      final s = build(transcriptsEnabled: false);
      addTearDown(s.dispose);
      final out = collect(s);

      await reachListening(s, transport);
      // The one session.update carries no transcription block.
      final update = transport.sent.firstWhere(
        (e) => e['type'] == 'session.update',
      );
      final input =
          ((update['session']! as Map<String, Object?>)['audio']!
                  as Map<String, Object?>)['input']!
              as Map<String, Object?>;
      expect(input.containsKey('transcription'), isFalse);

      // Transcript events are ignored entirely.
      await userTurn('u1');
      transport.emit(_userCompleted('u1', 'hi'));
      transport.emit(_responseCreated('r1'));
      transport.emit(_assistantDone('r1', 'yo'));
      await pumpEventLoop();
      expect(out, isEmpty);
    },
  );

  // ---- Required test 3 -----------------------------------------------------
  test(
    'a valid final user transcript is emitted untrimmed; delta is not',
    () async {
      final s = build();
      addTearDown(s.dispose);
      final out = collect(s);

      await reachListening(s, transport);
      await userTurn('u1');
      // A delta must never surface.
      transport.emit(_userDelta('u1'));
      await pumpEventLoop();
      expect(out, isEmpty);

      transport.emit(_userCompleted('u1', '  hello world  '));
      await pumpEventLoop();
      expect(out.length, 1);
      expect(out.single.role, OpenAIRealtimeVoiceTranscriptRole.user);
      // Passed through EXACTLY — no trim/normalize.
      expect(out.single.text, '  hello world  ');
    },
  );

  test('a user transcript for an unknown item id is ignored', () async {
    final s = build();
    addTearDown(s.dispose);
    final out = collect(s);

    await reachListening(s, transport);
    await userTurn('u1');
    // Never announced via speech_stopped.
    transport.emit(_userCompleted('u-foreign', 'nope'));
    await pumpEventLoop();
    expect(out, isEmpty);
  });

  test('an empty-string final user transcript is still emitted', () async {
    final s = build();
    addTearDown(s.dispose);
    final out = collect(s);

    await reachListening(s, transport);
    await userTurn('u1');
    transport.emit(_userCompleted('u1', ''));
    await pumpEventLoop();
    expect(out.length, 1);
    expect(out.single.role, OpenAIRealtimeVoiceTranscriptRole.user);
    expect(out.single.text, '');
  });

  // ---- Required test 4 -----------------------------------------------------
  test(
    'a valid final assistant transcript is emitted untrimmed; delta is not',
    () async {
      final s = build(mode: OpenAIRealtimeVoiceMode.conversation);
      addTearDown(s.dispose);
      final out = collect(s);

      await reachListening(s, transport);
      transport.emit(_responseCreated('r1'));
      await pumpEventLoop();
      // A delta must never surface.
      transport.emit(_assistantDelta('r1'));
      await pumpEventLoop();
      expect(out, isEmpty);

      // The authoritative final transcript is HELD until the reply completes
      // cleanly (done + stopped); only then is it published interrupted:false.
      transport.emit(_assistantDone('r1', '  spoken words  '));
      await pumpEventLoop();
      expect(out, isEmpty);
      transport.emit(_responseDone('r1'));
      transport.emit(_outputStopped('r1'));
      await pumpEventLoop();
      expect(out.length, 1);
      expect(out.single.role, OpenAIRealtimeVoiceTranscriptRole.assistant);
      expect(out.single.text, '  spoken words  ');
      expect(out.single.interrupted, isFalse);
    },
  );

  test(
    'an assistant transcript for an unknown response id is ignored',
    () async {
      final s = build(mode: OpenAIRealtimeVoiceMode.conversation);
      addTearDown(s.dispose);
      final out = collect(s);

      await reachListening(s, transport);
      transport.emit(_responseCreated('r1'));
      await pumpEventLoop();
      // r99 was never created in this session.
      transport.emit(_assistantDone('r99', 'foreign'));
      await pumpEventLoop();
      expect(out, isEmpty);
    },
  );

  // ---- Required test 5 -----------------------------------------------------
  test(
    'foreign/malformed transcript events do not emit, change state or reset the watchdog',
    () async {
      final factory = FakeWatchdogTimerFactory();
      final s = build(
        mode: OpenAIRealtimeVoiceMode.conversation,
        timerFactory: factory.call,
      );
      addTearDown(s.dispose);
      final out = collect(s);

      await reachListening(s, transport);
      await userTurn('u1');
      transport.emit(_responseCreated('r1'));
      await pumpEventLoop();
      expect(factory.created.length, 1);
      final phaseBefore = s.state.phase;

      // Malformed user completed: content_index missing.
      transport.emit(<String, Object?>{
        'type': 'conversation.item.input_audio_transcription.completed',
        'item_id': 'u1',
        'transcript': 'x',
      });
      // Malformed user completed: transcript is not a String.
      transport.emit(<String, Object?>{
        'type': 'conversation.item.input_audio_transcription.completed',
        'item_id': 'u1',
        'content_index': 0,
        'transcript': 123,
      });
      // Foreign user completed: unknown item.
      transport.emit(_userCompleted('u-foreign', 'x'));
      // Foreign assistant done: unknown response id.
      transport.emit(_assistantDone('r99', 'x'));
      // Malformed assistant done for the active response: transcript missing.
      transport.emit(<String, Object?>{
        'type': 'response.output_audio_transcript.done',
        'response_id': 'r1',
        'item_id': 'it',
        'output_index': 0,
        'content_index': 0,
      });
      await pumpEventLoop();

      expect(out, isEmpty);
      expect(s.state.phase, phaseBefore);
      expect(s.state.failure, isNull);
      // None of these are valid current-response progress → no watchdog kick.
      expect(factory.created.length, 1);
    },
  );

  // ---- Required test 6 -----------------------------------------------------
  test('a duplicate terminal transcript event emits exactly once', () async {
    final s = build(mode: OpenAIRealtimeVoiceMode.conversation);
    addTearDown(s.dispose);
    final out = collect(s);

    await reachListening(s, transport);
    await userTurn('u1');
    transport.emit(_responseCreated('r1'));
    await pumpEventLoop();

    transport.emit(_userCompleted('u1', 'hi'));
    // A duplicate completed for the same item must not emit again.
    transport.emit(_userCompleted('u1', 'hi-again'));
    transport.emit(_assistantDone('r1', 'A'));
    // A duplicate done for the same response/item/indices must not emit again.
    transport.emit(_assistantDone('r1', 'A-again'));
    // The held assistant final publishes once on the clean completion.
    transport.emit(_responseDone('r1'));
    transport.emit(_outputStopped('r1'));
    await pumpEventLoop();

    expect(out.length, 2);
    expect(out[0].role, OpenAIRealtimeVoiceTranscriptRole.user);
    expect(out[0].text, 'hi');
    expect(out[1].role, OpenAIRealtimeVoiceTranscriptRole.assistant);
    expect(out[1].text, 'A');
  });

  // ---- Required test 7 -----------------------------------------------------
  test(
    'barge-in: an abandoned-but-known assistant transcript emits; foreign is ignored; no cancel',
    () async {
      final s = build(mode: OpenAIRealtimeVoiceMode.conversation);
      addTearDown(s.dispose);
      final out = collect(s);

      await reachListening(s, transport);
      transport.emit(_responseCreated('r1'));
      await pumpEventLoop();
      // The user barges in — the server abandons r1; we send nothing.
      transport.emit(_speechStarted('u2'));
      await pumpEventLoop();
      expect(s.state.phase, OpenAIRealtimeVoicePhase.userSpeaking);

      // A late .done for the abandoned but previously-known r1 is still emitted
      // (interrupted:true — the response was barged in).
      transport.emit(_assistantDone('r1', 'spoken so far'));
      // A .done for a Response never created in this session is ignored.
      transport.emit(_assistantDone('r2', 'foreign'));
      await pumpEventLoop();

      expect(out.length, 1);
      expect(out.single.role, OpenAIRealtimeVoiceTranscriptRole.assistant);
      expect(out.single.text, 'spoken so far');
      // Existing barge-in semantics unchanged: no redundant client cancels.
      expect(_countSent(transport, 'response.cancel'), 0);
      expect(_countSent(transport, 'response.truncate'), 0);
      expect(_countSent(transport, 'output_audio_buffer.clear'), 0);
      expect(s.state.phase, OpenAIRealtimeVoicePhase.userSpeaking);
    },
  );

  // ---- Required test 8 -----------------------------------------------------
  test(
    'a user transcription failure emits nothing, keeps the conversation alive, no retry',
    () async {
      final s = build(mode: OpenAIRealtimeVoiceMode.conversation);
      addTearDown(s.dispose);
      final out = collect(s);

      await reachListening(s, transport);
      await userTurn('u1');
      transport.emit(_responseCreated('r1'));
      transport.emit(_assistantDone('r1', 'A'));
      transport.emit(_responseDone('r1'));
      transport.emit(_outputStopped('r1'));
      await pumpEventLoop();
      expect(s.state.phase, OpenAIRealtimeVoicePhase.listening);

      // The user transcription fails: no transcript, no failure, no cancel.
      transport.emit(_userFailed('u1'));
      await pumpEventLoop();
      expect(out.map((e) => e.role), <OpenAIRealtimeVoiceTranscriptRole>[
        OpenAIRealtimeVoiceTranscriptRole.assistant,
      ]);
      expect(s.state.phase, OpenAIRealtimeVoicePhase.listening);
      expect(s.state.failure, isNull);
      // Raw error never leaks into state.
      expect(s.state.toString().contains('super-secret-asr-detail'), isFalse);

      // The conversation still serves another turn.
      await userTurn('u2');
      transport.emit(_responseCreated('r2'));
      transport.emit(_responseDone('r2'));
      transport.emit(_outputStopped('r2'));
      await pumpEventLoop();
      expect(s.state.phase, OpenAIRealtimeVoicePhase.listening);
      // No retry / new mint / client-side response.create ever appeared.
      expect(provider.calls, 1);
      expect(_countSent(transport, 'response.create'), 0);
      expect(_countSent(transport, 'response.cancel'), 0);
      expect(transport.closeCalls, 0);
    },
  );

  // ---- Required test 9 -----------------------------------------------------
  test(
    'singleTurn keeps the transport open until the pending user transcript arrives',
    () async {
      final factory = FakeWatchdogTimerFactory();
      final s = build(timerFactory: factory.call);
      addTearDown(s.dispose);
      final out = collect(s);

      await reachListening(s, transport);
      await userTurn('u1');
      transport.emit(_responseCreated('r1'));
      transport.emit(_assistantDone('r1', 'A'));
      transport.emit(_responseDone('r1'));
      transport.emit(_outputStopped('r1'));
      await pumpEventLoop();

      // Audio finished, but the async user transcript is still pending — the
      // transport must NOT close yet.
      expect(s.state.phase, isNot(OpenAIRealtimeVoicePhase.ended));
      expect(transport.closeCalls, 0);
      // The idle-timeout seam bounds the wait (one live timer).
      expect(factory.active, isNotNull);

      // The user transcript arrives → it is emitted and the turn then ends.
      transport.emit(_userCompleted('u1', 'hi there'));
      await pumpEventLoop();
      expect(out.map((e) => e.text), <String>['A', 'hi there']);
      expect(s.state.phase, OpenAIRealtimeVoicePhase.ended);
      expect(s.state.failure, isNull);
      expect(transport.closeCalls, 1);
      expect(factory.active, isNull);
    },
  );

  test(
    'singleTurn: a user transcription failure allows the normal end without a transcript',
    () async {
      final s = build();
      addTearDown(s.dispose);
      final out = collect(s);

      await reachListening(s, transport);
      await userTurn('u1');
      transport.emit(_responseCreated('r1'));
      transport.emit(_responseDone('r1'));
      transport.emit(_outputStopped('r1'));
      await pumpEventLoop();
      expect(s.state.phase, isNot(OpenAIRealtimeVoicePhase.ended));
      expect(transport.closeCalls, 0);

      transport.emit(_userFailed('u1'));
      await pumpEventLoop();
      expect(out, isEmpty);
      expect(s.state.phase, OpenAIRealtimeVoicePhase.ended);
      expect(s.state.failure, isNull);
      expect(transport.closeCalls, 1);
    },
  );

  // Audit P1: a malformed `.failed` (missing content_index, non-int/negative
  // content_index, missing error, or non-Map error) is NOT a terminal outcome —
  // it is ignored, so it neither closes singleTurn early nor suppresses a later
  // valid completed.
  test(
    'singleTurn: malformed failed events are ignored and never suppress a later completed',
    () async {
      final factory = FakeWatchdogTimerFactory();
      final s = build(timerFactory: factory.call);
      addTearDown(s.dispose);
      final out = collect(s);

      await reachListening(s, transport);
      await userTurn('u1');
      transport.emit(_responseCreated('r1'));
      transport.emit(_responseDone('r1'));
      transport.emit(_outputStopped('r1'));
      await pumpEventLoop();
      // Audio finished; the transport waits for the pending user transcript.
      expect(s.state.phase, isNot(OpenAIRealtimeVoicePhase.ended));
      expect(transport.closeCalls, 0);
      expect(factory.active, isNotNull);

      // Several malformed `.failed` variants for the known item u1.
      final malformed = <Map<String, Object?>>[
        // content_index missing.
        <String, Object?>{
          'type': 'conversation.item.input_audio_transcription.failed',
          'item_id': 'u1',
          'error': <String, Object?>{'message': 'x', 'code': 'y'},
        },
        // content_index negative.
        <String, Object?>{
          'type': 'conversation.item.input_audio_transcription.failed',
          'item_id': 'u1',
          'content_index': -1,
          'error': <String, Object?>{'message': 'x'},
        },
        // content_index not an int.
        <String, Object?>{
          'type': 'conversation.item.input_audio_transcription.failed',
          'item_id': 'u1',
          'content_index': 'nope',
          'error': <String, Object?>{'message': 'x'},
        },
        // error missing.
        <String, Object?>{
          'type': 'conversation.item.input_audio_transcription.failed',
          'item_id': 'u1',
          'content_index': 0,
        },
        // error not a Map.
        <String, Object?>{
          'type': 'conversation.item.input_audio_transcription.failed',
          'item_id': 'u1',
          'content_index': 0,
          'error': 'oops',
        },
      ];
      for (final event in malformed) {
        transport.emit(event);
      }
      await pumpEventLoop();

      // None of them ended the turn, closed the transport, emitted a transcript
      // or expired the pending wait; no retry/mint/response.create appeared.
      expect(s.state.phase, isNot(OpenAIRealtimeVoicePhase.ended));
      expect(transport.closeCalls, 0);
      expect(out, isEmpty);
      expect(factory.active, isNotNull);
      expect(provider.calls, 1);
      expect(_countSent(transport, 'response.create'), 0);
      expect(_countSent(transport, 'response.cancel'), 0);

      // A subsequent VALID completed is still honoured exactly once and ends the
      // turn normally.
      transport.emit(_userCompleted('u1', '  kept verbatim  '));
      await pumpEventLoop();
      expect(out.length, 1);
      expect(out.single.role, OpenAIRealtimeVoiceTranscriptRole.user);
      expect(out.single.text, '  kept verbatim  ');
      expect(s.state.phase, OpenAIRealtimeVoicePhase.ended);
      expect(s.state.failure, isNull);
      expect(transport.closeCalls, 1);
      expect(factory.active, isNull);
    },
  );

  test(
    'singleTurn: the idle timeout releases a pending transcript wait without retry or hang',
    () async {
      final factory = FakeWatchdogTimerFactory();
      final s = build(timerFactory: factory.call);
      addTearDown(s.dispose);
      final out = collect(s);

      await reachListening(s, transport);
      await userTurn('u1');
      transport.emit(_responseCreated('r1'));
      transport.emit(_assistantDone('r1', 'A'));
      transport.emit(_responseDone('r1'));
      transport.emit(_outputStopped('r1'));
      await pumpEventLoop();
      expect(s.state.phase, isNot(OpenAIRealtimeVoicePhase.ended));

      // The transcript never comes; the bound expires → normal end, no
      // transcript, and no retry/mint/response.create.
      factory.active!.fire();
      await pumpEventLoop();
      expect(out.map((e) => e.text), <String>['A']);
      expect(s.state.phase, OpenAIRealtimeVoicePhase.ended);
      expect(s.state.failure, isNull);
      expect(transport.closeCalls, 1);
      expect(provider.calls, 1);
      expect(_countSent(transport, 'response.create'), 0);
      expect(factory.active, isNull);
    },
  );

  // ---- Required test 10 ----------------------------------------------------
  test(
    'conversation: a late user transcript never blocks the next Response',
    () async {
      final s = build(mode: OpenAIRealtimeVoiceMode.conversation);
      addTearDown(s.dispose);
      final out = collect(s);

      await reachListening(s, transport);
      // First turn — no user transcript yet.
      await userTurn('u1');
      transport.emit(_responseCreated('r1'));
      transport.emit(_responseDone('r1'));
      transport.emit(_outputStopped('r1'));
      await pumpEventLoop();
      expect(s.state.phase, OpenAIRealtimeVoicePhase.listening);
      expect(transport.closeCalls, 0);

      // Second turn proceeds fully even though u1's transcript is still absent.
      await userTurn('u2');
      transport.emit(_responseCreated('r2'));
      transport.emit(_assistantDone('r2', 'second'));
      transport.emit(_responseDone('r2'));
      transport.emit(_outputStopped('r2'));
      await pumpEventLoop();
      expect(s.state.phase, OpenAIRealtimeVoicePhase.listening);

      // The late transcript for the first reply still emits while active.
      transport.emit(_userCompleted('u1', 'first reply'));
      await pumpEventLoop();
      expect(
        out.any(
          (e) =>
              e.role == OpenAIRealtimeVoiceTranscriptRole.user &&
              e.text == 'first reply',
        ),
        isTrue,
      );
    },
  );

  // ---- Required test 11 ----------------------------------------------------
  test(
    'dispose closes both streams and drops late transcript events',
    () async {
      final s = build(mode: OpenAIRealtimeVoiceMode.conversation);
      final out = <OpenAIRealtimeVoiceTranscript>[];
      var statesDone = false;
      var transcriptsDone = false;
      final statesSub = s.states.listen(
        (_) {},
        onDone: () => statesDone = true,
      );
      final tSub = s.transcripts.listen(
        out.add,
        onDone: () => transcriptsDone = true,
      );
      addTearDown(statesSub.cancel);
      addTearDown(tSub.cancel);

      await reachListening(s, transport);
      await userTurn('u1');
      transport.emit(_responseCreated('r1'));
      transport.emit(_assistantDone('r1', 'A'));
      transport.emit(_responseDone('r1'));
      transport.emit(_outputStopped('r1'));
      await pumpEventLoop();
      expect(out.length, 1);

      await s.dispose();
      await pumpEventLoop();
      // Both controllers are closed.
      expect(statesDone, isTrue);
      expect(transcriptsDone, isTrue);
      // Exactly-once cleanup.
      expect(transport.closeCalls, 1);

      // A late event after teardown emits nothing.
      transport.emit(_userCompleted('u1', 'too late'));
      await pumpEventLoop();
      expect(out.length, 1);

      // Repeat dispose stays safe.
      await s.dispose();
      expect(transport.closeCalls, 1);
    },
  );

  // ---- Defect 3 (guardrail OFF): no premature interrupted:false ----------
  group('deferred assistant final (guardrail OFF)', () {
    OpenAIRealtimeVoiceTranscript assistantOf(
      List<OpenAIRealtimeVoiceTranscript> l,
    ) => l.firstWhere(
      (t) => t.role == OpenAIRealtimeVoiceTranscriptRole.assistant,
    );

    test(
      'a barge-in before stopped publishes the held final interrupted:true',
      () async {
        final s = build(mode: OpenAIRealtimeVoiceMode.conversation);
        addTearDown(s.dispose);
        final out = collect(s);
        await reachListening(s, transport);
        transport.emit(_responseCreated('r1'));
        await pumpEventLoop();
        // The authoritative final arrives while audio is still playing → held.
        transport.emit(_assistantDone('r1', 'answer'));
        await pumpEventLoop();
        expect(
          out.where(
            (t) => t.role == OpenAIRealtimeVoiceTranscriptRole.assistant,
          ),
          isEmpty,
        );
        // Barge-in before output_audio_buffer.stopped.
        transport.emit(_speechStarted('u2'));
        await pumpEventLoop();
        final a = assistantOf(out);
        expect(a.text, 'answer');
        expect(a.interrupted, isTrue);
      },
    );

    test(
      'interruptResponse after final but before stopped → interrupted:true',
      () async {
        final s = build(mode: OpenAIRealtimeVoiceMode.conversation);
        addTearDown(s.dispose);
        final out = collect(s);
        await reachListening(s, transport);
        transport.emit(_responseCreated('r1'));
        await pumpEventLoop();
        transport.emit(_assistantDone('r1', 'answer'));
        await pumpEventLoop();
        await s.interruptResponse();
        await pumpEventLoop();
        final a = assistantOf(out);
        expect(a.interrupted, isTrue);
      },
    );
  });
}
