// The session state machine's money-safe / lifecycle behaviour (required tests
// 4, 5, 8–20) driven by a private fake transport and a deterministic fake
// watchdog timer — no native WebRTC, no real clock.
import 'dart:async';

import 'package:chat_ai_openai_realtime_voice/chat_ai_openai_realtime_voice.dart';
// The package-internal test seam (voiceSessionForTesting) is imported from
// src/ — it is deliberately NOT part of the barrel's public surface.
import 'package:chat_ai_openai_realtime_voice/src/voice_session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

// Common event literals.
Map<String, Object?> _created = <String, Object?>{'type': 'session.created'};
Map<String, Object?> _updated = <String, Object?>{'type': 'session.updated'};
// Full, well-formed VAD pairs (the real wire always carries item_id + the ms
// boundary; the strict VAD-pair contract requires them).
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
// A `completed` response.done for [id] (the only success status). Pass a
// different [status] to model cancelled/failed/incomplete/unknown.
Map<String, Object?> _responseDone(String id, {String? status = 'completed'}) =>
    <String, Object?>{
      'type': 'response.done',
      'response': <String, Object?>{'id': id, 'status': ?status},
    };
Map<String, Object?> _outputStopped(String id) => <String, Object?>{
  'type': 'output_audio_buffer.stopped',
  'response_id': id,
};
// A real, minimally-structured audio progress event of the current response:
// non-empty item_id, non-negative indices and a non-empty delta.
Map<String, Object?> _audioDelta(String id) => <String, Object?>{
  'type': 'response.output_audio.delta',
  'response_id': id,
  'item_id': 'item_1',
  'output_index': 0,
  'content_index': 0,
  'delta': 'YXVkaW8=',
};

int _countSent(FakeRealtimeVoiceTransport t, String type) =>
    t.sent.where((e) => e['type'] == type).length;

void main() {
  late FakeClientSecretProvider provider;
  late FakeRealtimeVoiceTransport transport;
  late OpenAIRealtimeVoiceSession session;

  OpenAIRealtimeVoiceSession build({
    OpenAIRealtimeVoiceMode mode = OpenAIRealtimeVoiceMode.singleTurn,
    FakeClientSecretProvider? p,
    FakeRealtimeVoiceTransport? t,
    Timer Function(Duration, void Function())? timerFactory,
  }) {
    final provider0 = p ?? provider;
    final transport0 = t ?? transport;
    if (timerFactory != null) {
      return voiceSessionForTesting(
        clientSecretProvider: provider0,
        botProfile: botProfile(),
        transportFactory: () => transport0,
        mode: mode,
        timerFactory: timerFactory,
      );
    }
    return voiceSessionForTesting(
      clientSecretProvider: provider0,
      botProfile: botProfile(),
      transportFactory: () => transport0,
      mode: mode,
    );
  }

  setUp(() {
    provider = FakeClientSecretProvider();
    transport = FakeRealtimeVoiceTransport();
    session = build();
  });

  tearDown(() => session.dispose());

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

  // Required test 4.
  test('start calls the provider and connect exactly once', () async {
    await reachListening(session, transport);
    expect(provider.calls, 1);
    expect(transport.connectCalls, 1);
    expect(session.state.phase, OpenAIRealtimeVoicePhase.listening);
  });

  // Required test 5.
  test('a repeat start() is a programming error and never re-mints', () async {
    await session.start();
    await expectLater(session.start(), throwsA(isA<StateError>()));
    expect(provider.calls, 1);
    expect(transport.connectCalls, 1);
  });

  // Required test 6 (wire half): exactly one session.update, right after
  // session.created, with the approved structure.
  test('exactly one session.update is sent after session.created', () async {
    await session.start();
    transport.emit(_created);
    // A stray duplicate created event must not double the update.
    transport.emit(_created);
    await pumpEventLoop();
    final updates = transport.sent
        .where((e) => e['type'] == 'session.update')
        .toList();
    expect(updates.length, 1);
    final s = updates.single['session']! as Map<String, Object?>;
    expect(s['type'], 'realtime');
    expect(s['model'], 'gpt-realtime-2.1');
    expect(s['output_modalities'], <String>['audio']);
    expect(s['instructions'], 'be brief');
    final audio = s['audio']! as Map<String, Object?>;
    final turn =
        (audio['input']! as Map<String, Object?>)['turn_detection']!
            as Map<String, Object?>;
    expect(turn['type'], 'semantic_vad');
  });

  // Required test 8 (session half): the mic is enabled ONLY after
  // session.updated.
  test('the mic is enabled only after session.updated', () async {
    await session.start();
    transport.emit(_created);
    await pumpEventLoop();
    expect(transport.enabledCalls.where((e) => e).isEmpty, isTrue);
    transport.emit(_updated);
    await pumpEventLoop();
    expect(transport.enabledCalls.where((e) => e).length, 1);
    expect(session.state.phase, OpenAIRealtimeVoicePhase.listening);
  });

  // Required test 9.
  test('singleTurn does not end on response.done alone', () async {
    await reachListening(session, transport);
    transport.emit(_responseCreated('r1'));
    await pumpEventLoop();
    transport.emit(_responseDone('r1'));
    await pumpEventLoop();
    expect(session.state.phase, OpenAIRealtimeVoicePhase.assistantSpeaking);
    expect(transport.closeCalls, 0);
  });

  // Required test 10.
  test(
    'singleTurn ends after response.done AND output_audio_buffer.stopped',
    () async {
      await reachListening(session, transport);
      transport.emit(_responseCreated('r1'));
      await pumpEventLoop();
      transport.emit(_responseDone('r1'));
      transport.emit(_outputStopped('r1'));
      await pumpEventLoop();
      expect(session.state.phase, OpenAIRealtimeVoicePhase.ended);
      expect(session.state.failure, isNull);
      expect(transport.closeCalls, 1);
      // No response.create was ever sent (server VAD owns responses).
      expect(_countSent(transport, 'response.create'), 0);
    },
  );

  // Required test 11.
  test(
    'after the first speech_stopped no second user turn is possible',
    () async {
      await reachListening(session, transport);
      transport.emit(_speechStarted('u1'));
      await pumpEventLoop();
      expect(session.state.phase, OpenAIRealtimeVoicePhase.userSpeaking);
      transport.emit(_speechStopped('u1'));
      await pumpEventLoop();
      // The mic was disabled on the first speech_stopped.
      expect(transport.enabledCalls, <bool>[true, false]);
      // A second turn never re-enables the mic.
      transport.emit(_speechStarted('u2'));
      transport.emit(_speechStopped('u2'));
      await pumpEventLoop();
      expect(transport.enabledCalls.where((e) => e).length, 1);
      expect(transport.enabledCalls.last, isFalse);
    },
  );

  // Required test 12.
  test(
    'conversation stays active after a response and accepts a second turn',
    () async {
      final t = FakeRealtimeVoiceTransport();
      final s = build(mode: OpenAIRealtimeVoiceMode.conversation, t: t);
      addTearDown(s.dispose);

      await reachListening(s, t);
      // First turn.
      t.emit(_speechStarted('u1'));
      await pumpEventLoop();
      t.emit(_speechStopped('u1'));
      await pumpEventLoop();
      // conversation NEVER disables the mic.
      expect(t.enabledCalls, <bool>[true]);
      t.emit(_responseCreated('r1'));
      await pumpEventLoop();
      t.emit(_responseDone('r1'));
      t.emit(_outputStopped('r1'));
      await pumpEventLoop();
      // Back to listening, still connected.
      expect(s.state.phase, OpenAIRealtimeVoicePhase.listening);
      expect(t.closeCalls, 0);

      // Second turn accepted in the same conversation.
      t.emit(_speechStarted('u2'));
      await pumpEventLoop();
      expect(s.state.phase, OpenAIRealtimeVoicePhase.userSpeaking);
      t.emit(_speechStopped('u2'));
      await pumpEventLoop();
      t.emit(_responseCreated('r2'));
      await pumpEventLoop();
      t.emit(_responseDone('r2'));
      t.emit(_outputStopped('r2'));
      await pumpEventLoop();
      expect(s.state.phase, OpenAIRealtimeVoicePhase.listening);
      expect(t.closeCalls, 0);
      expect(t.enabledCalls, <bool>[true]);
    },
  );

  // Required test 13.
  test(
    'barge-in changes state but sends no redundant cancel/truncate',
    () async {
      final t = FakeRealtimeVoiceTransport();
      final s = build(mode: OpenAIRealtimeVoiceMode.conversation, t: t);
      addTearDown(s.dispose);

      await reachListening(s, t);
      t.emit(_responseCreated('r1'));
      await pumpEventLoop();
      expect(s.state.phase, OpenAIRealtimeVoicePhase.assistantSpeaking);

      // The user barges in over the assistant's response.
      t.emit(_speechStarted('u1'));
      await pumpEventLoop();
      expect(s.state.phase, OpenAIRealtimeVoicePhase.userSpeaking);

      // The server (interrupt_response: true) handles it; we send nothing.
      expect(_countSent(t, 'response.cancel'), 0);
      expect(_countSent(t, 'response.truncate'), 0);
      expect(_countSent(t, 'output_audio_buffer.clear'), 0);
    },
  );

  // Required test 14.
  test(
    'stop during an active response: one cancel, one clear, one teardown',
    () async {
      await reachListening(session, transport);
      transport.emit(_responseCreated('r1'));
      await pumpEventLoop();
      expect(session.state.phase, OpenAIRealtimeVoicePhase.assistantSpeaking);

      await session.stop();
      await pumpEventLoop();
      expect(_countSent(transport, 'response.cancel'), 1);
      expect(_countSent(transport, 'output_audio_buffer.clear'), 1);
      expect(transport.closeCalls, 1);
      expect(session.state.phase, OpenAIRealtimeVoicePhase.ended);

      // Idempotent: a second stop adds no cancel/clear/teardown.
      await session.stop();
      await pumpEventLoop();
      expect(_countSent(transport, 'response.cancel'), 1);
      expect(_countSent(transport, 'output_audio_buffer.clear'), 1);
      expect(transport.closeCalls, 1);
    },
  );

  // Required test 15 (mint boundary): a stop during minting cancels setup and
  // never connects.
  test('stop during minting cancels setup and never connects', () async {
    final f = session.start();
    // Cancel before the mint continuation reaches connect.
    await session.stop();
    await f;
    await pumpEventLoop();
    expect(provider.calls, 1);
    expect(transport.connectCalls, 0);
    expect(_countSent(transport, 'session.update'), 0);
    expect(session.state.phase, OpenAIRealtimeVoicePhase.ended);
  });

  // Required test 15 (connect boundary) + required test 16 (session half): a
  // stop while connect is gated tears down exactly once, sends no update, and
  // start's settlement waits for the connect/close.
  test(
    'stop during a gated connect tears down once; start settlement waits',
    () async {
      transport.connectGate = Completer<void>();
      final startFuture = session.start();
      await pumpEventLoop();
      expect(transport.connectCalls, 1);

      final stopFuture = session.stop();
      // The late connect now resolves.
      transport.connectGate!.complete();
      await startFuture;
      await stopFuture;
      await pumpEventLoop();

      expect(provider.calls, 1);
      expect(_countSent(transport, 'session.update'), 0);
      expect(transport.closeCalls, 1);
      expect(session.state.phase, OpenAIRealtimeVoicePhase.ended);
    },
  );

  // Required test 17 (setup death) + the `session` failure category.
  test(
    'a setup-phase transport death is a session failure, no retry',
    () async {
      await session.start();
      expect(session.state.phase, OpenAIRealtimeVoicePhase.connecting);
      transport.endEvents();
      await pumpEventLoop();
      expect(session.state.phase, OpenAIRealtimeVoicePhase.failed);
      expect(session.state.failure, OpenAIRealtimeVoiceFailure.session);
      expect(provider.calls, 1);
      expect(transport.connectCalls, 1);
    },
  );

  // Required test 17 (pre-response death, live session): terminal, no retry.
  test('a pre-response transport death is terminal with no retry', () async {
    await reachListening(session, transport);
    transport.endEvents();
    await pumpEventLoop();
    expect(session.state.phase, OpenAIRealtimeVoicePhase.failed);
    expect(session.state.failure, OpenAIRealtimeVoiceFailure.transport);
    expect(provider.calls, 1);
    expect(transport.connectCalls, 1);
    expect(_countSent(transport, 'response.create'), 0);
  });

  // Required test 17 (post-response death): terminal transport loss, no retry.
  test(
    'a post-response transport death is a transport failure, no retry',
    () async {
      await reachListening(session, transport);
      transport.emit(_responseCreated('r1'));
      await pumpEventLoop();
      transport.endEvents();
      await pumpEventLoop();
      expect(session.state.phase, OpenAIRealtimeVoicePhase.failed);
      expect(session.state.failure, OpenAIRealtimeVoiceFailure.transport);
      expect(provider.calls, 1);
      expect(transport.connectCalls, 1);
      expect(_countSent(transport, 'response.create'), 0);
    },
  );

  // Required test 18.
  test(
    'the idle watchdog only counts events of the current response_id',
    () async {
      final factory = FakeWatchdogTimerFactory();
      final t = FakeRealtimeVoiceTransport();
      final s = build(t: t, timerFactory: factory.call);
      addTearDown(s.dispose);

      await reachListening(s, t);
      t.emit(_responseCreated('r1'));
      await pumpEventLoop();
      // Armed once.
      expect(factory.created.length, 1);

      // A different response_id never kicks the watchdog.
      t.emit(_audioDelta('r2'));
      await pumpEventLoop();
      expect(factory.created.length, 1);

      // The current response_id kicks it (a new timer replaces the old).
      t.emit(_audioDelta('r1'));
      await pumpEventLoop();
      expect(factory.created.length, 2);
      expect(factory.created.first.isCancelled, isTrue);
    },
  );

  // Required test 19.
  test(
    'an idle timeout is one terminal responseTimeout with one cleanup',
    () async {
      final factory = FakeWatchdogTimerFactory();
      final t = FakeRealtimeVoiceTransport();
      final s = build(t: t, timerFactory: factory.call);
      addTearDown(s.dispose);

      await reachListening(s, t);
      t.emit(_responseCreated('r1'));
      await pumpEventLoop();

      // The active response goes idle → the live watchdog fires.
      factory.active!.fire();
      await pumpEventLoop();

      expect(s.state.phase, OpenAIRealtimeVoicePhase.failed);
      expect(s.state.failure, OpenAIRealtimeVoiceFailure.responseTimeout);
      expect(_countSent(t, 'response.cancel'), 1);
      expect(_countSent(t, 'output_audio_buffer.clear'), 1);
      expect(t.closeCalls, 1);
      expect(provider.calls, 1);
      // No live watchdog remains, and no second mint/response.
      expect(factory.active, isNull);
      expect(_countSent(t, 'response.create'), 0);
    },
  );

  // Required test 20 (mint leak): the provider's secret-laden exception surfaces
  // only as a coarse enum.
  test(
    'a mint failure surfaces only a coarse failure, no secret leak',
    () async {
      provider.throwError = Exception(
        'super-secret /private/tmp/x sdp v=0=leak',
      );
      await session.start();
      await pumpEventLoop();
      expect(session.state.phase, OpenAIRealtimeVoicePhase.failed);
      expect(session.state.failure, OpenAIRealtimeVoiceFailure.mint);
      expect(session.state.toString().contains('secret'), isFalse);
      expect(session.state.toString().contains('v=0'), isFalse);
    },
  );

  // Required test 20 (event leak): a raw error payload never reaches state.
  test(
    'an error event with a secret payload surfaces only a coarse failure',
    () async {
      await reachListening(session, transport);
      transport.emit(_responseCreated('r1'));
      await pumpEventLoop();
      transport.emit(<String, Object?>{
        'type': 'error',
        'error': <String, Object?>{
          'message': 'super-secret-native-detail',
          'code': 'x',
          'event_id': 'evt_123',
        },
      });
      await pumpEventLoop();
      expect(session.state.phase, OpenAIRealtimeVoicePhase.failed);
      expect(session.state.failure, OpenAIRealtimeVoiceFailure.transport);
      expect(session.state.toString().contains('secret'), isFalse);
      expect(session.state.toString().contains('evt_123'), isFalse);
      expect(transport.connectCalls, 1); // no reconnect
    },
  );

  // A stop() before any start() is an idempotent no-op.
  test('stop and dispose are idempotent before start', () async {
    await session.stop();
    await session.stop();
    expect(session.state.phase, OpenAIRealtimeVoicePhase.idle);
    await session.dispose();
    await session.dispose();
    expect(session.state.phase, OpenAIRealtimeVoicePhase.idle);
  });

  // ---- Defect 1: response.done status + strict id attribution ------------
  group('response.done status & strict id attribution (defect 1)', () {
    test('a cancelled response.done is a terminal transport failure', () async {
      await reachListening(session, transport);
      transport.emit(_responseCreated('r1'));
      await pumpEventLoop();
      transport.emit(_responseDone('r1', status: 'cancelled'));
      await pumpEventLoop();
      expect(session.state.phase, OpenAIRealtimeVoicePhase.failed);
      expect(session.state.failure, OpenAIRealtimeVoiceFailure.transport);
      expect(transport.closeCalls, 1);
    });

    test(
      'failed/incomplete/missing/unknown status is terminal transport',
      () async {
        for (final status in <String?>['failed', 'incomplete', null, 'weird']) {
          final t = FakeRealtimeVoiceTransport();
          final s = build(t: t);
          addTearDown(s.dispose);
          await reachListening(s, t);
          t.emit(_responseCreated('r1'));
          await pumpEventLoop();
          t.emit(_responseDone('r1', status: status));
          await pumpEventLoop();
          expect(
            s.state.phase,
            OpenAIRealtimeVoicePhase.failed,
            reason: '$status',
          );
          expect(
            s.state.failure,
            OpenAIRealtimeVoiceFailure.transport,
            reason: '$status',
          );
        }
      },
    );

    test(
      'an id-less response.created during a live session is terminal transport',
      () async {
        await reachListening(session, transport);
        transport.emit(<String, Object?>{
          'type': 'response.created',
          'response': <String, Object?>{},
        });
        await pumpEventLoop();
        expect(session.state.phase, OpenAIRealtimeVoicePhase.failed);
        expect(session.state.failure, OpenAIRealtimeVoiceFailure.transport);
      },
    );

    test(
      'a repeat response.created does not rebind or reset the response',
      () async {
        final factory = FakeWatchdogTimerFactory();
        final t = FakeRealtimeVoiceTransport();
        final s = build(t: t, timerFactory: factory.call);
        addTearDown(s.dispose);
        await reachListening(s, t);
        t.emit(_responseCreated('r1'));
        await pumpEventLoop();
        expect(factory.created.length, 1);
        // A second response.created (even with a new id) is ignored — no rebind,
        // no reset, no watchdog kick.
        t.emit(_responseCreated('r2'));
        await pumpEventLoop();
        expect(factory.created.length, 1);
        // Completion still keys off the ORIGINAL response id only.
        t.emit(_responseDone('r1', status: 'completed'));
        t.emit(_outputStopped('r1'));
        await pumpEventLoop();
        expect(s.state.phase, OpenAIRealtimeVoicePhase.ended);
      },
    );

    test(
      'a late response.done for an abandoned barged-in response is inert',
      () async {
        final t = FakeRealtimeVoiceTransport();
        final s = build(mode: OpenAIRealtimeVoiceMode.conversation, t: t);
        addTearDown(s.dispose);
        await reachListening(s, t);
        t.emit(_responseCreated('r1'));
        await pumpEventLoop();
        // Barge-in abandons r1.
        t.emit(_speechStarted('u1'));
        await pumpEventLoop();
        expect(s.state.phase, OpenAIRealtimeVoicePhase.userSpeaking);
        // A late completed done + stopped for the abandoned r1 changes nothing.
        t.emit(_responseDone('r1', status: 'completed'));
        t.emit(_outputStopped('r1'));
        await pumpEventLoop();
        expect(s.state.phase, OpenAIRealtimeVoicePhase.userSpeaking);
        expect(t.closeCalls, 0);
      },
    );

    test(
      'completion events with a foreign or missing id are ignored',
      () async {
        await reachListening(session, transport);
        transport.emit(_responseCreated('r1'));
        await pumpEventLoop();
        // Foreign done and id-less stopped are ignored (no failure, no ended).
        transport.emit(_responseDone('r2', status: 'completed'));
        transport.emit(<String, Object?>{
          'type': 'output_audio_buffer.stopped',
        });
        await pumpEventLoop();
        expect(session.state.phase, OpenAIRealtimeVoicePhase.assistantSpeaking);
        expect(session.state.failure, isNull);
        // The matching completed done alone still does not end singleTurn.
        transport.emit(_responseDone('r1', status: 'completed'));
        await pumpEventLoop();
        expect(session.state.phase, OpenAIRealtimeVoicePhase.assistantSpeaking);
      },
    );
  });

  // ---- Defect 2: strict watchdog progress attribution --------------------
  group('watchdog progress attribution (defect 2)', () {
    Future<(FakeWatchdogTimerFactory, FakeRealtimeVoiceTransport)>
    armed() async {
      final factory = FakeWatchdogTimerFactory();
      final t = FakeRealtimeVoiceTransport();
      final s = build(t: t, timerFactory: factory.call);
      addTearDown(s.dispose);
      await reachListening(s, t);
      t.emit(_responseCreated('r1'));
      await pumpEventLoop();
      expect(factory.created.length, 1);
      return (factory, t);
    }

    test('a foreign response progress event does not kick', () async {
      final (factory, t) = await armed();
      t.emit(_audioDelta('r2'));
      await pumpEventLoop();
      expect(factory.created.length, 1);
    });

    test('a missing-id progress event does not kick', () async {
      final (factory, t) = await armed();
      t.emit(<String, Object?>{
        'type': 'response.output_audio.delta',
        'delta': 'YXVkaW8=',
      });
      await pumpEventLoop();
      expect(factory.created.length, 1);
    });

    test('unknown / rate-limit events do not kick', () async {
      final (factory, t) = await armed();
      t.emit(<String, Object?>{
        'type': 'rate_limits.updated',
        'response_id': 'r1',
      });
      t.emit(<String, Object?>{
        'type': 'some.unknown.event',
        'response_id': 'r1',
      });
      await pumpEventLoop();
      expect(factory.created.length, 1);
    });

    test('empty or malformed delta look-alikes do not kick', () async {
      final (factory, t) = await armed();
      // Structurally valid otherwise, but the delta itself is empty / non-string.
      t.emit(<String, Object?>{
        'type': 'response.output_audio.delta',
        'response_id': 'r1',
        'item_id': 'item_1',
        'output_index': 0,
        'content_index': 0,
        'delta': '',
      });
      t.emit(<String, Object?>{
        'type': 'response.output_audio.delta',
        'response_id': 'r1',
        'item_id': 'item_1',
        'output_index': 0,
        'content_index': 0,
        'delta': 123,
      });
      await pumpEventLoop();
      expect(factory.created.length, 1);
    });

    test('a known progress event of the current response kicks', () async {
      final (factory, t) = await armed();
      t.emit(_audioDelta('r1'));
      await pumpEventLoop();
      expect(factory.created.length, 2);
      t.emit(<String, Object?>{
        'type': 'output_audio_buffer.started',
        'response_id': 'r1',
      });
      await pumpEventLoop();
      expect(factory.created.length, 3);
    });

    // Per-family type-specific matrix (P1): for EACH whitelisted progress
    // family a malformed variant must NOT kick, while the minimal correct
    // variant MUST kick.
    test(
      'malformed per-family look-alikes never kick; minimal valid ones do',
      () async {
        // (name, malformed, validMinimal) — all bound to the active id 'r1'.
        final families = <(String, Map<String, Object?>, Map<String, Object?>)>[
          (
            'output_audio.delta',
            <String, Object?>{
              'type': 'response.output_audio.delta',
              'response_id': 'r1',
              'item_id': '', // empty item_id
              'output_index': 0,
              'content_index': 0,
              'delta': 'd',
            },
            <String, Object?>{
              'type': 'response.output_audio.delta',
              'response_id': 'r1',
              'item_id': 'i',
              'output_index': 0,
              'content_index': 0,
              'delta': 'd',
            },
          ),
          (
            'output_audio_transcript.delta',
            <String, Object?>{
              'type': 'response.output_audio_transcript.delta',
              'response_id': 'r1',
              'item_id': 'i',
              'output_index': -1, // negative index
              'content_index': 0,
              'delta': 'd',
            },
            <String, Object?>{
              'type': 'response.output_audio_transcript.delta',
              'response_id': 'r1',
              'item_id': 'i',
              'output_index': 0,
              'content_index': 0,
              'delta': 'd',
            },
          ),
          (
            'output_audio.done',
            <String, Object?>{
              'type': 'response.output_audio.done',
              'response_id': 'r1',
              'item_id': 'i',
              'output_index': 0,
              // content_index missing
            },
            <String, Object?>{
              'type': 'response.output_audio.done',
              'response_id': 'r1',
              'item_id': 'i',
              'output_index': 0,
              'content_index': 0,
            },
          ),
          (
            'output_audio_transcript.done',
            <String, Object?>{
              'type': 'response.output_audio_transcript.done',
              'response_id': 'r1',
              'item_id': 'i',
              'output_index': 0,
              'content_index': 0,
              // transcript missing
            },
            <String, Object?>{
              'type': 'response.output_audio_transcript.done',
              'response_id': 'r1',
              'item_id': 'i',
              'output_index': 0,
              'content_index': 0,
              'transcript': 't',
            },
          ),
          (
            'content_part.added',
            <String, Object?>{
              'type': 'response.content_part.added',
              'response_id': 'r1',
              'item_id': 'i',
              'output_index': 0,
              'content_index': 0,
              'part': 'not-a-map', // part not a Map
            },
            <String, Object?>{
              'type': 'response.content_part.added',
              'response_id': 'r1',
              'item_id': 'i',
              'output_index': 0,
              'content_index': 0,
              'part': <String, Object?>{},
            },
          ),
          (
            'content_part.done',
            <String, Object?>{
              'type': 'response.content_part.done',
              'response_id': 'r1',
              'item_id': '', // empty item_id
              'output_index': 0,
              'content_index': 0,
              'part': <String, Object?>{},
            },
            <String, Object?>{
              'type': 'response.content_part.done',
              'response_id': 'r1',
              'item_id': 'i',
              'output_index': 0,
              'content_index': 0,
              'part': <String, Object?>{},
            },
          ),
          (
            'output_item.added',
            <String, Object?>{
              'type': 'response.output_item.added',
              'response_id': 'r1',
              'output_index': 0,
              'item': <String, Object?>{}, // item without a type
            },
            <String, Object?>{
              'type': 'response.output_item.added',
              'response_id': 'r1',
              'output_index': 0,
              'item': <String, Object?>{'type': 'message'},
            },
          ),
          (
            'output_item.done',
            <String, Object?>{
              'type': 'response.output_item.done',
              'response_id': 'r1',
              'output_index': -1, // negative index
              'item': <String, Object?>{'type': 'message'},
            },
            <String, Object?>{
              'type': 'response.output_item.done',
              'response_id': 'r1',
              'output_index': 0,
              'item': <String, Object?>{'type': 'message'},
            },
          ),
          (
            'output_audio_buffer.started',
            <String, Object?>{
              'type': 'output_audio_buffer.started',
              'response_id': 'r2', // foreign id
            },
            <String, Object?>{
              'type': 'output_audio_buffer.started',
              'response_id': 'r1',
            },
          ),
        ];

        final factory = FakeWatchdogTimerFactory();
        final t = FakeRealtimeVoiceTransport();
        final s = build(t: t, timerFactory: factory.call);
        addTearDown(s.dispose);
        await reachListening(s, t);
        t.emit(_responseCreated('r1'));
        await pumpEventLoop();
        var count = 1;
        expect(factory.created.length, count);

        for (final (name, malformed, valid) in families) {
          t.emit(malformed);
          await pumpEventLoop();
          expect(
            factory.created.length,
            count,
            reason: '$name malformed must NOT kick',
          );
          t.emit(valid);
          await pumpEventLoop();
          count++;
          expect(
            factory.created.length,
            count,
            reason: '$name minimal valid MUST kick',
          );
        }
      },
    );
  });

  // ---- Defect 6: lifecycle after dispose ---------------------------------
  group('lifecycle after dispose (defect 6)', () {
    test('start() after dispose is rejected with zero mint/connect', () async {
      await session.dispose();
      await expectLater(session.start(), throwsA(isA<StateError>()));
      expect(provider.calls, 0);
      expect(transport.connectCalls, 0);
    });

    test('start() after a started-then-disposed session is rejected', () async {
      await reachListening(session, transport);
      await session.dispose();
      await expectLater(session.start(), throwsA(isA<StateError>()));
      // Only the original mint/connect happened; no second one.
      expect(provider.calls, 1);
      expect(transport.connectCalls, 1);
    });

    test('repeat dispose and a stop after dispose stay safe', () async {
      await session.dispose();
      await session.dispose();
      await session.stop();
      expect(session.state.phase, OpenAIRealtimeVoicePhase.idle);
    });

    test(
      'dispose during an active start cancels and releases the session',
      () async {
        transport.connectGate = Completer<void>();
        final startFuture = session.start();
        await pumpEventLoop();
        expect(transport.connectCalls, 1);
        final disposeFuture = session.dispose();
        transport.connectGate!.complete();
        await startFuture;
        await disposeFuture;
        await pumpEventLoop();
        expect(transport.closeCalls, 1);
        expect(session.state.phase, OpenAIRealtimeVoicePhase.ended);
      },
    );
  });

  // ---- Defect 7: audio-readiness race ------------------------------------
  test(
    'an early session.updated during connect enables the mic only after connect (defect 7)',
    () async {
      transport.connectGate = Completer<void>();
      final startFuture = session.start();
      await pumpEventLoop();
      expect(transport.connectCalls, 1);

      // session.created + session.updated arrive over the DataChannel while
      // connect() is still in flight.
      transport.emit(_created);
      transport.emit(_updated);
      await pumpEventLoop();

      // The update is sent once, but the mic stays OFF until connect returns.
      expect(_countSent(transport, 'session.update'), 1);
      expect(transport.enabledCalls.where((e) => e).isEmpty, isTrue);
      expect(session.state.phase, isNot(OpenAIRealtimeVoicePhase.listening));

      // connect() completes → the mic is enabled exactly once, phase listening.
      transport.connectGate!.complete();
      await startFuture;
      await pumpEventLoop();
      expect(transport.enabledCalls.where((e) => e).length, 1);
      expect(session.state.phase, OpenAIRealtimeVoicePhase.listening);
      expect(_countSent(transport, 'session.update'), 1);
    },
  );

  // ---- Lost response.done after output_audio_buffer.stopped --------------
  // The turn must never hang: output_audio_buffer.stopped re-arms the existing
  // watchdog for a fresh idle period; a completed response.done cancels it, its
  // loss ends the session with exactly one responseTimeout.
  group('lost response.done after output_audio_buffer.stopped', () {
    // task test 1.
    test(
      'stopped with no matching done -> one responseTimeout, one close',
      () async {
        final factory = FakeWatchdogTimerFactory();
        final t = FakeRealtimeVoiceTransport();
        final s = build(t: t, timerFactory: factory.call);
        addTearDown(s.dispose);
        await reachListening(s, t);
        t.emit(_responseCreated('r1'));
        await pumpEventLoop();
        t.emit(
          _outputStopped('r1'),
        ); // audio stopped, response.done not (yet) here
        await pumpEventLoop();
        // The watchdog is re-armed rather than left disarmed.
        expect(factory.active, isNotNull);

        factory.active!.fire();
        await pumpEventLoop();
        expect(s.state.phase, OpenAIRealtimeVoicePhase.failed);
        expect(s.state.failure, OpenAIRealtimeVoiceFailure.responseTimeout);
        expect(t.closeCalls, 1);
        // Playback is already over: no extra cancel/clear.
        expect(_countSent(t, 'response.cancel'), 0);
        expect(_countSent(t, 'output_audio_buffer.clear'), 0);
        // No retry/reconnect/re-mint/new Response.
        expect(provider.calls, 1);
        expect(t.connectCalls, 1);
        expect(_countSent(t, 'response.create'), 0);
        expect(factory.active, isNull);
      },
    );

    // task test 2.
    test(
      'stopped then a completed done before deadline -> ended, no failure',
      () async {
        final factory = FakeWatchdogTimerFactory();
        final t = FakeRealtimeVoiceTransport();
        final s = build(t: t, timerFactory: factory.call);
        addTearDown(s.dispose);
        await reachListening(s, t);
        t.emit(_responseCreated('r1'));
        await pumpEventLoop();
        t.emit(_outputStopped('r1'));
        await pumpEventLoop();
        final armed = factory.active;
        expect(armed, isNotNull);

        t.emit(_responseDone('r1')); // completed, before the deadline fires
        await pumpEventLoop();
        expect(
          armed!.isCancelled,
          isTrue,
        ); // the re-armed deadline was cancelled
        expect(s.state.phase, OpenAIRealtimeVoicePhase.ended);
        expect(s.state.failure, isNull);
        expect(t.closeCalls, 1);
      },
    );

    // task test 3 (reverse order preserved).
    test('a completed done then stopped still ends successfully', () async {
      final t = FakeRealtimeVoiceTransport();
      final s = build(t: t);
      addTearDown(s.dispose);
      await reachListening(s, t);
      t.emit(_responseCreated('r1'));
      await pumpEventLoop();
      t.emit(_responseDone('r1')); // done first (waits for stopped)
      t.emit(_outputStopped('r1'));
      await pumpEventLoop();
      expect(s.state.phase, OpenAIRealtimeVoicePhase.ended);
      expect(s.state.failure, isNull);
      expect(t.closeCalls, 1);
    });

    // task test 4 (duplicate stopped).
    test('a duplicate stopped never re-arms a second deadline', () async {
      final factory = FakeWatchdogTimerFactory();
      final t = FakeRealtimeVoiceTransport();
      final s = build(
        mode: OpenAIRealtimeVoiceMode.conversation,
        t: t,
        timerFactory: factory.call,
      );
      addTearDown(s.dispose);
      await reachListening(s, t);
      t.emit(_responseCreated('r1'));
      await pumpEventLoop();
      t.emit(_outputStopped('r1'));
      await pumpEventLoop();
      final createdAfterFirst = factory.created.length;
      // A duplicate output_audio_buffer.stopped for the same response.
      t.emit(_outputStopped('r1'));
      await pumpEventLoop();
      expect(factory.created.length, createdAfterFirst); // no new deadline
      expect(s.state.phase, isNot(OpenAIRealtimeVoicePhase.failed));
      expect(s.state.phase, isNot(OpenAIRealtimeVoicePhase.ended));
      expect(t.closeCalls, 0);
    });

    // task test 5 (foreign done after stopped keeps the deadline).
    test(
      'a foreign done after stopped does not complete; deadline -> timeout',
      () async {
        final factory = FakeWatchdogTimerFactory();
        final t = FakeRealtimeVoiceTransport();
        final s = build(t: t, timerFactory: factory.call);
        addTearDown(s.dispose);
        await reachListening(s, t);
        t.emit(_responseCreated('r1'));
        await pumpEventLoop();
        t.emit(_outputStopped('r1'));
        await pumpEventLoop();
        final armed = factory.active;
        expect(armed, isNotNull);
        // A foreign response.done (different id) never satisfies completion...
        t.emit(_responseDone('other'));
        await pumpEventLoop();
        expect(
          armed!.isCancelled,
          isFalse,
        ); // the original deadline still stands
        expect(s.state.phase, isNot(OpenAIRealtimeVoicePhase.ended));
        // ...and the deadline yields exactly one responseTimeout.
        armed.fire();
        await pumpEventLoop();
        expect(s.state.phase, OpenAIRealtimeVoicePhase.failed);
        expect(s.state.failure, OpenAIRealtimeVoiceFailure.responseTimeout);
        expect(t.closeCalls, 1);
      },
    );
  });
}
