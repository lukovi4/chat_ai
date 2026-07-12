// Token Stream + edge replies (V1_SPEC §4/§11, test contract §12.10) and
// provider-opaque continuity (§12.9).
import 'dart:typed_data';

import 'package:chat_ai/chat_ai.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_session_test_utils.dart';

void main() {
  test('tokens carries the ACCUMULATED text, throttled to ~15/s, ending on '
      'the complete reply', () async {
    const text = 'a b c d e f g h i j k l m n o p q r s t u v w x y z';
    final fake = FakeChatBackend()
      ..reply(text, tokenDelay: const Duration(milliseconds: 4));
    final session = makeSession(backend: fake);
    final emissions = <String>[];
    session.tokens.listen(emissions.add);

    await session.send('alphabet');
    await waitForState(session, (s) => s is Done);
    await pumpEventQueue();

    expect(emissions, isNotEmpty);
    expect(emissions.last, text, reason: 'the final flush is complete');
    // Accumulated, not per-delta: every emission extends the previous one.
    for (var i = 1; i < emissions.length; i++) {
      expect(emissions[i], startsWith(emissions[i - 1]));
    }
    // 26 deltas over ~100 ms cannot legally produce 26 emissions at 66 ms
    // throttling.
    expect(emissions.length, lessThan(26));
  });

  test('an empty reply is a valid Done with an empty complete assistant '
      'Message — and is dropped from the next wire', () async {
    final fake = FakeChatBackend()
      ..emptyReply()
      ..reply('second');
    final session = makeSession(backend: fake, time: FakeTime());
    final emissions = <String>[];
    session.tokens.listen(emissions.add);
    final states = <ConversationState>[];
    session.states.listen(states.add);

    await session.send('say nothing');
    await waitForState(session, (s) => s is Done);
    expect(
      states.whereType<Streaming>(),
      isEmpty,
      reason: 'no token ever arrived',
    );
    final assistant = session.snapshot.messages.last;
    expect(assistant.role, MessageRole.assistant);
    expect(assistant.status, MessageStatus.complete);
    expect(assistant.parts, isEmpty);
    expect(emissions, isEmpty);

    // The empty complete reply stays in the snapshot but not on the wire.
    await session.send('again');
    await waitForState(session, (s) => s is Done);
    final second = capturedRequestsOf(fake).last;
    expect(second.messages.map((m) => m.id), isNot(contains(assistant.id)));
    expect(session.snapshot.messages.map((m) => m.id), contains(assistant.id));
  });

  test('a whitespace-only reply is content, not an error', () async {
    final fake = FakeChatBackend()..reply('   ');
    final session = makeSession(backend: fake, time: FakeTime());
    await session.send('hi');
    await waitForState(session, (s) => s is Done);
    final assistant = session.snapshot.messages.last;
    expect(assistant.status, MessageStatus.complete);
    expect(visibleText(assistant), '   ');
  });

  group('provider-opaque continuity (§12.9)', () {
    final opaque = ProviderOpaquePart(
      'openai',
      Uint8List.fromList([1, 2, 3, 255]),
    );

    test(
      'opaque parts are persisted in order, never on the Token Stream',
      () async {
        final backend = ManualBackend();
        final session = makeSession(backend: backend);
        final emissions = <String>[];
        session.tokens.listen(emissions.add);
        await session.send('hi');
        backend.emit(const BackendEvent.accepted());
        backend.emit(BackendEvent.providerState(opaque));
        backend.emit(const BackendEvent.delta('visible'));
        backend.emit(const BackendEvent.done());
        await pumpEventQueue();

        final assistant = session.snapshot.messages.last;
        expect(assistant.parts, hasLength(2));
        expect(assistant.parts.first, opaque, reason: 'source order kept');
        expect(assistant.parts.last, const ContentPart.text('visible'));
        expect(emissions, isNotEmpty);
        for (final emission in emissions) {
          expect(
            emission,
            'visible',
            reason: 'opaque bytes never reach the Token Stream',
          );
        }
        await session.dispose();
      },
    );

    test('opaque parts round-trip byte-exact through JSON and ride the '
        'next wire request inside their Message', () async {
      final backend = ManualBackend();
      final session = makeSession(backend: backend);
      await session.send('hi');
      backend.emit(const BackendEvent.accepted());
      backend.emit(BackendEvent.providerState(opaque));
      backend.emit(const BackendEvent.delta('t'));
      backend.emit(const BackendEvent.done());
      await pumpEventQueue();

      // JSON round-trip (restart) keeps the bytes exact.
      final restored = Conversation.fromJson(session.snapshot.toJson());
      final part = restored.messages.last.parts.first as ProviderOpaquePart;
      expect(part.provider, 'openai');
      expect(part.data, opaque.data);

      // The next leg's wire context carries the opaque part as-is.
      await session.send('follow-up');
      await pumpEventQueue();
      final wire = backend.requests.last.messages;
      final wireOpaque = wire
          .expand((m) => m.parts)
          .whereType<ProviderOpaquePart>()
          .single;
      expect(wireOpaque.data, opaque.data);
      await session.dispose();
    });
  });
}
