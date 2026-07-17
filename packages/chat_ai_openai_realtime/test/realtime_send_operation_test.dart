// One send() leg over the fake transport: secret handling, event mapping,
// the money-safe commit boundary and the never-throws stream contract
// (tests 1–4, 8, 10, 11, 14–17, 20–22 of the task's minimum set).

import 'dart:async';
import 'dart:convert';

import 'package:chat_ai/chat_ai.dart';
import 'package:chat_ai_openai_realtime/src/realtime_send_operation.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// JSON of a Realtime event with an arbitrary [type] (for non-progress /
/// unknown events the watchdog must ignore).
String eventOfType(String type, [Map<String, dynamic> extra = const {}]) =>
    jsonEncode(<String, dynamic>{'type': type, ...extra});

int cancelsIn(FakeConnection connection) =>
    connection.sentJson.where((m) => m['type'] == 'response.cancel').length;

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
  int maxOutputTokens = 4096,
  Duration responseIdleTimeout = const Duration(seconds: 60),
}) {
  final effectiveProvider = provider ?? RecordingSecretProvider();
  final effectiveTransport = transport ?? FakeTransport();
  final stream = runRealtimeSend(
    clientSecretProvider: effectiveProvider,
    transport: effectiveTransport,
    request: request ?? chatRequest(),
    maxOutputTokens: maxOutputTokens,
    responseIdleTimeout: responseIdleTimeout,
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
      transport: FakeTransport(connectError: StateError('handshake failed')),
    );
    await pumpEventQueue();
    expect(run.collector.events, hasLength(1));
    final error = run.collector.events.single as ErrorEvent;
    expect(error.cause, FailureCause.network);
    expect(error.detail, 'transport-connect-failed');
    expect(run.collector.errors, isEmpty);
    expect(run.collector.done, isTrue);
  });

  test('failure during/after the WebSocket send → upstream, and never '
      'a second response.create (tests 15, 17)', () async {
    final transport = FakeTransport();
    transport.connection.sendError = StateError('socket broke mid-send');
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

  // --- response idle watchdog (deterministic fake clock) --------------------

  const idle = Duration(seconds: 60);

  test('the idle watchdog does not exist before the commit boundary '
      '(test 5)', () {
    fakeAsync((async) {
      // Connect never completes → the leg never reaches the commit boundary,
      // so no timer is ever armed.
      final transport = FakeTransport()..gate = Completer<void>();
      final run = start(transport: transport, responseIdleTimeout: idle);
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 10));
      expect(run.collector.events, isEmpty);
      expect(run.collector.done, isFalse);
      expect(async.pendingTimers, isEmpty);
      run.collector.subscription.cancel();
      async.flushMicrotasks();
    });
  });

  test('the watchdog is armed just before send, fires a forever-hung '
      'response.create, and tears the leg down exactly once (tests 6, 13, '
      '17)', () {
    fakeAsync((async) {
      final transport = FakeTransport();
      transport.connection.sendGate = Completer<void>(); // send hangs forever
      final run = start(transport: transport, responseIdleTimeout: idle);
      async.flushMicrotasks();
      // The response.create was handed to the (hung) transport.
      expect(run.connection.sentResponseCreates, hasLength(1));
      expect(run.collector.events, isEmpty);
      async.elapse(idle);
      async.flushMicrotasks();
      // One terminal, and the leg actually completed and closed.
      final error = run.collector.events.single as ErrorEvent;
      expect(error.cause, FailureCause.upstream);
      expect(error.detail, 'response-idle-timeout');
      expect(run.collector.errors, isEmpty);
      expect(run.collector.done, isTrue);
      expect(run.connection.closeCalls, 1);
      // No retry/reconnect/second dispatch: one create, at most one cancel,
      // provider and connect exactly once.
      expect(run.provider.calls, 1);
      expect(run.transport.connectCalls, 1);
      expect(run.connection.sentResponseCreates, hasLength(1));
      expect(cancelsIn(run.connection), 1);
    });
  });

  test('after a timeout, a late-completing hung response.create send (success '
      'OR error) yields no second terminal, no retry and no unhandled zone '
      'error; close stays exactly once', () {
    for (final completeWithError in [false, true]) {
      final zoneErrors = <Object>[];
      runZonedGuarded(() {
        fakeAsync((async) {
          final transport = FakeTransport();
          final gate = Completer<void>();
          transport.connection.sendGate = gate;
          final run = start(transport: transport, responseIdleTimeout: idle);
          async.flushMicrotasks();
          async.elapse(idle);
          async.flushMicrotasks();
          expect(run.collector.events, hasLength(1));
          expect(run.connection.closeCalls, 1);
          // The hung response.create send Future settles only NOW, long after
          // the terminal.
          if (completeWithError) {
            gate.completeError(StateError('late send failure'));
          } else {
            gate.complete();
          }
          async.flushMicrotasks();
          // Still exactly one terminal and one close; no new create/connect.
          expect(run.collector.events, hasLength(1));
          expect(run.connection.closeCalls, 1);
          expect(run.connection.sentResponseCreates, hasLength(1));
          expect(run.transport.connectCalls, 1);
        });
      }, (error, _) => zoneErrors.add(error));
      expect(
        zoneErrors,
        isEmpty,
        reason: 'completeWithError=$completeWithError',
      );
    }
  });

  test('no terminal strictly before the deadline; exactly one upstream/'
      'response-idle-timeout at the deadline (test 7)', () {
    fakeAsync((async) {
      final run = start(responseIdleTimeout: idle);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 59));
      expect(run.collector.events, isEmpty);
      async.elapse(const Duration(seconds: 1));
      final error = run.collector.events.single as ErrorEvent;
      expect(error.cause, FailureCause.upstream);
      expect(error.detail, 'response-idle-timeout');
    });
  });

  test('response.created and a non-empty text delta each reset the countdown '
      '(test 8)', () {
    fakeAsync((async) {
      final run = start(responseIdleTimeout: idle);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 40));
      run.connection.serverEvents.add(responseCreated());
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 40)); // 40s since reset < 60
      run.connection.serverEvents.add(textDelta('hi'));
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 40)); // 40s since reset < 60
      expect(
        run.collector.events.whereType<ErrorEvent>(),
        isEmpty,
        reason: 'progress kept resetting the countdown',
      );
      async.elapse(const Duration(seconds: 20)); // now 60s idle since last
      expect(
        (run.collector.events.last as ErrorEvent).detail,
        'response-idle-timeout',
      );
    });
  });

  test('tool-call progress of the current Response resets the countdown '
      '(test 9)', () {
    fakeAsync((async) {
      final run = start(responseIdleTimeout: idle);
      async.flushMicrotasks();
      // The Response must be established first: only then are its progress
      // events attributable.
      run.connection.serverEvents.add(responseCreated());
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 40));
      run.connection.serverEvents.add(functionCallItemAdded());
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 40));
      run.connection.serverEvents.add(functionCallArgsDelta('{"c'));
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 40));
      run.connection.serverEvents.add(functionCallArgsDone('{"c":1}'));
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 40));
      expect(run.collector.events.whereType<ErrorEvent>(), isEmpty);
      async.elapse(const Duration(seconds: 20));
      expect(
        (run.collector.events.last as ErrorEvent).detail,
        'response-idle-timeout',
      );
    });
  });

  test('an event carrying a DIFFERENT response_id does not reset the '
      'countdown', () {
    fakeAsync((async) {
      final run = start(responseIdleTimeout: idle);
      async.flushMicrotasks();
      run.connection.serverEvents.add(responseCreated()); // binds resp_1
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 55));
      // A well-formed delta but of a FOREIGN Response.
      run.connection.serverEvents.add(textDelta('x', responseId: 'other_resp'));
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 5)); // 60s since response.created
      expect(
        (run.collector.events.last as ErrorEvent).detail,
        'response-idle-timeout',
      );
    });
  });

  test('structurally incomplete look-alike progress events do NOT reset the '
      'countdown', () {
    fakeAsync((async) {
      final run = start(responseIdleTimeout: idle);
      async.flushMicrotasks();
      run.connection.serverEvents.add(responseCreated());
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 55));
      // Each of these has the right type + response_id but is missing the
      // type-specific minimum structure.
      run.connection.serverEvents
        // text delta: missing item_id / indices
        ..add(
          eventOfType('response.output_text.delta', {
            'response_id': 'resp_1',
            'delta': 'x',
          }),
        )
        // content part: missing `part`
        ..add(
          eventOfType('response.content_part.added', {
            'response_id': 'resp_1',
            'item_id': 'item_1',
            'output_index': 0,
            'content_index': 0,
          }),
        )
        // output item: item without a non-empty `type`
        ..add(
          eventOfType('response.output_item.added', {
            'response_id': 'resp_1',
            'output_index': 0,
            'item': <String, dynamic>{'id': 'item_1'},
          }),
        )
        // function args delta: no matching call state yet
        ..add(
          eventOfType('response.function_call_arguments.delta', {
            'response_id': 'resp_1',
            'output_index': 9,
            'delta': '{',
          }),
        );
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 5)); // still the original deadline
      expect(
        (run.collector.events.last as ErrorEvent).detail,
        'response-idle-timeout',
      );
    });
  });

  test('a non-empty text delta with a NON-matching response_id still emits its '
      'Delta (mapping unchanged) but does NOT extend the watchdog', () {
    fakeAsync((async) {
      final run = start(responseIdleTimeout: idle);
      async.flushMicrotasks();
      run.connection.serverEvents.add(responseCreated()); // binds resp_1
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 55));
      run.connection.serverEvents.add(
        textDelta('visible', responseId: 'foreign'),
      );
      async.flushMicrotasks();
      // The Delta is still delivered (event→BackendEvent mapping is unchanged)…
      expect(
        run.collector.events.whereType<Delta>().map((d) => d.text),
        contains('visible'),
      );
      // …but it did not reset the countdown, which still fires at 60s.
      async.elapse(const Duration(seconds: 5));
      expect(
        (run.collector.events.last as ErrorEvent).detail,
        'response-idle-timeout',
      );
    });
  });

  test('rate_limits.updated, unknown events and an empty delta do NOT reset '
      'the countdown (test 10)', () {
    fakeAsync((async) {
      final run = start(responseIdleTimeout: idle);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 55));
      run.connection.serverEvents
        ..add(eventOfType('rate_limits.updated'))
        ..add(eventOfType('some.unknown.event'))
        ..add(textDelta('')); // empty delta
      async.flushMicrotasks();
      // None of those reset it → it still fires at the original 60s.
      async.elapse(const Duration(seconds: 5));
      expect(
        (run.collector.events.last as ErrorEvent).detail,
        'response-idle-timeout',
      );
    });
  });

  test('a successful response.done cancels the timer; advancing the clock '
      'afterwards changes nothing (test 11)', () {
    fakeAsync((async) {
      final run = start(responseIdleTimeout: idle);
      async.flushMicrotasks();
      run.connection.serverEvents.add(responseDoneCompleted());
      async.flushMicrotasks();
      expect(run.collector.events.single, isA<DoneEvent>());
      expect(async.pendingTimers, isEmpty);
      async.elapse(const Duration(minutes: 10));
      expect(run.collector.events.single, isA<DoneEvent>()); // still just Done
    });
  });

  test(
    'subscription cancel cancels the timer; no late ErrorEvent (test 12)',
    () {
      fakeAsync((async) {
        final run = start(responseIdleTimeout: idle);
        async.flushMicrotasks();
        run.collector.subscription.cancel();
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 10));
        expect(run.collector.events.whereType<ErrorEvent>(), isEmpty);
        expect(async.pendingTimers, isEmpty);
      });
    },
  );

  test('a timeout sends at most one response.cancel and one response.create; '
      'provider and connect ran exactly once (test 13)', () {
    fakeAsync((async) {
      final run = start(responseIdleTimeout: idle);
      async.flushMicrotasks();
      async.elapse(idle);
      async.flushMicrotasks();
      expect(run.provider.calls, 1);
      expect(run.transport.connectCalls, 1);
      expect(run.connection.sentResponseCreates, hasLength(1));
      expect(cancelsIn(run.connection), 1);
    });
  });

  test('a failing best-effort response.cancel does not change the timeout '
      'terminal and never becomes an unhandled error (test 14)', () {
    final zoneErrors = <Object>[];
    runZonedGuarded(() {
      fakeAsync((async) {
        final transport = FakeTransport();
        final run = start(transport: transport, responseIdleTimeout: idle);
        async.flushMicrotasks();
        // The response.cancel send throws.
        transport.connection.sendError = StateError('cancel failed');
        async.elapse(idle);
        async.flushMicrotasks();
        final error = run.collector.events.single as ErrorEvent;
        expect(error.cause, FailureCause.upstream);
        expect(error.detail, 'response-idle-timeout');
      });
    }, (error, _) => zoneErrors.add(error));
    expect(zoneErrors, isEmpty);
  });

  test('timeout and response.done are first-terminal-wins in both orders '
      '(test 15)', () {
    // done BEFORE the deadline → Done wins and cancels the timer; advancing
    // the clock past the deadline emits nothing more.
    fakeAsync((async) {
      final run = start(responseIdleTimeout: idle);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 30));
      run.connection.serverEvents.add(responseDoneCompleted());
      async.flushMicrotasks();
      expect(run.collector.events.single, isA<DoneEvent>());
      async.elapse(idle); // past the original deadline
      expect(run.collector.events.single, isA<DoneEvent>());
    });
    // timeout wins → exactly one ErrorEvent, and it stays the only terminal as
    // the clock keeps advancing (a would-be-late done can no longer be
    // delivered — the subscription is cancelled and the stream closed).
    fakeAsync((async) {
      final run = start(responseIdleTimeout: idle);
      async.flushMicrotasks();
      async.elapse(idle);
      async.flushMicrotasks();
      expect(run.collector.events.single, isA<ErrorEvent>());
      expect(
        (run.collector.events.single as ErrorEvent).detail,
        'response-idle-timeout',
      );
      async.elapse(const Duration(minutes: 10));
      expect(run.collector.events, hasLength(1));
    });
  });

  test('a timeout after partial deltas keeps the already-emitted deltas and '
      'ends with one ErrorEvent (test 16)', () {
    fakeAsync((async) {
      final run = start(responseIdleTimeout: idle);
      async.flushMicrotasks();
      run.connection.serverEvents
        ..add(responseCreated())
        ..add(textDelta('Hel'))
        ..add(textDelta('lo'));
      async.flushMicrotasks();
      async.elapse(idle); // 60s after the last delta reset
      final events = run.collector.events;
      expect(events.whereType<Delta>().map((d) => d.text), ['Hel', 'lo']);
      expect(events.last, isA<ErrorEvent>());
      expect((events.last as ErrorEvent).detail, 'response-idle-timeout');
      expect(events.whereType<ErrorEvent>(), hasLength(1));
    });
  });

  test(
    'a response.done also tears down exactly once (teardown regression)',
    () {
      fakeAsync((async) {
        final run = start(responseIdleTimeout: idle);
        async.flushMicrotasks();
        run.connection.serverEvents.add(responseCreated());
        run.connection.serverEvents.add(responseDoneCompleted());
        async.flushMicrotasks();
        expect(run.collector.events.last, isA<DoneEvent>());
        expect(run.collector.done, isTrue);
        expect(run.connection.closeCalls, 1);
      });
    },
  );
}
