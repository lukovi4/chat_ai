// The initial-history contract: the pure ChatConversation → conversation.item.create
// mapper (exact mapping / filtering) and the session's one-at-a-time seeding flow
// (each item waits for a well-formed conversation.item.added, bounded by
// responseIdleTimeout; the mic is off until the whole history is acknowledged; an
// error, a transport death or a lost ack during loading is terminal).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_ai/chat_ai.dart';
import 'package:chat_ai_openai_realtime_voice/chat_ai_openai_realtime_voice.dart';
import 'package:chat_ai_openai_realtime_voice/src/voice_history.dart';
import 'package:chat_ai_openai_realtime_voice/src/voice_session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

final DateTime _t = DateTime.utc(2026, 7, 24);

Message _user(
  String id,
  List<ContentPart> parts, {
  MessageStatus status = MessageStatus.sent,
}) => Message(
  id: id,
  role: MessageRole.user,
  parts: parts,
  status: status,
  createdAt: _t,
);

Message _assistant(
  String id,
  List<ContentPart> parts, {
  MessageStatus status = MessageStatus.complete,
}) => Message(
  id: id,
  role: MessageRole.assistant,
  parts: parts,
  status: status,
  createdAt: _t,
);

Message _system(String id, String text) => Message(
  id: id,
  role: MessageRole.system,
  parts: <ContentPart>[ContentPart.text(text)],
  status: MessageStatus.complete,
  createdAt: _t,
);

/// A well-formed server acknowledgement. The [id] is whatever the SERVER
/// assigned — the session never correlates it with a client-side id.
Map<String, Object?> _ack([String id = 'item_srv_1']) => <String, Object?>{
  'type': 'conversation.item.added',
  'item': <String, Object?>{'id': id},
};

Map<String, Object?> _created = <String, Object?>{'type': 'session.created'};
Map<String, Object?> _updated = <String, Object?>{'type': 'session.updated'};

int _countSent(FakeRealtimeVoiceTransport t, String type) =>
    t.sent.where((e) => e['type'] == type).length;

List<Map<String, Object?>> _creates(FakeRealtimeVoiceTransport t) => t.sent
    .where((e) => e['type'] == 'conversation.item.create')
    .cast<Map<String, Object?>>()
    .toList();

void main() {
  // ======================================================================
  // Pure mapper
  // ======================================================================
  group('prepareInitialHistory mapping & filtering', () {
    test('exact mapping and order of every allowed part', () {
      final image = Uint8List.fromList(<int>[1, 2, 3]);
      final conversation = Conversation(
        messages: <Message>[
          _system('s1', 'be a helpful bot'),
          _user('u1', <ContentPart>[
            ContentPart.text('hello'),
            ContentPart.image(image),
          ]),
          _assistant('a1', <ContentPart>[
            ContentPart.text('hi there'),
            ContentPart.toolCall('c1', 'get_time', <String, dynamic>{
              'tz': 'UTC',
            }),
            ContentPart.toolResult('c1', '12:00', false),
          ]),
        ],
      );

      final wire = prepareInitialHistory(conversation);

      // Order: system, user (text + image), assistant text, function_call,
      // function_call_output.
      expect(wire.length, 5);

      expect(wire[0]['type'], 'message');
      expect(wire[0]['role'], 'system');
      expect(wire[0]['content'], <Map<String, Object?>>[
        <String, Object?>{'type': 'input_text', 'text': 'be a helpful bot'},
      ]);

      expect(wire[1]['role'], 'user');
      final userContent = wire[1]['content']! as List<Object?>;
      expect(userContent[0], <String, Object?>{
        'type': 'input_text',
        'text': 'hello',
      });
      expect((userContent[1]! as Map)['type'], 'input_image');
      expect(
        (userContent[1]! as Map)['image_url'],
        'data:image/jpeg;base64,${base64Encode(image)}',
      );

      expect(wire[2]['role'], 'assistant');
      expect(wire[2]['content'], <Map<String, Object?>>[
        <String, Object?>{'type': 'output_text', 'text': 'hi there'},
      ]);

      expect(wire[3]['type'], 'function_call');
      expect(wire[3]['call_id'], 'c1');
      expect(wire[3]['name'], 'get_time');
      expect(wire[3]['arguments'], jsonEncode(<String, dynamic>{'tz': 'UTC'}));

      expect(wire[4]['type'], 'function_call_output');
      expect(wire[4]['call_id'], 'c1');
      expect(
        wire[4]['output'],
        jsonEncode(<String, Object?>{'content': '12:00', 'isError': false}),
      );

      // No client-side item id rides on the wire: the server assigns ids.
      expect(wire.any((e) => e.containsKey('id')), isFalse);
    });

    test('failed user messages are excluded; sent are kept', () {
      final conversation = Conversation(
        messages: <Message>[
          _user('u1', <ContentPart>[
            ContentPart.text('kept'),
          ], status: MessageStatus.sent),
          _user('u2', <ContentPart>[
            ContentPart.text('dropped'),
          ], status: MessageStatus.failed),
        ],
      );
      final wire = prepareInitialHistory(conversation);
      expect(wire.length, 1);
      expect((wire.single['content']! as List).first, <String, Object?>{
        'type': 'input_text',
        'text': 'kept',
      });
    });

    test('an incomplete tool call and an orphan tool result are dropped', () {
      final conversation = Conversation(
        messages: <Message>[
          // A tool call with NO matching result → dropped.
          _assistant('a1', <ContentPart>[
            ContentPart.text('thinking'),
            ContentPart.toolCall('c1', 'f', <String, dynamic>{}),
          ]),
          // An orphan tool result (no call) → dropped, but the text stays.
          _assistant('a2', <ContentPart>[
            ContentPart.text('answer'),
            ContentPart.toolResult('c-orphan', 'x', false),
          ]),
        ],
      );
      final wire = prepareInitialHistory(conversation);
      // a1: only the text (call dropped). a2: only the text (orphan dropped).
      expect(wire.length, 2);
      expect(wire.every((e) => e['type'] == 'message'), isTrue);
      expect(wire.any((e) => e['type'] == 'function_call'), isFalse);
      expect(wire.any((e) => e['type'] == 'function_call_output'), isFalse);
    });

    test('ProviderOpaquePart is dropped and an empty assistant is dropped', () {
      final conversation = Conversation(
        messages: <Message>[
          // Only opaque + an incomplete tool call → nothing to send → dropped.
          _assistant('a1', <ContentPart>[
            ContentPart.providerOpaque('openai', Uint8List.fromList(<int>[9])),
            ContentPart.toolCall('c1', 'f', <String, dynamic>{}),
          ]),
          _user('u1', <ContentPart>[
            ContentPart.text('real'),
            ContentPart.providerOpaque('openai', Uint8List.fromList(<int>[1])),
          ]),
        ],
      );
      final wire = prepareInitialHistory(conversation);
      // The empty assistant is gone; the user keeps only its text.
      expect(wire.length, 1);
      expect(wire.single['role'], 'user');
      expect((wire.single['content']! as List).length, 1);
    });

    test('an interrupted assistant is preserved', () {
      final conversation = Conversation(
        messages: <Message>[
          _assistant('a1', <ContentPart>[
            ContentPart.text('partial'),
          ], status: MessageStatus.interrupted),
        ],
      );
      final wire = prepareInitialHistory(conversation);
      expect(wire.length, 1);
      expect(wire.single['role'], 'assistant');
    });

    test('schemaVersion != 1 is rejected synchronously', () {
      final conversation = Conversation(
        schemaVersion: 2,
        messages: <Message>[
          _user('u1', <ContentPart>[ContentPart.text('x')]),
        ],
      );
      expect(() => prepareInitialHistory(conversation), throwsArgumentError);
    });

    test('a sending user is rejected; a streaming assistant is rejected', () {
      final sending = Conversation(
        messages: <Message>[
          _user('u1', <ContentPart>[
            ContentPart.text('x'),
          ], status: MessageStatus.sending),
        ],
      );
      expect(() => prepareInitialHistory(sending), throwsArgumentError);

      final streaming = Conversation(
        messages: <Message>[
          _assistant('a1', <ContentPart>[
            ContentPart.text('x'),
          ], status: MessageStatus.streaming),
        ],
      );
      expect(() => prepareInitialHistory(streaming), throwsArgumentError);
    });
  });

  // ======================================================================
  // Session-level validation & seeding
  // ======================================================================
  group('session seeding', () {
    late FakeClientSecretProvider provider;
    late FakeRealtimeVoiceTransport transport;

    setUp(() {
      provider = FakeClientSecretProvider();
      transport = FakeRealtimeVoiceTransport();
    });

    OpenAIRealtimeVoiceSession build(
      Conversation? history, {
      Timer Function(Duration, void Function())? timerFactory,
    }) => voiceSessionForTesting(
      clientSecretProvider: provider,
      botProfile: botProfile(),
      transportFactory: () => transport,
      mode: OpenAIRealtimeVoiceMode.conversation,
      initialConversation: history,
      timerFactory: timerFactory ?? FakeWatchdogTimerFactory().call,
    );

    /// Starts [s] and drives it to the point where the first history item has
    /// been sent (session.created → session.update → session.updated).
    Future<void> startAndSeed(OpenAIRealtimeVoiceSession s) async {
      await s.start();
      transport.emit(_created);
      await pumpEventLoop();
      transport.emit(_updated);
      await pumpEventLoop();
    }

    Conversation twoUserMessages() => Conversation(
      messages: <Message>[
        _user('u1', <ContentPart>[ContentPart.text('one')]),
        _user('u2', <ContentPart>[ContentPart.text('two')]),
      ],
    );

    /// The first `input_text` of a sent `conversation.item.create`.
    String createdText(Map<String, Object?> create) {
      final item = create['item']! as Map<String, Object?>;
      final content = item['content']! as List<Object?>;
      return (content.first! as Map<String, Object?>)['text']! as String;
    }

    test('an invalid initialConversation is rejected before any mint', () {
      final sending = Conversation(
        messages: <Message>[
          _user('u1', <ContentPart>[
            ContentPart.text('x'),
          ], status: MessageStatus.sending),
        ],
      );
      expect(() => build(sending), throwsArgumentError);
      expect(provider.calls, 0);
    });

    test(
      'items go out one at a time; the mic is off until the last ack',
      () async {
        final s = build(twoUserMessages());
        addTearDown(s.dispose);
        await startAndSeed(s);

        // Only the first item is out; no mic yet.
        var creates = _creates(transport);
        expect(creates.length, 1);
        expect(createdText(creates[0]), 'one');
        expect(transport.enabledCalls.where((e) => e).isEmpty, isTrue);
        expect(s.state.phase, isNot(OpenAIRealtimeVoicePhase.listening));

        // The ack releases the second item — and only the second.
        transport.emit(_ack());
        await pumpEventLoop();
        creates = _creates(transport);
        expect(creates.length, 2);
        expect(createdText(creates[1]), 'two');
        // Still no mic until the LAST ack.
        expect(transport.enabledCalls.where((e) => e).isEmpty, isTrue);
        expect(s.state.phase, isNot(OpenAIRealtimeVoicePhase.listening));

        // The final ack arms the mic — and sends nothing more.
        transport.emit(_ack());
        await pumpEventLoop();
        expect(_creates(transport).length, 2);
        expect(transport.enabledCalls.where((e) => e).length, 1);
        expect(s.state.phase, OpenAIRealtimeVoicePhase.listening);
      },
    );

    test(
      'a well-formed ack confirms the pending item whatever its id is',
      () async {
        final s = build(twoUserMessages());
        addTearDown(s.dispose);
        await startAndSeed(s);
        expect(_creates(transport).length, 1);

        // Server-assigned ids the client has never seen still acknowledge the
        // one item in flight (no client-side id correlation).
        transport.emit(_ack('item_ABC123xyz'));
        await pumpEventLoop();
        expect(_creates(transport).length, 2);

        transport.emit(_ack('msg_totally_unrelated_9'));
        await pumpEventLoop();
        expect(transport.enabledCalls.where((e) => e).length, 1);
        expect(s.state.phase, OpenAIRealtimeVoicePhase.listening);
      },
    );

    test('a malformed conversation.item.added confirms nothing', () async {
      final s = build(twoUserMessages());
      addTearDown(s.dispose);
      await startAndSeed(s);
      expect(_creates(transport).length, 1);

      // No item / a non-Map item / an empty or non-String item.id.
      transport.emit(<String, Object?>{'type': 'conversation.item.added'});
      transport.emit(<String, Object?>{
        'type': 'conversation.item.added',
        'item': 'not-a-map',
      });
      transport.emit(<String, Object?>{
        'type': 'conversation.item.added',
        'item': <String, Object?>{'id': ''},
      });
      transport.emit(<String, Object?>{
        'type': 'conversation.item.added',
        'item': <String, Object?>{'id': 7},
      });
      transport.emit(<String, Object?>{
        'type': 'conversation.item.added',
        'item': <String, Object?>{'type': 'message'},
      });
      await pumpEventLoop();

      // Nothing advanced: still one item out, no mic, no failure.
      expect(_creates(transport).length, 1);
      expect(transport.enabledCalls.where((e) => e).isEmpty, isTrue);
      expect(s.state.phase, isNot(OpenAIRealtimeVoicePhase.listening));
      expect(s.state.failure, isNull);

      // The wait continues and a well-formed ack still releases the next item.
      transport.emit(_ack());
      await pumpEventLoop();
      expect(_creates(transport).length, 2);
    });

    test('only conversation.item.added acknowledges an item', () async {
      final s = build(twoUserMessages());
      addTearDown(s.dispose);
      await startAndSeed(s);
      expect(_creates(transport).length, 1);

      // The legacy `conversation.item.created` and the `conversation.item.done`
      // that follows a real `conversation.item.added` are NOT acknowledgements,
      // however well-formed they are.
      transport.emit(<String, Object?>{
        'type': 'conversation.item.created',
        'item': <String, Object?>{'id': 'item_srv_1'},
      });
      transport.emit(<String, Object?>{
        'type': 'conversation.item.done',
        'item': <String, Object?>{'id': 'item_srv_1'},
      });
      await pumpEventLoop();

      // Nothing advanced: still one item out, no mic, no failure.
      expect(_creates(transport).length, 1);
      expect(transport.enabledCalls.where((e) => e).isEmpty, isTrue);
      expect(s.state.phase, isNot(OpenAIRealtimeVoicePhase.listening));
      expect(s.state.failure, isNull);

      // The wait continues and the real ack still releases the next item.
      transport.emit(_ack());
      await pumpEventLoop();
      expect(_creates(transport).length, 2);
    });

    test(
      'a lost ack fails the session after responseIdleTimeout, once',
      () async {
        final timers = FakeWatchdogTimerFactory();
        final s = build(twoUserMessages(), timerFactory: timers.call);
        addTearDown(s.dispose);
        final states = <OpenAIRealtimeVoiceState>[];
        final sub = s.states.listen(states.add);
        addTearDown(sub.cancel);

        await startAndSeed(s);
        expect(_creates(transport).length, 1);

        // The ack deadline is the existing responseIdleTimeout (60s default).
        final deadline = timers.active;
        expect(deadline, isNotNull);
        expect(deadline!.duration, const Duration(seconds: 60));

        deadline.fire();
        await pumpEventLoop();

        expect(s.state.phase, OpenAIRealtimeVoicePhase.failed);
        expect(s.state.failure, OpenAIRealtimeVoiceFailure.session);
        // No mic, no second item, no retry / reconnect / re-mint, one teardown.
        expect(transport.enabledCalls.where((e) => e).isEmpty, isTrue);
        expect(_creates(transport).length, 1);
        expect(provider.calls, 1);
        expect(transport.connectCalls, 1);
        expect(transport.closeCalls, 1);
        expect(
          states
              .where((e) => e.phase == OpenAIRealtimeVoicePhase.failed)
              .length,
          1,
        );
        // The deadline is disarmed by the teardown.
        expect(timers.active, isNull);
      },
    );

    test('a late ack after the timeout is inert', () async {
      final timers = FakeWatchdogTimerFactory();
      final s = build(twoUserMessages(), timerFactory: timers.call);
      addTearDown(s.dispose);
      final states = <OpenAIRealtimeVoiceState>[];
      final sub = s.states.listen(states.add);
      addTearDown(sub.cancel);

      await startAndSeed(s);
      timers.active!.fire();
      // An ack queued in the very turn the deadline fired (the teardown has not
      // closed the transport yet) must be inert…
      transport.emit(_ack());
      await pumpEventLoop();
      final afterFailure = states.length;

      // …and so must one that arrives afterwards.
      transport.emit(_ack());
      await pumpEventLoop();

      expect(states.length, afterFailure);
      expect(s.state.phase, OpenAIRealtimeVoicePhase.failed);
      expect(s.state.failure, OpenAIRealtimeVoiceFailure.session);
      expect(_creates(transport).length, 1);
      expect(transport.enabledCalls.where((e) => e).isEmpty, isTrue);
      expect(transport.closeCalls, 1);
    });

    test('a late ack racing stop, and one after dispose, are inert', () async {
      final s = build(twoUserMessages());
      await startAndSeed(s);
      expect(_creates(transport).length, 1);

      // An ack already queued when stop() runs advances nothing.
      transport.emit(_ack());
      await s.stop();
      await pumpEventLoop();
      expect(s.state.phase, OpenAIRealtimeVoicePhase.ended);
      expect(_creates(transport).length, 1);
      expect(transport.enabledCalls.where((e) => e).isEmpty, isTrue);

      await s.dispose();
      await pumpEventLoop();
      // After dispose nothing reaches the (closed) state controller either.
      transport.emit(_ack());
      await pumpEventLoop();
      expect(_creates(transport).length, 1);
      expect(s.state.phase, OpenAIRealtimeVoicePhase.ended);
      expect(transport.closeCalls, 1);
    });

    // ---- Seeding waits for connect() AND session.updated -------------------

    test('an early session.updated during connect seeds nothing until connect '
        'returns', () async {
      final s = build(twoUserMessages());
      addTearDown(s.dispose);
      transport.connectGate = Completer<void>();
      final startFuture = s.start();
      await pumpEventLoop();
      expect(transport.connectCalls, 1);

      // session.created + session.updated arrive over the data channel while
      // connect() is STILL in flight.
      transport.emit(_created);
      transport.emit(_updated);
      await pumpEventLoop();

      // The session.update went out, but NO history item may ride a
      // not-yet-ready connection — and the mic stays off.
      expect(_countSent(transport, 'session.update'), 1);
      expect(_creates(transport), isEmpty);
      expect(transport.enabledCalls.where((e) => e).isEmpty, isTrue);
      expect(s.state.phase, isNot(OpenAIRealtimeVoicePhase.listening));

      // connect() returns → exactly the FIRST history item goes out.
      transport.connectGate!.complete();
      await startFuture;
      await pumpEventLoop();
      expect(_creates(transport).length, 1);
      expect(createdText(_creates(transport)[0]), 'one');
      expect(transport.enabledCalls.where((e) => e).isEmpty, isTrue);

      // The rest of the history proceeds normally; the last ack arms the mic.
      transport.emit(_ack());
      await pumpEventLoop();
      expect(_creates(transport).length, 2);
      transport.emit(_ack());
      await pumpEventLoop();
      expect(transport.enabledCalls.where((e) => e).length, 1);
      expect(s.state.phase, OpenAIRealtimeVoicePhase.listening);
    });

    test(
      'stop after an early session.updated seeds nothing, before or after the '
      'late connect',
      () async {
        final s = build(twoUserMessages());
        transport.connectGate = Completer<void>();
        final startFuture = s.start();
        await pumpEventLoop();

        transport.emit(_created);
        transport.emit(_updated);
        await pumpEventLoop();
        expect(_creates(transport), isEmpty);

        // The session is stopped while connect() is still pending.
        final stopFuture = s.stop();
        // connect() only returns afterwards — it must seed nothing either.
        transport.connectGate!.complete();
        await startFuture;
        await stopFuture;
        await pumpEventLoop();

        expect(_creates(transport), isEmpty);
        expect(transport.enabledCalls.where((e) => e).isEmpty, isTrue);
        // No second mint and no reconnect.
        expect(provider.calls, 1);
        expect(transport.connectCalls, 1);

        await s.dispose();
        await pumpEventLoop();
        expect(_creates(transport), isEmpty);
        expect(transport.enabledCalls.where((e) => e).isEmpty, isTrue);
        expect(provider.calls, 1);
        expect(transport.connectCalls, 1);
      },
    );

    // ---- The deadline bounds the SEND, not just the wait for the ack --------

    /// Drives [s] to the point where the FIRST `conversation.item.create` has
    /// been handed to the transport but its send Future is still PENDING, and
    /// returns the gate that releases it. (The fake records the event before
    /// awaiting the gate, so the create is observable while the send hangs.)
    Future<Completer<void>> startWithHungCreate(
      OpenAIRealtimeVoiceSession s,
    ) async {
      await s.start();
      transport.emit(_created);
      await pumpEventLoop();
      // Gate ONLY the history create — session.update has already gone out.
      final gate = Completer<void>();
      transport.sendGate = gate;
      transport.emit(_updated);
      await pumpEventLoop();
      return gate;
    }

    test('a hung conversation.item.create send fails the session after '
        'responseIdleTimeout', () async {
      final timers = FakeWatchdogTimerFactory();
      final s = build(twoUserMessages(), timerFactory: timers.call);
      addTearDown(s.dispose);
      final states = <OpenAIRealtimeVoiceState>[];
      final sub = s.states.listen(states.add);
      addTearDown(sub.cancel);

      final gate = await startWithHungCreate(s);
      // The item is on the wire but its send has NOT resolved.
      expect(_creates(transport).length, 1);

      // The deadline is armed BEFORE the send, so it bounds the hung send too.
      final deadline = timers.active;
      expect(deadline, isNotNull);
      expect(deadline!.duration, const Duration(seconds: 60));

      deadline.fire();
      await pumpEventLoop();

      expect(s.state.phase, OpenAIRealtimeVoicePhase.failed);
      expect(s.state.failure, OpenAIRealtimeVoiceFailure.session);
      // No mic, no second item, no retry / reconnect / re-mint, one teardown.
      expect(transport.enabledCalls.where((e) => e).isEmpty, isTrue);
      expect(_creates(transport).length, 1);
      expect(provider.calls, 1);
      expect(transport.connectCalls, 1);
      expect(transport.closeCalls, 1);
      expect(
        states.where((e) => e.phase == OpenAIRealtimeVoicePhase.failed).length,
        1,
      );
      // The deadline is disarmed by the teardown.
      expect(timers.active, isNull);

      // Leave nothing pending behind this test.
      transport.sendGate = null;
      gate.complete();
      await pumpEventLoop();
    });

    test('a late send SUCCESS after the timeout is inert', () async {
      final timers = FakeWatchdogTimerFactory();
      final s = build(twoUserMessages(), timerFactory: timers.call);
      addTearDown(s.dispose);
      final states = <OpenAIRealtimeVoiceState>[];
      final sub = s.states.listen(states.add);
      addTearDown(sub.cancel);

      final gate = await startWithHungCreate(s);
      timers.active!.fire();
      await pumpEventLoop();
      final afterFailure = states.length;

      // The send finally succeeds — long after the session died.
      transport.sendGate = null;
      gate.complete();
      await pumpEventLoop();

      // Nothing advances: no next item, no mic, no second failure or teardown.
      expect(_creates(transport).length, 1);
      expect(transport.enabledCalls.where((e) => e).isEmpty, isTrue);
      expect(states.length, afterFailure);
      expect(s.state.phase, OpenAIRealtimeVoicePhase.failed);
      expect(s.state.failure, OpenAIRealtimeVoiceFailure.session);
      expect(transport.closeCalls, 1);
    });

    test('a late send ERROR after the timeout is inert and raises no unhandled '
        'error', () async {
      final timers = FakeWatchdogTimerFactory();
      final s = build(twoUserMessages(), timerFactory: timers.call);
      addTearDown(s.dispose);
      final states = <OpenAIRealtimeVoiceState>[];
      final sub = s.states.listen(states.add);
      addTearDown(sub.cancel);

      final gate = await startWithHungCreate(s);
      timers.active!.fire();
      await pumpEventLoop();
      final afterFailure = states.length;

      // The send finally FAILS, after the teardown. The seeding loop swallows
      // it: no second failure, and no unhandled Zone error — which the test
      // binding would otherwise surface as a failure of this test.
      transport.sendGate = null;
      gate.completeError(StateError('late send failure'));
      await pumpEventLoop();

      expect(_creates(transport).length, 1);
      expect(transport.enabledCalls.where((e) => e).isEmpty, isTrue);
      expect(states.length, afterFailure);
      expect(s.state.phase, OpenAIRealtimeVoicePhase.failed);
      expect(s.state.failure, OpenAIRealtimeVoiceFailure.session);
      expect(transport.closeCalls, 1);
    });

    test(
      'an ack arriving while the send is pending continues the history',
      () async {
        final timers = FakeWatchdogTimerFactory();
        final s = build(twoUserMessages(), timerFactory: timers.call);
        addTearDown(s.dispose);

        final gate = await startWithHungCreate(s);
        expect(_creates(transport).length, 1);
        final firstDeadline = timers.active;
        expect(firstDeadline, isNotNull);

        // The server acknowledges while the send Future is STILL pending.
        transport.emit(_ack());
        await pumpEventLoop();
        // The ack is remembered and the first item's deadline is disarmed…
        expect(firstDeadline!.isCancelled, isTrue);
        // …but the loop cannot advance until the send itself resolves.
        expect(_creates(transport).length, 1);

        // The send completes: the second item goes out with its OWN deadline.
        transport.sendGate = null;
        gate.complete();
        await pumpEventLoop();
        expect(_creates(transport).length, 2);
        expect(createdText(_creates(transport)[1]), 'two');
        final secondDeadline = timers.active;
        expect(secondDeadline, isNotNull);
        expect(identical(secondDeadline, firstDeadline), isFalse);

        // The last ack finishes the history and arms the mic.
        transport.emit(_ack());
        await pumpEventLoop();
        expect(secondDeadline!.isCancelled, isTrue);
        expect(transport.enabledCalls.where((e) => e).length, 1);
        expect(s.state.phase, OpenAIRealtimeVoicePhase.listening);
      },
    );

    test(
      'a transport death during loading is a terminal session failure',
      () async {
        final history = Conversation(
          messages: <Message>[
            _user('u1', <ContentPart>[ContentPart.text('one')]),
            _user('u2', <ContentPart>[ContentPart.text('two')]),
          ],
        );
        final s = build(history);
        addTearDown(s.dispose);

        await s.start();
        transport.emit(_created);
        await pumpEventLoop();
        transport.emit(_updated);
        await pumpEventLoop();
        expect(_creates(transport).length, 1);

        // The channel dies before the first ack.
        transport.endEvents();
        await pumpEventLoop();
        expect(s.state.phase, OpenAIRealtimeVoicePhase.failed);
        expect(s.state.failure, OpenAIRealtimeVoiceFailure.session);
        // The mic never enabled; no second item, no retry/reconnect/re-mint.
        expect(transport.enabledCalls.where((e) => e).isEmpty, isTrue);
        expect(_creates(transport).length, 1);
        expect(provider.calls, 1);
        expect(transport.connectCalls, 1);
      },
    );

    test(
      'an error event during loading is a terminal session failure',
      () async {
        final history = Conversation(
          messages: <Message>[
            _user('u1', <ContentPart>[ContentPart.text('one')]),
          ],
        );
        final s = build(history);
        addTearDown(s.dispose);
        await s.start();
        transport.emit(_created);
        await pumpEventLoop();
        transport.emit(_updated);
        await pumpEventLoop();

        transport.emit(<String, Object?>{
          'type': 'error',
          'error': <String, Object?>{'message': 'boom', 'code': 'x'},
        });
        await pumpEventLoop();
        expect(s.state.phase, OpenAIRealtimeVoicePhase.failed);
        expect(s.state.failure, OpenAIRealtimeVoiceFailure.session);
        expect(transport.enabledCalls.where((e) => e).isEmpty, isTrue);
      },
    );

    test('empty history keeps the prior startup flow', () async {
      final s = build(null);
      addTearDown(s.dispose);
      await s.start();
      transport.emit(_created);
      await pumpEventLoop();
      transport.emit(_updated);
      await pumpEventLoop();
      // No conversation.item.create at all; the mic came up as before.
      expect(_creates(transport), isEmpty);
      expect(transport.enabledCalls.where((e) => e).length, 1);
      expect(s.state.phase, OpenAIRealtimeVoicePhase.listening);
    });

    test('the one session.update sets truncation: disabled', () async {
      final s = build(null);
      addTearDown(s.dispose);
      await s.start();
      transport.emit(_created);
      await pumpEventLoop();
      final update = transport.sent.firstWhere(
        (e) => e['type'] == 'session.update',
      );
      final session = update['session']! as Map<String, Object?>;
      expect(session['truncation'], 'disabled');
      expect(_countSent(transport, 'session.update'), 1);
    });
  });
}
