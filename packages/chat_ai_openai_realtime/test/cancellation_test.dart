// Wire-cancel and teardown discipline (tests 18, 19, 23 of the task's
// minimum set + the corrective increment's regressions): pre-dispatch
// cancellation actively interrupts pending setup — the wait on the secret
// provider stops immediately (its late result/error is ignored, connect is
// never attempted), the signal reaches the transport which aborts and
// releases partial resources, and no `response.cancel` is sent;
// post-dispatch cancellation best-effort cancels the response, closes
// everything and delivers no late events; teardown runs exactly once and is
// idempotent, and its defects never become stream errors.

import 'dart:async';

import 'package:chat_ai/chat_ai.dart';
import 'package:chat_ai_openai_realtime/src/client_secret_provider.dart';
import 'package:chat_ai_openai_realtime/src/realtime_send_operation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

({Collector collector, FakeTransport transport, FakeConnection connection})
start({FakeTransport? transport, ClientSecretProvider? provider}) {
  final effectiveTransport = transport ?? FakeTransport();
  final stream = runRealtimeSend(
    clientSecretProvider: provider ?? RecordingSecretProvider(),
    transport: effectiveTransport,
    request: chatRequest(),
  );
  return (
    collector: Collector(stream),
    transport: effectiveTransport,
    connection: effectiveTransport.connection,
  );
}

void main() {
  test('cancellation during a never-completing secret Future: cancel '
      'completes immediately, connect is never attempted, the late '
      'result/error is ignored (regression 2)', () async {
    // Late ERROR is observed and swallowed — never an unhandled zone error.
    final errorProvider = HangingSecretProvider();
    final errorRun = start(provider: errorProvider);
    await pumpEventQueue(); // suspended awaiting the secret
    expect(errorProvider.calls, 1);

    await expectLater(errorRun.collector.subscription.cancel(), completes);
    await pumpEventQueue();
    expect(errorRun.transport.connectCalls, 0);

    errorProvider.completer.completeError(StateError('late secret failure'));
    await pumpEventQueue();
    expect(errorRun.transport.connectCalls, 0);
    expect(errorRun.collector.events, isEmpty);
    expect(errorRun.collector.errors, isEmpty);

    // Late VALUE is equally ignored: still no connect, no events.
    final valueProvider = HangingSecretProvider();
    final valueRun = start(provider: valueProvider);
    await pumpEventQueue();
    await valueRun.collector.subscription.cancel();

    valueProvider.completer.complete('late-secret');
    await pumpEventQueue();
    expect(valueRun.transport.connectCalls, 0);
    expect(valueRun.collector.events, isEmpty);
    expect(valueRun.collector.errors, isEmpty);
  });

  test('cancellation during pending connect actively interrupts setup: the '
      'signal reaches the transport, partial resources close, nothing is '
      'ever sent (tests 18, regression 3)', () async {
    final transport = FakeTransport()..gate = Completer<void>();
    final run = start(transport: transport);
    await pumpEventQueue(); // suspended inside transport.connect()
    expect(transport.connectCalls, 1);

    // The gate is deliberately NEVER completed: the cancel below must not
    // depend on the connect eventually succeeding.
    await expectLater(run.collector.subscription.cancel(), completes);
    await pumpEventQueue();

    expect(transport.receivedCancellation?.isCancelled, isTrue);
    expect(transport.abortedByCancellation, isTrue);
    // Partial resources are released; nothing was ever sent — neither
    // response.create nor response.cancel.
    expect(run.connection.closeCalls, 1);
    expect(run.connection.sent, isEmpty);
    expect(run.collector.events, isEmpty);
    expect(run.collector.errors, isEmpty);
  });

  test('a cancel racing a successful connect closes the connection exactly '
      'once and never sends response.create (regression 4)', () async {
    final transport = FakeTransport()
      ..gate = Completer<void>()
      ..ignoreCancellation = true;
    final run = start(transport: transport);
    await pumpEventQueue(); // suspended inside transport.connect()

    final cancelled = run.collector.subscription.cancel();
    transport.gate!.complete(); // connect completes successfully — too late
    await cancelled;
    await pumpEventQueue();

    expect(run.connection.closeCalls, 1);
    expect(run.connection.sent, isEmpty);
    expect(run.collector.events, isEmpty);
    expect(run.collector.errors, isEmpty);
  });

  test('cancellation after dispatch best-effort sends response.cancel with '
      'the known response_id, closes resources, delivers no late events '
      '(test 19)', () async {
    final run = start();
    await pumpEventQueue();
    run.connection.serverEvents.add(responseCreated(id: 'resp_42'));
    await pumpEventQueue();
    expect(run.collector.events, const [Accepted()]);

    await run.collector.subscription.cancel();
    // Late server events after the wire-cancel never reach the subscriber.
    if (!run.connection.serverEvents.isClosed) {
      run.connection.serverEvents.add(textDelta('late'));
      run.connection.serverEvents.add(responseDoneCompleted());
    }
    await pumpEventQueue();

    expect(run.connection.sentJson, hasLength(2));
    expect(run.connection.sentJson[0]['type'], 'response.create');
    expect(run.connection.sentJson[1], {
      'type': 'response.cancel',
      'response_id': 'resp_42',
    });
    expect(run.connection.closeCalls, 1);
    expect(run.collector.events, const [Accepted()]);
    expect(run.collector.errors, isEmpty);
  });

  test('cancellation after dispatch but before response.created sends '
      'response.cancel without a response_id (test 19)', () async {
    final run = start();
    await pumpEventQueue();
    expect(run.connection.sentResponseCreates, hasLength(1));

    await run.collector.subscription.cancel();
    await pumpEventQueue();

    expect(run.connection.sentJson, hasLength(2));
    expect(run.connection.sentJson[1], {'type': 'response.cancel'});
    expect(run.connection.closeCalls, 1);
    expect(run.collector.events, isEmpty);
  });

  test('teardown errors never surface: a failing close and a failing '
      'response.cancel still cancel cleanly', () async {
    final transport = FakeTransport();
    transport.connection.closeError = StateError('native close defect');
    final run = start(transport: transport);
    await pumpEventQueue();
    run.connection.sendError = StateError('channel already dead');

    // The wire-cancel completes normally despite both defects.
    await expectLater(run.collector.subscription.cancel(), completes);
    expect(run.connection.closeCalls, 1);
    expect(run.collector.errors, isEmpty);
  });

  test('teardown runs exactly once and is idempotent (test 23)', () async {
    final run = start();
    await pumpEventQueue();
    run.connection.serverEvents.add(responseCreated());
    run.connection.serverEvents.add(responseDoneCompleted());
    await pumpEventQueue();
    expect(run.collector.done, isTrue);
    // Terminal already tore the session down; the implicit post-done
    // subscription cancel and an explicit repeated cancel add nothing.
    expect(run.connection.closeCalls, 1);
    await run.collector.subscription.cancel();
    await run.collector.subscription.cancel();
    await pumpEventQueue();
    expect(run.connection.closeCalls, 1);
    // And no second billable dispatch ever happened.
    expect(run.connection.sentResponseCreates, hasLength(1));
    expect(run.transport.connectCalls, 1);
  });
}
