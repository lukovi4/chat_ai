// Recover-before-rebill + the checkpoint discipline (V1_SPEC §4/§6/§8, test
// contract §12.6/.7): persisted-key recovery, the one explicit 409/410
// fresh-key fallback, edit/resend key rules, and checkpoint-before-every-
// billable-dispatch with its pinned failure terminals.
import 'dart:typed_data';

import 'package:chat_ai/chat_ai.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_session_test_utils.dart';

void main() {
  group('resend (failed user Message)', () {
    test('re-runs under the SAME persisted key, checkpointed first', () async {
      final fake = FakeChatBackend()..reply('delivered');
      final log = <String>[];
      final session = makeSession(
        backend: LoggingBackend(fake, log),
        time: FakeTime(),
        checkpoint: (snapshot) async {
          log.add('checkpoint:${snapshot.messages.last.attemptKey}');
        },
        history: Conversation(
          messages: [userMessage('u-1', 'hi', status: MessageStatus.failed)],
        ),
      );
      await session.resend('u-1');
      await waitForState(session, (s) => s is Done);

      expect(
        log,
        ['checkpoint:key-u-1', 'dispatch:key-u-1'],
        reason:
            'an explicit same-key resend still checkpoints before its '
            'first backend request',
      );
      expect(session.snapshot.messages.first.status, MessageStatus.sent);
      expect(visibleText(session.snapshot.messages.last), 'delivered');
    });

    test(
      'explicit 410 → exactly one checkpointed fresh-key fallback',
      () async {
        final fake = FakeChatBackend()
          ..respondGone410()
          ..reply('re-billed');
        final log = <String>[];
        final uuid = SequentialUuid();
        final session = makeSession(
          backend: LoggingBackend(fake, log),
          time: FakeTime(),
          uuid: uuid,
          checkpoint: (snapshot) async {
            log.add('checkpoint:${snapshot.messages.first.attemptKey}');
          },
          history: Conversation(
            messages: [userMessage('u-1', 'hi', status: MessageStatus.failed)],
          ),
        );
        await session.resend('u-1');
        await waitForState(session, (s) => s is Done);

        expect(log, [
          'checkpoint:key-u-1',
          'dispatch:key-u-1',
          'checkpoint:uuid-1',
          'dispatch:uuid-1',
        ]);
        expect(
          session.snapshot.messages.first.attemptKey,
          'uuid-1',
          reason: 'the fresh key is persisted on the user Message',
        );
      },
    );

    test('a second 410 after the fallback is terminal — never more than one '
        'automatic fallback per command', () async {
      final fake = FakeChatBackend()
        ..respondGone410()
        ..respondGone410()
        ..reply('never dispatched');
      final session = makeSession(
        backend: fake,
        time: FakeTime(),
        history: Conversation(
          messages: [userMessage('u-1', 'hi', status: MessageStatus.failed)],
        ),
      );
      await session.resend('u-1');
      final failed = await waitForState(session, (s) => s is Failed) as Failed;
      expect(failed.cause, FailureCause.upstream);
      expect(capturedRequestsOf(fake), hasLength(2));
    });

    test('explicit 409 gets the same single fallback', () async {
      final fake = FakeChatBackend()
        ..respondConflict409()
        ..reply('fresh run');
      final session = makeSession(
        backend: fake,
        time: FakeTime(),
        uuid: SequentialUuid(),
        history: Conversation(
          messages: [userMessage('u-1', 'hi', status: MessageStatus.failed)],
        ),
      );
      await session.resend('u-1');
      await waitForState(session, (s) => s is Done);
      final keys = [
        for (final request in capturedRequestsOf(fake)) request.idempotencyKey,
      ];
      expect(keys, ['key-u-1', 'uuid-1']);
    });
  });

  group('regenerate (recover-before-rebill)', () {
    test('interrupted reply first repeats its persisted leg key and replaces '
        'the partial only when new content arrives', () async {
      final fake = FakeChatBackend()
        ..replayOnSameKey()
        ..reply('the full stored answer');
      final session = makeSession(
        backend: fake,
        time: FakeTime(),
        history: Conversation(
          messages: [
            userMessage('u-1', 'hi'),
            assistantMessage(
              'a-1',
              'half an ans',
              status: MessageStatus.interrupted,
              attemptKey: 'leg-key-1',
            ),
          ],
        ),
      );
      await session.regenerate();
      await waitForState(session, (s) => s is Done);

      final request = capturedRequestsOf(fake).single;
      expect(request.idempotencyKey, 'leg-key-1');
      expect(
        request.messages.map((m) => m.id),
        isNot(contains('a-1')),
        reason:
            'a first-leg recovery request never carries the assistant — '
            'the original leg-1 request had none',
      );
      final assistant = session.snapshot.messages.last;
      expect(assistant.id, 'a-1', reason: 'the same Message is recovered');
      expect(assistant.status, MessageStatus.complete);
      expect(
        visibleText(assistant),
        'the full stored answer',
        reason: 'the stale partial was replaced, not appended to',
      );
    });

    test('a first-leg recovery request is provider-effective identical to '
        'the original send request', () async {
      final fake = FakeChatBackend()
        ..breakAfterFirstToken()
        ..reply('recovered in full');
      final session = makeSession(backend: fake, time: FakeTime());
      await session.send('hi there');
      await waitForState(session, (s) => s is Failed);
      expect(session.snapshot.messages.last.status, MessageStatus.interrupted);

      await session.regenerate();
      await waitForState(session, (s) => s is Done);

      final requests = capturedRequestsOf(fake);
      expect(requests, hasLength(2));
      expect(
        requests[1].idempotencyKey,
        requests[0].idempotencyKey,
        reason: 'recover-before-rebill reuses the persisted leg key',
      );
      expect(
        providerEffective(requests[1]),
        providerEffective(requests[0]),
        reason:
            'the recovery repeat must hash identical on the server — '
            'the partial output never rides in it',
      );
    });

    test('a multi-tool recovery request carries the completed tool '
        'exchanges but never the interrupted leg\'s partial', () async {
      final opaque = ProviderOpaquePart('openai', Uint8List.fromList([9, 9]));
      final fake = FakeChatBackend()..reply('rest of the answer');
      final session = makeSession(
        backend: fake,
        time: FakeTime(),
        history: Conversation(
          messages: [
            userMessage('u-1', 'hi'),
            Message(
              id: 'a-1',
              role: MessageRole.assistant,
              status: MessageStatus.interrupted,
              attemptKey: 'leg-key-3',
              createdAt: DateTime.utc(2026, 7, 10, 9, 1),
              parts: [
                const ContentPart.text('let me check '),
                const ContentPart.toolCall('call_1', 'searchNotes', {}),
                const ContentPart.toolResult('call_1', '3 notes', false),
                const ContentPart.toolCall('call_2', 'searchNotes', {}),
                const ContentPart.toolResult('call_2', 'none', false),
                // The interrupted leg's partial: text, opaque state and an
                // unmatched trailing call — none of it may ride the wire.
                const ContentPart.text('so far I found'),
                ContentPart.providerOpaque('openai', opaque.data),
                const ContentPart.toolCall('call_3', 'searchNotes', {}),
              ],
            ),
          ],
        ),
      );
      await session.regenerate();
      await waitForState(session, (s) => s is Done);

      final request = capturedRequestsOf(fake).single;
      expect(request.idempotencyKey, 'leg-key-3');
      final wireAssistant = request.messages.singleWhere((m) => m.id == 'a-1');
      expect(
        wireAssistant.parts,
        hasLength(5),
        reason: 'exactly up to the last completed toolResult',
      );
      expect(
        wireAssistant.parts.last,
        const ContentPart.toolResult('call_2', 'none', false),
      );
      // The snapshot kept the full partial until the replacing content came.
      expect(
        session.snapshot.messages.last.parts.whereType<ToolCallPart>(),
        hasLength(2),
        reason:
            'the unmatched trailing call was replaced by '
            'the recovered leg output',
      );
    });

    test('the fresh-key fallback re-uses the SAME cleaned regeneration base, '
        'only the key changes', () async {
      final fake = FakeChatBackend()
        ..respondGone410()
        ..reply('re-billed');
      final session = makeSession(
        backend: fake,
        time: FakeTime(),
        uuid: SequentialUuid(),
        history: Conversation(
          messages: [
            userMessage('u-1', 'hi'),
            assistantMessage(
              'a-1',
              'half an ans',
              status: MessageStatus.interrupted,
              attemptKey: 'leg-key-1',
            ),
          ],
        ),
      );
      await session.regenerate();
      await waitForState(session, (s) => s is Done);
      final requests = capturedRequestsOf(fake);
      expect(requests, hasLength(2));
      expect(requests[0].idempotencyKey, 'leg-key-1');
      expect(requests[1].idempotencyKey, 'uuid-1');
      expect(
        providerEffective(requests[1]),
        providerEffective(requests[0]),
        reason: 'the fallback dispatches the same cleaned base',
      );
      expect(requests[1].messages.map((m) => m.id), isNot(contains('a-1')));
    });

    test('a failed recovery keeps the partial untouched', () async {
      final fake = FakeChatBackend()..failWith(FailureCause.auth);
      final session = makeSession(
        backend: fake,
        time: FakeTime(),
        history: Conversation(
          messages: [
            userMessage('u-1', 'hi'),
            assistantMessage(
              'a-1',
              'half an ans',
              status: MessageStatus.interrupted,
            ),
          ],
        ),
      );
      await session.regenerate();
      final failed = await waitForState(session, (s) => s is Failed) as Failed;
      expect(failed.cause, FailureCause.auth);
      expect(
        failed.phase,
        FailurePhase.streaming,
        reason: 'the reply visibly exists — the failure is anchored on it',
      );
      final assistant = session.snapshot.messages.last;
      expect(assistant.status, MessageStatus.interrupted);
      expect(visibleText(assistant), 'half an ans');
    });

    test('final sent user with no assistant recovers under the USER key; '
        '410 falls back once', () async {
      final fake = FakeChatBackend()
        ..respondGone410()
        ..reply('recovered');
      final session = makeSession(
        backend: fake,
        time: FakeTime(),
        uuid: SequentialUuid(),
        history: Conversation(messages: [userMessage('u-1', 'hi')]),
      );
      await session.regenerate();
      await waitForState(session, (s) => s is Done);
      final keys = [
        for (final request in capturedRequestsOf(fake)) request.idempotencyKey,
      ];
      expect(keys, ['key-u-1', 'uuid-1']);
      expect(session.snapshot.messages.first.attemptKey, 'uuid-1');
      expect(session.snapshot.messages.first.status, MessageStatus.sent);
    });

    test('complete reply regenerates under a fresh key immediately, '
        'truncating the old reply', () async {
      final fake = FakeChatBackend()..reply('take two');
      final uuid = SequentialUuid();
      final session = makeSession(
        backend: fake,
        time: FakeTime(),
        uuid: uuid,
        history: Conversation(
          messages: [
            userMessage('u-1', 'hi'),
            assistantMessage('a-1', 'take one'),
          ],
        ),
      );
      await session.regenerate();
      await waitForState(session, (s) => s is Done);

      final request = capturedRequestsOf(fake).single;
      expect(
        request.idempotencyKey,
        'uuid-1',
        reason:
            'fresh key, no '
            'recovery attempt for a complete reply',
      );
      expect(
        request.messages.map((m) => m.id),
        isNot(contains('a-1')),
        reason: 'the old reply is truncated away before the dispatch',
      );
      final messages = session.snapshot.messages;
      expect(messages, hasLength(2));
      expect(messages.first.attemptKey, 'uuid-1');
      expect(visibleText(messages.last), 'take two');
      expect(messages.last.id, isNot('a-1'));
    });
  });

  group('editAndResend', () {
    test('truncates after the edited Message, replaces text, keeps processed '
        'images without re-resize, mints a fresh key', () async {
      final fake = FakeChatBackend()..reply('edited answer');
      final uuid = SequentialUuid();
      var processed = 0;
      final imageBytes = Uint8List.fromList([1, 2, 3]);
      final session = makeSession(
        backend: fake,
        time: FakeTime(),
        uuid: uuid,
        processImage: (raw, options) async {
          processed++;
          return raw;
        },
        history: Conversation(
          messages: [
            userMessage(
              'u-1',
              'original',
              parts: [
                const ContentPart.text('original'),
                ContentPart.image(imageBytes),
              ],
            ),
            assistantMessage('a-1', 'old reply'),
            userMessage('u-2', 'later turn'),
          ],
        ),
      );
      await session.editAndResend('u-1', 'edited');
      await waitForState(session, (s) => s is Done);

      final messages = session.snapshot.messages;
      expect(messages.map((m) => m.id), isNot(contains('a-1')));
      expect(
        messages.map((m) => m.id),
        isNot(contains('u-2')),
        reason: 'everything after the edited Message is truncated',
      );
      final edited = messages.first;
      expect(edited.id, 'u-1');
      expect(visibleText(edited), 'edited');
      expect(
        (edited.parts.whereType<ImagePart>().single).bytes,
        imageBytes,
        reason: 'processed ImageParts ride along untouched',
      );
      expect(processed, 0, reason: 'no re-resize on edit');
      expect(edited.attemptKey, 'uuid-1', reason: 'fresh key');
      expect(capturedRequestsOf(fake).single.idempotencyKey, 'uuid-1');
    });

    test(
      'empty new text is allowed only when the Message keeps images',
      () async {
        final fake = FakeChatBackend()..reply('image only');
        final session = makeSession(
          backend: fake,
          time: FakeTime(),
          history: Conversation(
            messages: [
              userMessage(
                'u-1',
                '',
                parts: [
                  ContentPart.image(Uint8List.fromList([9])),
                ],
              ),
            ],
          ),
        );
        await session.editAndResend('u-1', '');
        await waitForState(session, (s) => s is Done);
        final edited = session.snapshot.messages.first;
        expect(edited.parts.whereType<TextPart>(), isEmpty);
        expect(edited.parts.whereType<ImagePart>(), hasLength(1));
      },
    );
  });

  group('an empty user Message is never a provider anchor', () {
    // A user Message with no parts is a legal storage/UI-only entry that
    // never rides the wire, so every recovery command that would answer it
    // is a FULL no-op: nothing mutates, no key is minted, no checkpoint runs
    // and the backend is never called.
    Future<void> expectFullNoOp(
      Conversation history,
      Future<void> Function(ChatSession session) command,
    ) async {
      final fake = FakeChatBackend()..reply('never dispatched');
      final uuid = SequentialUuid();
      final checkpoints = <Conversation>[];
      final session = makeSession(
        backend: fake,
        time: FakeTime(),
        uuid: uuid,
        checkpoint: (snapshot) async => checkpoints.add(snapshot),
        history: history,
      );
      final before = session.snapshot.toJson();
      final stateBefore = session.state;

      await command(session);
      await Future<void>.delayed(Duration.zero);

      expect(capturedRequestsOf(fake), isEmpty, reason: 'no dispatch');
      expect(checkpoints, isEmpty, reason: 'no checkpoint');
      expect(uuid.minted, isEmpty, reason: 'no key or id minted');
      expect(session.snapshot.toJson(), before, reason: 'Conversation intact');
      expect(session.state, stateBefore, reason: 'state intact');
    }

    final emptyUser = userMessage('u-empty', '', parts: const []);

    test('regenerate on a final empty sent user', () async {
      await expectFullNoOp(
        Conversation(messages: [emptyUser]),
        (session) => session.regenerate(),
      );
    });

    test('resend of an empty failed user', () async {
      await expectFullNoOp(
        Conversation(
          messages: [
            userMessage(
              'u-empty',
              '',
              parts: const [],
              status: MessageStatus.failed,
            ),
          ],
        ),
        (session) => session.resend('u-empty'),
      );
    });

    test('regenerate of a complete reply whose nearest user anchor is '
        'empty', () async {
      await expectFullNoOp(
        Conversation(
          messages: [emptyUser, assistantMessage('a-1', 'take one')],
        ),
        (session) => session.regenerate(),
      );
    });

    test('regenerate of an interrupted reply whose nearest user anchor is '
        'empty (recover-before-rebill)', () async {
      await expectFullNoOp(
        Conversation(
          messages: [
            emptyUser,
            assistantMessage(
              'a-1',
              'half an ans',
              status: MessageStatus.interrupted,
              attemptKey: 'leg-key-1',
            ),
          ],
        ),
        (session) => session.regenerate(),
      );
    });

    test('editAndResend still turns it into a real turn', () async {
      final fake = FakeChatBackend()..reply('answered');
      final session = makeSession(
        backend: fake,
        time: FakeTime(),
        uuid: SequentialUuid(),
        history: Conversation(messages: [emptyUser]),
      );
      await session.editAndResend('u-empty', 'now with content');
      await waitForState(session, (s) => s is Done);

      final request = capturedRequestsOf(fake).single;
      expect(request.messages.map((m) => m.id), contains('u-empty'));
      expect(visibleText(request.messages.first), 'now with content');
      expect(visibleText(session.snapshot.messages.last), 'answered');
    });
  });

  group('checkpoint discipline', () {
    test('the snapshot given to the checkpoint already contains the new '
        'Message and key', () async {
      final fake = FakeChatBackend()..reply('ok');
      final uuid = SequentialUuid();
      Conversation? seen;
      final session = makeSession(
        backend: fake,
        time: FakeTime(),
        uuid: uuid,
        checkpoint: (snapshot) async => seen = snapshot,
      );
      await session.send('hi');
      await waitForState(session, (s) => s is Done);
      final user = seen!.messages.single;
      expect(visibleText(user), 'hi');
      expect(user.status, MessageStatus.sending);
      expect(
        user.attemptKey,
        'uuid-2',
        reason: 'uuid-1 is the Message id, uuid-2 its attemptKey',
      );
    });

    test(
      'first-leg checkpoint failure: user failed, '
      'Failed(upstream, sending, checkpoint-failed), backend never called',
      () async {
        final fake = FakeChatBackend()..reply('never dispatched');
        final session = makeSession(
          backend: fake,
          time: FakeTime(),
          checkpoint: (snapshot) async => throw Exception('disk full'),
        );
        await session.send('hi');
        final failed =
            await waitForState(session, (s) => s is Failed) as Failed;
        expect(failed.cause, FailureCause.upstream);
        expect(failed.phase, FailurePhase.sending);
        expect(failed.developerDetail, 'checkpoint-failed');
        expect(capturedRequestsOf(fake), isEmpty);
        expect(session.snapshot.messages.single.status, MessageStatus.failed);
      },
    );

    test(
      'checkpoint rejection is the rejected disposition (draft kept)',
      () async {
        final session = makeSession(
          backend: FakeChatBackend(),
          time: FakeTime(),
          checkpoint: (snapshot) async => throw Exception('nope'),
        );
        expect(
          await sendWithDisposition(session, 'hi'),
          ChatCommandDisposition.rejected,
        );
      },
    );
  });
}
