// One send() leg over the fake transport: secret handling, event mapping,
// the money-safe commit boundary and the never-throws stream contract
// (tests 1–4, 8, 10, 11, 14–17, 20–22 of the task's minimum set).

import 'dart:convert';

import 'package:chat_ai/chat_ai.dart';
import 'package:chat_ai_openai_realtime/src/realtime_send_operation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

({
  Collector collector,
  FakeTransport transport,
  FakeConnection connection,
  RecordingSecretProvider provider,
})
start({
  RecordingSecretProvider? provider,
  FakeTransport? transport,
  ChatRequest? request,
}) {
  final effectiveProvider = provider ?? RecordingSecretProvider();
  final effectiveTransport = transport ?? FakeTransport();
  final stream = runRealtimeSend(
    clientSecretProvider: effectiveProvider,
    transport: effectiveTransport,
    request: request ?? chatRequest(),
  );
  return (
    collector: Collector(stream),
    transport: effectiveTransport,
    connection: effectiveTransport.connection,
    provider: effectiveProvider,
  );
}

void main() {
  test(
    'ClientSecretProvider receives only botId, anew per send (test 1)',
    () async {
      final provider = RecordingSecretProvider();
      final transport = FakeTransport();
      final first = start(
        provider: provider,
        transport: transport,
        request: chatRequest(botId: 'bot-alpha'),
      );
      await pumpEventQueue();
      expect(provider.calls, 1);
      expect(provider.receivedBotIds, ['bot-alpha']);
      expect(transport.receivedSecrets, ['fake-ephemeral-secret']);

      // A second send() calls the provider anew.
      final secondTransport = FakeTransport();
      final second = start(
        provider: provider,
        transport: secondTransport,
        request: chatRequest(botId: 'bot-alpha'),
      );
      await pumpEventQueue();
      expect(provider.calls, 2);
      expect(provider.receivedBotIds, ['bot-alpha', 'bot-alpha']);

      expect(first.collector.errors, isEmpty);
      expect(second.collector.errors, isEmpty);
    },
  );

  test('provider exception → one sanitized upstream; stream never throws '
      '(test 2)', () async {
    final run = start(
      provider: RecordingSecretProvider(
        error: StateError('super-secret-token leaked details'),
      ),
    );
    await pumpEventQueue();
    expect(run.collector.events, hasLength(1));
    final error = run.collector.events.single as ErrorEvent;
    expect(error.cause, FailureCause.upstream);
    expect(error.detail, 'client-secret-failed');
    expect(error.detail, isNot(contains('super-secret-token')));
    expect(run.collector.errors, isEmpty);
    expect(run.collector.done, isTrue);
    expect(run.transport.connectCalls, 0);
  });

  test('empty secret → one sanitized upstream (test 2)', () async {
    final run = start(provider: RecordingSecretProvider(secret: ''));
    await pumpEventQueue();
    final error = run.collector.events.single as ErrorEvent;
    expect(error.cause, FailureCause.upstream);
    expect(error.detail, 'client-secret-empty');
    expect(run.collector.errors, isEmpty);
    expect(run.collector.done, isTrue);
    expect(run.transport.connectCalls, 0);
  });

  test('normal flow: created → deltas → completed done maps to '
      'Accepted → Delta* → Done(usage) (test 3)', () async {
    final run = start();
    await pumpEventQueue();
    expect(run.connection.sentResponseCreates, hasLength(1));

    run.connection.serverEvents.add(responseCreated());
    run.connection.serverEvents.add(textDelta('He'));
    run.connection.serverEvents.add(textDelta('')); // empty: dropped
    run.connection.serverEvents.add(textDelta('llo'));
    run.connection.serverEvents.add(responseCreated()); // duplicate: ignored
    run.connection.serverEvents.add(responseDoneCompleted());
    await pumpEventQueue();

    expect(run.collector.events, hasLength(4));
    expect(run.collector.events[0], const Accepted());
    expect(run.collector.events[1], const Delta('He'));
    expect(run.collector.events[2], const Delta('llo'));
    final done = run.collector.events[3] as DoneEvent;
    expect(done.usage?.inputTokens, 10);
    expect(done.usage?.outputTokens, 5);
    expect(done.usage?.usageRaw, usageJson());
    expect(run.collector.errors, isEmpty);
    expect(run.collector.done, isTrue);
  });

  test('nothing — especially Accepted — is emitted before response.created '
      '(test 4)', () async {
    final run = start();
    await pumpEventQueue();
    // Secret fetched, session connected, response.create dispatched — and
    // still no event: Accepted means the SERVER said response.created.
    expect(run.connection.sentResponseCreates, hasLength(1));
    expect(run.collector.events, isEmpty);

    run.connection.serverEvents.add(responseCreated());
    await pumpEventQueue();
    expect(run.collector.events, const [Accepted()]);
  });

  test('completed done without usage → upstream, never faked zeros', () async {
    final run = start();
    await pumpEventQueue();
    run.connection.serverEvents.add(responseCreated());
    run.connection.serverEvents.add(responseDoneCompletedWithoutUsage());
    await pumpEventQueue();
    final error = run.collector.events.last as ErrorEvent;
    expect(error.cause, FailureCause.upstream);
    expect(error.detail, 'missing-usage');
  });

  test('malformed usage (negative/fractional) → upstream', () async {
    final run = start();
    await pumpEventQueue();
    run.connection.serverEvents.add(responseCreated());
    run.connection.serverEvents.add(
      responseDoneCompleted(
        usage: <String, dynamic>{'input_tokens': -1, 'output_tokens': 5},
      ),
    );
    await pumpEventQueue();
    expect(
      (run.collector.events.last as ErrorEvent).cause,
      FailureCause.upstream,
    );
  });

  test('one function call with object args and usage → terminal ToolCallEvent '
      '(test 8)', () async {
    final run = start();
    await pumpEventQueue();
    run.connection.serverEvents.add(responseCreated());
    run.connection.serverEvents.add(functionCallItemAdded());
    run.connection.serverEvents.add(functionCallArgsDelta('{"ci'));
    run.connection.serverEvents.add(functionCallArgsDelta('ty":"Kyiv"}'));
    run.connection.serverEvents.add(functionCallArgsDone('{"city":"Kyiv"}'));
    run.connection.serverEvents.add(responseDoneCompleted());
    await pumpEventQueue();

    expect(run.collector.events, hasLength(2));
    final toolCall = run.collector.events.last as ToolCallEvent;
    expect(toolCall.call.id, 'call_1');
    expect(toolCall.call.name, 'get_weather');
    expect(toolCall.call.args, {'city': 'Kyiv'});
    expect(toolCall.usage?.inputTokens, 10);
    expect(toolCall.usage?.outputTokens, 5);
    expect(run.collector.done, isTrue);
    expect(run.collector.errors, isEmpty);
  });

  test(
    'buffered argument deltas alone are enough when arguments.done is lost',
    () async {
      final run = start();
      await pumpEventQueue();
      run.connection.serverEvents.add(responseCreated());
      run.connection.serverEvents.add(functionCallItemAdded());
      run.connection.serverEvents.add(functionCallArgsDelta('{"city":"Kyiv"}'));
      run.connection.serverEvents.add(responseDoneCompleted());
      await pumpEventQueue();
      final toolCall = run.collector.events.last as ToolCallEvent;
      expect(toolCall.call.args, {'city': 'Kyiv'});
    },
  );

  test('a second function call → one upstream (test 10)', () async {
    final run = start();
    await pumpEventQueue();
    run.connection.serverEvents.add(responseCreated());
    run.connection.serverEvents.add(functionCallItemAdded(outputIndex: 0));
    run.connection.serverEvents.add(
      functionCallItemAdded(outputIndex: 1, callId: 'call_2'),
    );
    run.connection.serverEvents.add(responseDoneCompleted()); // late: ignored
    await pumpEventQueue();

    expect(run.collector.events, hasLength(2));
    final error = run.collector.events.last as ErrorEvent;
    expect(error.cause, FailureCause.upstream);
    expect(error.detail, 'second-function-call');
    expect(run.collector.done, isTrue);
  });

  test('malformed function args → one upstream (test 11)', () async {
    for (final arguments in ['{"broken', '"scalar"', '[1,2]', 'null']) {
      final run = start();
      await pumpEventQueue();
      run.connection.serverEvents.add(responseCreated());
      run.connection.serverEvents.add(functionCallItemAdded());
      run.connection.serverEvents.add(functionCallArgsDone(arguments));
      run.connection.serverEvents.add(responseDoneCompleted());
      await pumpEventQueue();
      expect(run.collector.events, hasLength(2), reason: arguments);
      final error = run.collector.events.last as ErrorEvent;
      expect(error.cause, FailureCause.upstream, reason: arguments);
      expect(error.detail, 'malformed-function-call', reason: arguments);
    }
  });

  test('failure before the commit boundary → network (test 14)', () async {
    final run = start(
      transport: FakeTransport(connectError: StateError('ice failed')),
    );
    await pumpEventQueue();
    expect(run.collector.events, hasLength(1));
    final error = run.collector.events.single as ErrorEvent;
    expect(error.cause, FailureCause.network);
    expect(error.detail, 'transport-connect-failed');
    expect(run.collector.errors, isEmpty);
    expect(run.collector.done, isTrue);
  });

  test('failure during/after the RTCDataChannel send → upstream, and never '
      'a second response.create (tests 15, 17)', () async {
    final transport = FakeTransport();
    transport.connection.sendError = StateError('channel broke mid-send');
    final run = start(transport: transport);
    await pumpEventQueue();
    final error = run.collector.events.single as ErrorEvent;
    expect(error.cause, FailureCause.upstream);
    expect(error.detail, 'transport-send-failed');
    // The ambiguous dispatch is never retried by this backend.
    expect(transport.connectCalls, 1);
    expect(transport.connection.sent, isEmpty);
    expect(run.collector.done, isTrue);
  });

  test('post-commit disconnect before response.created → upstream '
      '(tests 16, 17)', () async {
    final run = start();
    await pumpEventQueue();
    expect(run.connection.sentResponseCreates, hasLength(1));
    await run.connection.serverEvents.close(); // EOF before any server event
    await pumpEventQueue();
    final error = run.collector.events.single as ErrorEvent;
    expect(error.cause, FailureCause.upstream);
    expect(error.detail, 'transport-closed');
    expect(run.transport.connectCalls, 1);
    expect(run.connection.sentResponseCreates, hasLength(1));
  });

  test('server error event → upstream; context overflow code → '
      'contextTooLong', () async {
    final upstreamRun = start();
    await pumpEventQueue();
    upstreamRun.connection.serverEvents.add(
      jsonEncode(<String, dynamic>{
        'type': 'error',
        'error': <String, dynamic>{
          'type': 'server_error',
          'code': 'internal',
          'message': 'raw provider text that must not leak',
        },
      }),
    );
    await pumpEventQueue();
    final upstreamError = upstreamRun.collector.events.single as ErrorEvent;
    expect(upstreamError.cause, FailureCause.upstream);
    expect(upstreamError.detail, isNot(contains('raw provider text')));

    final overflowRun = start();
    await pumpEventQueue();
    overflowRun.connection.serverEvents.add(
      jsonEncode(<String, dynamic>{
        'type': 'error',
        'error': <String, dynamic>{'code': 'context_length_exceeded'},
      }),
    );
    await pumpEventQueue();
    expect(
      (overflowRun.collector.events.single as ErrorEvent).cause,
      FailureCause.contextTooLong,
    );
  });

  test('documented content filter terminal → contentFilter', () async {
    final run = start();
    await pumpEventQueue();
    run.connection.serverEvents.add(responseCreated());
    run.connection.serverEvents.add(
      jsonEncode(<String, dynamic>{
        'type': 'response.done',
        'response': <String, dynamic>{
          'id': 'resp_1',
          'status': 'incomplete',
          'status_details': <String, dynamic>{
            'type': 'incomplete',
            'reason': 'content_filter',
          },
          'usage': usageJson(),
        },
      }),
    );
    await pumpEventQueue();
    final error = run.collector.events.last as ErrorEvent;
    expect(error.cause, FailureCause.contentFilter);
    expect(error.usage?.inputTokens, 10); // best-effort usage kept
  });

  test('failed/unknown response.done outcome → upstream', () async {
    for (final status in ['failed', 'cancelled', 'weird-new-status']) {
      final run = start();
      await pumpEventQueue();
      run.connection.serverEvents.add(responseCreated());
      run.connection.serverEvents.add(
        jsonEncode(<String, dynamic>{
          'type': 'response.done',
          'response': <String, dynamic>{'id': 'resp_1', 'status': status},
        }),
      );
      await pumpEventQueue();
      final error = run.collector.events.last as ErrorEvent;
      expect(error.cause, FailureCause.upstream, reason: status);
    }
  });

  test(
    'EOF without terminal after visible output → one upstream (test 20)',
    () async {
      final run = start();
      await pumpEventQueue();
      run.connection.serverEvents.add(responseCreated());
      run.connection.serverEvents.add(textDelta('partial'));
      await pumpEventQueue();
      await run.connection.serverEvents.close();
      await pumpEventQueue();
      expect(run.collector.events, [
        const Accepted(),
        const Delta('partial'),
        const ErrorEvent(FailureCause.upstream, detail: 'transport-closed'),
      ]);
      expect(run.collector.done, isTrue);
      // Post-commit ambiguity never dispatches again (test 17).
      expect(run.transport.connectCalls, 1);
      expect(run.connection.sentResponseCreates, hasLength(1));
    },
  );

  test('duplicate/late terminal is ignored (test 21)', () async {
    final run = start();
    await pumpEventQueue();
    run.connection.serverEvents.add(responseCreated());
    run.connection.serverEvents.add(responseDoneCompleted());
    await pumpEventQueue();
    expect(run.collector.events, hasLength(2));
    expect(run.collector.done, isTrue);

    // Late duplicates after the terminal: nothing changes, nothing throws.
    if (!run.connection.serverEvents.isClosed) {
      run.connection.serverEvents.add(responseDoneCompleted());
      run.connection.serverEvents.add(textDelta('late'));
    }
    await pumpEventQueue();
    expect(run.collector.events, hasLength(2));
    expect(run.collector.errors, isEmpty);
  });

  test('the backend stream never throws — not even on malformed server JSON '
      'or non-Exception errors (test 22)', () async {
    final malformedRun = start();
    await pumpEventQueue();
    malformedRun.connection.serverEvents.add('not json at all {{{');
    await pumpEventQueue();
    expect(malformedRun.collector.errors, isEmpty);
    final malformedError = malformedRun.collector.events.single as ErrorEvent;
    expect(malformedError.cause, FailureCause.upstream);
    expect(malformedError.detail, 'malformed-event');

    final errorRun = start(provider: RecordingSecretProvider(error: Error()));
    await pumpEventQueue();
    expect(errorRun.collector.errors, isEmpty);
    expect(errorRun.collector.events.single, isA<ErrorEvent>());
    expect(errorRun.collector.done, isTrue);
  });
}
