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
  /// [model] is the Realtime model requested in the WebSocket URL; it defaults
  /// to [defaultRealtimeModel]. It must be non-empty (whitespace-only is
  /// rejected here, before any token request or network I/O) and must match
  /// the model the app's mint endpoint binds to the ephemeral credential.
  OpenAIRealtimeChatBackend({
    required ClientSecretProvider clientSecretProvider,
    String model = defaultRealtimeModel,
  }) : _clientSecretProvider = clientSecretProvider,
       _model = model {
    if (_model.trim().isEmpty) {
      throw ArgumentError.value(
        model,
        'model',
        'Realtime model must be a non-empty, non-whitespace string',
      );
    }
  }

  final ClientSecretProvider _clientSecretProvider;
  final String _model;

  @override
  Stream<BackendEvent> send(ChatRequest request) => runRealtimeSend(
    clientSecretProvider: _clientSecretProvider,
    transport: WebSocketRealtimeTransport(model: _model),
    request: request,
  );
}
