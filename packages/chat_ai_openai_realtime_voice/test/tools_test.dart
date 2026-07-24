// The universal tools contract: synchronous configuration validation, the exact
// session tools payload, the resolver round-trip, unknown/invalid/throwing
// resolvers, duplicate call_ids, the tool-only leg (no audio-stopped), the single
// response.create per result, the money-safe per-reply limit, a late resolver
// result, one assistant turnId across the chain, and an ambiguous send failure
// that is never retried.
import 'dart:async';
import 'dart:convert';

import 'package:chat_ai/chat_ai.dart'
    show BotProfile, OnToolCall, Tool, ToolCall, ToolResult;
import 'package:chat_ai_openai_realtime_voice/chat_ai_openai_realtime_voice.dart';
import 'package:chat_ai_openai_realtime_voice/src/voice_session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

Tool _tool([String name = 'get_time']) => Tool(
  name: name,
  description: 'Return the current time.',
  parameters: const <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{
      'tz': <String, dynamic>{'type': 'string'},
    },
    'required': <String>['tz'],
    'additionalProperties': false,
  },
);

Map<String, Object?> _created = <String, Object?>{'type': 'session.created'};
Map<String, Object?> _updated = <String, Object?>{'type': 'session.updated'};

Map<String, Object?> _responseCreated(String id) => <String, Object?>{
  'type': 'response.created',
  'response': <String, Object?>{'id': id},
};

Map<String, Object?> _responseDone(String id) => <String, Object?>{
  'type': 'response.done',
  'response': <String, Object?>{'id': id, 'status': 'completed'},
};

Map<String, Object?> _responseDoneCall(
  String id, {
  required String callId,
  String name = 'get_time',
  String arguments = '{"tz":"UTC"}',
}) => <String, Object?>{
  'type': 'response.done',
  'response': <String, Object?>{
    'id': id,
    'status': 'completed',
    'output': <Object?>[
      <String, Object?>{
        'type': 'function_call',
        'call_id': callId,
        'name': name,
        'arguments': arguments,
      },
    ],
  },
};

Map<String, Object?> _outputStopped(String id) => <String, Object?>{
  'type': 'output_audio_buffer.stopped',
  'response_id': id,
};

// A completed response.done carrying an arbitrary list of raw output items.
Map<String, Object?> _responseDoneOutputs(
  String id,
  List<Map<String, Object?>> output,
) => <String, Object?>{
  'type': 'response.done',
  'response': <String, Object?>{
    'id': id,
    'status': 'completed',
    'output': output,
  },
};

Map<String, Object?> _fc({String? callId = 'c', String? name = 'get_time'}) =>
    <String, Object?>{
      'type': 'function_call',
      'call_id': ?callId,
      'name': ?name,
      'arguments': '{"tz":"UTC"}',
    };

Map<String, Object?> _delta(String id, String delta) => <String, Object?>{
  'type': 'response.output_audio_transcript.delta',
  'response_id': id,
  'item_id': 'i',
  'output_index': 0,
  'content_index': 0,
  'delta': delta,
};

int _countSent(FakeRealtimeVoiceTransport t, String type) =>
    t.sent.where((e) => e['type'] == type).length;

List<Map<String, Object?>> _toolOutputs(FakeRealtimeVoiceTransport t) => t.sent
    .where(
      (e) =>
          e['type'] == 'conversation.item.create' &&
          (e['item']! as Map)['type'] == 'function_call_output',
    )
    .cast<Map<String, Object?>>()
    .toList();

void main() {
  late FakeClientSecretProvider provider;
  late FakeRealtimeVoiceTransport transport;

  setUp(() {
    provider = FakeClientSecretProvider();
    transport = FakeRealtimeVoiceTransport();
  });

  OpenAIRealtimeVoiceSession build({
    required OnToolCall onToolCall,
    List<Tool> tools = const <Tool>[],
    int maxToolTurns = 5,
    bool transcriptsEnabled = false,
    OpenAIRealtimeVoiceMode mode = OpenAIRealtimeVoiceMode.conversation,
  }) {
    return voiceSessionForTesting(
      clientSecretProvider: provider,
      botProfile: BotProfile(
        id: 'bot',
        systemPrompt: 'be brief',
        tools: tools.isEmpty ? <Tool>[_tool()] : tools,
      ),
      transportFactory: () => transport,
      mode: mode,
      transcriptsEnabled: transcriptsEnabled,
      onToolCall: onToolCall,
      maxToolTurns: maxToolTurns,
    );
  }

  Future<void> reachListening(OpenAIRealtimeVoiceSession s) async {
    await s.start();
    transport.emit(_created);
    await pumpEventLoop();
    transport.emit(_updated);
    await pumpEventLoop();
  }

  // ---- Configuration validation (before the network) --------------------
  group('configuration validation', () {
    OpenAIRealtimeVoiceSession make({
      List<Tool>? tools,
      OnToolCall? onToolCall,
      int maxToolTurns = 5,
    }) => voiceSessionForTesting(
      clientSecretProvider: provider,
      botProfile: BotProfile(
        id: 'bot',
        systemPrompt: 'x',
        tools: tools ?? <Tool>[_tool()],
      ),
      transportFactory: () => transport,
      onToolCall: onToolCall,
      maxToolTurns: maxToolTurns,
    );

    test('non-empty tools without onToolCall is rejected before mint', () {
      expect(() => make(onToolCall: null), throwsArgumentError);
      expect(provider.calls, 0);
    });

    test('maxToolTurns <= 0 is rejected before mint', () {
      expect(
        () => make(
          onToolCall: (_) async =>
              const ToolResult(content: 'ok', isError: false),
          maxToolTurns: 0,
        ),
        throwsArgumentError,
      );
    });

    test('a duplicate tool name is rejected before mint', () {
      expect(
        () => make(
          tools: <Tool>[_tool('dup'), _tool('dup')],
          onToolCall: (_) async =>
              const ToolResult(content: 'ok', isError: false),
        ),
        throwsArgumentError,
      );
    });

    test('an invalid tool schema is rejected before mint', () {
      final bad = Tool(
        name: 'bad',
        description: 'x',
        // Root without properties/required/additionalProperties → invalid v1.
        parameters: const <String, dynamic>{'type': 'object'},
      );
      expect(
        () => make(
          tools: <Tool>[bad],
          onToolCall: (_) async =>
              const ToolResult(content: 'ok', isError: false),
        ),
        throwsArgumentError,
      );
    });

    test('valid tools + onToolCall construct fine', () {
      expect(
        make(
          onToolCall: (_) async =>
              const ToolResult(content: 'ok', isError: false),
        ),
        isA<OpenAIRealtimeVoiceSession>(),
      );
    });
  });

  test('the session.update carries the tools payload', () async {
    final s = build(
      onToolCall: (_) async => const ToolResult(content: 'ok', isError: false),
    );
    addTearDown(s.dispose);
    await reachListening(s);
    final update = transport.sent.firstWhere(
      (e) => e['type'] == 'session.update',
    );
    final session = update['session']! as Map<String, Object?>;
    expect(session['tool_choice'], 'auto');
    expect(session['parallel_tool_calls'], false);
    expect((session['tools']! as List).length, 1);
  });

  test(
    'a normal resolver round-trip: output then one response.create',
    () async {
      final calls = <ToolCall>[];
      final s = build(
        onToolCall: (call) async {
          calls.add(call);
          return const ToolResult(content: '12:00', isError: false);
        },
      );
      addTearDown(s.dispose);
      await reachListening(s);

      transport.emit(_responseCreated('r1'));
      await pumpEventLoop();
      transport.emit(_responseDoneCall('r1', callId: 'c1'));
      await pumpEventLoop();

      // The resolver ran exactly once with the parsed call.
      expect(calls.length, 1);
      expect(calls.single.id, 'c1');
      expect(calls.single.name, 'get_time');
      expect(calls.single.args, <String, dynamic>{'tz': 'UTC'});

      // Exactly one function_call_output (content → isError order) + one create.
      final outputs = _toolOutputs(transport);
      expect(outputs.length, 1);
      expect((outputs.single['item']! as Map)['call_id'], 'c1');
      expect(
        (outputs.single['item']! as Map)['output'],
        jsonEncode(<String, Object?>{'content': '12:00', 'isError': false}),
      );
      expect(_countSent(transport, 'response.create'), 1);

      // The continuation reply then completes normally.
      transport.emit(_responseCreated('r2'));
      await pumpEventLoop();
      transport.emit(_responseDone('r2'));
      transport.emit(_outputStopped('r2'));
      await pumpEventLoop();
      expect(s.state.phase, OpenAIRealtimeVoicePhase.listening);
    },
  );

  test(
    'unknown tool, invalid args and a throwing resolver → sanitized error',
    () async {
      // unknown tool name.
      final s1 = build(
        onToolCall: (_) async {
          fail('resolver must not run for an unknown tool');
        },
      );
      addTearDown(s1.dispose);
      await reachListening(s1);
      transport.emit(_responseCreated('r1'));
      await pumpEventLoop();
      transport.emit(_responseDoneCall('r1', callId: 'c1', name: 'nope'));
      await pumpEventLoop();
      final o1 = _toolOutputs(transport).single;
      expect((o1['item']! as Map)['output'], contains('"isError":true'));

      // invalid arguments (not a JSON object).
      final t2 = FakeRealtimeVoiceTransport();
      final s2 = voiceSessionForTesting(
        clientSecretProvider: FakeClientSecretProvider(),
        botProfile: BotProfile(
          id: 'b',
          systemPrompt: 'x',
          tools: <Tool>[_tool()],
        ),
        transportFactory: () => t2,
        mode: OpenAIRealtimeVoiceMode.conversation,
        onToolCall: (_) async {
          fail('resolver must not run for invalid args');
        },
      );
      addTearDown(s2.dispose);
      await s2.start();
      t2.emit(_created);
      await pumpEventLoop();
      t2.emit(_updated);
      await pumpEventLoop();
      t2.emit(_responseCreated('r1'));
      await pumpEventLoop();
      t2.emit(_responseDoneCall('r1', callId: 'c1', arguments: '[]'));
      await pumpEventLoop();
      final o2 = t2.sent
          .where(
            (e) =>
                e['type'] == 'conversation.item.create' &&
                (e['item']! as Map)['type'] == 'function_call_output',
          )
          .single;
      expect((o2['item']! as Map)['output'], contains('"isError":true'));

      // a throwing resolver — the exception text never rides the wire.
      final t3 = FakeRealtimeVoiceTransport();
      final s3 = voiceSessionForTesting(
        clientSecretProvider: FakeClientSecretProvider(),
        botProfile: BotProfile(
          id: 'b',
          systemPrompt: 'x',
          tools: <Tool>[_tool()],
        ),
        transportFactory: () => t3,
        mode: OpenAIRealtimeVoiceMode.conversation,
        onToolCall: (_) async => throw StateError('SUPER-SECRET-STACK'),
      );
      addTearDown(s3.dispose);
      await s3.start();
      t3.emit(_created);
      await pumpEventLoop();
      t3.emit(_updated);
      await pumpEventLoop();
      t3.emit(_responseCreated('r1'));
      await pumpEventLoop();
      t3.emit(_responseDoneCall('r1', callId: 'c1'));
      await pumpEventLoop();
      final o3 = t3.sent
          .where(
            (e) =>
                e['type'] == 'conversation.item.create' &&
                (e['item']! as Map)['type'] == 'function_call_output',
          )
          .single;
      expect((o3['item']! as Map)['output'], contains('"isError":true'));
      expect((o3['item']! as Map)['output'], isNot(contains('SUPER-SECRET')));
    },
  );

  // Defect 2: a repeat call_id is a terminal protocol/transport error.
  test(
    'a duplicate call_id is a terminal transport failure, not re-run',
    () async {
      var runs = 0;
      final s = build(
        onToolCall: (_) async {
          runs++;
          return const ToolResult(content: 'ok', isError: false);
        },
      );
      addTearDown(s.dispose);
      await reachListening(s);

      transport.emit(_responseCreated('r1'));
      await pumpEventLoop();
      transport.emit(_responseDoneCall('r1', callId: 'c1'));
      await pumpEventLoop();
      // The first leg ran once and dispatched exactly one output + one create.
      expect(runs, 1);
      expect(_toolOutputs(transport).length, 1);
      expect(_countSent(transport, 'response.create'), 1);

      transport.emit(_responseCreated('r2'));
      await pumpEventLoop();
      // The SAME call_id arrives again — a protocol violation → terminal transport
      // failure (one teardown), never re-run and never re-sent.
      transport.emit(_responseDoneCall('r2', callId: 'c1'));
      await pumpEventLoop();

      expect(runs, 1);
      expect(_toolOutputs(transport).length, 1);
      expect(_countSent(transport, 'response.create'), 1);
      expect(s.state.phase, OpenAIRealtimeVoicePhase.failed);
      expect(s.state.failure, OpenAIRealtimeVoiceFailure.transport);
      expect(transport.closeCalls, 1);
    },
  );

  // Defect 4: a malformed function call (missing/empty call_id or name)
  // terminates immediately — never mistaken for an audio completion.
  test('a malformed function call is a terminal transport failure', () async {
    for (final bad in <Map<String, Object?>>[
      <String, Object?>{'call_id': '', 'name': 'get_time'},
      <String, Object?>{'call_id': 'c1', 'name': ''},
      <String, Object?>{'name': 'get_time'}, // missing call_id
      <String, Object?>{'call_id': 'c1'}, // missing name
    ]) {
      final p = FakeClientSecretProvider();
      final t = FakeRealtimeVoiceTransport();
      var runs = 0;
      final s = voiceSessionForTesting(
        clientSecretProvider: p,
        botProfile: BotProfile(
          id: 'b',
          systemPrompt: 'x',
          tools: <Tool>[_tool()],
        ),
        transportFactory: () => t,
        mode: OpenAIRealtimeVoiceMode.conversation,
        onToolCall: (_) async {
          runs++;
          return const ToolResult(content: 'ok', isError: false);
        },
      );
      addTearDown(s.dispose);
      await s.start();
      t.emit(_created);
      await pumpEventLoop();
      t.emit(_updated);
      await pumpEventLoop();
      t.emit(_responseCreated('r1'));
      await pumpEventLoop();
      t.emit(<String, Object?>{
        'type': 'response.done',
        'response': <String, Object?>{
          'id': 'r1',
          'status': 'completed',
          'output': <Object?>[
            <String, Object?>{'type': 'function_call', ...bad},
          ],
        },
      });
      await pumpEventLoop();

      expect(runs, 0, reason: '$bad');
      expect(_toolOutputs(t), isEmpty, reason: '$bad');
      expect(t.sent.where((e) => e['type'] == 'response.create'), isEmpty);
      expect(s.state.phase, OpenAIRealtimeVoicePhase.failed, reason: '$bad');
      expect(s.state.failure, OpenAIRealtimeVoiceFailure.transport);
      expect(t.closeCalls, 1, reason: '$bad');
    }
  });

  // Defect 3: interruptResponse() while a tool resolver is pending invalidates
  // the tool chain (no meaningless cancel) and the late resolver result is inert.
  test('interruptResponse during a pending resolver (conversation)', () async {
    final gate = Completer<ToolResult>();
    final s = build(onToolCall: (_) => gate.future);
    addTearDown(s.dispose);
    await reachListening(s);
    transport.emit(_responseCreated('r1'));
    await pumpEventLoop();
    transport.emit(_responseDoneCall('r1', callId: 'c1'));
    await pumpEventLoop();

    await s.interruptResponse();
    await pumpEventLoop();
    // No meaningless response.cancel/clear (nothing was generating audio).
    expect(_countSent(transport, 'response.cancel'), 0);
    expect(_countSent(transport, 'output_audio_buffer.clear'), 0);
    expect(s.state.phase, OpenAIRealtimeVoicePhase.listening);

    // The late resolver result is inert — no output, no response.create.
    gate.complete(const ToolResult(content: 'late', isError: false));
    await pumpEventLoop();
    expect(_toolOutputs(transport), isEmpty);
    expect(_countSent(transport, 'response.create'), 0);
    expect(s.state.phase, OpenAIRealtimeVoicePhase.listening);
  });

  test(
    'interruptResponse during a pending resolver (singleTurn) ends',
    () async {
      final gate = Completer<ToolResult>();
      final s = build(
        mode: OpenAIRealtimeVoiceMode.singleTurn,
        onToolCall: (_) => gate.future,
      );
      addTearDown(s.dispose);
      await reachListening(s);
      transport.emit(<String, Object?>{
        'type': 'input_audio_buffer.speech_started',
        'item_id': 'u1',
        'audio_start_ms': 0,
      });
      await pumpEventLoop();
      transport.emit(<String, Object?>{
        'type': 'input_audio_buffer.speech_stopped',
        'item_id': 'u1',
        'audio_end_ms': 10,
      });
      await pumpEventLoop();
      transport.emit(_responseCreated('r1'));
      await pumpEventLoop();
      transport.emit(_responseDoneCall('r1', callId: 'c1'));
      await pumpEventLoop();

      await s.interruptResponse();
      await pumpEventLoop();
      expect(_countSent(transport, 'response.cancel'), 0);
      expect(s.state.phase, OpenAIRealtimeVoicePhase.ended);
      expect(transport.closeCalls, 1);

      gate.complete(const ToolResult(content: 'late', isError: false));
      await pumpEventLoop();
      expect(_toolOutputs(transport), isEmpty);
      expect(_countSent(transport, 'response.create'), 0);
    },
  );

  test('a tool-only leg needs no output_audio_buffer.stopped', () async {
    final s = build(
      onToolCall: (_) async => const ToolResult(content: 'ok', isError: false),
    );
    addTearDown(s.dispose);
    await reachListening(s);
    transport.emit(_responseCreated('r1'));
    await pumpEventLoop();
    // response.done (function_call) but NO output_audio_buffer.stopped ever.
    transport.emit(_responseDoneCall('r1', callId: 'c1'));
    await pumpEventLoop();
    // The result + one response.create were dispatched, and the session did not
    // fail or hang on a missing audio-stopped.
    expect(_toolOutputs(transport).length, 1);
    expect(_countSent(transport, 'response.create'), 1);
    expect(s.state.phase, isNot(OpenAIRealtimeVoicePhase.failed));
  });

  test('five resolver calls are allowed; the sixth is not executed', () async {
    var runs = 0;
    final s = build(
      onToolCall: (_) async {
        runs++;
        return const ToolResult(content: 'ok', isError: false);
      },
    );
    addTearDown(s.dispose);
    await reachListening(s);

    for (var i = 1; i <= 6; i++) {
      transport.emit(_responseCreated('r$i'));
      await pumpEventLoop();
      transport.emit(_responseDoneCall('r$i', callId: 'c$i'));
      await pumpEventLoop();
    }

    // Five resolver invocations; the sixth is refused with a terminal
    // toolLoopLimit and no function_call_output / response.create for it.
    expect(runs, 5);
    expect(_toolOutputs(transport).length, 5);
    expect(_countSent(transport, 'response.create'), 5);
    expect(s.state.phase, OpenAIRealtimeVoicePhase.failed);
    expect(s.state.failure, OpenAIRealtimeVoiceFailure.toolLoopLimit);
  });

  test('a late resolver result after a new user turn is inert', () async {
    final gate = Completer<ToolResult>();
    final s = build(onToolCall: (_) => gate.future);
    addTearDown(s.dispose);
    await reachListening(s);

    transport.emit(_responseCreated('r1'));
    await pumpEventLoop();
    transport.emit(_responseDoneCall('r1', callId: 'c1'));
    await pumpEventLoop();
    // A new user turn arises while the resolver is still pending.
    transport.emit(<String, Object?>{
      'type': 'input_audio_buffer.speech_started',
      'item_id': 'u2',
      'audio_start_ms': 0,
    });
    await pumpEventLoop();

    gate.complete(const ToolResult(content: 'late', isError: false));
    await pumpEventLoop();
    // The late result is dropped: no function_call_output, no response.create.
    expect(_toolOutputs(transport), isEmpty);
    expect(_countSent(transport, 'response.create'), 0);
  });

  test('a late resolver result after dispose is inert', () async {
    final gate = Completer<ToolResult>();
    final s = build(onToolCall: (_) => gate.future);
    await reachListening(s);
    transport.emit(_responseCreated('r1'));
    await pumpEventLoop();
    transport.emit(_responseDoneCall('r1', callId: 'c1'));
    await pumpEventLoop();
    await s.dispose();
    gate.complete(const ToolResult(content: 'late', isError: false));
    await pumpEventLoop();
    expect(_toolOutputs(transport), isEmpty);
    expect(_countSent(transport, 'response.create'), 0);
  });

  test('one assistant turnId spans the whole tool chain', () async {
    final deltas = <OpenAIRealtimeVoiceTranscriptDelta>[];
    final s = build(
      transcriptsEnabled: true,
      onToolCall: (_) async => const ToolResult(content: 'ok', isError: false),
    );
    addTearDown(s.dispose);
    s.assistantTranscriptDeltas.listen(deltas.add);
    await reachListening(s);

    // Leg 1 (a tool leg that also happens to stream a fragment).
    transport.emit(_responseCreated('r1'));
    await pumpEventLoop();
    transport.emit(_delta('r1', 'A'));
    await pumpEventLoop();
    transport.emit(_responseDoneCall('r1', callId: 'c1'));
    await pumpEventLoop();

    // Leg 2 (the continuation) streams too, then completes.
    transport.emit(_responseCreated('r2'));
    await pumpEventLoop();
    transport.emit(_delta('r2', 'B'));
    await pumpEventLoop();
    transport.emit(_responseDone('r2'));
    transport.emit(_outputStopped('r2'));
    await pumpEventLoop();

    // Both legs share ONE assistant turnId.
    final chainTurnIds = deltas.map((d) => d.turnId).toSet();
    expect(chainTurnIds.length, 1);

    // A brand-new logical reply after a user turn gets a DIFFERENT turnId.
    transport.emit(<String, Object?>{
      'type': 'input_audio_buffer.speech_started',
      'item_id': 'u2',
      'audio_start_ms': 0,
    });
    await pumpEventLoop();
    transport.emit(<String, Object?>{
      'type': 'input_audio_buffer.speech_stopped',
      'item_id': 'u2',
      'audio_end_ms': 10,
    });
    await pumpEventLoop();
    transport.emit(_responseCreated('r3'));
    await pumpEventLoop();
    transport.emit(_delta('r3', 'C'));
    await pumpEventLoop();
    expect(deltas.last.turnId, isNot(chainTurnIds.single));
  });

  test('an ambiguous output send failure is not retried', () async {
    final s = build(
      onToolCall: (_) async => const ToolResult(content: 'ok', isError: false),
    );
    addTearDown(s.dispose);
    await reachListening(s);
    transport.emit(_responseCreated('r1'));
    await pumpEventLoop();
    // The function_call_output send fails.
    transport.failSendTypes = <String>{'conversation.item.create'};
    transport.emit(_responseDoneCall('r1', callId: 'c1'));
    await pumpEventLoop();

    // Exactly one attempt; no retry; one terminal transport failure; no create.
    expect(
      transport.sendAttempts
          .where((t) => t == 'conversation.item.create')
          .length,
      1,
    );
    expect(_countSent(transport, 'response.create'), 0);
    expect(s.state.phase, OpenAIRealtimeVoicePhase.failed);
    expect(s.state.failure, OpenAIRealtimeVoiceFailure.transport);
    expect(transport.closeCalls, 1);
  });

  // ---- P1 defect 1: a full count of function_call items -------------------
  group('multiple / malformed function calls', () {
    test('two function calls in one response are terminal transport', () async {
      var runs = 0;
      final s = build(
        onToolCall: (_) async {
          runs++;
          return const ToolResult(content: 'ok', isError: false);
        },
      );
      addTearDown(s.dispose);
      await reachListening(s);
      transport.emit(_responseCreated('r1'));
      await pumpEventLoop();
      // parallel_tool_calls:false is always sent — two calls is a violation.
      transport.emit(
        _responseDoneOutputs('r1', <Map<String, Object?>>[
          _fc(callId: 'c1'),
          _fc(callId: 'c2'),
        ]),
      );
      await pumpEventLoop();
      expect(runs, 0);
      expect(_toolOutputs(transport), isEmpty);
      expect(_countSent(transport, 'response.create'), 0);
      expect(s.state.phase, OpenAIRealtimeVoicePhase.failed);
      expect(s.state.failure, OpenAIRealtimeVoiceFailure.transport);
      expect(transport.closeCalls, 1);
    });

    test(
      'one valid + one malformed function call is terminal transport',
      () async {
        var runs = 0;
        final s = build(
          onToolCall: (_) async {
            runs++;
            return const ToolResult(content: 'ok', isError: false);
          },
        );
        addTearDown(s.dispose);
        await reachListening(s);
        transport.emit(_responseCreated('r1'));
        await pumpEventLoop();
        transport.emit(
          _responseDoneOutputs('r1', <Map<String, Object?>>[
            _fc(callId: 'c1'),
            _fc(callId: ''), // malformed
          ]),
        );
        await pumpEventLoop();
        expect(runs, 0);
        expect(_toolOutputs(transport), isEmpty);
        expect(_countSent(transport, 'response.create'), 0);
        expect(s.state.phase, OpenAIRealtimeVoicePhase.failed);
        expect(s.state.failure, OpenAIRealtimeVoiceFailure.transport);
        expect(transport.closeCalls, 1);
      },
    );

    test('zero function calls is an ordinary audio completion', () async {
      final s = build(
        onToolCall: (_) async =>
            const ToolResult(content: 'ok', isError: false),
      );
      addTearDown(s.dispose);
      await reachListening(s);
      transport.emit(_responseCreated('r1'));
      await pumpEventLoop();
      transport.emit(_responseDone('r1'));
      transport.emit(_outputStopped('r1'));
      await pumpEventLoop();
      expect(_toolOutputs(transport), isEmpty);
      expect(s.state.phase, OpenAIRealtimeVoicePhase.listening);
      expect(s.state.failure, isNull);
    });
  });

  // ---- P1 defect 2: no pending-resolver race between turns ----------------
  test('a stale resolver cannot clear a newer turn\'s pending operation', () async {
    final g1 = Completer<ToolResult>();
    final g2 = Completer<ToolResult>();
    var calls = 0;
    final s = build(
      onToolCall: (_) {
        calls++;
        return calls == 1 ? g1.future : g2.future;
      },
    );
    addTearDown(s.dispose);
    await reachListening(s);

    // r1 tool leg → resolver r1 (gated).
    transport.emit(_responseCreated('r1'));
    await pumpEventLoop();
    transport.emit(_responseDoneCall('r1', callId: 'c1'));
    await pumpEventLoop();

    // A brand-new valid user turn arises (invalidating r1's operation).
    transport.emit(<String, Object?>{
      'type': 'input_audio_buffer.speech_started',
      'item_id': 'u2',
      'audio_start_ms': 0,
    });
    await pumpEventLoop();
    transport.emit(<String, Object?>{
      'type': 'input_audio_buffer.speech_stopped',
      'item_id': 'u2',
      'audio_end_ms': 10,
    });
    await pumpEventLoop();

    // r2 tool leg → resolver r2 (gated).
    transport.emit(_responseCreated('r2'));
    await pumpEventLoop();
    transport.emit(_responseDoneCall('r2', callId: 'c2'));
    await pumpEventLoop();

    // r1 completes LATE — it must be fully inert (no output/create) and must NOT
    // clear r2's pending operation.
    g1.complete(const ToolResult(content: 'r1 late', isError: false));
    await pumpEventLoop();
    expect(_toolOutputs(transport), isEmpty);
    expect(_countSent(transport, 'response.create'), 0);

    // interruptResponse() still sees and interrupts the CURRENT (r2) operation,
    // with NO cancel for a non-existent active generation.
    await s.interruptResponse();
    await pumpEventLoop();
    expect(_countSent(transport, 'response.cancel'), 0);
    expect(s.state.phase, OpenAIRealtimeVoicePhase.listening);

    // r2 completes late — inert too.
    g2.complete(const ToolResult(content: 'r2 late', isError: false));
    await pumpEventLoop();
    expect(_toolOutputs(transport), isEmpty);
    expect(_countSent(transport, 'response.create'), 0);
    expect(s.state.failure, isNull);
  });

  // ---- P1 race: ownership held through the gated function_call_output send --
  group('tool operation ownership across the gated output send', () {
    // Drives a session up to a HUNG function_call_output send (the resolver has
    // already returned; the output send is gated open), then returns the gate.
    Future<Completer<void>> reachHungOutput(
      OpenAIRealtimeVoiceSession s,
    ) async {
      await reachListening(s);
      transport.emit(_responseCreated('r1'));
      await pumpEventLoop();
      final gate = Completer<void>();
      transport.sendGate = gate;
      transport.emit(_responseDoneCall('r1', callId: 'c1'));
      await pumpEventLoop();
      // The function_call_output send is enqueued but hung on the gate; the
      // response.create has NOT been sent yet.
      expect(
        transport.sendAttempts
            .where((t) => t == 'conversation.item.create')
            .length,
        1,
      );
      expect(_countSent(transport, 'response.create'), 0);
      return gate;
    }

    test(
      'interrupt during the hung output → no response.create after release',
      () async {
        final s = build(
          onToolCall: (_) async =>
              const ToolResult(content: 'ok', isError: false),
        );
        addTearDown(s.dispose);
        final gate = await reachHungOutput(s);

        // Interrupt while the output send is still hung.
        await s.interruptResponse();
        await pumpEventLoop();
        expect(s.state.phase, OpenAIRealtimeVoicePhase.listening);

        // Release the gate: the now-stale output send is inert — no response.create.
        gate.complete();
        await pumpEventLoop();
        expect(_countSent(transport, 'response.create'), 0);
        // Output attempted exactly once; never repeated.
        expect(
          transport.sendAttempts
              .where((t) => t == 'conversation.item.create')
              .length,
          1,
        );
        expect(s.state.failure, isNull);
      },
    );

    test(
      'a new valid user turn during the window keeps the new state, no create',
      () async {
        final s = build(
          onToolCall: (_) async =>
              const ToolResult(content: 'ok', isError: false),
        );
        addTearDown(s.dispose);
        final gate = await reachHungOutput(s);

        // A brand-new valid user turn begins while the output send is hung.
        transport.emit(<String, Object?>{
          'type': 'input_audio_buffer.speech_started',
          'item_id': 'u2',
          'audio_start_ms': 0,
        });
        await pumpEventLoop();
        expect(s.state.phase, OpenAIRealtimeVoicePhase.userSpeaking);

        gate.complete();
        await pumpEventLoop();
        // The stale operation sends no response.create; the newer state is kept.
        expect(_countSent(transport, 'response.create'), 0);
        expect(s.state.phase, OpenAIRealtimeVoicePhase.userSpeaking);
      },
    );

    test('dispose during the window → a late success is inert', () async {
      final s = build(
        onToolCall: (_) async =>
            const ToolResult(content: 'ok', isError: false),
      );
      final gate = await reachHungOutput(s);

      final disposed = s.dispose();
      // Release the hung output send AFTER teardown began.
      gate.complete();
      await disposed;
      await pumpEventLoop();
      expect(_countSent(transport, 'response.create'), 0);
      expect(
        transport.sendAttempts
            .where((t) => t == 'conversation.item.create')
            .length,
        1,
      );
    });

    test(
      'stop during the window → a late ERROR of the send is inert (no unhandled error)',
      () async {
        final s = build(
          onToolCall: (_) async =>
              const ToolResult(content: 'ok', isError: false),
        );
        addTearDown(s.dispose);
        final gate = await reachHungOutput(s);

        await s.stop();
        // The hung output send now fails late — it must be caught and inert.
        gate.completeError(StateError('late transport error'));
        await pumpEventLoop();
        expect(_countSent(transport, 'response.create'), 0);
        // stop() is the terminal reason; no extra tool-driven transport failure.
        expect(s.state.phase, OpenAIRealtimeVoicePhase.ended);
      },
    );

    test(
      'the normal (ungated) flow still sends exactly one output then one create',
      () async {
        final s = build(
          onToolCall: (_) async =>
              const ToolResult(content: 'ok', isError: false),
        );
        addTearDown(s.dispose);
        await reachListening(s);
        transport.emit(_responseCreated('r1'));
        await pumpEventLoop();
        transport.emit(_responseDoneCall('r1', callId: 'c1'));
        await pumpEventLoop();
        expect(_toolOutputs(transport).length, 1);
        expect(_countSent(transport, 'response.create'), 1);
      },
    );
  });

  // ---- Defect 1: runtime argument validation against the tool schema -------
  group('runtime tool argument schema validation', () {
    // A rich Chat AI Tool Schema v1 tool exercising every construct.
    final complexTool = Tool(
      name: 'complex',
      description: 'x',
      parameters: const <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'name': <String, dynamic>{'type': 'string'},
          'count': <String, dynamic>{'type': 'integer'},
          'ratio': <String, dynamic>{'type': 'number'},
          'flag': <String, dynamic>{'type': 'boolean'},
          'color': <String, dynamic>{
            'type': 'string',
            'enum': <String>['red', 'green'],
          },
          'note': <String, dynamic>{
            'type': <String>['string', 'null'],
          },
          'nested': <String, dynamic>{
            'type': 'object',
            'properties': <String, dynamic>{
              'x': <String, dynamic>{'type': 'integer'},
            },
            'required': <String>['x'],
            'additionalProperties': false,
          },
          'tags': <String, dynamic>{
            'type': 'array',
            'items': <String, dynamic>{'type': 'string'},
          },
        },
        'required': <String>[
          'name',
          'count',
          'ratio',
          'flag',
          'color',
          'note',
          'nested',
          'tags',
        ],
        'additionalProperties': false,
      },
    );

    Map<String, dynamic> baseArgs() => <String, dynamic>{
      'name': 'n',
      'count': 2,
      'ratio': 1.5,
      'flag': true,
      'color': 'red',
      'note': null,
      'nested': <String, dynamic>{'x': 1},
      'tags': <String>['a', 'b'],
    };

    // Runs one tool call with [arguments] and returns whether the resolver ran
    // and whether the sent function_call_output was a sanitized error.
    Future<({int runs, bool isError})> run(String arguments) async {
      final p = FakeClientSecretProvider();
      final t = FakeRealtimeVoiceTransport();
      var runs = 0;
      final s = voiceSessionForTesting(
        clientSecretProvider: p,
        botProfile: BotProfile(
          id: 'b',
          systemPrompt: 'x',
          tools: <Tool>[complexTool],
        ),
        transportFactory: () => t,
        mode: OpenAIRealtimeVoiceMode.conversation,
        onToolCall: (_) async {
          runs++;
          return const ToolResult(content: 'ran', isError: false);
        },
      );
      addTearDown(s.dispose);
      await s.start();
      t.emit(_created);
      await pumpEventLoop();
      t.emit(_updated);
      await pumpEventLoop();
      t.emit(_responseCreated('r1'));
      await pumpEventLoop();
      t.emit(
        _responseDoneCall(
          'r1',
          callId: 'c1',
          name: 'complex',
          arguments: arguments,
        ),
      );
      await pumpEventLoop();
      final outputs = t.sent.where(
        (e) =>
            e['type'] == 'conversation.item.create' &&
            (e['item']! as Map)['type'] == 'function_call_output',
      );
      final isError =
          outputs.isNotEmpty &&
          ((outputs.first['item']! as Map)['output']! as String).contains(
            '"isError":true',
          );
      return (runs: runs, isError: isError);
    }

    Future<void> expectInvalid(Map<String, dynamic> args, String why) async {
      final r = await run(jsonEncode(args));
      expect(r.runs, 0, reason: '$why: resolver must NOT run');
      expect(r.isError, isTrue, reason: '$why: a sanitized error is sent');
    }

    test('a valid complex object calls the resolver exactly once', () async {
      final r = await run(jsonEncode(baseArgs()));
      expect(r.runs, 1);
      expect(r.isError, isFalse);
    });

    test('a nullable field accepts both null and the base type', () async {
      final withNull = await run(jsonEncode(baseArgs()..['note'] = null));
      expect(withNull.runs, 1);
      final withText = await run(jsonEncode(baseArgs()..['note'] = 'hi'));
      expect(withText.runs, 1);
    });

    test('a missing required field is invalid', () async {
      await expectInvalid(baseArgs()..remove('count'), 'missing required');
    });

    test('an unknown extra field is invalid', () async {
      await expectInvalid(baseArgs()..['extra'] = 1, 'extra field');
    });

    test('a wrong scalar type is invalid', () async {
      await expectInvalid(baseArgs()..['name'] = 123, 'wrong scalar type');
    });

    test('a non-integer value for an integer field is invalid', () async {
      await expectInvalid(baseArgs()..['count'] = 1.5, 'non-integer integer');
    });

    test('an out-of-enum value is invalid', () async {
      await expectInvalid(baseArgs()..['color'] = 'blue', 'enum');
    });

    test('a nullable field with a wrong non-null type is invalid', () async {
      await expectInvalid(baseArgs()..['note'] = 5, 'nullable wrong type');
    });

    test('an invalid nested object is invalid', () async {
      await expectInvalid(
        baseArgs()..['nested'] = <String, dynamic>{'x': 'bad'},
        'nested object',
      );
    });

    test('an array with a wrong item type is invalid', () async {
      await expectInvalid(baseArgs()..['tags'] = <int>[1, 2], 'array items');
    });

    test('non-object / malformed JSON arguments are invalid', () async {
      // A JSON array, a scalar, and unparseable text — never the resolver.
      for (final raw in <String>['[]', '"x"', 'not json', '']) {
        final r = await run(raw);
        expect(r.runs, 0, reason: raw);
        expect(r.isError, isTrue, reason: raw);
      }
    });
  });
}
