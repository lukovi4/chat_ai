// The production transport FirebaseChatBackend (V1_SPEC §2/§6/§8;
// SERVER-CONTRACT §2–§6, §10–§11): exact HTTP request form, auth/App Check
// gate, status/header/body mapping, Retry-After, the SSE pipeline through
// the full stack, immediate wire-cancel and sanitization. Uses the internal
// test seam `firebaseChatBackendForTesting` with a fake HttpClientAdapter —
// no real Firebase or network. The seam is NOT exported from
// package:chat_ai/chat_ai.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_ai/chat_ai.dart' hide FirebaseChatBackend;
import 'package:chat_ai_firebase/src/backend/chat_request_wire.dart';
import 'package:chat_ai_firebase/src/backend/firebase_chat_backend.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show DebugPrintCallback, debugPrint;
import 'package:flutter_test/flutter_test.dart';

const String testUrl = 'https://chat.example.test/send';
const Map<String, List<String>> wireVersionHeaders = {
  'X-Chat-AI-Wire-Version': ['1'],
};

const BackendEvent accepted = BackendEvent.accepted();
const BackendEvent done = BackendEvent.done();

final ChatRequest request = ChatRequest(
  botId: 'premium',
  system: 'be kind',
  messages: [
    Message(
      id: 'u1',
      role: MessageRole.user,
      parts: const [ContentPart.text('hi')],
      status: MessageStatus.sent,
      attemptKey: 'attempt-1',
      createdAt: DateTime.utc(2026, 7, 12, 12),
    ),
  ],
  tools: const [],
  idempotencyKey: 'idem-key-1',
);

typedef Responder =
    Future<ResponseBody> Function(
      RequestOptions options,
      Future<void>? cancelFuture,
    );

/// A minimal fake [HttpClientAdapter]: records every dispatched request
/// (options + the exact body bytes dio handed over) and delegates the
/// response to a swappable [respond] callback. No real I/O.
class _FakeHttpAdapter implements HttpClientAdapter {
  _FakeHttpAdapter(this.respond);

  Responder respond;
  int calls = 0;
  RequestOptions? lastOptions;
  String? lastBody;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls += 1;
    lastOptions = options;
    if (requestStream == null) {
      lastBody = null;
    } else {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in requestStream) {
        builder.add(chunk);
      }
      lastBody = utf8.decode(builder.takeBytes());
    }
    return respond(options, cancelFuture);
  }

  @override
  void close({bool force = false}) {}
}

(FirebaseChatBackend, _FakeHttpAdapter) backendWith(
  Responder respond, {
  Future<String?> Function()? idToken,
  Future<String?> Function()? appCheckToken,
  DateTime Function()? now,
  String url = testUrl,
}) {
  final adapter = _FakeHttpAdapter(respond);
  final backend = firebaseChatBackendForTesting(
    url: url,
    dio: Dio()..httpClientAdapter = adapter,
    idToken: idToken ?? () async => 'test-id-token',
    appCheckToken: appCheckToken ?? () async => 'test-app-check-token',
    now: now,
  );
  return (backend, adapter);
}

/// A canned non-streaming response.
Responder reply(
  int status, {
  String body = '',
  Map<String, List<String>> headers = const {},
}) =>
    (options, cancel) async =>
        ResponseBody.fromString(body, status, headers: headers);

Uint8List sseBytes(String text) => Uint8List.fromList(utf8.encode(text));

/// A 200 SSE response streaming [chunks] as separate transport chunks.
ResponseBody sseResponse(
  Iterable<String> chunks, {
  Map<String, List<String>> headers = wireVersionHeaders,
}) => ResponseBody(
  Stream.fromIterable([for (final chunk in chunks) sseBytes(chunk)]),
  200,
  headers: headers,
);

List<String> detailsOf(Iterable<BackendEvent> events) => [
  for (final event in events)
    if (event is ErrorEvent && event.detail != null) event.detail!,
];

void main() {
  group('successful 200 leg', () {
    test('sends one POST with the exact frozen body and headers, then relays '
        'Accepted first and the SSE events in wire order', () async {
      final (backend, adapter) = backendWith(
        (options, cancel) async => sseResponse([
          'event: delta\ndata: {"text":"Hel"}\n\n',
          'event: delta\ndata: {"text":"lo"}\n\n'
              'event: provider_state\n'
              'data: {"provider":"openai","data":"AQID"}\n\n',
          'event: done\ndata: {"usage":{"inputTokens":3,"outputTokens":2}}'
              '\n\n',
        ]),
      );

      final events = await backend.send(request).toList();

      expect(adapter.calls, 1, reason: 'exactly one POST, no retry here');
      final options = adapter.lastOptions!;
      expect(options.method, 'POST');
      expect(options.uri.toString(), testUrl);
      expect(options.responseType, ResponseType.stream);
      expect(options.headers['Authorization'], 'Bearer test-id-token');
      expect(options.headers['X-Firebase-AppCheck'], 'test-app-check-token');
      expect(options.headers['Idempotency-Key'], 'idem-key-1');
      expect(options.contentType, 'application/json');
      expect(
        adapter.lastBody,
        encodeChatRequestBody(request),
        reason: 'the frozen serialized request rides byte-identical',
      );

      expect(events, [
        accepted,
        const BackendEvent.delta('Hel'),
        const BackendEvent.delta('lo'),
        BackendEvent.providerState(
          ProviderOpaquePart('openai', base64Decode('AQID')),
        ),
        const BackendEvent.done(usage: Usage(inputTokens: 3, outputTokens: 2)),
      ]);
    });

    test('the wire-version header is matched case-insensitively', () async {
      final (backend, _) = backendWith(
        (options, cancel) async => sseResponse(
          ['event: done\ndata: {}\n\n'],
          headers: const {
            'x-chat-ai-wire-version': ['1'],
          },
        ),
      );
      expect(await backend.send(request).toList(), [accepted, done]);
    });
  });

  group('wire-version gate on 200', () {
    test('missing/mismatched/non-single header value → exactly one upstream '
        'unsupported-wire-version event, never Accepted', () async {
      const rows = <(String, Map<String, List<String>>)>[
        ('missing header', {}),
        (
          'mismatched version',
          {
            'X-Chat-AI-Wire-Version': ['2'],
          },
        ),
        (
          'duplicated header',
          {
            'X-Chat-AI-Wire-Version': ['1', '1'],
          },
        ),
      ];
      for (final (label, headers) in rows) {
        final (backend, _) = backendWith(
          (options, cancel) async =>
              sseResponse(['event: done\ndata: {}\n\n'], headers: headers),
        );
        expect(await backend.send(request).toList(), const [
          BackendEvent.error(
            FailureCause.upstream,
            detail: 'unsupported-wire-version',
          ),
        ], reason: label);
      }
    });
  });

  group('protocol signals', () {
    test('HTTP 409 → exactly one ConflictEvent, body ignored', () async {
      final (backend, _) = backendWith(reply(409, body: '<not json'));
      expect(await backend.send(request).toList(), const [
        BackendEvent.conflict(),
      ]);
    });

    test('HTTP 410 → exactly one GoneEvent, body ignored', () async {
      final (backend, _) = backendWith(reply(410, body: '<not json'));
      expect(await backend.send(request).toList(), const [BackendEvent.gone()]);
    });

    test('HTTP 426 → pinned upstream unsupported-wire-version regardless of a '
        'malformed body', () async {
      final (backend, _) = backendWith(reply(426, body: '{oops'));
      expect(await backend.send(request).toList(), const [
        BackendEvent.error(
          FailureCause.upstream,
          detail: 'unsupported-wire-version',
        ),
      ]);
    });
  });

  group('pre-stream failure mapping', () {
    test('all nine wire cause codes map onto their FailureCause', () async {
      const rows = <(String, FailureCause)>[
        ('auth', FailureCause.auth),
        ('entitlement', FailureCause.entitlement),
        ('quota', FailureCause.quota),
        ('rate', FailureCause.rate),
        ('overloaded', FailureCause.overloaded),
        ('content-filter', FailureCause.contentFilter),
        ('context-too-long', FailureCause.contextTooLong),
        ('network', FailureCause.network),
        ('upstream', FailureCause.upstream),
      ];
      for (final (wire, cause) in rows) {
        final (backend, _) = backendWith(reply(400, body: '{"cause":"$wire"}'));
        expect(await backend.send(request).toList(), [
          BackendEvent.error(cause),
        ], reason: wire);
      }
    });

    test('an optional detail rides along; unknown body fields are '
        'ignored', () async {
      final (backend, _) = backendWith(
        reply(
          402,
          body:
              '{"cause":"quota","detail":"allowance exhausted",'
              '"extra":{"ignored":true}}',
        ),
      );
      expect(await backend.send(request).toList(), const [
        BackendEvent.error(FailureCause.quota, detail: 'allowance exhausted'),
      ]);
    });
  });

  group('Retry-After', () {
    test('both standard forms land in ErrorEvent.retryAfter', () async {
      // 2026-12-31 23:59:30 UTC is 30 s before the (valid) HTTP-date below.
      DateTime beforeDate() => DateTime.utc(2026, 12, 31, 23, 59, 30);
      DateTime afterDate() => DateTime.utc(2027, 1, 1, 1);
      const httpDate = 'Fri, 01 Jan 2027 00:00:00 GMT';
      final rows = <(String, String, DateTime Function()?, Duration?)>[
        ('integer seconds', '30', null, const Duration(seconds: 30)),
        ('zero seconds', '0', null, Duration.zero),
        ('future HTTP-date', httpDate, beforeDate, const Duration(seconds: 30)),
        ('past HTTP-date', httpDate, afterDate, Duration.zero),
        ('malformed', 'soon', null, null),
        ('negative', '-5', null, null),
      ];
      for (final (label, header, now, expected) in rows) {
        final (backend, _) = backendWith(
          reply(
            429,
            body: '{"cause":"rate"}',
            headers: {
              'Retry-After': [header],
            },
          ),
          now: now,
        );
        final events = await backend.send(request).toList();
        final error = events.single as ErrorEvent;
        expect(error.cause, FailureCause.rate, reason: label);
        expect(error.retryAfter, expected, reason: label);
      }
    });
  });

  group('malformed pre-stream failure body', () {
    test('UTF-8/JSON/shape/cause/detail violations all collapse into one '
        'sanitized upstream event; the stream never errors', () async {
      final rows = <(String, ResponseBody Function())>[
        (
          'malformed UTF-8',
          () => ResponseBody.fromBytes(const [0xC3, 0x28], 400),
        ),
        ('malformed JSON', () => ResponseBody.fromString('{oops', 400)),
        ('non-object root', () => ResponseBody.fromString('[]', 400)),
        ('missing cause', () => ResponseBody.fromString('{}', 400)),
        (
          'unknown cause',
          () => ResponseBody.fromString('{"cause":"mystery"}', 400),
        ),
        (
          'tool-loop-limit never crosses the wire',
          () => ResponseBody.fromString('{"cause":"tool-loop-limit"}', 400),
        ),
        (
          'wrong-type cause',
          () => ResponseBody.fromString('{"cause":42}', 400),
        ),
        (
          'wrong-type detail',
          () => ResponseBody.fromString('{"cause":"rate","detail":42}', 400),
        ),
      ];
      final details = <String>{};
      for (final (label, body) in rows) {
        final (backend, _) = backendWith((options, cancel) async => body());
        final events = await backend.send(request).toList();
        expect(events, hasLength(1), reason: label);
        final error = events.single as ErrorEvent;
        expect(error.cause, FailureCause.upstream, reason: label);
        expect(error.detail, isNotNull, reason: label);
        expect(error.detail, isNot(contains('mystery')), reason: label);
        expect(error.detail, isNot(contains('oops')), reason: label);
        details.add(error.detail!);
      }
      expect(
        details,
        hasLength(1),
        reason: 'one stable marker for every malformed shape',
      );
    });
  });

  group('auth / App Check gate', () {
    test(
      'missing/empty/throwing tokens produce exactly one auth event with the '
      'pinned detail and never dispatch HTTP',
      () async {
        Future<String?> boom() async => throw StateError('SENTINEL_token');
        final rows =
            <
              (
                String,
                Future<String?> Function()?,
                Future<String?> Function()?,
                String,
              )
            >[
              ('null id-token', () async => null, null, 'id-token'),
              ('empty id-token', () async => '', null, 'id-token'),
              ('throwing id-token', boom, null, 'id-token'),
              ('null App Check token', null, () async => null, 'app-check'),
              ('empty App Check token', null, () async => '', 'app-check'),
              ('throwing App Check token', null, boom, 'app-check'),
            ];
        for (final (label, idToken, appCheckToken, detail) in rows) {
          final (backend, adapter) = backendWith(
            reply(200),
            idToken: idToken,
            appCheckToken: appCheckToken,
          );
          expect(await backend.send(request).toList(), [
            BackendEvent.error(FailureCause.auth, detail: detail),
          ], reason: label);
          expect(
            adapter.calls,
            0,
            reason: '$label: the HTTP adapter must never run',
          );
        }
      },
    );
  });

  group('transport failures (never a stream error)', () {
    test(
      'an adapter failure before any response → one network event',
      () async {
        final (backend, _) = backendWith(
          (options, cancel) => throw StateError('boom SENTINEL_dio'),
        );
        // toList() would throw if the failure escaped as a stream error.
        final events = await backend.send(request).toList();
        final error = events.single as ErrorEvent;
        expect(error.cause, FailureCause.network);
        expect(error.detail, isNotNull);
        expect(error.detail, isNot(contains('SENTINEL_dio')));
      },
    );

    test('a mid-stream break in the SSE body → the delivered events plus '
        'exactly one network event', () async {
      Stream<Uint8List> breakingBody() async* {
        yield sseBytes('event: delta\ndata: {"text":"a"}\n\n');
        yield* Stream<Uint8List>.error(StateError('reset SENTINEL_stream'));
      }

      final (backend, _) = backendWith(
        (options, cancel) async =>
            ResponseBody(breakingBody(), 200, headers: wireVersionHeaders),
      );
      final events = await backend.send(request).toList();
      expect(events, hasLength(3));
      expect(events[0], accepted);
      expect(events[1], const BackendEvent.delta('a'));
      final error = events[2] as ErrorEvent;
      expect(error.cause, FailureCause.network);
      expect(error.detail, isNotNull);
      expect(error.detail, isNot(contains('SENTINEL_stream')));
    });

    test(
      'a break while reading a pre-stream failure body → one network event',
      () async {
        final (backend, _) = backendWith(
          (options, cancel) async => ResponseBody(
            Stream<Uint8List>.error(StateError('reset SENTINEL_body')),
            400,
          ),
        );
        final events = await backend.send(request).toList();
        final error = events.single as ErrorEvent;
        expect(error.cause, FailureCause.network);
        expect(error.detail, isNot(contains('SENTINEL_body')));
      },
    );
  });

  group('SSE pipeline through the full stack', () {
    test(
      'malformed JSON / unknown event / EOF without terminal → Accepted, the '
      'events so far, then exactly one upstream terminal; nothing escapes',
      () async {
        const delta = 'event: delta\ndata: {"text":"a"}\n\n';
        const rows = <(String, List<String>)>[
          ('malformed JSON', [delta, 'event: delta\ndata: {oops\n\n']),
          ('unknown event', [delta, 'event: surprise\ndata: {}\n\n']),
          ('EOF without terminal', [delta]),
        ];
        for (final (label, chunks) in rows) {
          final (backend, _) = backendWith(
            (options, cancel) async => sseResponse(chunks),
          );
          final events = await backend.send(request).toList();
          expect(events, hasLength(3), reason: label);
          expect(events[0], accepted, reason: label);
          expect(events[1], const BackendEvent.delta('a'), reason: label);
          final error = events[2] as ErrorEvent;
          expect(error.cause, FailureCause.upstream, reason: label);
          expect(error.detail, isNotNull, reason: label);
        }
      },
    );

    test('first terminal wins across the whole pipeline', () async {
      final (backend, _) = backendWith(
        (options, cancel) async => sseResponse([
          'event: done\ndata: {}\n\n'
              'event: delta\ndata: {"text":"late"}\n\n'
              'event: done\ndata: {}\n\n',
        ]),
      );
      expect(await backend.send(request).toList(), [accepted, done]);
    });
  });

  group('internal failure guard (outer lifecycle)', () {
    test('a local defect — request serialization or a throwing clock — becomes '
        'exactly one stable sanitized upstream event (never network); the '
        'stream completes without throwing or hanging', () async {
      const sentinel = 'LEAK_SENTINEL_clock_4a7b';
      final markers = <String>[];
      final DebugPrintCallback original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        markers.add(message ?? '');
      };
      final details = <String>{};
      try {
        // Scenario 1: encodeChatRequestBody throws — a Tool schema holds a
        // non-JSON-encodable value (plain data, no contract change).
        final badRequest = ChatRequest(
          botId: 'premium',
          system: 'be kind',
          messages: const [],
          tools: [
            Tool(
              name: 'searchNotes',
              description: 'd',
              parameters: {'value': Object()},
            ),
          ],
          idempotencyKey: 'idem-bad',
        );
        final (encodeBackend, adapter) = backendWith(reply(200));
        final encodeEvents = await encodeBackend
            .send(badRequest)
            .toList()
            .timeout(const Duration(seconds: 5));
        expect(encodeEvents, hasLength(1));
        final encodeError = encodeEvents.single as ErrorEvent;
        expect(
          encodeError.cause,
          FailureCause.upstream,
          reason: 'a local defect is not a transport failure',
        );
        expect(encodeError.detail, isNotNull);
        details.add(encodeError.detail!);
        expect(
          adapter.calls,
          0,
          reason: 'the defect fires before any HTTP dispatch',
        );

        // Scenario 2: a valid pre-stream response whose HTTP-date
        // Retry-After parsing hits a throwing test clock.
        final (clockBackend, _) = backendWith(
          reply(
            429,
            body: '{"cause":"rate"}',
            headers: const {
              'Retry-After': ['Fri, 01 Jan 2027 00:00:00 GMT'],
            },
          ),
          now: () => throw StateError('$sentinel-clock'),
        );
        final clockEvents = await clockBackend
            .send(request)
            .toList()
            .timeout(const Duration(seconds: 5));
        expect(clockEvents, hasLength(1));
        final clockError = clockEvents.single as ErrorEvent;
        expect(clockError.cause, FailureCause.upstream);
        expect(clockError.detail, isNotNull);
        details.add(clockError.detail!);
      } finally {
        debugPrint = original;
      }

      expect(
        details,
        hasLength(1),
        reason: 'one stable internal marker for every guarded defect',
      );
      for (final text in [...details, ...markers]) {
        expect(
          text.contains(sentinel),
          isFalse,
          reason: '"$text" must not leak the sentinel',
        );
      }
    });
  });

  group('cancellation (wire-cancel)', () {
    test('a pending HTTP request observes CancelToken cancellation immediately '
        'after subscription.cancel(); the canceller gets no events', () async {
      final requestStarted = Completer<void>();
      final cancelObserved = Completer<void>();
      final (backend, _) = backendWith((options, cancelFuture) {
        requestStarted.complete();
        unawaited(cancelFuture!.whenComplete(cancelObserved.complete));
        return Completer<ResponseBody>().future; // no response, ever
      });

      final events = <BackendEvent>[];
      final errors = <Object>[];
      final subscription = backend
          .send(request)
          .listen(events.add, onError: errors.add);
      await requestStarted.future;
      await subscription.cancel();

      await expectLater(cancelObserved.future, completes);
      await pumpEventQueue();
      expect(events, isEmpty, reason: 'no event reaches the canceller');
      expect(errors, isEmpty);
    });

    test('an active SSE stream is cancelled at once and the same backend can '
        'send again', () async {
      final body = StreamController<Uint8List>();
      var bodyCancelled = false;
      body.onCancel = () => bodyCancelled = true;
      final (backend, adapter) = backendWith(
        (options, cancel) async =>
            ResponseBody(body.stream, 200, headers: wireVersionHeaders),
      );

      final events = <BackendEvent>[];
      final subscription = backend.send(request).listen(events.add);
      await pumpEventQueue();
      body.add(sseBytes('event: delta\ndata: {"text":"a"}\n\n'));
      await pumpEventQueue();
      expect(events, [accepted, const BackendEvent.delta('a')]);

      await subscription.cancel();
      await pumpEventQueue();
      expect(
        bodyCancelled,
        isTrue,
        reason: 'wire-cancel stops reading the connection',
      );

      body.add(sseBytes('event: delta\ndata: {"text":"late"}\n\n'));
      await pumpEventQueue();
      expect(events, hasLength(2), reason: 'nothing after cancel');

      adapter.respond = (options, cancel) async =>
          sseResponse(['event: done\ndata: {}\n\n']);
      expect(
        await backend.send(request).toList(),
        [accepted, done],
        reason: 'the backend instance stays usable after a cancel',
      );
    });

    test(
      'cancelling during an active non-200 failure-body read closes the '
      'read immediately; nothing hangs and the backend stays usable',
      () async {
        final body = StreamController<Uint8List>();
        final bodyListened = Completer<void>();
        var bodyCancelled = false;
        body.onListen = bodyListened.complete;
        body.onCancel = () => bodyCancelled = true;
        final (backend, adapter) = backendWith(
          // A pre-stream failure whose body starts but never completes.
          (options, cancel) async => ResponseBody(body.stream, 400),
        );

        final events = <BackendEvent>[];
        final errors = <Object>[];
        final subscription = backend
            .send(request)
            .listen(events.add, onError: errors.add);
        await bodyListened.future;
        body.add(sseBytes('{"cause":'));
        await pumpEventQueue();

        await subscription.cancel();
        expect(
          bodyCancelled,
          isTrue,
          reason: 'the active error-body read is closed at once',
        );
        await pumpEventQueue();
        expect(events, isEmpty, reason: 'the canceller receives no events');
        expect(errors, isEmpty);

        adapter.respond = (options, cancel) async =>
            sseResponse(['event: done\ndata: {}\n\n']);
        expect(
          await backend.send(request).toList(),
          [accepted, done],
          reason: 'the same backend can run a fresh send afterwards',
        );
      },
    );
  });

  group('sanitization (no leakage into details or debug output)', () {
    test('sentinels from token exceptions, transport exceptions, malformed '
        'bodies/frames and the URL never appear in ErrorEvent.detail or '
        'debug output', () async {
      const sentinel = 'LEAK_SENTINEL_9c4d1';
      const leakyUrl = 'https://$sentinel.example.test/$sentinel';
      final markers = <String>[];
      final DebugPrintCallback original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        markers.add(message ?? '');
      };
      final details = <String>[];
      try {
        final scenarios = <Future<List<BackendEvent>>>[];

        // A throwing token callback + a sentinel-bearing URL.
        final (authBackend, _) = backendWith(
          reply(500),
          idToken: () async => throw StateError('$sentinel-token'),
          url: leakyUrl,
        );
        scenarios.add(authBackend.send(request).toList());

        // A transport exception carrying the sentinel.
        final (transportBackend, _) = backendWith(
          (options, cancel) => throw StateError('$sentinel-transport'),
          url: leakyUrl,
        );
        scenarios.add(transportBackend.send(request).toList());

        // A malformed pre-stream body and Retry-After both carrying it.
        final (bodyBackend, _) = backendWith(
          reply(
            400,
            body: '{"cause":"$sentinel"',
            headers: {
              'Retry-After': [sentinel],
            },
          ),
          url: leakyUrl,
        );
        scenarios.add(bodyBackend.send(request).toList());

        // A defective SSE frame (unknown event + payload) carrying it,
        // followed by post-terminal frames that hit the debug markers.
        final (sseBackend, _) = backendWith(
          (options, cancel) async => sseResponse([
            'event: $sentinel\ndata: {"note":"$sentinel"}\n\n'
                'event: delta\ndata: {"text":"$sentinel"}\n\n',
          ]),
          url: leakyUrl,
        );
        scenarios.add(sseBackend.send(request).toList());

        for (final events in await Future.wait(scenarios)) {
          details.addAll(detailsOf(events));
        }
      } finally {
        debugPrint = original;
      }

      expect(details, isNotEmpty);
      for (final text in [...details, ...markers]) {
        expect(
          text.contains(sentinel),
          isFalse,
          reason: '"$text" must not leak the sentinel',
        );
      }
    });
  });
}
