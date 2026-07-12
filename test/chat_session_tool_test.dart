// Tool Use Cycle (V1_SPEC §4/§8, ADR 0003, test contract §12.8): per-leg
// keys, usage summing, schema/sanitisation guards, toolCallId dedupe, loop
// limit and the frozen profile snapshot.
import 'dart:async';

import 'package:chat_ai/chat_ai.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_session_test_utils.dart';

const Tool searchTool = Tool(
  name: 'searchNotes',
  description: 'search the notes DB',
  parameters: {
    'type': 'object',
    'properties': {
      'period': {'type': 'string'},
    },
    'required': ['period'],
    'additionalProperties': false,
  },
);

const BotProfile toolProfile = BotProfile(
  id: 'premium',
  systemPrompt: 'be kind',
  tools: [searchTool],
);

void main() {
  test('full cycle: one assistant Message, fresh leg key, AwaitingTool '
      'phase, summed usage with usageRaw dropped', () async {
    final fake = FakeChatBackend()
      ..requestTool('searchNotes', args: {'period': '2026-06'})
      ..reply('You noted a plant in June.');
    final uuid = SequentialUuid();
    final calls = <ToolCall>[];
    final states = <ConversationState>[];
    final session = makeSession(
      backend: fake,
      time: FakeTime(),
      uuid: uuid,
      botProfile: toolProfile,
      onToolCall: (call) async {
        calls.add(call);
        return const ToolResult(content: '3 notes found', isError: false);
      },
    );
    session.states.listen(states.add);

    await session.send('what did I note?');
    final done = await waitForState(session, (s) => s is Done) as Done;

    // The resolver saw the complete, schema-valid call.
    expect(calls.single.name, 'searchNotes');
    expect(calls.single.args, {'period': '2026-06'});

    // One reply = one assistant Message with the ordered parts inside.
    final messages = session.snapshot.messages;
    expect(messages, hasLength(2));
    final assistant = messages.last;
    expect(assistant.status, MessageStatus.complete);
    expect(assistant.parts, hasLength(3));
    expect(assistant.parts[0], isA<ToolCallPart>());
    expect(
      assistant.parts[1],
      const ContentPart.toolResult('call_1', '3 notes found', false),
    );
    expect(assistant.parts[2], isA<TextPart>());

    // Each leg minted its own key; the assistant carries the LAST leg's key.
    final keys = [
      for (final request in capturedRequestsOf(fake)) request.idempotencyKey,
    ];
    expect(keys, hasLength(2));
    expect(keys.toSet(), hasLength(2), reason: 'fresh key per leg');
    expect(assistant.attemptKey, keys.last);

    // The tool-leg request carried the in-progress assistant with the
    // closing toolCall+toolResult pair — no second mapper.
    final legTwo = capturedRequestsOf(fake).last;
    final wireAssistant = legTwo.messages.last;
    expect(wireAssistant.role, MessageRole.assistant);
    expect(wireAssistant.parts.whereType<ToolCallPart>(), hasLength(1));
    expect(wireAssistant.parts.whereType<ToolResultPart>(), hasLength(1));

    // AwaitingTool was a real public phase between the legs.
    expect(states.whereType<AwaitingTool>().single.call.id, 'call_1');

    // Usage: SUM over the legs (1+1 input, 1+N output), usageRaw dropped on
    // a multi-leg reply.
    final usage = done.usage!;
    expect(usage.inputTokens, 2);
    expect(usage.outputTokens, greaterThan(1));
    expect(usage.usageRaw, isNull);
  });

  test('a single-leg Done keeps usageRaw', () async {
    final fake = FakeChatBackend()..reply('plain');
    final session = makeSession(backend: fake, time: FakeTime());
    await session.send('hi');
    final done = await waitForState(session, (s) => s is Done) as Done;
    expect(done.usage!.usageRaw, {'fake': 'raw'});
  });

  test('a tool-only reply (no text) is normal', () async {
    final fake = FakeChatBackend()
      ..requestTool('searchNotes', args: {'period': '2026-06'})
      ..emptyReply();
    final session = makeSession(
      backend: fake,
      time: FakeTime(),
      botProfile: toolProfile,
      onToolCall: (call) async =>
          const ToolResult(content: 'ok', isError: false),
    );
    await session.send('go');
    await waitForState(session, (s) => s is Done);
    final assistant = session.snapshot.messages.last;
    expect(assistant.status, MessageStatus.complete);
    expect(visibleText(assistant), isEmpty);
    expect(assistant.parts.whereType<ToolCallPart>(), hasLength(1));
  });

  group('safety guards (never reach the resolver)', () {
    test('unknown tool → sanitised is_error, resolver untouched', () async {
      final fake = FakeChatBackend()
        ..requestTool('ghostTool')
        ..reply('the bot reacts');
      var resolverCalls = 0;
      final session = makeSession(
        backend: fake,
        time: FakeTime(),
        botProfile: toolProfile,
        onToolCall: (call) async {
          resolverCalls++;
          return const ToolResult(content: 'x', isError: false);
        },
      );
      await session.send('go');
      await waitForState(session, (s) => s is Done);
      expect(resolverCalls, 0);
      final result = session.snapshot.messages.last.parts
          .whereType<ToolResultPart>()
          .single;
      expect(result.isError, isTrue);
      expect(result.content, 'unknown-tool');
    });

    test(
      'schema-invalid args → sanitised is_error, resolver untouched',
      () async {
        final fake = FakeChatBackend()
          ..requestTool('searchNotes', args: {'period': 42})
          ..reply('the bot reacts');
        var resolverCalls = 0;
        final session = makeSession(
          backend: fake,
          time: FakeTime(),
          botProfile: toolProfile,
          onToolCall: (call) async {
            resolverCalls++;
            return const ToolResult(content: 'x', isError: false);
          },
        );
        await session.send('go');
        await waitForState(session, (s) => s is Done);
        expect(resolverCalls, 0);
        final result = session.snapshot.messages.last.parts
            .whereType<ToolResultPart>()
            .single;
        expect(result.isError, isTrue);
        expect(result.content, 'invalid-tool-arguments');
      },
    );

    test('a resolver exception becomes a sanitised is_error result — no '
        'exception text leaks anywhere', () async {
      final fake = FakeChatBackend()
        ..requestTool('searchNotes', args: {'period': '2026-06'})
        ..reply('the bot reacts');
      final session = makeSession(
        backend: fake,
        time: FakeTime(),
        botProfile: toolProfile,
        onToolCall: (call) async =>
            throw StateError('SECRET-DB-PASSWORD in a stack trace'),
      );
      await session.send('go');
      await waitForState(session, (s) => s is Done);
      final result = session.snapshot.messages.last.parts
          .whereType<ToolResultPart>()
          .single;
      expect(result.isError, isTrue);
      expect(result.content, 'tool-execution-failed');
      expect(
        capturedRequestsOf(fake).last.messages.toString(),
        isNot(contains('SECRET')),
      );
    });
  });

  test('an existing matching ToolResultPart deduplicates: the resolver is '
      'never re-invoked for the same toolCallId', () async {
    // A loaded history whose interrupted reply already holds call_1 + its
    // result: a recovery re-run of that leg re-emits the same call.
    final fake = FakeChatBackend()
      ..requestTool('searchNotes', args: {'period': '2026-06'}) // → call_1
      ..reply('continues');
    var resolverCalls = 0;
    final session = makeSession(
      backend: fake,
      time: FakeTime(),
      botProfile: toolProfile,
      onToolCall: (call) async {
        resolverCalls++;
        return const ToolResult(content: 'fresh run', isError: false);
      },
      history: Conversation(
        messages: [
          userMessage('u-1', 'hi'),
          assistantMessage(
            'a-1',
            '',
            status: MessageStatus.interrupted,
            attemptKey: 'leg-key-1',
            parts: const [
              ContentPart.toolCall('call_1', 'searchNotes', {
                'period': '2026-06',
              }),
              ContentPart.toolResult('call_1', 'stored result', false),
            ],
          ),
        ],
      ),
    );
    await session.regenerate();
    await waitForState(session, (s) => s is Done);

    expect(resolverCalls, 0, reason: 'earlier legs are history, not work');
    final assistant = session.snapshot.messages.last;
    expect(
      assistant.parts.whereType<ToolCallPart>(),
      hasLength(1),
      reason: 'the re-delivered call is never appended twice',
    );
    expect(
      assistant.parts.whereType<ToolResultPart>().single.content,
      'stored result',
    );
    expect(visibleText(assistant), 'continues');
  });

  test(
    'the loop guard stops the cycle: Failed(toolLoopLimit), partial kept',
    () async {
      final fake = FakeChatBackend()
        ..requestTool('searchNotes', args: {'period': '1'})
        ..requestTool('searchNotes', args: {'period': '2'})
        ..requestTool('searchNotes', args: {'period': '3'});
      var resolverCalls = 0;
      final session = makeSession(
        backend: fake,
        time: FakeTime(),
        maxToolTurns: 2,
        botProfile: toolProfile,
        onToolCall: (call) async {
          resolverCalls++;
          return const ToolResult(content: 'ok', isError: false);
        },
      );
      await session.send('go');
      final failed = await waitForState(session, (s) => s is Failed) as Failed;
      expect(failed.cause, FailureCause.toolLoopLimit);
      expect(failed.phase, FailurePhase.streaming);
      expect(resolverCalls, 2, reason: 'the third call is refused, not run');
      final assistant = session.snapshot.messages.last;
      expect(assistant.status, MessageStatus.interrupted);
      expect(
        (assistant.parts.last as ToolCallPart).args,
        {'period': '3'},
        reason: 'the refused trailing call is kept on the interrupted reply',
      );
      expect(
        capturedRequestsOf(fake),
        hasLength(3),
        reason: 'exactly maxToolTurns billable tool legs after the first',
      );
    },
  );

  test('the tool-loop cap survives a restart: completed exchanges of the '
      'recovered reply count as used tool legs', () async {
    final fake = FakeChatBackend()
      ..requestTool('searchNotes', args: {'period': '2026-07'});
    var resolverCalls = 0;
    final session = makeSession(
      backend: fake,
      time: FakeTime(),
      maxToolTurns: 2,
      botProfile: toolProfile,
      onToolCall: (call) async {
        resolverCalls++;
        return const ToolResult(content: 'ok', isError: false);
      },
      history: Conversation(
        messages: [
          userMessage('u-1', 'hi'),
          Message(
            id: 'a-1',
            role: MessageRole.assistant,
            status: MessageStatus.interrupted,
            attemptKey: 'leg-key-3',
            createdAt: DateTime.utc(2026, 7, 10, 9, 1),
            parts: const [
              ContentPart.toolCall('done_1', 'searchNotes', {'period': '1'}),
              ContentPart.toolResult('done_1', 'r1', false),
              ContentPart.toolCall('done_2', 'searchNotes', {'period': '2'}),
              ContentPart.toolResult('done_2', 'r2', false),
              // The unmatched trailing call was never executed: it must NOT
              // count as a used leg…
              ContentPart.toolCall('open_3', 'searchNotes', {'period': '3'}),
            ],
          ),
        ],
      ),
    );
    await session.regenerate();
    final failed = await waitForState(session, (s) => s is Failed) as Failed;
    // …but the two completed exchanges do: the recovered reply already used
    // its entire cap of 2, so the re-delivered tool_call trips the guard
    // without reaching the resolver.
    expect(failed.cause, FailureCause.toolLoopLimit);
    expect(resolverCalls, 0);
    expect(
      capturedRequestsOf(fake),
      hasLength(1),
      reason: 'no billable tool leg beyond the cap after the restart',
    );
    expect(session.snapshot.messages.last.status, MessageStatus.interrupted);
  });

  test(
    'the profile of one logical reply stays frozen across its legs',
    () async {
      final fake = FakeChatBackend()
        ..requestTool('searchNotes', args: {'period': '2026-06'})
        ..reply('done under the old profile')
        ..reply('next command reply');
      final resolverGate = Completer<ToolResult>();
      late final ChatSession session;
      session = makeSession(
        backend: fake,
        time: FakeTime(),
        botProfile: toolProfile,
        onToolCall: (call) => resolverGate.future,
      );
      await session.send('go');
      await waitForState(session, (s) => s is AwaitingTool);

      // Switching bots mid-reply affects only the NEXT command.
      session.botProfile = const BotProfile(
        id: 'free',
        systemPrompt: 'be terse',
        tools: [],
      );
      resolverGate.complete(const ToolResult(content: 'ok', isError: false));
      await waitForState(session, (s) => s is Done);

      final requests = capturedRequestsOf(fake);
      expect(requests, hasLength(2));
      expect(requests.last.botId, 'premium');
      expect(requests.last.system, 'be kind');
      expect(
        requests.last.tools,
        [searchTool],
        reason: 'the tool-result leg rides the snapshotted profile',
      );

      await session.send('next');
      await waitForState(session, (s) => s is Done);
      expect(capturedRequestsOf(fake).last.botId, 'free');
      expect(capturedRequestsOf(fake).last.tools, isEmpty);
    },
  );

  test(
    'tool-leg checkpoint failure: assistant interrupted, '
    'Failed(upstream, streaming, checkpoint-failed), no second dispatch',
    () async {
      final fake = FakeChatBackend()
        ..requestTool('searchNotes', args: {'period': '2026-06'})
        ..reply('never dispatched');
      var checkpoints = 0;
      final session = makeSession(
        backend: fake,
        time: FakeTime(),
        botProfile: toolProfile,
        onToolCall: (call) async =>
            const ToolResult(content: 'ok', isError: false),
        checkpoint: (snapshot) async {
          checkpoints++;
          if (checkpoints == 2) {
            throw Exception('disk full on the tool leg');
          }
        },
      );
      await session.send('go');
      final failed = await waitForState(session, (s) => s is Failed) as Failed;
      expect(failed.cause, FailureCause.upstream);
      expect(failed.phase, FailurePhase.streaming);
      expect(failed.developerDetail, 'checkpoint-failed');
      expect(
        capturedRequestsOf(fake),
        hasLength(1),
        reason: 'the backend is never called after a failed checkpoint',
      );
      final assistant = session.snapshot.messages.last;
      expect(assistant.status, MessageStatus.interrupted);
      expect(
        assistant.parts.whereType<ToolResultPart>(),
        hasLength(1),
        reason: 'the applied tool result is kept for the next recovery',
      );
    },
  );
}
