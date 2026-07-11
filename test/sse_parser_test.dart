// The internal SSE framing layer (V1_SPEC §8 "SSE parser contract", the
// framing subset of §12.16): bytes → SseFrame, no JSON, no BackendEvent.
// Imports the internal file directly — the type is deliberately NOT exported
// from package:chat_ai/chat_ai.dart.
import 'dart:convert';

import 'package:chat_ai/src/backend/sse_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// Frames a stream assembled from string chunks (each chunk UTF-8 encoded).
Future<List<SseFrame>> frames(Iterable<String> chunks) => parseSseFrames(
  Stream.fromIterable([for (final chunk in chunks) utf8.encode(chunk)]),
).toList();

/// Frames a stream assembled from raw byte chunks.
Future<List<SseFrame>> byteFrames(Iterable<List<int>> chunks) =>
    parseSseFrames(Stream.fromIterable(chunks.toList())).toList();

void main() {
  group('basic framing', () {
    test('a plain ASCII event frames into event + data', () async {
      expect(await frames(['event: delta\ndata: {"text":"hi"}\n\n']), const [
        SseFrame(event: 'delta', data: '{"text":"hi"}'),
      ]);
    });

    test('a data-only block has a null event name', () async {
      expect(await frames(['data: hello\n\n']), const [
        SseFrame(data: 'hello'),
      ]);
    });

    test(
      'data may contain colons — only the first colon splits the field',
      () async {
        expect(await frames(['data: a:b c\n\n']), const [
          SseFrame(data: 'a:b c'),
        ]);
      },
    );

    test('LF and CRLF line endings frame identically', () async {
      const expected = [SseFrame(event: 'delta', data: 'hi')];
      expect(await frames(['event: delta\ndata: hi\n\n']), expected);
      expect(await frames(['event: delta\r\ndata: hi\r\n\r\n']), expected);
    });

    test('at most one leading space after the colon is stripped', () async {
      expect(await frames(['data:nospace\n\n']), const [
        SseFrame(data: 'nospace'),
      ]);
      expect(await frames(['data:  two spaces\n\n']), const [
        SseFrame(data: ' two spaces'),
      ]);
      expect(await frames(['event:delta\ndata: x\n\n']), const [
        SseFrame(event: 'delta', data: 'x'),
      ]);
    });
  });

  group('comments and unknown fields', () {
    test('comment lines and the ": ping" keepalive are ignored', () async {
      expect(await frames([': ping\n:comment\ndata: x\n\n']), const [
        SseFrame(data: 'x'),
      ]);
    });

    test('a keepalive-only stream produces no frames', () async {
      expect(await frames([': ping\n\n: ping\n\n']), isEmpty);
    });

    test(
      'unknown fields are ignored (id, retry, v2 stream/event ids, junk)',
      () async {
        expect(
          await frames([
            'id: 7\nretry: 100\nstreamId: s1\neventId: 3\nnocolonline\ndata: x\n\n',
          ]),
          const [SseFrame(data: 'x')],
        );
      },
    );
  });

  group('multi-line data and multiple events', () {
    test('consecutive data: lines join with \\n', () async {
      expect(await frames(['data: a\ndata: b\n\n']), const [
        SseFrame(data: 'a\nb'),
      ]);
    });

    test('empty data: lines participate in the join', () async {
      expect(await frames(['data:\n\n']), const [SseFrame(data: '')]);
      expect(await frames(['data:\ndata: x\n\n']), const [
        SseFrame(data: '\nx'),
      ]);
    });

    test('a block with no data: lines dispatches nothing', () async {
      expect(await frames(['event: ghost\n\n']), isEmpty);
    });

    test('one transport chunk may carry several events, in order', () async {
      expect(await frames(['data: one\n\nevent: delta\ndata: two\n\n']), const [
        SseFrame(data: 'one'),
        SseFrame(event: 'delta', data: 'two'),
      ]);
    });

    test(
      'per-event state resets between blocks (no event-name leak)',
      () async {
        expect(await frames(['event: delta\ndata: a\n\ndata: b\n\n']), const [
          SseFrame(event: 'delta', data: 'a'),
          SseFrame(data: 'b'),
        ]);
        // A dispatched data-less block resets its name too.
        expect(await frames(['event: ghost\n\ndata: c\n\n']), const [
          SseFrame(data: 'c'),
        ]);
      },
    );
  });

  group('chunk boundaries', () {
    test('a line and its JSON text may be split across chunks', () async {
      expect(await frames(['da', 'ta: {"te', 'xt":"hel', 'lo"}\n\n']), const [
        SseFrame(data: '{"text":"hello"}'),
      ]);
    });

    test('a UTF-8 scalar may be split between byte chunks', () async {
      final bytes = utf8.encode('data: €\n\n'); // '€' = E2 82 AC at offset 6
      expect(await byteFrames([bytes.sublist(0, 7), bytes.sublist(7)]), const [
        SseFrame(data: '€'),
      ]);
    });

    test('a CRLF pair may be split between chunks', () async {
      expect(await frames(['data: x\r', '\n\r\n']), const [
        SseFrame(data: 'x'),
      ]);
    });

    test('every byte-level split of a mixed stream frames identically', () async {
      const raw =
          'event: delta\r\ndata: {"a": "π€😀"}\ndata: tail\n\n: ping\nevent: done\ndata: {}\n\n';
      const expected = [
        SseFrame(event: 'delta', data: '{"a": "π€😀"}\ntail'),
        SseFrame(event: 'done', data: '{}'),
      ];
      final bytes = utf8.encode(raw);
      for (var split = 1; split < bytes.length; split++) {
        expect(
          await byteFrames([bytes.sublist(0, split), bytes.sublist(split)]),
          expected,
          reason: 'split at byte $split must not change the framing',
        );
      }
    });
  });

  group('malformed UTF-8 (strict decoding)', () {
    test('an invalid byte sequence inside data errors the stream with '
        'FormatException', () async {
      final corrupted = <int>[
        ...utf8.encode('event: delta\ndata: {"text":"'),
        0xE2, 0x82, 0x28, // truncated 3-byte sequence — invalid UTF-8
        ...utf8.encode('"}\n\n'),
      ];
      await expectLater(
        parseSseFrames(Stream.fromIterable([corrupted])).toList(),
        throwsFormatException,
      );
    });

    test(
      'no SseFrame with U+FFFD is ever emitted for malformed input',
      () async {
        final corrupted = <int>[
          ...utf8.encode('data: abc'),
          0x80, // lone continuation byte — invalid UTF-8
          ...utf8.encode('def\n\n'),
        ];
        final received = <SseFrame>[];
        await expectLater(
          parseSseFrames(
            Stream.fromIterable([corrupted]),
          ).forEach(received.add),
          throwsFormatException,
        );
        expect(received, isEmpty);
        expect(
          received.where((frame) => frame.data.contains('\u{FFFD}')),
          isEmpty,
        );
      },
    );
  });

  group('EOF', () {
    test(
      'a pending frame is flushed at EOF without the trailing empty line',
      () async {
        expect(await frames(['event: done\ndata: {}\n']), const [
          SseFrame(event: 'done', data: '{}'),
        ]);
      },
    );

    test('an unterminated final line is treated as complete at EOF', () async {
      expect(await frames(['data: last']), const [SseFrame(data: 'last')]);
    });

    test('a cleanly terminated stream flushes nothing extra at EOF', () async {
      expect(await frames(['data: x\n\n']), const [SseFrame(data: 'x')]);
    });

    test('an empty stream produces no frames', () async {
      expect(await byteFrames([]), isEmpty);
      expect(await frames(['']), isEmpty);
    });
  });
}
