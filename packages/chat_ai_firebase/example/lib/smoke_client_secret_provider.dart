// Public named parameters assign private fields here (the adapter's own
// convention): a private named initializing formal is not an option, and the
// line-level ignore does not survive the formatter.
// ignore_for_file: prefer_initializing_formals

// The smoke-only ClientSecretProvider of the dual-backend harness
// (SMOKE_BACKEND=realtime). NOT a production sample and NOT a package API:
// token issuance, entitlement, quota and spend protection belong to the
// app's own backend. The standard OpenAI API key is never on the device —
// this provider only relays Firebase attestation to the app-owned endpoint
// and hands the returned ephemeral client secret to the Realtime adapter.
import 'dart:convert';
import 'dart:io';

import 'package:chat_ai_openai_realtime/chat_ai_openai_realtime.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Stable sanitized markers — the ONLY text a provider failure ever carries.
/// Deliberately constants: the endpoint URL, HTTP status/body, Firebase
/// tokens, the client secret and the original exception are never echoed.
const String smokeSecretIdTokenFailure =
    'client-secret: missing Firebase id-token';
const String smokeSecretAppCheckFailure =
    'client-secret: missing App Check token';
const String smokeSecretTransportFailure = 'client-secret: transport failure';
const String smokeSecretStatusFailure = 'client-secret: non-200 response';
const String smokeSecretMalformedFailure = 'client-secret: malformed response';

/// The sanitized failure of [SmokeClientSecretProvider]: carries one of the
/// pinned marker strings above and nothing else. The Realtime adapter maps
/// any provider exception into one sanitized `ErrorEvent(upstream)`.
class SmokeClientSecretException implements Exception {
  const SmokeClientSecretException(this.message);

  final String message;

  @override
  String toString() => 'SmokeClientSecretException: $message';
}

/// Smoke implementation of the Realtime adapter's [ClientSecretProvider]:
/// one `POST {"botId": …}` to the app-owned mint endpoint per call, carrying
/// only the Firebase id-token + App Check attestation — never a prompt,
/// message, image, tool, conversation state, `ChatRequest`, idempotency key
/// or the standard OpenAI API key.
///
/// The endpoint is expected to return the official OpenAI
/// `POST /v1/realtime/client_secrets` passthrough response: a JSON object
/// whose non-empty top-level string `value` is the ephemeral client secret.
///
/// Behaviour, pinned by the harness tests:
/// - both Firebase tokens are fetched anew for every call;
/// - exactly one HTTP request per call — no retry and no redirect
///   following on any failure;
/// - only HTTP 200 is accepted; any 3xx (303 included) is an ordinary
///   non-200 failure, so attestation headers can never reach a redirect
///   target;
/// - the HTTP client is closed on every branch;
/// - the response body, tokens, URL and secret are never persisted, never
///   logged and never included in a thrown exception; their transient
///   in-memory presence while building the request and reading the reply
///   is unavoidable;
/// - every failure is one [SmokeClientSecretException] with a pinned marker.
class SmokeClientSecretProvider implements ClientSecretProvider {
  /// [endpoint] is the deployed mint endpoint
  /// (`REALTIME_CLIENT_SECRET_ENDPOINT`). The token/client seams exist only
  /// so the harness tests run against a loopback server without Firebase —
  /// production smoke uses the defaults.
  SmokeClientSecretProvider({
    required Uri endpoint,
    Future<String?> Function()? idToken,
    Future<String?> Function()? appCheckToken,
    HttpClient Function()? createHttpClient,
  }) : _endpoint = endpoint,
       _idToken = idToken ?? _firebaseIdToken,
       _appCheckToken = appCheckToken ?? _firebaseAppCheckToken,
       _createHttpClient = createHttpClient ?? HttpClient.new;

  final Uri _endpoint;
  final Future<String?> Function() _idToken;
  final Future<String?> Function() _appCheckToken;
  final HttpClient Function() _createHttpClient;

  @override
  Future<String> getClientSecret({required String botId}) async {
    // Both tokens are fetched anew on every call; a missing/empty/throwing
    // fetch rejects the call BEFORE any HTTP request is dispatched.
    final idToken = await _token(_idToken);
    if (idToken == null) {
      throw const SmokeClientSecretException(smokeSecretIdTokenFailure);
    }
    final appCheckToken = await _token(_appCheckToken);
    if (appCheckToken == null) {
      throw const SmokeClientSecretException(smokeSecretAppCheckFailure);
    }

    // A synchronous factory failure is a transport failure like any other —
    // sanitized, with no client to close (nothing was created).
    final HttpClient client;
    try {
      client = _createHttpClient();
    } catch (_) {
      throw const SmokeClientSecretException(smokeSecretTransportFailure);
    }
    final String body;
    try {
      final request = await client.postUrl(_endpoint);
      // Redirects are never followed — set BEFORE any header/body. dart:io
      // would otherwise auto-follow a 303 to a POST with a second HTTP
      // request to the Location target: on a cross-origin redirect Dart
      // normally does not carry Authorization over, but it may carry the
      // custom X-Firebase-AppCheck header; on a same-origin/subdomain
      // redirect both headers may be carried over. followRedirects=false
      // rules out the second request entirely — no attestation header can
      // ever reach a redirect target: any 3xx is an ordinary non-200 below
      // (sanitized failure, no manual following).
      request.followRedirects = false;
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $idToken');
      request.headers.set('X-Firebase-AppCheck', appCheckToken);
      // The body is exactly {"botId": …} — nothing else ever rides along.
      request.add(utf8.encode(jsonEncode({'botId': botId})));
      final response = await request.close();
      if (response.statusCode != 200) {
        // The failure body is never read; close(force) below drops it.
        throw const SmokeClientSecretException(smokeSecretStatusFailure);
      }
      body = await response.transform(utf8.decoder).join();
    } on SmokeClientSecretException {
      rethrow;
    } catch (_) {
      // Dropped by design: no exception text, URL or token is echoed.
      throw const SmokeClientSecretException(smokeSecretTransportFailure);
    } finally {
      client.close(force: true);
    }

    final Object? root;
    try {
      root = jsonDecode(body);
    } on FormatException {
      throw const SmokeClientSecretException(smokeSecretMalformedFailure);
    }
    if (root is! Map<String, dynamic>) {
      throw const SmokeClientSecretException(smokeSecretMalformedFailure);
    }
    // The official client_secrets response: a non-empty top-level `value`.
    final Object? value = root['value'];
    if (value is! String || value.isEmpty) {
      throw const SmokeClientSecretException(smokeSecretMalformedFailure);
    }
    return value;
  }

  /// Normalizes one token fetch: null/empty and any thrown exception all
  /// become null — the raw Firebase exception is dropped by design.
  static Future<String?> _token(Future<String?> Function() fetch) async {
    try {
      final token = await fetch();
      return token == null || token.isEmpty ? null : token;
    } catch (_) {
      return null;
    }
  }

  /// Production id-token source: the current `firebase_auth` user, fetched
  /// lazily per call.
  static Future<String?> _firebaseIdToken() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return null;
    }
    return user.getIdToken();
  }

  /// Production attestation source: `firebase_app_check`, fetched lazily
  /// per call.
  static Future<String?> _firebaseAppCheckToken() =>
      FirebaseAppCheck.instance.getToken();
}
