import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpDate;

// The core contracts (ChatBackend, ChatRequest, BackendEvent, FailureCause)
// come exclusively through the public barrel.
import 'package:chat_ai/chat_ai.dart';
import 'package:dio/dio.dart';
import 'package:firebase_app_check/firebase_app_check.dart'
    show FirebaseAppCheck;
import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuth;
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'chat_request_wire.dart';
import 'sse_event_stream.dart';
import 'sse_parser.dart';

/// The pinned logs-only detail of every wire-version failure: the server's
/// own HTTP 426 detail string (SERVER-CONTRACT §5), reused verbatim when the
/// client itself rejects a 200 response with a missing/mismatched
/// `X-Chat-AI-Wire-Version` header or no readable body stream (V1_SPEC §8).
const String _unsupportedWireVersionDetail = 'unsupported-wire-version';

/// The pinned `auth` details of the two attestation legs
/// (SERVER-CONTRACT §10: `auth` rides with `id-token` / `app-check`).
const String _idTokenDetail = 'id-token';
const String _appCheckDetail = 'app-check';

/// Stable sanitized markers for client-side transport failures
/// (SERVER-CONTRACT §10: mapped by the client as `network`). Deliberately
/// constants: exception text, response bodies and URLs are never echoed.
const String _requestFailureDetail = 'Transport failure before response';
const String _streamFailureDetail = 'Transport failure while streaming';

/// Stable sanitized marker for a pre-stream failure body that violates the
/// wire shape (malformed UTF-8/JSON, non-object root, missing/unknown/
/// wrong-type `cause`, wrong-type `detail`). The offending body is never
/// echoed.
const String _malformedFailureBodyDetail = 'Malformed pre-stream failure body';

/// Stable sanitized marker for an unexpected local defect (serialization,
/// internal logic) caught by the outer lifecycle guard of [_run]. Not a
/// transport fact — never `network`: the stream still completes with exactly
/// one `ErrorEvent(upstream)` instead of throwing or hanging (V1_SPEC §8:
/// "a thrown error escaping `send()` is a bug by contract" — even a bug
/// becomes data). The caught exception is dropped: its text and stack never
/// reach a detail or diagnostics.
const String _internalFailureDetail = 'Firebase backend internal failure';

/// Every successful SSE response carries this header with the single value
/// `"1"` (SERVER-CONTRACT §5); it is verified before `Accepted`.
const String _wireVersionHeader = 'X-Chat-AI-Wire-Version';

/// The standard pre-stream backoff header (V1_SPEC §6: "one backoff input,
/// two wires" — in-stream errors use `retryAfterMs` instead).
const String _retryAfterHeader = 'Retry-After';

/// The nine kebab-case wire cause codes a pre-stream failure body may carry
/// (V1_SPEC §6; SERVER-CONTRACT §10). The kebab-case mapping belongs to the
/// transport layer by contract (see [FailureCause]). `tool-loop-limit` is
/// client-only and never crosses the wire — deliberately absent, so it is
/// rejected like any unknown code.
const Map<String, FailureCause> _wireCauses = {
  'auth': FailureCause.auth,
  'entitlement': FailureCause.entitlement,
  'quota': FailureCause.quota,
  'rate': FailureCause.rate,
  'overloaded': FailureCause.overloaded,
  'content-filter': FailureCause.contentFilter,
  'context-too-long': FailureCause.contextTooLong,
  'network': FailureCause.network,
  'upstream': FailureCause.upstream,
};

/// The production [ChatBackend]: one `POST` per [send] over `dio`
/// (`ResponseType.stream`), Firebase id-token + App Check attestation
/// headers, and the internal SSE pipeline ([parseSseFrames] →
/// [decodeSseEventStream]) — V1_SPEC §2/§6/§8, SERVER-CONTRACT §2–§6/§10.
///
/// **The returned stream never throws** — every outcome is a [BackendEvent]:
/// - pre-dispatch auth failures (no user, null/empty token, a throwing
///   Firebase call) → exactly one `ErrorEvent(auth)` with the pinned
///   `id-token`/`app-check` detail; the HTTP request is never dispatched;
/// - HTTP `409`/`410` → [ConflictEvent]/[GoneEvent]; `426` →
///   `ErrorEvent(upstream, "unsupported-wire-version")` regardless of body;
/// - any other non-200 → the strict `{"cause", "detail"?}` body mapped onto
///   the nine wire causes plus the standard `Retry-After` header as
///   [ErrorEvent.retryAfter]; a malformed body → `ErrorEvent(upstream)` with
///   a stable sanitized marker;
/// - `200` → the `X-Chat-AI-Wire-Version: 1` header is verified, then
///   [Accepted] precedes the decoded SSE events in wire order; parser defects
///   and EOF-without-terminal are converted by the lifecycle layer; a
///   transport break becomes one `ErrorEvent(network)`;
/// - an unexpected local defect (e.g. request serialization) → exactly one
///   `ErrorEvent(upstream)` with a stable internal marker — never `network`
///   and never a hanging or throwing stream;
/// - no wire payload, token, URL or exception text ever reaches a `detail`.
///
/// **Cancelling the subscription is the wire-cancel** (SERVER-CONTRACT §3):
/// it synchronously cancels the per-send [CancelToken] (aborting a pending
/// HTTP future immediately) and cancels the SSE subscription (closing the
/// connection); the canceller receives no further events. The proxy's
/// upstream abort is best-effort and the orphan is bounded.
///
/// This class is a dumb pipe: no retry/backoff (the money-aware loop lives
/// in the Core, V1_SPEC §8), no timeouts into a live stream (deadline
/// mechanics are the Core's), no cancel endpoint.
class FirebaseChatBackend implements ChatBackend {
  /// The single public constructor (V1_SPEC §8: `FirebaseChatBackend(url)`).
  ///
  /// [url] is the deployed function endpoint. The backend owns a private
  /// `dio` instance and pulls the id-token from `firebase_auth` and the
  /// attestation from `firebase_app_check` **per request** — nothing
  /// Firebase-related is touched at construction time, and the package never
  /// calls `Firebase.initializeApp` (the consuming app initializes Firebase;
  /// `firebase_core` arrives transitively).
  FirebaseChatBackend(String url)
    : this._(
        url: url,
        dio: Dio(),
        idToken: _firebaseIdToken,
        appCheckToken: _firebaseAppCheckToken,
        now: null,
      );

  FirebaseChatBackend._({
    required this._url,
    required this._dio,
    required this._idToken,
    required this._appCheckToken,
    required DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _dio.interceptors.add(InterceptorsWrapper(onRequest: _attachAuthHeaders));
  }

  final String _url;
  final Dio _dio;
  final Future<String?> Function() _idToken;
  final Future<String?> Function() _appCheckToken;

  /// Clock for the HTTP-date form of `Retry-After` — injectable only through
  /// the internal test seam, so that form is testable deterministically.
  final DateTime Function() _now;

  @override
  Stream<BackendEvent> send(ChatRequest request) {
    // One fresh CancelToken per send: cancelling the subscription is the
    // wire-cancel and must abort THIS request only, immediately.
    final cancelToken = CancelToken();
    var cancelled = false;
    StreamSubscription<BackendEvent>? sseSubscription;
    Future<void> Function()? cancelBodyRead;
    late final StreamController<BackendEvent> controller;
    controller = StreamController<BackendEvent>(
      onListen: () {
        // _run never throws: its outer guard turns even an internal defect
        // into one terminal event and closes the controller.
        unawaited(
          _run(
            request,
            controller,
            cancelToken,
            isCancelled: () => cancelled,
            onSseSubscription: (subscription) => sseSubscription = subscription,
            onBodyRead: (cancel) {
              cancelBodyRead = cancel;
              if (cancel != null && cancelled) {
                // Cancellation raced the registration: the freshly started
                // read must terminate itself right away.
                cancel().ignore();
              }
            },
          ),
        );
      },
      onCancel: () async {
        cancelled = true;
        // Synchronous: a pending HTTP future is rejected right away (dio
        // races the adapter against `whenCancel`) — no waiting for the
        // response or the next SSE chunk.
        cancelToken.cancel();
        try {
          await sseSubscription?.cancel();
          // An active non-200 failure-body read is closed at once too: its
          // pending read completes instead of hanging.
          await cancelBodyRead?.call();
        } catch (_) {
          // Teardown defects must not surface to the canceller.
        }
      },
    );
    return controller.stream;
  }

  /// The outer lifecycle guard of one send: [_dispatch] does the real work;
  /// any unexpected local defect escaping it (request serialization, internal
  /// logic — NOT a transport fact) becomes exactly one
  /// `ErrorEvent(upstream, detail: [_internalFailureDetail])` — provided the
  /// subscriber has not cancelled and the controller is still open — and the
  /// controller is then closed. A cancelled stream is closed silently. This
  /// completes the "never throws / never hangs" guarantee: no exit of the
  /// unawaited future leaves the controller open.
  Future<void> _run(
    ChatRequest request,
    StreamController<BackendEvent> controller,
    CancelToken cancelToken, {
    required bool Function() isCancelled,
    required void Function(StreamSubscription<BackendEvent>) onSseSubscription,
    required void Function(Future<void> Function()? cancel) onBodyRead,
  }) async {
    try {
      await _dispatch(
        request,
        controller,
        cancelToken,
        isCancelled: isCancelled,
        onSseSubscription: onSseSubscription,
        onBodyRead: onBodyRead,
      );
    } catch (_) {
      // The exception is dropped by design: never echoed (sanitization).
      if (!isCancelled() && !controller.isClosed) {
        controller.add(
          const BackendEvent.error(
            FailureCause.upstream,
            detail: _internalFailureDetail,
          ),
        );
      }
      await controller.close();
    }
  }

  /// One backend request: exactly one POST (no retry here — V1_SPEC §8),
  /// then the HTTP status/header mapping and, for a valid 200, the SSE
  /// pipeline. Transport failures are mapped here; anything else escaping
  /// this method is an internal defect handled by [_run]'s guard.
  Future<void> _dispatch(
    ChatRequest request,
    StreamController<BackendEvent> controller,
    CancelToken cancelToken, {
    required bool Function() isCancelled,
    required void Function(StreamSubscription<BackendEvent>) onSseSubscription,
    required void Function(Future<void> Function()? cancel) onBodyRead,
  }) async {
    final Response<ResponseBody> response;
    try {
      response = await _dio.post<ResponseBody>(
        _url,
        // The frozen serialized request (V1_SPEC §8): dio sends a String
        // body as-is — no re-encoding, byte-identical across silent retries.
        data: encodeChatRequestBody(request),
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          // Non-200 statuses are protocol data mapped below, never thrown.
          validateStatus: (_) => true,
          headers: <String, Object>{
            Headers.contentTypeHeader: 'application/json',
            'Idempotency-Key': request.idempotencyKey,
          },
        ),
      );
    } on DioException catch (exception) {
      if (!isCancelled() && exception.type != DioExceptionType.cancel) {
        final Object? marker = exception.error;
        controller.add(
          marker is _AuthFailure
              ? BackendEvent.error(FailureCause.auth, detail: marker.detail)
              : const BackendEvent.error(
                  FailureCause.network,
                  detail: _requestFailureDetail,
                ),
        );
      }
      await controller.close();
      return;
    }
    // Deliberately no generic catch here: a non-Dio exception (e.g. a
    // request-serialization defect) is not a transport failure — it falls
    // through to [_run]'s guard as `upstream`, never `network`.

    final Object? body = response.data;
    if (isCancelled()) {
      _discard(body);
      await controller.close();
      return;
    }

    if (response.statusCode == 200) {
      final versions = response.headers[_wireVersionHeader];
      if (body is! ResponseBody ||
          versions == null ||
          versions.length != 1 ||
          versions.single != '1') {
        _discard(body);
        controller.add(
          const BackendEvent.error(
            FailureCause.upstream,
            detail: _unsupportedWireVersionDetail,
          ),
        );
        await controller.close();
        return;
      }
      // Only a verified response is Accepted; then the existing SSE layers
      // own the event order, terminals and defect conversion. A remaining
      // non-FormatException stream error is a client transport break.
      controller.add(const BackendEvent.accepted());
      // `cast`: the framer's strict Utf8Decoder is a
      // StreamTransformer<List<int>, String>; dio's reified
      // Stream<Uint8List> would fail its covariant runtime check.
      onSseSubscription(
        decodeSseEventStream(
          parseSseFrames(body.stream.cast<List<int>>()),
        ).listen(
          controller.add,
          onError: (Object _) {
            controller.add(
              const BackendEvent.error(
                FailureCause.network,
                detail: _streamFailureDetail,
              ),
            );
            unawaited(controller.close());
          },
          onDone: controller.close,
          cancelOnError: true,
        ),
      );
      return;
    }

    final BackendEvent event;
    switch (response.statusCode) {
      case 409:
        _discard(body);
        event = const BackendEvent.conflict();
      case 410:
        _discard(body);
        event = const BackendEvent.gone();
      case 426:
        // Pinned outcome regardless of body quality (V1_SPEC §6).
        _discard(body);
        event = const BackendEvent.error(
          FailureCause.upstream,
          detail: _unsupportedWireVersionDetail,
        );
      default:
        event = await _preStreamFailure(body, response.headers, onBodyRead);
    }
    if (!isCancelled()) {
      controller.add(event);
    }
    await controller.close();
  }

  /// Maps a generic non-200 pre-stream failure: the UTF-8 JSON body
  /// `{"cause": "<wire code>", "detail": "..."?}` (V1_SPEC §6) read
  /// strictly — object root, `cause` required and one of the nine wire
  /// codes, `detail` absent/null or String, unknown fields ignored. Any
  /// violation collapses into one `ErrorEvent(upstream)` with the stable
  /// sanitized marker. The `Retry-After` header rides along as
  /// [ErrorEvent.retryAfter]; the backoff decision itself is the Core's.
  ///
  /// The body read is explicitly cancellable: its `StreamIterator.cancel` is
  /// registered through [onBodyRead] so a wire-cancel closes the connection
  /// at once — cancelling completes a pending `moveNext` with `false`, so
  /// this read can never be left hanging. After the read ends the hook is
  /// cleared (no stale cancel callback).
  Future<BackendEvent> _preStreamFailure(
    Object? body,
    Headers headers,
    void Function(Future<void> Function()? cancel) onBodyRead,
  ) async {
    final Duration? retryAfter = _retryAfter(headers);
    final String text;
    try {
      if (body is! ResponseBody) {
        throw const FormatException();
      }
      final bytes = <int>[];
      final iterator = StreamIterator(body.stream);
      onBodyRead(iterator.cancel);
      try {
        while (await iterator.moveNext()) {
          bytes.addAll(iterator.current);
        }
      } finally {
        onBodyRead(null);
        await iterator.cancel();
      }
      text = utf8.decode(bytes); // strict: malformed UTF-8 throws
    } on FormatException {
      return BackendEvent.error(
        FailureCause.upstream,
        detail: _malformedFailureBodyDetail,
        retryAfter: retryAfter,
      );
    } catch (_) {
      // A transport break while reading the failure body.
      return BackendEvent.error(
        FailureCause.network,
        detail: _streamFailureDetail,
        retryAfter: retryAfter,
      );
    }
    try {
      final Object? root = jsonDecode(text);
      if (root is! Map<String, dynamic>) {
        throw const FormatException();
      }
      final Object? wire = root['cause'];
      final FailureCause? cause = wire is String ? _wireCauses[wire] : null;
      if (cause == null) {
        // Missing/wrong-type/unknown cause — `tool-loop-limit` included:
        // it never crosses the wire (SERVER-CONTRACT §2).
        throw const FormatException();
      }
      final Object? detail = root['detail'];
      if (detail != null && detail is! String) {
        throw const FormatException();
      }
      return BackendEvent.error(
        cause,
        detail: detail as String?,
        retryAfter: retryAfter,
      );
    } on FormatException {
      return BackendEvent.error(
        FailureCause.upstream,
        detail: _malformedFailureBodyDetail,
        retryAfter: retryAfter,
      );
    }
  }

  /// Parses the standard `Retry-After` header (both RFC 9110 forms) into a
  /// [Duration]: non-negative delta-seconds; an HTTP-date as its distance
  /// from UTC now (already past → [Duration.zero]); malformed/negative →
  /// null. No backoff is applied here — the value is data for the Core.
  Duration? _retryAfter(Headers headers) {
    final values = headers[_retryAfterHeader];
    if (values == null || values.length != 1) {
      return null;
    }
    final value = values.single.trim();
    if (_deltaSeconds.hasMatch(value)) {
      final seconds = int.tryParse(value);
      return seconds == null ? null : Duration(seconds: seconds);
    }
    final DateTime date;
    try {
      date = HttpDate.parse(value);
    } catch (_) {
      return null; // neither delta-seconds nor a valid HTTP-date
    }
    final difference = date.difference(_now().toUtc());
    return difference.isNegative ? Duration.zero : difference;
  }

  static final RegExp _deltaSeconds = RegExp(r'^\d+$');

  /// Fetches both tokens before dispatch and attaches
  /// `Authorization: Bearer <id-token>` + `X-Firebase-AppCheck` (V1_SPEC §6).
  /// A missing/empty/throwing token rejects the request before the HTTP
  /// adapter runs, carrying only the pinned detail marker.
  Future<void> _attachAuthHeaders(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final idToken = await _token(_idToken);
    if (idToken == null) {
      handler.reject(_authRejection(options, _idTokenDetail));
      return;
    }
    final appCheckToken = await _token(_appCheckToken);
    if (appCheckToken == null) {
      handler.reject(_authRejection(options, _appCheckDetail));
      return;
    }
    options.headers['Authorization'] = 'Bearer $idToken';
    options.headers['X-Firebase-AppCheck'] = appCheckToken;
    handler.next(options);
  }

  /// Normalizes one token fetch: null/empty and any thrown exception all
  /// become null. The raw Firebase exception is dropped by design — it must
  /// never reach an `ErrorEvent.detail` or diagnostics.
  static Future<String?> _token(Future<String?> Function() fetch) async {
    try {
      final token = await fetch();
      return token == null || token.isEmpty ? null : token;
    } catch (_) {
      return null;
    }
  }

  static DioException _authRejection(RequestOptions options, String detail) =>
      DioException(requestOptions: options, error: _AuthFailure(detail));

  /// Releases an unconsumed response body (409/410/426, failed wire-version
  /// check, post-response cancel race): cancelling the stream closes the
  /// connection without reading it.
  static void _discard(Object? body) {
    if (body is ResponseBody) {
      body.stream.listen(null, onError: (Object _) {}).cancel().ignore();
    }
  }

  /// Production id-token source: the current `firebase_auth` user, fetched
  /// lazily per request (no user → null → `auth`/`id-token`).
  static Future<String?> _firebaseIdToken() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return null;
    }
    return user.getIdToken();
  }

  /// Production attestation source: `firebase_app_check`, fetched lazily
  /// per request.
  static Future<String?> _firebaseAppCheckToken() =>
      FirebaseAppCheck.instance.getToken();
}

/// Internal marker riding inside the auth-rejection [DioException]: carries
/// only the pinned detail (`id-token` / `app-check`), never the underlying
/// Firebase exception.
class _AuthFailure {
  const _AuthFailure(this.detail);

  final String detail;
}

/// Internal test seam — NOT exported from `package:chat_ai/chat_ai.dart`.
///
/// Returns the same production implementation with its per-request inputs
/// replaced: a [dio] whose adapter is a test fake, plain token callbacks
/// instead of Firebase, and an optional [now] clock so the HTTP-date form of
/// `Retry-After` is deterministic. This exists so the transport contract is
/// testable without real Firebase/network; it is deliberately not a public
/// constructor, DI container or interface — the public surface stays exactly
/// `FirebaseChatBackend(url)` (V1_SPEC §3/§8).
@visibleForTesting
FirebaseChatBackend firebaseChatBackendForTesting({
  required String url,
  required Dio dio,
  required Future<String?> Function() idToken,
  required Future<String?> Function() appCheckToken,
  DateTime Function()? now,
}) => FirebaseChatBackend._(
  url: url,
  dio: dio,
  idToken: idToken,
  appCheckToken: appCheckToken,
  now: now,
);
