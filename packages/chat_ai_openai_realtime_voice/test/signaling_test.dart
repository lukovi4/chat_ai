// Required test 4: SDP signaling is exactly one POST, application/sdp, with the
// ephemeral secret as the ONLY credential and no redirect following.
// Part of required test 20: a non-2xx status never leaks the response body.
import 'dart:async';
import 'dart:io';

import 'package:chat_ai_openai_realtime_voice/src/voice_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'signaling is one POST with Bearer secret and application/sdp',
    () async {
      final client = _FakeHttpClient(statusCode: 200, body: 'v=0\r\nanswer');

      final answer = await postSdpOffer(
        client,
        'ephemeral-secret',
        'v=0\r\noffer',
      );

      expect(answer, 'v=0\r\nanswer');
      expect(client.postUrlCalls.length, 1);
      expect(
        client.postUrlCalls.single.toString(),
        'https://api.openai.com/v1/realtime/calls',
      );
      final request = client.lastRequest!;
      expect(request.followRedirectsValue, isFalse);
      expect(
        request.fakeHeaders.setCalls['authorization'],
        'Bearer ephemeral-secret',
      );
      expect(
        request.fakeHeaders.contentTypeValue.toString(),
        'application/sdp',
      );
      expect(request.written.join(), contains('offer'));
    },
  );

  test('a non-2xx signaling status throws without reading the body', () async {
    final client = _FakeHttpClient(statusCode: 403, body: 'secret error body');
    Object? caught;
    try {
      await postSdpOffer(client, 'ephemeral-secret', 'v=0\r\noffer');
    } catch (e) {
      caught = e;
    }
    expect(caught, isA<RealtimeVoiceConnectException>());
    expect(caught.toString().contains('secret error body'), isFalse);
    expect(caught.toString().contains('403'), isFalse);
    // Defect 4: the response body stream was never even listened to/read.
    expect(client.lastRequest!.lastResponse!.listened, isFalse);
  });
}

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
  final List<Uri> postUrlCalls = <Uri>[];
  _FakeRequest? lastRequest;

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    postUrlCalls.add(url);
    final request = _FakeRequest(statusCode: statusCode, body: body);
    lastRequest = request;
    return request;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
  final _FakeHeaders _headers = _FakeHeaders();
  final List<Object?> written = <Object?>[];
  bool followRedirectsValue = true;
  _FakeResponse? lastResponse;

  _FakeHeaders get fakeHeaders => _headers;

  @override
  HttpHeaders get headers => _headers;

  @override
  set followRedirects(bool value) => followRedirectsValue = value;

  @override
  void write(Object? object) => written.add(object);

  @override
  Future<HttpClientResponse> close() async =>
      lastResponse = _FakeResponse(statusCode: statusCode, body: body);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHeaders implements HttpHeaders {
  final Map<String, String> setCalls = <String, String>{};
  ContentType contentTypeValue = ContentType('text', 'plain');

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    setCalls[name.toLowerCase()] = value.toString();
  }

  @override
  set contentType(ContentType? value) {
    if (value != null) {
      contentTypeValue = value;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse({required this.statusCode, required this.body});

  @override
  final int statusCode;
  final String body;
  bool listened = false;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    listened = true;
    return Stream<List<int>>.fromIterable(<List<int>>[body.codeUnits]).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
