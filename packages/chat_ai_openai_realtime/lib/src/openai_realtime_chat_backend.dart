// The one constructor below deliberately assigns its spec-pinned PUBLIC named
// parameters (`clientSecretProvider:` and `model:` must be callable from
// consuming apps) to private fields — the initializing-formal shorthand would
// change the public parameter shape.
// ignore_for_file: prefer_initializing_formals

import 'package:chat_ai/chat_ai.dart';

import 'client_secret_provider.dart';
import 'realtime_send_operation.dart';
import 'websocket_realtime_transport.dart';

/// The default Realtime model the adapter is verified against. The consuming
/// app MUST keep this in sync with what its mint endpoint binds to the
/// ephemeral credential — the client secret is not a secure model pin.
const String defaultRealtimeModel = 'gpt-realtime-2.1';

/// The inclusive upper bound OpenAI Realtime accepts for `max_output_tokens`
/// (1…4096; the value covers tool-call tokens too). OpenAI's own default is
/// the unbounded `inf`, which this package never uses.
const int _maxOutputTokensCeiling = 4096;

/// The OpenAI Realtime [ChatBackend]: each [send] leg runs over its own direct
/// OpenAI Realtime WebSocket (`wss://api.openai.com/v1/realtime`) as exactly
/// one out-of-band `response.create` (`conversation: "none"`, stateless input,
/// text output). No WebRTC, no microphone/camera, no native audio dependency.
///
/// The backend performs no retry at any stage. Failures before the
/// `response.create` dispatch end as `network` (safe for the Core's pre-token
/// silent retry); once the dispatch may have reached the provider, every
/// failure is terminal `upstream`, so the Core never re-runs a possibly-billed
/// call. Cancelling the subscription is the wire-cancel: best-effort
/// `response.cancel`, then full session teardown.
///
/// The ephemeral client secret comes from the app's [ClientSecretProvider]
/// (called anew per leg, receives only the bot id); token issuance, limits and
/// spend protection belong to the app.
class OpenAIRealtimeChatBackend implements ChatBackend {
  /// [model] is the Realtime model requested in the WebSocket URL (default
  /// [defaultRealtimeModel]); it must be non-empty (whitespace-only rejected)
  /// and match the model the app's mint endpoint binds to the credential.
  ///
  /// [maxOutputTokens] is the finite `max_output_tokens` placed inside every
  /// `response.create` (default 4096; accepted range 1…4096, tool-call tokens
  /// included). It is an upper bound on output, not a guarantee of a specific
  /// bill.
  ///
  /// [responseIdleTimeout] is a post-commit idle watchdog (default 60 s): if
  /// the server reports no Response progress for this long after a possible
  /// `response.create` dispatch, the leg ends as one terminal `upstream`
  /// (`response-idle-timeout`) after a best-effort `response.cancel` — never a
  /// retry, never a second billable call. It must be strictly greater than
  /// [Duration.zero].
  ///
  /// All invalid values throw [ArgumentError] synchronously at construction,
  /// before any client-secret request or network I/O.
  OpenAIRealtimeChatBackend({
    required ClientSecretProvider clientSecretProvider,
    String model = defaultRealtimeModel,
    int maxOutputTokens = _maxOutputTokensCeiling,
    Duration responseIdleTimeout = const Duration(seconds: 60),
  }) : _clientSecretProvider = clientSecretProvider,
       _model = model,
       _maxOutputTokens = maxOutputTokens,
       _responseIdleTimeout = responseIdleTimeout {
    if (_model.trim().isEmpty) {
      throw ArgumentError.value(
        model,
        'model',
        'Realtime model must be a non-empty, non-whitespace string',
      );
    }
    if (maxOutputTokens < 1 || maxOutputTokens > _maxOutputTokensCeiling) {
      throw ArgumentError.value(
        maxOutputTokens,
        'maxOutputTokens',
        'must be an integer in 1..$_maxOutputTokensCeiling',
      );
    }
    if (responseIdleTimeout <= Duration.zero) {
      throw ArgumentError.value(
        responseIdleTimeout,
        'responseIdleTimeout',
        'must be strictly greater than Duration.zero',
      );
    }
  }

  final ClientSecretProvider _clientSecretProvider;
  final String _model;
  final int _maxOutputTokens;
  final Duration _responseIdleTimeout;

  @override
  Stream<BackendEvent> send(ChatRequest request) => runRealtimeSend(
    clientSecretProvider: _clientSecretProvider,
    transport: WebSocketRealtimeTransport(model: _model),
    request: request,
    maxOutputTokens: _maxOutputTokens,
    responseIdleTimeout: _responseIdleTimeout,
  );
}
