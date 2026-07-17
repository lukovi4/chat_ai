// The WebSocket transport: exact URL/model encoding, and — through the REAL
// package-internal production opener against a loopback server — the auth
// header carrying the ephemeral secret (never in the URI/query/subprotocol)
// and the genuine abort of a pending `WebSocket.connect` by force-closing the
// registered HttpClient. Plus single-session orchestration, text passthrough,
// binary-frame failure, EOF handling, exactly-once close, canonical
// cancellation and the delayed late-close contract. No OpenAI, no real secret.
import 'dart:async';
import 'dart:io';

import 'package:chat_ai_openai_realtime/src/realtime_transport.dart';
import 'package:chat_ai_openai_realtime/src/websocket_realtime_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake WebSocket whose [frames] the test drives explicitly. An optional
/// [closeGate] models a delayed native close: `close()` records the call
/// immediately but does not COMPLETE until the gate opens.
class FakeWebSocket implements RealtimeWebSocket {
  FakeWebSocket({this.closeGate});

  final StreamController<dynamic> controller = StreamController<dynamic>();
  final List<String> sent = <String>[];
  final Completer<void>? closeGate;
  int closeCalls = 0;
  Object? addError;

  @override
  Stream<dynamic> get frames => controller.stream;

  @override
  void add(String message) {
    final error = addError;
    if (error != null) {
      throw error;
    }
    sent.add(message);
  }

  @override
  Future<void> close() async {
    closeCalls++;
    // Fire-and-forget like a real socket close: never block on a listener.
    if (!controller.isClosed) {
      unawaited(controller.close());
    }
    // A delayed native close: the returned future stays pending until the
    // test opens the gate.
    final gate = closeGate;
    if (gate != null) {
      await gate.future;
    }
  }
}

/// Records what the transport passed to the opener; [gate], when set, holds
/// the open until the test completes it (a pending / late handshake).
class RecordingOpener {
  RecordingOpener({FakeWebSocket? socket}) : socket = socket ?? FakeWebSocket();

  final List<Uri> urls = <Uri>[];
  final List<String> secrets = <String>[];
  int calls = 0;
  final FakeWebSocket socket;
  Completer<void>? gate;

  RealtimeWebSocketOpener get opener =>
      (Uri url, String clientSecret, HttpClient client) async {
        calls++;
        urls.add(url);
        secrets.add(clientSecret);
        final gate = this.gate;
        if (gate != null) {
          await gate.future;
        }
        return socket;
      };
}

WebSocketRealtimeTransport transportWith(
  RecordingOpener rec, {
  String model = 'gpt-realtime-2.1',
}) => WebSocketRealtimeTransport.forTesting(model: model, open: rec.opener);

void main() {
  group('URL & model encoding (test 1)', () {
    test('builds exactly wss://api.openai.com/v1/realtime with the URL-encoded '
        'model query param', () {
      final url = buildRealtimeWebSocketUrl('gpt-realtime-2.1');
      expect(url.scheme, 'wss');
      expect(url.host, 'api.openai.com');
      expect(url.path, '/v1/realtime');
      expect(url.queryParameters, {'model': 'gpt-realtime-2.1'});
    });

    test('URL-encodes a model with reserved characters', () {
      final url = buildRealtimeWebSocketUrl('a model/with spaces&x');
      expect(url.queryParameters['model'], 'a model/with spaces&x');
      expect(url.query, contains('model='));
      expect(url.query, isNot(contains(' ')));
    });

    test('the transport connects using the model URL', () async {
      final cancellation = RealtimeCancellation();
      final rec = RecordingOpener();
      await transportWith(rec).connect('secret-1', cancellation);
      expect(rec.urls.single, buildRealtimeWebSocketUrl('gpt-realtime-2.1'));
    });
  });

  group('the REAL production opener against a loopback server', () {
    test('sends the ephemeral secret only as the Authorization: Bearer header '
        '— never in the URI/query/subprotocol — and establishes a text '
        'session (tests 2 & 3)', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var upgradeCount = 0;
      HttpHeaders? capturedHeaders;
      Uri? capturedUri;
      String? subprotocol;
      server.listen((request) async {
        upgradeCount++;
        capturedHeaders = request.headers;
        capturedUri = request.uri;
        subprotocol = request.headers.value('sec-websocket-protocol');
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add('{"type":"response.created"}');
        await socket.close();
      });
      addTearDown(() => server.close(force: true));

      final loopback = Uri(
        scheme: 'ws',
        host: '127.0.0.1',
        port: server.port,
        path: '/v1/realtime',
        queryParameters: {'model': 'gpt-realtime-2.1'},
      );
      final client = HttpClient();
      const secret = 'ek_secret_value';
      // The REAL package-internal production opener — a regression that drops
      // the header would fail here.
      final socket = await openRealtimeWebSocket(loopback, secret, client);
      final firstFrame = await socket.frames.first;
      await socket.close();
      client.close(force: true);

      expect(upgradeCount, 1);
      expect(
        capturedHeaders!.value(HttpHeaders.authorizationHeader),
        'Bearer $secret',
      );
      expect(capturedUri!.toString(), isNot(contains(secret)));
      expect(capturedUri!.query, isNot(contains(secret)));
      expect(subprotocol ?? '', isNot(contains(secret)));
      // The text session actually works: the server frame arrived unchanged.
      expect(firstFrame, '{"type":"response.created"}');
    });

    test('a wire-cancel force-closes the registered HttpClient and aborts a '
        'real pending WebSocket.connect → controlled RealtimeConnectCancelled '
        '(test 10, real handshake)', () async {
      final gotRequest = Completer<void>();
      var requestCount = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        requestCount++;
        if (!gotRequest.isCompleted) {
          gotRequest.complete();
        }
        // Hold the handshake: never upgrade, never respond → connect stays
        // pending until the client is force-closed.
      });
      addTearDown(() => server.close(force: true));

      final loopback = Uri(
        scheme: 'ws',
        host: '127.0.0.1',
        port: server.port,
        path: '/v1/realtime',
        queryParameters: {'model': 'gpt-realtime-2.1'},
      );

      final zoneErrors = <Object>[];
      await runZonedGuarded(() async {
        final cancellation = RealtimeCancellation();
        // The transport's OWN registered HttpClient (default factory) is
        // handed to the real opener as the customClient — no fake reacts to
        // cancellation here; only the force-close aborts the handshake.
        final transport = WebSocketRealtimeTransport.forTesting(
          model: 'gpt-realtime-2.1',
          open: (Uri url, String secret, HttpClient client) =>
              openRealtimeWebSocket(loopback, secret, client),
        );
        final future = transport.connect('ek_secret', cancellation);
        await gotRequest.future;
        cancellation.cancel();
        await expectLater(future, throwsA(isA<RealtimeConnectCancelled>()));
      }, (error, _) => zoneErrors.add(error));

      expect(requestCount, 1);
      expect(zoneErrors, isEmpty);
    });
  });

  group('single-session orchestration', () {
    test('one WebSocket per connect() (test 4)', () async {
      final cancellation = RealtimeCancellation();
      final rec = RecordingOpener();
      await transportWith(rec).connect('s', cancellation);
      expect(rec.calls, 1);
    });

    test('text frames pass through unchanged into events (test 5)', () async {
      final cancellation = RealtimeCancellation();
      final rec = RecordingOpener();
      final connection = await transportWith(rec).connect('s', cancellation);
      final received = <String>[];
      connection.events.listen(received.add);
      rec.socket.controller.add('{"type":"response.created"}');
      rec.socket.controller.add('{"type":"response.output_text.delta"}');
      await pumpEventQueue();
      expect(received, [
        '{"type":"response.created"}',
        '{"type":"response.output_text.delta"}',
      ]);
    });

    test(
      'a binary frame is a controlled error, not its bytes (test 6)',
      () async {
        final cancellation = RealtimeCancellation();
        final rec = RecordingOpener();
        final connection = await transportWith(rec).connect('s', cancellation);
        Object? error;
        connection.events.listen((_) {}, onError: (Object e) => error = e);
        rec.socket.controller.add(<int>[1, 2, 3, 4]);
        await pumpEventQueue();
        expect(error, isA<RealtimeBinaryFrameException>());
        expect(error.toString(), isNot(contains('1')));
      },
    );

    test('EOF closes the event stream (test 7)', () async {
      final cancellation = RealtimeCancellation();
      final rec = RecordingOpener();
      final connection = await transportWith(rec).connect('s', cancellation);
      var done = false;
      connection.events.listen((_) {}, onDone: () => done = true);
      await rec.socket.controller.close();
      await pumpEventQueue();
      expect(done, isTrue);
    });

    test('a socket stream error becomes a sanitized event error', () async {
      final cancellation = RealtimeCancellation();
      final rec = RecordingOpener();
      final connection = await transportWith(rec).connect('s', cancellation);
      Object? error;
      connection.events.listen((_) {}, onError: (Object e) => error = e);
      rec.socket.controller.addError(
        const SocketException('raw-network-detail'),
      );
      await pumpEventQueue();
      expect(error, isA<RealtimeSocketException>());
      expect(error.toString(), isNot(contains('raw-network-detail')));
    });

    test('send() forwards exactly one unchanged string (test 8)', () async {
      final cancellation = RealtimeCancellation();
      final rec = RecordingOpener();
      final connection = await transportWith(rec).connect('s', cancellation);
      await connection.send('{"type":"response.create"}');
      expect(rec.socket.sent, ['{"type":"response.create"}']);
    });

    test('close() is exactly once under concurrent calls (test 9)', () async {
      final cancellation = RealtimeCancellation();
      final rec = RecordingOpener();
      final connection = await transportWith(rec).connect('s', cancellation);
      await Future.wait(<Future<void>>[
        connection.close(),
        connection.close(),
        connection.close(),
      ]);
      await connection.close();
      expect(rec.socket.closeCalls, 1);
    });
  });

  group('canonical cancellation & delayed late close', () {
    test('a genuine (non-cancelled) handshake failure keeps its original '
        'error — it is not turned into cancellation', () async {
      final cancellation = RealtimeCancellation();
      final transport = WebSocketRealtimeTransport.forTesting(
        model: 'm',
        open: (Uri url, String secret, HttpClient client) async =>
            throw const SocketException('network down'),
      );
      await expectLater(
        transport.connect('s', cancellation),
        throwsA(isA<SocketException>()),
      );
    });

    test('a late WebSocket after cancel is closed exactly once, and connect '
        'stays UNSETTLED until the delayed native close finishes, then '
        'completes with RealtimeConnectCancelled (test 11)', () async {
      final cancellation = RealtimeCancellation();
      final closeGate = Completer<void>();
      final socket = FakeWebSocket(closeGate: closeGate);
      final openGate = Completer<void>();
      final transport = WebSocketRealtimeTransport.forTesting(
        model: 'm',
        // Ignores cancellation; the socket materializes only when openGate
        // opens — after the cancel sweep.
        open: (Uri url, String secret, HttpClient client) async {
          await openGate.future;
          return socket;
        },
      );

      var settled = false;
      Object? outcome;
      final future = () async {
        try {
          await transport.connect('s', cancellation);
          settled = true;
        } catch (e) {
          settled = true;
          outcome = e;
        }
      }();

      await pumpEventQueue();
      cancellation.cancel();
      await pumpEventQueue();
      // The socket materializes after the sweep.
      openGate.complete();
      await pumpEventQueue();

      // The late socket was adopted and its close was invoked exactly once...
      expect(socket.closeCalls, 1);
      // ...but the native close is still in flight (closeGate closed), so
      // connect MUST NOT have settled yet.
      expect(settled, isFalse);

      // Finish the delayed native close; only now may connect settle.
      closeGate.complete();
      await future;
      expect(settled, isTrue);
      expect(outcome, isA<RealtimeConnectCancelled>());
      expect(socket.closeCalls, 1);
    });

    test('a throwing late closer does not become an unhandled zone error '
        '(test 12)', () async {
      final errors = <Object>[];
      await runZonedGuarded(() async {
        final cancellation = RealtimeCancellation();
        final openGate = Completer<void>();
        final transport = WebSocketRealtimeTransport.forTesting(
          model: 'm',
          open: (Uri url, String secret, HttpClient client) async {
            await openGate.future;
            return _ThrowingCloseWebSocket();
          },
        );
        final future = transport.connect('s', cancellation);
        await pumpEventQueue();
        cancellation.cancel();
        await pumpEventQueue();
        openGate.complete();
        await future.then((_) {}, onError: (_) {});
        await pumpEventQueue();
      }, (error, _) => errors.add(error));
      expect(errors, isEmpty);
    });
  });
}

/// A WebSocket whose close always throws — to prove late-close errors are
/// swallowed and never reach the zone.
class _ThrowingCloseWebSocket implements RealtimeWebSocket {
  final StreamController<dynamic> controller = StreamController<dynamic>();

  @override
  Stream<dynamic> get frames => controller.stream;

  @override
  void add(String message) {}

  @override
  Future<void> close() async {
    throw StateError('close failed');
  }
}
