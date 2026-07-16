// The one constructor below deliberately assigns its spec-pinned PUBLIC
// named parameter (`clientSecretProvider:` must be callable from consuming
// apps) to a private field — the initializing-formal shorthand would change
// the public parameter shape.
// ignore_for_file: prefer_initializing_formals

import 'package:chat_ai/chat_ai.dart';

import 'client_secret_provider.dart';
import 'realtime_send_operation.dart';
import 'webrtc_realtime_transport.dart';

/// The OpenAI Realtime (WebRTC) [ChatBackend]: each [send] leg runs over its
/// own WebRTC session as exactly one out-of-band `response.create`
/// (`conversation: "none"`, stateless input, text output). iOS/Android only.
///
/// The backend performs no retry at any stage. Failures before the
/// `response.create` dispatch end as `network` (safe for the Core's
/// pre-token silent retry); once the dispatch may have reached the provider,
/// every failure is terminal `upstream`, so the Core never re-runs a
/// possibly-billed call. Cancelling the subscription is the wire-cancel:
/// best-effort `response.cancel`, then full session teardown.
///
/// The ephemeral client secret comes from the app's [ClientSecretProvider]
/// (called anew per leg, receives only the bot id); token issuance, limits
/// and spend protection belong to the app.
class OpenAIRealtimeChatBackend implements ChatBackend {
  OpenAIRealtimeChatBackend({
    required ClientSecretProvider clientSecretProvider,
  }) : _clientSecretProvider = clientSecretProvider;

  final ClientSecretProvider _clientSecretProvider;

  @override
  Stream<BackendEvent> send(ChatRequest request) => runRealtimeSend(
    clientSecretProvider: _clientSecretProvider,
    transport: const WebRtcRealtimeTransport(),
    request: request,
  );
}
