// The internal lifecycle of the normalized SSE event stream (V1_SPEC §8 "SSE
// parser contract", §12.16; SERVER-CONTRACT §2): Stream<SseFrame> →
// Stream<BackendEvent> with first-terminal-wins, converted parser defects,
// the EOF policy and pass-through transport errors. Imports internal files
// directly — decodeSseEventStream is NOT exported from
// package:chat_ai/chat_ai.dart.
import 'dart:convert';

import 'package:chat_ai/chat_ai.dart';
import 'package:chat_ai_firebase/src/backend/sse_event_stream.dart';
import 'package:chat_ai_firebase/src/backend/sse_parser.dart';
import 'package:flutter/foundation.dart' show DebugPrintCallback, debugPrint;
import 'package:flutter_test/flutter_test.dart';

SseFrame deltaFrame(String text) =>
    SseFrame(event: 'delta', data: '{"text":"$text"}');

const SseFrame doneFrame = SseFrame(event: 'done', data: '{}');
const SseFrame toolCallFrame = SseFrame(
  event: 'tool_call',
  data: '{"id":"c1","name":"n","args":{}}',
);
const SseFrame errorFrame = SseFrame(event: 'error', data: '{"cause":"rate"}');
const SseFrame providerStateFrame = SseFrame(
  event: 'provider_state',
  data: '{"provider":"openai","data":"AQID"}',
);

const BackendEvent doneEvent = BackendEvent.done();
const BackendEvent toolCallEvent = BackendEvent.toolCall(
  ToolCall(id: 'c1', name: 'n', args: {}),
);
const BackendEvent rateErrorEvent = BackendEvent.error(FailureCause.rate);

/// Runs the lifecycle over an error-free frame sequence.
Future<List<BackendEvent>> lifecycle(Iterable<SseFrame> frames) =>
    decodeSseEventStream(Stream.fromIterable(frames)).toList();

/// A frame stream that emits [before], then [error], then [after].
Stream<SseFrame> framesWithError(
  Iterable<SseFrame> before,
  Object error, [
  Iterable<SseFrame> after = const [],
]) async* {
  yield* Stream.fromIterable(before);
  yield* Stream<SseFrame>.error(error);
  yield* Stream.fromIterable(after);
}

/// Collects the lifecycle output while capturing the debug markers this
/// layer sends through [debugPrint].
Future<(List<BackendEvent>, List<String>)> lifecycleWithMarkers(
  Stream<SseFrame> frames,
) async {
  final markers = <String>[];
  final DebugPrintCallback original = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    markers.add(message ?? '');
  };
  try {
    return (await decodeSseEventStream(frames).toList(), markers);
  } finally {
    debugPrint = original;
  }
}

/// Asserts [event] is a converted-defect terminal: `ErrorEvent(upstream)`
/// with a non-null logs-only detail (exact texts are not pinned).
void expectUpstreamError(BackendEvent event, {required String reason}) {
  expect(event, isA<ErrorEvent>(), reason: reason);
  final error = event as ErrorEvent;
  expect(error.cause, FailureCause.upstream, reason: reason);
  expect(error.detail, isNotNull, reason: reason);
}

void main() {
  final providerStateEvent = BackendEvent.providerState(
    ProviderOpaquePart('openai', base64Decode('AQID')),
  );

  group('pre-terminal pass-through', () {
    test('decoded events are emitted unchanged and in order '
        '(provider_state ordered relative to delta)', () async {
      expect(
        await lifecycle([
          deltaFrame('a'),
          providerStateFrame,
          deltaFrame('b'),
          doneFrame,
        ]),
        [
          const BackendEvent.delta('a'),
          providerStateEvent,
          const BackendEvent.delta('b'),
          doneEvent,
        ],
      );
    });
  });

  group('first terminal wins', () {
    const terminals = [
      ('tool_call', toolCallFrame, toolCallEvent),
      ('done', doneFrame, doneEvent),
      ('error', errorFrame, rateErrorEvent),
    ];

    test('each terminal is emitted exactly once; duplicate terminals and later '
        'frames are ignored with debug markers only', () async {
      for (final (label, frame, expected) in terminals) {
        final (events, markers) = await lifecycleWithMarkers(
          Stream.fromIterable([
            frame,
            frame, // duplicate terminal
            toolCallFrame, // another terminal kind
            deltaFrame('late'), // nonterminal after terminal
            // A late terminal-named frame with defective JSON data: it must
            // be classified by frame.event alone, never decoded.
            const SseFrame(event: 'tool_call', data: '{oops'),
          ]),
        );
        expect(events, [expected], reason: '$label must close the stream');
        const prefix = 'chat_ai SSE lifecycle: ';
        expect(
          markers,
          const [
            '${prefix}duplicate terminal ignored',
            '${prefix}duplicate terminal ignored',
            '${prefix}event after terminal ignored',
            '${prefix}duplicate terminal ignored',
          ],
          reason:
              '$label: one marker per ignored frame, classified by '
              'frame.event alone — the malformed late tool_call is a '
              'duplicate terminal, not decoded and not echoed',
        );
      }
    });

    test('EOF right after a terminal adds no extra event', () async {
      for (final (label, frame, expected) in terminals) {
        expect(
          await lifecycle([frame]),
          [expected],
          reason: '$label: no EOF ErrorEvent after a terminal',
        );
      }
    });
  });

  group('converted parser defects (decode FormatException)', () {
    test('a defective frame before terminal becomes exactly one terminal '
        'upstream ErrorEvent; the remaining frames are ignored', () async {
      const defects = [
        ('malformed JSON', SseFrame(event: 'delta', data: '{oops')),
        ('unknown event', SseFrame(event: 'message', data: '{}')),
        ('missing event name', SseFrame(data: '{"text":"x"}')),
      ];
      for (final (label, defective) in defects) {
        final (events, _) = await lifecycleWithMarkers(
          Stream.fromIterable([
            deltaFrame('a'),
            defective,
            deltaFrame('b'),
            doneFrame,
          ]),
        );
        expect(events, hasLength(2), reason: '$label: defect is terminal');
        expect(events.first, const BackendEvent.delta('a'), reason: label);
        expectUpstreamError(events[1], reason: label);
      }
    });
  });

  group('frame-stream FormatException (framing / strict UTF-8)', () {
    test('before terminal it becomes exactly one upstream ErrorEvent, '
        'not a stream error', () async {
      final events = await decodeSseEventStream(
        framesWithError([deltaFrame('a')], const FormatException('framing')),
      ).toList();
      expect(events, hasLength(2));
      expect(events.first, const BackendEvent.delta('a'));
      expectUpstreamError(events[1], reason: 'framing error must convert');
    });

    test('after terminal: no second event and no stream error', () async {
      final (events, markers) = await lifecycleWithMarkers(
        framesWithError([doneFrame], const FormatException('late framing')),
      );
      expect(events, [doneEvent]);
      expect(markers, hasLength(1), reason: 'debug marker only');
    });
  });

  group('EOF without terminal', () {
    test('EOF after a nonterminal delta yields the delta plus exactly one '
        'upstream ErrorEvent', () async {
      final events = await lifecycle([deltaFrame('a')]);
      expect(events, hasLength(2));
      expect(events.first, const BackendEvent.delta('a'));
      expectUpstreamError(events[1], reason: 'EOF without terminal');
    });

    test(
      'a completely empty stream yields exactly one upstream ErrorEvent',
      () async {
        final events = await lifecycle(const []);
        expect(events, hasLength(1));
        expectUpstreamError(events.single, reason: 'empty stream');
      },
    );
  });

  group('transport errors (non-FormatException)', () {
    test(
      'before terminal the error passes through as a stream error',
      () async {
        final received = <BackendEvent>[];
        await expectLater(
          decodeSseEventStream(
            framesWithError([deltaFrame('a')], StateError('socket reset')),
          ).forEach(received.add),
          throwsStateError,
        );
        expect(received, [const BackendEvent.delta('a')]);
      },
    );

    test(
      'after terminal the error is ignored with a debug marker only',
      () async {
        final (events, markers) = await lifecycleWithMarkers(
          framesWithError([doneFrame], StateError('late socket reset')),
        );
        expect(events, [doneEvent]);
        expect(markers, hasLength(1));
      },
    );
  });

  group('sanitization (no wire payload leakage)', () {
    test('details and debug markers never contain frame data, unknown event '
        'names or exception message/source', () async {
      const sentinel = 'LEAK_SENTINEL_51b3a';
      // Run 1: a decode defect embedding the sentinel becomes the terminal;
      // post-terminal frames and a late frame-stream FormatException (with
      // the sentinel in message and source) produce debug markers only.
      final (events, markers) = await lifecycleWithMarkers(
        framesWithError([
          SseFrame(event: '$sentinel-event', data: '{"note":"$sentinel"}'),
          SseFrame(event: 'delta', data: '{"text":"$sentinel"}'),
          doneFrame,
          SseFrame(event: '$sentinel-late', data: sentinel),
        ], FormatException('utf-8 $sentinel', '$sentinel-source')),
      );
      expect(events, hasLength(1));
      expectUpstreamError(events.single, reason: 'converted decode defect');
      expect(markers, isNotEmpty, reason: 'debug diagnostics must fire');

      // Run 2: a frame-stream FormatException before terminal — its
      // converted detail must be the stable constant, not exception text.
      final (events2, markers2) = await lifecycleWithMarkers(
        framesWithError(const [], FormatException('utf-8 $sentinel', sentinel)),
      );
      expect(events2, hasLength(1));
      expectUpstreamError(events2.single, reason: 'converted framing error');

      final details = [
        for (final event in [...events, ...events2])
          if (event is ErrorEvent && event.detail != null) event.detail!,
      ];
      expect(details, isNotEmpty);
      for (final text in [...details, ...markers, ...markers2]) {
        expect(
          text.contains(sentinel),
          isFalse,
          reason: '"$text" must not leak the sentinel',
        );
      }
    });
  });
}
