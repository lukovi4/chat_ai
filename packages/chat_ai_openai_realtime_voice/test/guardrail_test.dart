// The optional output guardrail: the deterministic 250 ms throttle, single
// callback at a time, coalescing, the mandatory final check that gates turn
// completion, stale results, block / callback-exception fail-closed with the
// exact cancel → clear → no-context replacement ordering, the new replacement
// turnId, an interrupted original, replacement allow, a replacement block that is
// terminal (no second replacement), and no retry / extra response.create.
import 'dart:async';

import 'package:chat_ai_openai_realtime_voice/chat_ai_openai_realtime_voice.dart';
import 'package:chat_ai_openai_realtime_voice/src/voice_session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

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
Map<String, Object?> _speechStarted(String itemId) => <String, Object?>{
  'type': 'input_audio_buffer.speech_started',
  'item_id': itemId,
  'audio_start_ms': 0,
};

int _countSent(FakeRealtimeVoiceTransport t, String type) =>
    t.sent.where((e) => e['type'] == type).length;

/// A controllable output guardrail: it records each check's text/turnId and can
/// resolve immediately (allow/block/throw) or be gated per call.
class FakeGuardrail {
  final List<String> texts = <String>[];
  final List<String> turnIds = <String>[];
  final List<Completer<OpenAIRealtimeVoiceGuardrailDecision>> completers =
      <Completer<OpenAIRealtimeVoiceGuardrailDecision>>[];

  bool gated = false;
  bool immediateThrow = false;
  OpenAIRealtimeVoiceGuardrailDecision immediate =
      OpenAIRealtimeVoiceGuardrailDecision.allow;

  int get inFlight => completers.where((c) => !c.isCompleted).length;

  Future<OpenAIRealtimeVoiceGuardrailDecision> call({
    required String turnId,
    required String accumulatedText,
  }) {
    texts.add(accumulatedText);
    turnIds.add(turnId);
    if (gated) {
      final c = Completer<OpenAIRealtimeVoiceGuardrailDecision>();
      completers.add(c);
      return c.future;
    }
    if (immediateThrow) {
      return Future<OpenAIRealtimeVoiceGuardrailDecision>.error(
        StateError('classifier boom'),
      );
    }
    return Future<OpenAIRealtimeVoiceGuardrailDecision>.value(immediate);
  }
}

FakeWatchdogTimer? _cooldown(FakeWatchdogTimerFactory f) {
  for (final t in f.created.reversed) {
    if (t.duration == const Duration(milliseconds: 250) && !t.isCancelled) {
      return t;
    }
  }
  return null;
}

void main() {
  late FakeClientSecretProvider provider;
  late FakeRealtimeVoiceTransport transport;
  late FakeGuardrail guard;
  late FakeWatchdogTimerFactory timers;

  setUp(() {
    provider = FakeClientSecretProvider();
    transport = FakeRealtimeVoiceTransport();
    guard = FakeGuardrail();
    timers = FakeWatchdogTimerFactory();
  });

  OpenAIRealtimeVoiceSession build({
    OpenAIRealtimeVoiceMode mode = OpenAIRealtimeVoiceMode.conversation,
    bool transcriptsEnabled = false,
    bool recordingEnabled = false,
    FakeRecorderFactory? recorders,
    String safe = 'You cannot help with that.',
  }) => voiceSessionForTesting(
    clientSecretProvider: provider,
    botProfile: botProfile(),
    transportFactory: () => transport,
    mode: mode,
    transcriptsEnabled: transcriptsEnabled,
    recordingEnabled: recordingEnabled,
    recordingDirectoryPath: recordingEnabled ? '/rec' : null,
    recorderFactory: recordingEnabled ? recorders?.call : null,
    outputGuardrail: guard.call,
    safeReplacementInstructions: safe,
    timerFactory: timers.call,
  );

  Future<void> reachListening(OpenAIRealtimeVoiceSession s) async {
    await s.start();
    transport.emit(_created);
    await pumpEventLoop();
    transport.emit(_updated);
    await pumpEventLoop();
  }

  // ---- Configuration validation -----------------------------------------
  group('configuration validation', () {
    test('one of the two guardrail values without the other is rejected', () {
      expect(
        () => voiceSessionForTesting(
          clientSecretProvider: provider,
          botProfile: botProfile(),
          transportFactory: () => transport,
          outputGuardrail: guard.call,
          // safeReplacementInstructions missing.
        ),
        throwsArgumentError,
      );
      expect(
        () => voiceSessionForTesting(
          clientSecretProvider: provider,
          botProfile: botProfile(),
          transportFactory: () => transport,
          safeReplacementInstructions: 'x',
          // outputGuardrail missing.
        ),
        throwsArgumentError,
      );
    });

    test('empty replacement instructions are rejected before mint', () {
      expect(
        () => voiceSessionForTesting(
          clientSecretProvider: provider,
          botProfile: botProfile(),
          transportFactory: () => transport,
          outputGuardrail: guard.call,
          safeReplacementInstructions: '   ',
        ),
        throwsArgumentError,
      );
      expect(provider.calls, 0);
    });
  });

  // ---- Scheduling --------------------------------------------------------
  test(
    'checks are throttled to once per 250 ms (leading edge + coalesce)',
    () async {
      final s = build();
      addTearDown(s.dispose);
      await reachListening(s);
      transport.emit(_responseCreated('r1'));
      await pumpEventLoop();

      // First delta → an immediate leading-edge check.
      transport.emit(_delta('r1', 'a'));
      await pumpEventLoop();
      expect(guard.texts, <String>['a']);

      // More deltas within the 250 ms window coalesce — no new check yet.
      transport.emit(_delta('r1', 'b'));
      transport.emit(_delta('r1', 'c'));
      await pumpEventLoop();
      expect(guard.texts, <String>['a']);

      // Firing the cooldown runs exactly one more check with the coalesced text.
      _cooldown(timers)!.fire();
      await pumpEventLoop();
      expect(guard.texts, <String>['a', 'abc']);
    },
  );

  test('only one callback runs at a time; new text is checked after', () async {
    guard.gated = true;
    final s = build();
    addTearDown(s.dispose);
    await reachListening(s);
    transport.emit(_responseCreated('r1'));
    await pumpEventLoop();

    transport.emit(_delta('r1', 'a'));
    await pumpEventLoop();
    expect(guard.inFlight, 1);

    // New text arrives while the callback runs — no second concurrent callback.
    transport.emit(_delta('r1', 'b'));
    await pumpEventLoop();
    expect(guard.inFlight, 1);
    // Even firing the cooldown does not start a parallel callback.
    _cooldown(timers)?.fire();
    await pumpEventLoop();
    expect(guard.inFlight, 1);

    // Resolving the first check lets the coalesced text be checked next.
    guard.completers[0].complete(OpenAIRealtimeVoiceGuardrailDecision.allow);
    await pumpEventLoop();
    expect(guard.texts, <String>['a', 'ab']);
    expect(guard.inFlight, 1);
    guard.completers[1].complete(OpenAIRealtimeVoiceGuardrailDecision.allow);
    await pumpEventLoop();
  });

  test(
    'completion waits for the exact-final check on the authoritative transcript',
    () async {
      guard.gated = true;
      final s = build();
      addTearDown(s.dispose);
      await reachListening(s);
      transport.emit(_responseCreated('r1'));
      transport.emit(_outputStarted('r1'));
      await pumpEventLoop();
      // A periodic check runs on the accumulated delta 'a'.
      transport.emit(_delta('r1', 'a'));
      await pumpEventLoop();
      expect(guard.inFlight, 1);

      // The audio reply finishes; the turn must NOT close — it waits for the
      // authoritative exact final transcript + verdict.
      transport.emit(_responseDone('r1'));
      transport.emit(_outputStopped('r1'));
      await pumpEventLoop();
      expect(s.state.phase, isNot(OpenAIRealtimeVoicePhase.listening));

      // The authoritative final transcript arrives (differs from the deltas).
      transport.emit(_assistantDone('r1', 'the exact final text'));
      await pumpEventLoop();
      // Still not closed, and the mandatory final check has NOT started in
      // parallel with the still-running periodic callback.
      expect(s.state.phase, isNot(OpenAIRealtimeVoicePhase.listening));
      expect(guard.inFlight, 1);

      // Resolve the periodic (allow) → the mandatory final check now runs, using
      // the AUTHORITATIVE final text (not the accumulated deltas).
      guard.completers[0].complete(OpenAIRealtimeVoiceGuardrailDecision.allow);
      await pumpEventLoop();
      expect(s.state.phase, isNot(OpenAIRealtimeVoicePhase.listening));
      expect(guard.inFlight, 1);
      expect(guard.texts.last, 'the exact final text');

      // The final check allows → the turn closes.
      guard.completers.last.complete(
        OpenAIRealtimeVoiceGuardrailDecision.allow,
      );
      await pumpEventLoop();
      expect(s.state.phase, OpenAIRealtimeVoicePhase.listening);
    },
  );

  test('a stale callback result after a barge-in is inert', () async {
    guard.gated = true;
    final s = build();
    addTearDown(s.dispose);
    await reachListening(s);
    transport.emit(_responseCreated('r1'));
    transport.emit(_outputStarted('r1'));
    await pumpEventLoop();
    transport.emit(_delta('r1', 'bad'));
    await pumpEventLoop();
    // The user barges in — the reply (and its guardrail context) is abandoned.
    transport.emit(_speechStarted('u2'));
    await pumpEventLoop();
    // The stale callback finally BLOCKS, but it must be inert.
    guard.completers[0].complete(OpenAIRealtimeVoiceGuardrailDecision.block);
    await pumpEventLoop();
    expect(s.state.phase, OpenAIRealtimeVoicePhase.userSpeaking);
    expect(_countSent(transport, 'response.cancel'), 0);
    expect(_countSent(transport, 'response.create'), 0);
  });

  // ---- Fail-closed replacement ------------------------------------------
  test(
    'a block fails closed: cancel → clear → no-context replacement',
    () async {
      guard.immediate = OpenAIRealtimeVoiceGuardrailDecision.block;
      final events = <OpenAIRealtimeVoiceGuardrailEvent>[];
      final s = build(transcriptsEnabled: true);
      addTearDown(s.dispose);
      s.guardrailEvents.listen(events.add);
      final deltas = <OpenAIRealtimeVoiceTranscriptDelta>[];
      s.assistantTranscriptDeltas.listen(deltas.add);
      await reachListening(s);

      transport.emit(_responseCreated('r1'));
      transport.emit(_outputStarted('r1'));
      await pumpEventLoop();
      transport.emit(_delta('r1', 'unsafe words'));
      await pumpEventLoop();

      // Exactly one coarse event, carrying the blocked reply's turnId.
      expect(events.length, 1);
      final blockedTurnId = deltas.single.turnId;
      expect(events.single.turnId, blockedTurnId);

      // Wire order: cancel, then clear, then the replacement response.create.
      final types = transport.sent.map((e) => e['type']).toList();
      final ci = types.indexOf('response.cancel');
      final cl = types.indexOf('output_audio_buffer.clear');
      final cr = types.indexOf('response.create');
      expect(ci >= 0 && cl == ci + 1, isTrue);
      expect(cr > cl, isTrue);
      expect(_countSent(transport, 'response.create'), 1);

      // Exact no-context / no-tools replacement payload.
      final create = transport.sent.firstWhere(
        (e) => e['type'] == 'response.create',
      );
      final response = create['response']! as Map<String, Object?>;
      expect(response.keys.toSet(), <String>{'input', 'tools', 'instructions'});
      expect(response['input'], isEmpty);
      expect(response['tools'], isEmpty);
      expect(response['instructions'], 'You cannot help with that.');

      // The replacement (r2) gets a NEW assistant turnId. Allow it so we can
      // observe its turnId without a second block.
      guard.immediate = OpenAIRealtimeVoiceGuardrailDecision.allow;
      transport.emit(_responseCreated('r2'));
      await pumpEventLoop();
      transport.emit(_delta('r2', 'safe'));
      await pumpEventLoop();
      expect(deltas.last.turnId, isNot(blockedTurnId));
      expect(s.state.phase, OpenAIRealtimeVoicePhase.assistantSpeaking);
    },
  );

  test('a callback exception also fails closed with one replacement', () async {
    guard.immediateThrow = true;
    final s = build();
    addTearDown(s.dispose);
    await reachListening(s);
    transport.emit(_responseCreated('r1'));
    transport.emit(_outputStarted('r1'));
    await pumpEventLoop();
    transport.emit(_delta('r1', 'x'));
    await pumpEventLoop();
    expect(_countSent(transport, 'response.cancel'), 1);
    expect(_countSent(transport, 'output_audio_buffer.clear'), 1);
    expect(_countSent(transport, 'response.create'), 1);
  });

  test('a block interrupts the original assistant recording', () async {
    guard.immediate = OpenAIRealtimeVoiceGuardrailDecision.block;
    final recorders = FakeRecorderFactory();
    final recordings = <OpenAIRealtimeVoiceRecording>[];
    final s = build(recordingEnabled: true, recorders: recorders);
    addTearDown(s.dispose);
    s.recordings.listen(recordings.add);
    await s.start();
    transport.completeRemoteTrack();
    transport.emit(_created);
    await pumpEventLoop();
    transport.emit(_updated);
    await pumpEventLoop();

    transport.emit(_responseCreated('r1'));
    transport.emit(_outputStarted('r1')); // opens the assistant segment
    await pumpEventLoop();
    transport.emit(_delta('r1', 'unsafe'));
    await pumpEventLoop();

    final assistant = recordings.firstWhere(
      (r) => r.role == OpenAIRealtimeVoiceRecordingRole.assistant,
    );
    expect(assistant.interrupted, isTrue);
  });

  test('the replacement passes the guardrail and completes normally', () async {
    // Block the first reply; allow everything in the replacement.
    var callCount = 0;
    final s = voiceSessionForTesting(
      clientSecretProvider: provider,
      botProfile: botProfile(),
      transportFactory: () => transport,
      mode: OpenAIRealtimeVoiceMode.conversation,
      outputGuardrail: ({required turnId, required accumulatedText}) async {
        callCount++;
        return callCount == 1
            ? OpenAIRealtimeVoiceGuardrailDecision.block
            : OpenAIRealtimeVoiceGuardrailDecision.allow;
      },
      safeReplacementInstructions: 'safe',
      timerFactory: timers.call,
    );
    addTearDown(s.dispose);
    await reachListening(s);

    transport.emit(_responseCreated('r1'));
    transport.emit(_outputStarted('r1'));
    await pumpEventLoop();
    transport.emit(_delta('r1', 'bad')); // blocks → replacement
    await pumpEventLoop();
    expect(_countSent(transport, 'response.create'), 1);

    // The replacement runs; its authoritative final transcript passes the same
    // exact-final guardrail flow, and the reply completes cleanly.
    transport.emit(_responseCreated('r2'));
    transport.emit(_outputStarted('r2'));
    await pumpEventLoop();
    transport.emit(_delta('r2', 'good'));
    await pumpEventLoop();
    transport.emit(_responseDone('r2'));
    transport.emit(_outputStopped('r2'));
    transport.emit(_assistantDone('r2', 'good final'));
    await pumpEventLoop();
    expect(s.state.phase, OpenAIRealtimeVoicePhase.listening);
    // No second replacement / no extra response.create.
    expect(_countSent(transport, 'response.create'), 1);
    expect(s.state.failure, isNull);
  });

  test(
    'a block inside the replacement is terminal with no second replacement',
    () async {
      guard.immediate = OpenAIRealtimeVoiceGuardrailDecision.block;
      final s = build();
      addTearDown(s.dispose);
      await reachListening(s);

      transport.emit(_responseCreated('r1'));
      transport.emit(_outputStarted('r1'));
      await pumpEventLoop();
      transport.emit(_delta('r1', 'bad')); // block → replacement (1 create)
      await pumpEventLoop();
      expect(_countSent(transport, 'response.create'), 1);

      // The replacement itself blocks.
      transport.emit(_responseCreated('r2'));
      transport.emit(_outputStarted('r2'));
      await pumpEventLoop();
      transport.emit(_delta('r2', 'still bad'));
      await pumpEventLoop();

      // Terminal guardrail failure; no second replacement.
      expect(s.state.phase, OpenAIRealtimeVoicePhase.failed);
      expect(s.state.failure, OpenAIRealtimeVoiceFailure.guardrail);
      expect(_countSent(transport, 'response.create'), 1);
      expect(transport.closeCalls, 1);
    },
  );

  test(
    'an interrupted original turn late transcript carries interrupted:true',
    () async {
      guard.immediate = OpenAIRealtimeVoiceGuardrailDecision.block;
      final transcripts = <OpenAIRealtimeVoiceTranscript>[];
      final s = build(transcriptsEnabled: true);
      addTearDown(s.dispose);
      s.transcripts.listen(transcripts.add);
      await reachListening(s);

      transport.emit(_responseCreated('r1'));
      transport.emit(_outputStarted('r1'));
      await pumpEventLoop();
      transport.emit(_delta('r1', 'bad')); // block
      await pumpEventLoop();

      // A late final assistant transcript for the blocked r1 still arrives.
      transport.emit(_assistantDone('r1', 'the unsafe answer'));
      await pumpEventLoop();
      final assistantFinal = transcripts.firstWhere(
        (t) => t.role == OpenAIRealtimeVoiceTranscriptRole.assistant,
      );
      expect(assistantFinal.interrupted, isTrue);
    },
  );

  test(
    'a pending check is inert after stop()/dispose() — no late replacement',
    () async {
      guard.gated = true;
      final s = build();
      await reachListening(s);
      transport.emit(_responseCreated('r1'));
      transport.emit(_outputStarted('r1'));
      await pumpEventLoop();
      transport.emit(_delta('r1', 'x'));
      await pumpEventLoop();
      expect(guard.inFlight, 1);

      // A manual stop tears the session down while the check is pending.
      await s.stop();
      await pumpEventLoop();
      expect(s.state.phase, OpenAIRealtimeVoicePhase.ended);
      final createsBefore = _countSent(transport, 'response.create');

      // The late block resolves AFTER teardown — it must be completely inert.
      guard.completers[0].complete(OpenAIRealtimeVoiceGuardrailDecision.block);
      await pumpEventLoop();
      expect(_countSent(transport, 'response.create'), createsBefore);
      expect(s.state.failure, isNull);
      await s.dispose();
    },
  );

  test(
    'the guardrail runs with transcripts disabled and publishes no transcript',
    () async {
      guard.immediate = OpenAIRealtimeVoiceGuardrailDecision.block;
      final s = build(); // transcriptsEnabled: false
      addTearDown(s.dispose);
      final deltas = <OpenAIRealtimeVoiceTranscriptDelta>[];
      s.assistantTranscriptDeltas.listen(deltas.add);
      await reachListening(s);
      transport.emit(_responseCreated('r1'));
      transport.emit(_outputStarted('r1'));
      await pumpEventLoop();
      transport.emit(_delta('r1', 'unsafe'));
      await pumpEventLoop();

      // The guardrail still saw the delta and fired (it works internally)...
      expect(guard.texts, contains('unsafe'));
      expect(_countSent(transport, 'response.create'), 1);
      // ...but the transcript-delta stream stays silent (transcripts are off).
      expect(deltas, isEmpty);
    },
  );

  // ---- Defect 6: exact final transcript --------------------------------
  test(
    'the mandatory final check uses the authoritative final transcript',
    () async {
      final s = build(); // immediate allow
      addTearDown(s.dispose);
      await reachListening(s);
      transport.emit(_responseCreated('r1'));
      transport.emit(_outputStarted('r1'));
      await pumpEventLoop();
      // Deltas accumulate to 'AB'...
      transport.emit(_delta('r1', 'A'));
      transport.emit(_delta('r1', 'B'));
      await pumpEventLoop();
      // ...but the authoritative final transcript DIFFERS.
      transport.emit(_responseDone('r1'));
      transport.emit(_outputStopped('r1'));
      transport.emit(_assistantDone('r1', 'the different exact final'));
      await pumpEventLoop();
      // The mandatory final check ran on the AUTHORITATIVE final text, not 'AB'.
      expect(guard.texts.last, 'the different exact final');
      expect(s.state.phase, OpenAIRealtimeVoicePhase.listening);
    },
  );

  test(
    'a missing final transcript ends as a controlled responseTimeout',
    () async {
      final s = build();
      addTearDown(s.dispose);
      await reachListening(s);
      transport.emit(_responseCreated('r1'));
      transport.emit(_outputStarted('r1'));
      await pumpEventLoop();
      transport.emit(_delta('r1', 'a'));
      await pumpEventLoop();
      // Audio completes, but the authoritative final transcript never arrives.
      transport.emit(_responseDone('r1'));
      transport.emit(_outputStopped('r1'));
      await pumpEventLoop();
      expect(s.state.phase, isNot(OpenAIRealtimeVoicePhase.listening));
      // The idle watchdog bounds the wait; on expiry it is a controlled timeout.
      final deadline = timers.created.lastWhere(
        (t) =>
            t.duration != const Duration(milliseconds: 250) && !t.isCancelled,
      );
      deadline.fire();
      await pumpEventLoop();
      expect(s.state.phase, OpenAIRealtimeVoicePhase.failed);
      expect(s.state.failure, OpenAIRealtimeVoiceFailure.responseTimeout);
      expect(_countSent(transport, 'response.create'), 0);
    },
  );

  test(
    'the public final transcript is published only after an allow verdict',
    () async {
      guard.gated = true;
      final transcripts = <OpenAIRealtimeVoiceTranscript>[];
      final s = build(transcriptsEnabled: true);
      addTearDown(s.dispose);
      s.transcripts.listen(transcripts.add);
      await reachListening(s);
      transport.emit(_responseCreated('r1'));
      transport.emit(_outputStarted('r1'));
      await pumpEventLoop();
      // The authoritative final arrives; the final check is gated.
      transport.emit(_assistantDone('r1', 'the final text'));
      transport.emit(_responseDone('r1'));
      transport.emit(_outputStopped('r1'));
      await pumpEventLoop();
      // Nothing published yet — the verdict is pending.
      expect(transcripts, isEmpty);
      // Allow → the final transcript publishes with interrupted:false.
      guard.completers.last.complete(
        OpenAIRealtimeVoiceGuardrailDecision.allow,
      );
      await pumpEventLoop();
      final assistant = transcripts.firstWhere(
        (t) => t.role == OpenAIRealtimeVoiceTranscriptRole.assistant,
      );
      expect(assistant.text, 'the final text');
      expect(assistant.interrupted, isFalse);
      expect(s.state.phase, OpenAIRealtimeVoicePhase.listening);
    },
  );

  test(
    'a replacement whose exact final blocks is terminal (no 2nd replacement)',
    () async {
      // Block whenever the checked text contains BLOCK; allow otherwise.
      final s = voiceSessionForTesting(
        clientSecretProvider: provider,
        botProfile: botProfile(),
        transportFactory: () => transport,
        mode: OpenAIRealtimeVoiceMode.conversation,
        outputGuardrail: ({required turnId, required accumulatedText}) async =>
            accumulatedText.contains('BLOCK')
            ? OpenAIRealtimeVoiceGuardrailDecision.block
            : OpenAIRealtimeVoiceGuardrailDecision.allow,
        safeReplacementInstructions: 'safe',
        timerFactory: timers.call,
      );
      addTearDown(s.dispose);
      await reachListening(s);

      // Original r1 blocks on a periodic delta → replacement r2.
      transport.emit(_responseCreated('r1'));
      transport.emit(_outputStarted('r1'));
      await pumpEventLoop();
      transport.emit(_delta('r1', 'BLOCK'));
      await pumpEventLoop();
      expect(_countSent(transport, 'response.create'), 1);

      // r2 passes its periodic delta but its EXACT FINAL transcript blocks.
      transport.emit(_responseCreated('r2'));
      transport.emit(_outputStarted('r2'));
      await pumpEventLoop();
      transport.emit(_delta('r2', 'ok'));
      await pumpEventLoop();
      transport.emit(_responseDone('r2'));
      transport.emit(_outputStopped('r2'));
      transport.emit(_assistantDone('r2', 'BLOCK final'));
      await pumpEventLoop();

      // Terminal guardrail failure; no second replacement.
      expect(s.state.phase, OpenAIRealtimeVoicePhase.failed);
      expect(s.state.failure, OpenAIRealtimeVoiceFailure.guardrail);
      expect(_countSent(transport, 'response.create'), 1);
    },
  );

  // ---- Defect 5: the one-replacement budget is per USER TURN --------------
  test('each new user turn re-opens its one-replacement budget', () async {
    // Block whenever the checked text contains BLOCK; allow otherwise.
    final s = voiceSessionForTesting(
      clientSecretProvider: provider,
      botProfile: botProfile(),
      transportFactory: () => transport,
      mode: OpenAIRealtimeVoiceMode.conversation,
      outputGuardrail: ({required turnId, required accumulatedText}) async =>
          accumulatedText.contains('BLOCK')
          ? OpenAIRealtimeVoiceGuardrailDecision.block
          : OpenAIRealtimeVoiceGuardrailDecision.allow,
      safeReplacementInstructions: 'safe',
      timerFactory: timers.call,
    );
    addTearDown(s.dispose);
    await reachListening(s);

    Future<void> blockedThenReplaced(String orig, String repl) async {
      transport.emit(_responseCreated(orig));
      transport.emit(_outputStarted(orig));
      await pumpEventLoop();
      transport.emit(_delta(orig, 'BLOCK')); // periodic block → replacement
      await pumpEventLoop();
      transport.emit(_responseCreated(repl));
      transport.emit(_outputStarted(repl));
      await pumpEventLoop();
      transport.emit(_delta(repl, 'ok'));
      transport.emit(_responseDone(repl));
      transport.emit(_outputStopped(repl));
      transport.emit(_assistantDone(repl, 'ok final'));
      await pumpEventLoop();
    }

    // User turn 1: original blocked → one replacement (allowed) → listening.
    transport.emit(_speechStarted('u1'));
    await pumpEventLoop();
    transport.emit(<String, Object?>{
      'type': 'input_audio_buffer.speech_stopped',
      'item_id': 'u1',
      'audio_end_ms': 10,
    });
    await pumpEventLoop();
    await blockedThenReplaced('r1', 'r2');
    expect(s.state.phase, OpenAIRealtimeVoicePhase.listening);
    expect(_countSent(transport, 'response.create'), 1);

    // User turn 2 re-opens the budget: its original is blocked and STILL gets
    // its own replacement (the first turn's replacement did not consume it).
    transport.emit(_speechStarted('u2'));
    await pumpEventLoop();
    transport.emit(<String, Object?>{
      'type': 'input_audio_buffer.speech_stopped',
      'item_id': 'u2',
      'audio_end_ms': 10,
    });
    await pumpEventLoop();
    await blockedThenReplaced('r3', 'r4');
    expect(s.state.phase, OpenAIRealtimeVoicePhase.listening);
    expect(s.state.failure, isNull);
    // Exactly one replacement per user turn (two total), never a terminal.
    expect(_countSent(transport, 'response.create'), 2);
  });

  // ---- Defect 7: no guardrail callback concurrency between turns ----------
  test('at most one app callback runs at a time, even across turns', () async {
    guard.gated = true;
    final s = build(); // conversation
    addTearDown(s.dispose);
    await reachListening(s);
    transport.emit(_responseCreated('r1'));
    transport.emit(_outputStarted('r1'));
    await pumpEventLoop();
    transport.emit(_delta('r1', 'a')); // r1's periodic check starts (gated)
    await pumpEventLoop();
    expect(guard.inFlight, 1);

    // A new user turn (barge-in) abandons r1 while its callback is still running.
    transport.emit(_speechStarted('u2'));
    await pumpEventLoop();
    // r2 begins and wants its own check.
    transport.emit(_responseCreated('r2'));
    transport.emit(_outputStarted('r2'));
    await pumpEventLoop();
    transport.emit(_delta('r2', 'b'));
    await pumpEventLoop();
    // Still exactly one PHYSICAL callback (r1's) — no parallel second callback.
    expect(guard.inFlight, 1);
    expect(guard.texts, <String>['a']); // only r1's check has started

    // r1's callback finally resolves (a late BLOCK) — it is stale/inert.
    guard.completers[0].complete(OpenAIRealtimeVoiceGuardrailDecision.block);
    await pumpEventLoop();
    // r1's late block did NOT cancel r2 or create a replacement.
    expect(_countSent(transport, 'response.create'), 0);
    expect(s.state.failure, isNull);
    expect(s.state.phase, OpenAIRealtimeVoicePhase.assistantSpeaking);
    // Now r2's callback runs (the freed slot) with r2's text.
    expect(guard.inFlight, 1);
    expect(guard.texts, <String>['a', 'b']);
    guard.completers[1].complete(OpenAIRealtimeVoiceGuardrailDecision.allow);
    await pumpEventLoop();
  });

  // ---- Defect 3: no premature interrupted:false publication --------------
  group('deferred final-transcript publication (guardrail ON)', () {
    OpenAIRealtimeVoiceTranscript? assistantOf(
      List<OpenAIRealtimeVoiceTranscript> l,
    ) {
      for (final t in l) {
        if (t.role == OpenAIRealtimeVoiceTranscriptRole.assistant) return t;
      }
      return null;
    }

    test(
      'an allowed final is published interrupted:false only after done+stopped',
      () async {
        final out = <OpenAIRealtimeVoiceTranscript>[];
        final s = build(transcriptsEnabled: true); // immediate allow
        addTearDown(s.dispose);
        s.transcripts.listen(out.add);
        await reachListening(s);
        transport.emit(_responseCreated('r1'));
        transport.emit(_outputStarted('r1'));
        await pumpEventLoop();
        // The exact-final callback fires and ALLOWS, but audio is still playing.
        transport.emit(_assistantDone('r1', 'safe final'));
        await pumpEventLoop();
        expect(out, isEmpty); // held — not yet published
        // The reply completes cleanly.
        transport.emit(_responseDone('r1'));
        transport.emit(_outputStopped('r1'));
        await pumpEventLoop();
        final a = assistantOf(out)!;
        expect(a.text, 'safe final');
        expect(a.interrupted, isFalse);
      },
    );

    test(
      'a barge-in before stopped publishes the held final interrupted:true',
      () async {
        final out = <OpenAIRealtimeVoiceTranscript>[];
        final s = build(transcriptsEnabled: true);
        addTearDown(s.dispose);
        s.transcripts.listen(out.add);
        await reachListening(s);
        transport.emit(_responseCreated('r1'));
        transport.emit(_outputStarted('r1'));
        await pumpEventLoop();
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
        final a = assistantOf(out)!;
        expect(a.text, 'answer');
        expect(a.interrupted, isTrue);
      },
    );

    test(
      'interruptResponse after final but before stopped → interrupted:true',
      () async {
        final out = <OpenAIRealtimeVoiceTranscript>[];
        final s = build(transcriptsEnabled: true);
        addTearDown(s.dispose);
        s.transcripts.listen(out.add);
        await reachListening(s);
        transport.emit(_responseCreated('r1'));
        transport.emit(_outputStarted('r1'));
        await pumpEventLoop();
        transport.emit(_assistantDone('r1', 'answer'));
        await pumpEventLoop();
        await s.interruptResponse();
        await pumpEventLoop();
        final a = assistantOf(out)!;
        expect(a.interrupted, isTrue);
      },
    );

    test(
      'a guardrail-blocked exact-final publishes the original interrupted:true',
      () async {
        guard.immediate = OpenAIRealtimeVoiceGuardrailDecision.block;
        final out = <OpenAIRealtimeVoiceTranscript>[];
        final s = build(transcriptsEnabled: true);
        addTearDown(s.dispose);
        s.transcripts.listen(out.add);
        await reachListening(s);
        transport.emit(_responseCreated('r1'));
        transport.emit(_outputStarted('r1'));
        await pumpEventLoop();
        // No deltas → the FIRST check is the exact-final on transcript.done.
        transport.emit(_assistantDone('r1', 'unsafe final'));
        await pumpEventLoop();
        final a = assistantOf(out)!;
        expect(a.text, 'unsafe final');
        expect(a.interrupted, isTrue);
        // The block produced the one replacement.
        expect(_countSent(transport, 'response.create'), 1);
      },
    );

    test(
      'a replacement clean completion publishes interrupted:false',
      () async {
        final out = <OpenAIRealtimeVoiceTranscript>[];
        // Block only text containing BLOCK; allow otherwise.
        final s = voiceSessionForTesting(
          clientSecretProvider: provider,
          botProfile: botProfile(),
          transportFactory: () => transport,
          mode: OpenAIRealtimeVoiceMode.conversation,
          transcriptsEnabled: true,
          outputGuardrail:
              ({required turnId, required accumulatedText}) async =>
                  accumulatedText.contains('BLOCK')
                  ? OpenAIRealtimeVoiceGuardrailDecision.block
                  : OpenAIRealtimeVoiceGuardrailDecision.allow,
          safeReplacementInstructions: 'safe',
          timerFactory: timers.call,
        );
        addTearDown(s.dispose);
        s.transcripts.listen(out.add);
        await reachListening(s);
        // r1's exact-final blocks → replacement.
        transport.emit(_responseCreated('r1'));
        transport.emit(_outputStarted('r1'));
        await pumpEventLoop();
        transport.emit(_assistantDone('r1', 'BLOCK final'));
        await pumpEventLoop();
        expect(_countSent(transport, 'response.create'), 1);
        // r2 (the replacement) completes cleanly → interrupted:false.
        transport.emit(_responseCreated('r2'));
        transport.emit(_outputStarted('r2'));
        await pumpEventLoop();
        transport.emit(_assistantDone('r2', 'safe final'));
        transport.emit(_responseDone('r2'));
        transport.emit(_outputStopped('r2'));
        await pumpEventLoop();
        final r2Final = out.lastWhere(
          (t) => t.role == OpenAIRealtimeVoiceTranscriptRole.assistant,
        );
        expect(r2Final.text, 'safe final');
        expect(r2Final.interrupted, isFalse);
      },
    );
  });

  // ---- P1 race: replacement ownership across the gated cancel/clear -------
  group('replacement ownership across the gated cancel/clear', () {
    // Drives a guardrail block whose cancel/clear sends are gated open (hung),
    // and returns the gate. The replacement response.create has NOT been sent.
    Future<Completer<void>> reachHungCancel(
      OpenAIRealtimeVoiceSession s,
    ) async {
      await reachListening(s);
      transport.emit(_responseCreated('r1'));
      transport.emit(_outputStarted('r1'));
      await pumpEventLoop();
      final gate = Completer<void>();
      transport.sendGate = gate;
      transport.emit(_delta('r1', 'unsafe')); // periodic block → fail closed
      await pumpEventLoop();
      // cancel + clear are enqueued but hung; no replacement yet.
      expect(_countSent(transport, 'response.cancel'), 1);
      expect(_countSent(transport, 'output_audio_buffer.clear'), 1);
      expect(_countSent(transport, 'response.create'), 0);
      return gate;
    }

    test(
      'a new speech_started during the gate → no replacement, stays userSpeaking',
      () async {
        guard.immediate = OpenAIRealtimeVoiceGuardrailDecision.block;
        final s = build();
        addTearDown(s.dispose);
        final gate = await reachHungCancel(s);

        // A new valid user turn arrives while cancel/clear are hung.
        transport.emit(_speechStarted('u2'));
        await pumpEventLoop();
        expect(s.state.phase, OpenAIRealtimeVoicePhase.userSpeaking);

        // Releasing the gate must NOT create the superseded replacement.
        gate.complete();
        await pumpEventLoop();
        expect(_countSent(transport, 'response.create'), 0);
        expect(s.state.phase, OpenAIRealtimeVoicePhase.userSpeaking);
        expect(s.state.failure, isNull);
      },
    );

    test(
      'dispose during the gate → no replacement, no late failure / unhandled error',
      () async {
        guard.immediate = OpenAIRealtimeVoiceGuardrailDecision.block;
        final s = build();
        final gate = await reachHungCancel(s);

        final disposed = s.dispose();
        // A late ERROR of the hung cancel/clear must be caught and inert.
        gate.completeError(StateError('late cancel/clear error'));
        await disposed;
        await pumpEventLoop();
        expect(_countSent(transport, 'response.create'), 0);
      },
    );

    test('stop during the gate → no replacement, ends cleanly', () async {
      guard.immediate = OpenAIRealtimeVoiceGuardrailDecision.block;
      final s = build();
      addTearDown(s.dispose);
      final gate = await reachHungCancel(s);

      await s.stop();
      gate.complete();
      await pumpEventLoop();
      expect(_countSent(transport, 'response.create'), 0);
      expect(s.state.phase, OpenAIRealtimeVoicePhase.ended);
    });

    test(
      'the normal (ungated) block still creates exactly one replacement',
      () async {
        guard.immediate = OpenAIRealtimeVoiceGuardrailDecision.block;
        final s = build();
        addTearDown(s.dispose);
        await reachListening(s);
        transport.emit(_responseCreated('r1'));
        transport.emit(_outputStarted('r1'));
        await pumpEventLoop();
        transport.emit(_delta('r1', 'unsafe'));
        await pumpEventLoop();
        expect(_countSent(transport, 'response.create'), 1);
        expect(s.state.failure, isNull);
      },
    );
  });
}
