// Context assembly + trimming (V1_SPEC §6, test contract §12.12/.14):
// filtering, system mapping order, the chars/4 budget and the degenerate
// context-too-long outcome.
import 'package:chat_ai/chat_ai.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_session_test_utils.dart';

void main() {
  test(
    'assembly: failed users excluded, interrupted partials included, '
    'empty complete replies dropped, system Messages chronological',
    () async {
      final fake = FakeChatBackend()..reply('ok');
      final session = makeSession(
        backend: fake,
        time: FakeTime(),
        history: Conversation(
          messages: [
            systemMessage('s-1', 'remember: terse'),
            userMessage('u-1', 'first'),
            assistantMessage('a-empty', '', parts: const []),
            userMessage(
              'u-failed',
              'never made it',
              status: MessageStatus.failed,
            ),
            assistantMessage(
              'a-partial',
              'cut off…',
              status: MessageStatus.interrupted,
            ),
            systemMessage('s-2', 'update: friendly'),
          ],
        ),
      );
      await session.send('new turn');
      await waitForState(session, (s) => s is Done);

      final request = capturedRequestsOf(fake).single;
      expect(request.botId, 'premium');
      expect(
        request.system,
        'be kind',
        reason:
            'the profile prompt rides the '
            'system field; persisted system Messages stay in the history',
      );
      final ids = request.messages.map((m) => m.id).toList();
      expect(
        ids,
        ['s-1', 'u-1', 'a-partial', 's-2', ids.last],
        reason:
            'failed user and empty complete reply are wire-excluded; '
            'chronological order kept',
      );
      // The new user Message is the last wire message, still `sending` at
      // dispatch time.
      expect(request.messages.last.status, MessageStatus.sending);
      expect(visibleText(request.messages.last), 'new turn');
      // The snapshot keeps what the wire dropped.
      expect(
        session.snapshot.messages.map((m) => m.id),
        containsAll(['a-empty', 'u-failed']),
      );
    },
  );

  test('an empty user Message is storage/UI-only: never on the wire, kept '
      'unchanged in the snapshot', () async {
    final fake = FakeChatBackend()..reply('ok');
    final session = makeSession(
      backend: fake,
      time: FakeTime(),
      history: Conversation(
        messages: [
          userMessage('u-1', 'first'),
          assistantMessage('a-1', 'answer'),
          // A legal Conversation entry with no provider-effective content.
          userMessage('u-empty', '', parts: const []),
        ],
      ),
    );
    await session.send('new turn');
    await waitForState(session, (s) => s is Done);

    final ids = capturedRequestsOf(
      fake,
    ).single.messages.map((m) => m.id).toList();
    expect(ids, [
      'u-1',
      'a-1',
      ids.last,
    ], reason: 'the empty user Message is wire-excluded; order kept');
    expect(ids, isNot(contains('u-empty')));

    final kept = session.snapshot.messages.firstWhere((m) => m.id == 'u-empty');
    expect(kept.role, MessageRole.user);
    expect(kept.status, MessageStatus.sent);
    expect(kept.attemptKey, 'key-u-empty');
    expect(kept.parts, isEmpty, reason: 'storage is not rewritten by assembly');
  });

  test('the idempotency key never rides in the body, only on the request '
      'field', () async {
    final fake = FakeChatBackend()..reply('ok');
    final session = makeSession(backend: fake, time: FakeTime());
    await session.send('hi');
    await waitForState(session, (s) => s is Done);
    final request = capturedRequestsOf(fake).single;
    expect(request.idempotencyKey, session.snapshot.messages.first.attemptKey);
  });

  group('trimming (trimBudget)', () {
    test('null budget: nothing is ever trimmed', () async {
      final fake = FakeChatBackend()..reply('ok');
      final session = makeSession(
        backend: fake,
        time: FakeTime(),
        history: Conversation(
          messages: [
            userMessage('u-1', 'x' * 4000),
            assistantMessage('a-1', 'y' * 4000),
          ],
        ),
      );
      await session.send('hi');
      await waitForState(session, (s) => s is Done);
      expect(capturedRequestsOf(fake).single.messages, hasLength(3));
    });

    test('keeps the system input and the newest Messages that fit, oldest '
        'dropped first, whole Messages only', () async {
      final fake = FakeChatBackend()..reply('ok');
      final session = makeSession(
        backend: fake,
        time: FakeTime(),
        // 'be kind' ≈ 2 tokens; each 100-char message ≈ 25 tokens.
        trimBudget: 80,
        history: Conversation(
          messages: [
            systemMessage('s-1', 'terse'),
            userMessage('u-old', 'o' * 100),
            assistantMessage('a-old', 'p' * 100),
            userMessage('u-new', 'q' * 100),
          ],
        ),
      );
      await session.send('r' * 160);
      await waitForState(session, (s) => s is Done);
      final ids = capturedRequestsOf(
        fake,
      ).single.messages.map((m) => m.id).toList();
      expect(ids.first, 's-1', reason: 'system input is always kept');
      expect(ids, isNot(contains('u-old')));
      expect(ids, isNot(contains('a-old')));
      expect(ids, contains('u-new'));
      expect(ids, hasLength(3), reason: 's-1 + u-new + the new Message');
    });

    test('degenerate case: system + the one mandatory Message do not fit → '
        'Failed(contextTooLong, sending), backend never called', () async {
      final fake = FakeChatBackend()..reply('never dispatched');
      final session = makeSession(
        backend: fake,
        time: FakeTime(),
        trimBudget: 10,
      );
      await session.send('x' * 200);
      final failed = await waitForState(session, (s) => s is Failed) as Failed;
      expect(failed.cause, FailureCause.contextTooLong);
      expect(failed.phase, FailurePhase.sending);
      expect(capturedRequestsOf(fake), isEmpty);
      expect(
        session.snapshot.messages.single.status,
        MessageStatus.failed,
        reason:
            'the Message and key exist — resend stays possible after '
            'the app raises the budget',
      );
    });

    test('trimming is a per-dispatch decision, not a mutation: the snapshot '
        'keeps every Message', () async {
      final fake = FakeChatBackend()..reply('ok');
      final session = makeSession(
        backend: fake,
        time: FakeTime(),
        trimBudget: 60,
        history: Conversation(
          messages: [
            userMessage('u-old', 'o' * 150),
            assistantMessage('a-old', 'p' * 150),
          ],
        ),
      );
      await session.send('short');
      await waitForState(session, (s) => s is Done);
      expect(
        capturedRequestsOf(fake).single.messages.map((m) => m.id),
        isNot(contains('u-old')),
      );
      expect(
        session.snapshot.messages.map((m) => m.id),
        containsAll(['u-old', 'a-old']),
      );
    });
  });
}
