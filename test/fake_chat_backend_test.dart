// FakeChatBackend (V1_SPEC §10): scriptable normative event order, replay,
// Gone/Conflict, cancellation — no network, no money. The request-capture
// seam stays package-internal (export boundary: public_api_test).
import 'package:chat_ai/chat_ai.dart';
import 'package:chat_ai/src/testing/fake_chat_backend.dart';
import 'package:flutter_test/flutter_test.dart';

ChatRequest request(String key) => ChatRequest(
  botId: 'premium',
  system: 'be kind',
  messages: const [],
  tools: const [],
  idempotencyKey: key,
);

void main() {
  test(
    'reply streams Accepted, word-ish deltas, then done with usage',
    () async {
      final fake = FakeChatBackend()..reply('Hello brave world');
      final events = await fake.send(request('k-1')).toList();

      expect(events.first, const BackendEvent.accepted());
      final deltas = events.whereType<Delta>().map((d) => d.text).toList();
      expect(deltas.join(), 'Hello brave world');
      expect(deltas.length, greaterThan(1));
      final done = events.last as DoneEvent;
      expect(done.usage!.outputTokens, deltas.length);
      expect(done.usage!.usageRaw, isNotNull);
    },
  );

  test('a whitespace-only reply still reconstructs exactly', () async {
    final fake = FakeChatBackend()..reply('   ');
    final events = await fake.send(request('k-1')).toList();
    expect(events.whereType<Delta>().map((d) => d.text).join(), '   ');
  });

  test(
    'failWith afterTokens: 0 is a pre-stream failure — no Accepted',
    () async {
      final fake = FakeChatBackend()..failWith(FailureCause.rate);
      final events = await fake.send(request('k-1')).toList();
      expect(events, hasLength(1));
      final error = events.single as ErrorEvent;
      expect(error.cause, FailureCause.rate);
      expect(error.retryAfter, isNull);
      expect(error.detail, isNull);
    },
  );

  test('the internal seam scripts the wire-level detail and Retry-After the '
      'public surface omits', () async {
    final fake = FakeChatBackend();
    scriptFailureResponse(
      fake,
      FailureCause.rate,
      detail: '429 raw',
      retryAfter: const Duration(milliseconds: 1200),
    );
    final error =
        (await fake.send(request('k-1')).toList()).single as ErrorEvent;
    expect(error.cause, FailureCause.rate);
    expect(error.detail, '429 raw');
    expect(error.retryAfter, const Duration(milliseconds: 1200));
  });

  test('failWith afterTokens > 0 emits Accepted and deltas first', () async {
    final fake = FakeChatBackend()
      ..failWith(FailureCause.overloaded, afterTokens: 2);
    final events = await fake.send(request('k-1')).toList();
    expect(events.first, const BackendEvent.accepted());
    expect(events.whereType<Delta>(), hasLength(2));
    expect((events.last as ErrorEvent).cause, FailureCause.overloaded);
  });

  test(
    'breakAfterFirstToken: one delta then a mid-stream upstream break',
    () async {
      final fake = FakeChatBackend()..breakAfterFirstToken();
      final events = await fake.send(request('k-1')).toList();
      expect(events, hasLength(3));
      expect(events[1], const BackendEvent.delta('partial'));
      expect((events.last as ErrorEvent).cause, FailureCause.upstream);
    },
  );

  test(
    'requestTool is a terminal tool_call with deterministic fresh ids',
    () async {
      final fake = FakeChatBackend()
        ..requestTool('searchNotes', args: {'period': '2026-06'})
        ..requestTool('searchNotes');
      final first = await fake.send(request('k-1')).toList();
      final second = await fake.send(request('k-2')).toList();

      final call1 = (first.last as ToolCallEvent).call;
      final call2 = (second.last as ToolCallEvent).call;
      expect(call1.id, 'call_1');
      expect(call1.args, {'period': '2026-06'});
      expect(call2.id, 'call_2');
      expect(
        first.whereType<DoneEvent>(),
        isEmpty,
        reason: 'tool_call is the terminal of its leg — no done follows',
      );
      expect((first.last as ToolCallEvent).usage, isNotNull);
    },
  );

  test('emptyReply and an exhausted script are a valid empty done', () async {
    final fake = FakeChatBackend()..emptyReply();
    final scripted = await fake.send(request('k-1')).toList();
    final unscripted = await fake.send(request('k-2')).toList();
    for (final events in [scripted, unscripted]) {
      expect(events, hasLength(2));
      expect(events.first, const BackendEvent.accepted());
      expect((events.last as DoneEvent).usage!.outputTokens, 0);
    }
  });

  test(
    'respondGone410 / respondConflict409 are bare protocol signals',
    () async {
      final fake = FakeChatBackend()
        ..respondGone410()
        ..respondConflict409();
      expect(await fake.send(request('k-1')).toList(), [
        const BackendEvent.gone(),
      ]);
      expect(await fake.send(request('k-1')).toList(), [
        const BackendEvent.conflict(),
      ]);
    },
  );

  group('replayOnSameKey', () {
    test(
      'a completed key replays its recorded outcome, not the script',
      () async {
        final fake = FakeChatBackend()
          ..replayOnSameKey()
          ..reply('the answer')
          ..failWith(FailureCause.upstream);
        final first = await fake.send(request('k-1')).toList();
        final replayed = await fake.send(request('k-1')).toList();
        expect(replayed, first, reason: 'stored outcome, no second generation');
        // A different key consumes the next script step.
        final other = await fake.send(request('k-2')).toList();
        expect(other.single, isA<ErrorEvent>());
      },
    );

    test('a tool_call terminal replays with the same toolCallId', () async {
      final fake = FakeChatBackend()
        ..replayOnSameKey()
        ..requestTool('searchNotes');
      final first = await fake.send(request('k-1')).toList();
      final replayed = await fake.send(request('k-1')).toList();
      expect(
        (replayed.last as ToolCallEvent).call.id,
        (first.last as ToolCallEvent).call.id,
      );
    });

    test('the replay comparator is canonical: re-ordered map keys are the '
        'same request, a changed value is not', () async {
      final fake = FakeChatBackend()
        ..replayOnSameKey()
        ..reply('stored');
      ChatRequest build(
        Map<String, dynamic> parameters,
        Map<String, dynamic> args,
      ) => ChatRequest(
        botId: 'premium',
        system: 's',
        messages: [
          Message(
            id: 'a-1',
            role: MessageRole.assistant,
            status: MessageStatus.interrupted,
            attemptKey: 'k-1',
            createdAt: DateTime.utc(2026, 7, 12),
            parts: [ContentPart.toolCall('c1', 'searchNotes', args)],
          ),
        ],
        tools: [
          Tool(name: 'searchNotes', description: 'd', parameters: parameters),
        ],
        idempotencyKey: 'k-1',
      );

      final first = await fake
          .send(
            build(
              {
                'alpha': 1,
                'beta': {'x': 1, 'y': 2},
              },
              {'p': 1, 'q': 2},
            ),
          )
          .toList();
      expect(first.last, isA<DoneEvent>());

      // The SAME data, maps re-serialised in another key order (a restart
      // round-trip): still a replay, never a masking 409.
      final reordered = await fake
          .send(
            build(
              {
                'beta': {'y': 2, 'x': 1},
                'alpha': 1,
              },
              {'q': 2, 'p': 1},
            ),
          )
          .toList();
      expect(reordered, first);

      // A real value difference under the same key stays an honest 409.
      final changed = await fake
          .send(
            build(
              {
                'alpha': 1,
                'beta': {'x': 1, 'y': 3},
              },
              {'p': 1, 'q': 2},
            ),
          )
          .toList();
      expect(changed, [const BackendEvent.conflict()]);
    });

    test('a same-key repeat with mismatched provider-effective params is an '
        'honest 409 Conflict, never a masking replay', () async {
      final fake = FakeChatBackend()
        ..replayOnSameKey()
        ..reply('the answer');
      final original = ChatRequest(
        botId: 'premium',
        system: 'be kind',
        messages: const [],
        tools: const [],
        idempotencyKey: 'k-1',
      );
      final first = await fake.send(original).toList();
      expect(first.last, isA<DoneEvent>());

      // Same key, different provider-effective body → 409.
      final conflicting = await fake
          .send(original.copyWith(system: 'be terse'))
          .toList();
      expect(conflicting, [const BackendEvent.conflict()]);

      // A byte-identical repeat still replays (client-only wireVersion
      // differences are ignored by the provider-effective comparison).
      final replayed = await fake
          .send(original.copyWith(wireVersion: 1))
          .toList();
      expect(replayed, first);
    });

    test(
      'an errored key stays unknown: its repeat re-runs the script',
      () async {
        final fake = FakeChatBackend()
          ..replayOnSameKey()
          ..failWith(FailureCause.rate)
          ..reply('second run');
        expect(
          (await fake.send(request('k-1')).toList()).single,
          isA<ErrorEvent>(),
        );
        final rerun = await fake.send(request('k-1')).toList();
        expect(rerun.last, isA<DoneEvent>());
      },
    );
  });

  test(
    'cancelling the subscription stops a pending tokenDelay emission',
    () async {
      final fake = FakeChatBackend()
        ..reply('one two three', tokenDelay: const Duration(milliseconds: 20));
      final received = <BackendEvent>[];
      final subscription = fake.send(request('k-1')).listen(received.add);
      // Let Accepted and at most the first delta through, then cancel.
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await subscription.cancel();
      final countAtCancel = received.length;
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(
        received.length,
        countAtCancel,
        reason: 'nothing arrives after the wire-cancel',
      );
      expect(received.whereType<DoneEvent>(), isEmpty);
    },
  );
}
