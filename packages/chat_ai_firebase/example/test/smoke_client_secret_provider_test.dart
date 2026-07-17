// The smoke ClientSecretProvider against a local loopback HTTP server: the
// exact request bytes/headers, the official `value` extraction, sanitized
// failures without any echo of endpoint/body/tokens/secret, exactly one
// HTTP request per call, and per-call token fetches. No Firebase, no OpenAI,
// no paid endpoint.
import 'dart:convert';
import 'dart:io';

import 'package:example/smoke_client_secret_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// One captured loopback request: everything the provider actually sent.
class CapturedRequest {
  CapturedRequest(this.method, this.headers, this.body);

  final String method;
  final HttpHeaders headers;
  final String body;
}

/// A loopback server answering every request with [status]/[body]; captures
/// each request into [requests].
Future<(HttpServer, List<CapturedRequest>, Uri)> startServer({
  required int status,
  required String body,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final requests = <CapturedRequest>[];
  server.listen((request) async {
    requests.add(
      CapturedRequest(
        request.method,
        request.headers,
        await utf8.decoder.bind(request).join(),
      ),
    );
    request.response.statusCode = status;
    request.response.write(body);
    await request.response.close();
  });
  final uri = Uri.parse('http://127.0.0.1:${server.port}/mint');
  return (server, requests, uri);
}

SmokeClientSecretProvider providerFor(
  Uri endpoint, {
  Future<String?> Function()? idToken,
  Future<String?> Function()? appCheckToken,
  HttpClient Function()? createHttpClient,
}) => SmokeClientSecretProvider(
  endpoint: endpoint,
  idToken: idToken ?? (() async => 'id-token-1'),
  appCheckToken: appCheckToken ?? (() async => 'app-check-1'),
  createHttpClient: createHttpClient,
);

void main() {
  test('sends exactly {"botId": …} with Authorization, X-Firebase-AppCheck '
      'and Content-Type, and returns the top-level value', () async {
    final (server, requests, uri) = await startServer(
      status: 200,
      body: '{"value":"ek_smoke_secret","expires_at":123}',
    );
    addTearDown(() => server.close(force: true));

    final secret = await providerFor(uri).getClientSecret(botId: 'bot-7');

    expect(secret, 'ek_smoke_secret');
    expect(requests, hasLength(1));
    final request = requests.single;
    expect(request.method, 'POST');
    // The body is EXACTLY the botId object — no prompt/messages/images/
    // tools/state/ChatRequest/idempotency key ever rides along.
    expect(request.body, '{"botId":"bot-7"}');
    expect(request.headers.value('authorization'), 'Bearer id-token-1');
    expect(request.headers.value('x-firebase-appcheck'), 'app-check-1');
    expect(request.headers.contentType?.mimeType, 'application/json');
  });

  test('both tokens are fetched anew for every call', () async {
    final (server, requests, uri) = await startServer(
      status: 200,
      body: '{"value":"ek_s"}',
    );
    addTearDown(() => server.close(force: true));
    var idFetches = 0;
    var appCheckFetches = 0;
    final provider = providerFor(
      uri,
      idToken: () async {
        idFetches++;
        return 'id-$idFetches';
      },
      appCheckToken: () async {
        appCheckFetches++;
        return 'ac-$appCheckFetches';
      },
    );

    await provider.getClientSecret(botId: 'b');
    await provider.getClientSecret(botId: 'b');

    expect(idFetches, 2);
    expect(appCheckFetches, 2);
    expect(requests, hasLength(2));
    expect(requests.last.headers.value('authorization'), 'Bearer id-2');
    expect(requests.last.headers.value('x-firebase-appcheck'), 'ac-2');
  });

  test('non-200 → sanitized error, exactly one request, no echo of '
      'endpoint/body/tokens', () async {
    final (server, requests, uri) = await startServer(
      status: 403,
      body: '{"error":"secret-server-detail"}',
    );
    addTearDown(() => server.close(force: true));

    await expectLater(
      providerFor(uri).getClientSecret(botId: 'b'),
      throwsA(
        isA<SmokeClientSecretException>().having(
          (e) => e.message,
          'message',
          smokeSecretStatusFailure,
        ),
      ),
    );
    // No automatic second HTTP request on failure.
    expect(requests, hasLength(1));
  });

  test('malformed JSON, non-object root, missing/empty/non-string value '
      '→ sanitized error, one request each', () async {
    const bodies = [
      'not json at all',
      '[1, 2, 3]',
      '{"secret":"ek_x"}', // no top-level value
      '{"value":""}', // empty value
      '{"value":42}', // non-string value
    ];
    for (final responseBody in bodies) {
      final (server, requests, uri) = await startServer(
        status: 200,
        body: responseBody,
      );
      await expectLater(
        providerFor(uri).getClientSecret(botId: 'b'),
        throwsA(
          isA<SmokeClientSecretException>().having(
            (e) => e.message,
            'message',
            smokeSecretMalformedFailure,
          ),
        ),
        reason: 'body: $responseBody',
      );
      expect(requests, hasLength(1), reason: 'body: $responseBody');
      await server.close(force: true);
    }
  });

  test('failure text never contains the endpoint, response body, tokens or '
      'a secret', () async {
    final (server, _, uri) = await startServer(
      status: 500,
      body: '{"error":"ek_leaky_secret","token":"id-token-1"}',
    );
    addTearDown(() => server.close(force: true));

    Object? caught;
    try {
      await providerFor(uri).getClientSecret(botId: 'b');
    } catch (error) {
      caught = error;
    }

    final text = caught.toString();
    expect(caught, isA<SmokeClientSecretException>());
    expect(text, isNot(contains(uri.host)));
    expect(text, isNot(contains('${uri.port}')));
    expect(text, isNot(contains('/mint')));
    expect(text, isNot(contains('ek_leaky_secret')));
    expect(text, isNot(contains('id-token-1')));
    expect(text, isNot(contains('app-check-1')));
  });

  test('a missing/throwing token rejects BEFORE any HTTP request '
      '(and stays sanitized)', () async {
    final (server, requests, uri) = await startServer(
      status: 200,
      body: '{"value":"ek_s"}',
    );
    addTearDown(() => server.close(force: true));

    await expectLater(
      providerFor(
        uri,
        idToken: () async => throw StateError('raw firebase detail'),
      ).getClientSecret(botId: 'b'),
      throwsA(
        isA<SmokeClientSecretException>().having(
          (e) => e.message,
          'message',
          smokeSecretIdTokenFailure,
        ),
      ),
    );
    await expectLater(
      providerFor(
        uri,
        appCheckToken: () async => null,
      ).getClientSecret(botId: 'b'),
      throwsA(
        isA<SmokeClientSecretException>().having(
          (e) => e.message,
          'message',
          smokeSecretAppCheckFailure,
        ),
      ),
    );
    // Neither rejected call ever reached the server.
    expect(requests, isEmpty);
  });

  test('a 303 redirect is NOT followed: sanitized status failure, one '
      'request to the mint server, ZERO requests to the redirect target, '
      'no leak in the error text', () async {
    // The redirect target is a SEPARATE loopback server: following the
    // redirect would hand Authorization/X-Firebase-AppCheck to it.
    final targetRequests = <CapturedRequest>[];
    final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target.listen((request) async {
      targetRequests.add(
        CapturedRequest(
          request.method,
          request.headers,
          await utf8.decoder.bind(request).join(),
        ),
      );
      request.response.statusCode = 200;
      request.response.write('{"value":"ek_stolen"}');
      await request.response.close();
    });
    addTearDown(() => target.close(force: true));
    final targetUrl = 'http://127.0.0.1:${target.port}/stolen';

    // The mint server answers the single POST with 303 See Other — the one
    // 3xx dart:io would auto-follow for a POST by default.
    final mintRequests = <CapturedRequest>[];
    final mint = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    mint.listen((request) async {
      mintRequests.add(
        CapturedRequest(
          request.method,
          request.headers,
          await utf8.decoder.bind(request).join(),
        ),
      );
      request.response.statusCode = 303;
      request.response.headers.set('location', targetUrl);
      await request.response.close();
    });
    addTearDown(() => mint.close(force: true));
    final mintUri = Uri.parse('http://127.0.0.1:${mint.port}/mint');

    Object? caught;
    try {
      await providerFor(mintUri).getClientSecret(botId: 'b');
    } catch (error) {
      caught = error;
    }

    expect(
      caught,
      isA<SmokeClientSecretException>().having(
        (e) => e.message,
        'message',
        smokeSecretStatusFailure,
      ),
    );
    // Let any (forbidden) late follow-up request surface before counting.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(mintRequests, hasLength(1));
    expect(targetRequests, isEmpty);

    final text = caught.toString();
    expect(text, isNot(contains('/mint')));
    expect(text, isNot(contains('/stolen')));
    expect(text, isNot(contains('${mint.port}')));
    expect(text, isNot(contains('${target.port}')));
    expect(text, isNot(contains('id-token-1')));
    expect(text, isNot(contains('app-check-1')));
    expect(text, isNot(contains('ek_stolen')));
  });

  test('a throwing HttpClient factory → sanitized transport failure with '
      'no raw detail and no HTTP request', () async {
    final (server, requests, uri) = await startServer(
      status: 200,
      body: '{"value":"ek_s"}',
    );
    addTearDown(() => server.close(force: true));

    Object? caught;
    try {
      await providerFor(
        uri,
        createHttpClient: () => throw StateError('raw-factory-detail-42'),
      ).getClientSecret(botId: 'b');
    } catch (error) {
      caught = error;
    }

    expect(
      caught,
      isA<SmokeClientSecretException>().having(
        (e) => e.message,
        'message',
        smokeSecretTransportFailure,
      ),
    );
    expect(caught.toString(), isNot(contains('raw-factory-detail-42')));
    expect(requests, isEmpty);
  });

  test('an unreachable endpoint → sanitized transport failure', () async {
    // Bind-then-close guarantees a refused port with no server behind it.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final uri = Uri.parse('http://127.0.0.1:${server.port}/mint');
    await server.close(force: true);

    await expectLater(
      providerFor(uri).getClientSecret(botId: 'b'),
      throwsA(
        isA<SmokeClientSecretException>().having(
          (e) => e.message,
          'message',
          smokeSecretTransportFailure,
        ),
      ),
    );
  });
}
