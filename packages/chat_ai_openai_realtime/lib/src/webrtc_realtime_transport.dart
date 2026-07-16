// The production RealtimeTransport: flutter_webrtc peer connection + the
// `oai-events` data channel, with the official OpenAI WebRTC signaling
// (`POST https://api.openai.com/v1/realtime/calls`, SDP offer in,
// SDP answer out, the ephemeral secret as the Bearer credential).
//
// Deliberately data-channel-only: no microphone permission is requested and
// no audio/media track is ever created. SDP signaling uses dart:io — no
// extra HTTP dependency. iOS/Android only (flutter_webrtc data channels).
//
// Cancellation & ownership: every resource of one connect attempt is owned
// by a RealtimeSetupRelease coordinator the instant it exists — including a
// resource whose creation Future completes only AFTER cancellation already
// swept (it is then closed immediately on adoption). Release is memoized
// and exactly-once per native resource; the closers are shared with the
// connection wrapper so no path closes a native object twice. A cancelled
// connect fails as `RealtimeConnectCancelled`, which the send operation
// swallows.
//
// No secret, SDP or provider response body ever leaves this file through an
// exception message that could reach an event `detail` — the send operation
// maps any throw here to a sanitized marker anyway.

// The transport constructors below deliberately assign their named
// parameters to private fields — the initializing-formal shorthand would
// make the parameter names private (the same audit finding as the public
// backend constructor).
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'realtime_setup_release.dart';
import 'realtime_transport.dart';

const String _callsEndpoint = 'https://api.openai.com/v1/realtime/calls';

/// One WebRTC session per [connect] call; nothing is shared or pooled.
class WebRtcRealtimeTransport implements RealtimeTransport {
  const WebRtcRealtimeTransport()
    : _createPeerConnection = createPeerConnection,
      _postSdpOffer = _postOffer;

  /// Package-internal seam for deterministic orchestration tests: injects
  /// the peer-connection factory and the SDP signaling call. Never exported
  /// — not public API.
  const WebRtcRealtimeTransport.forTesting({
    required Future<RTCPeerConnection> Function(
      Map<String, dynamic> configuration,
    )
    createPeerConnection,
    Future<String> Function(
          HttpClient client,
          String clientSecret,
          String offerSdp,
        )
        postSdpOffer =
        _postOffer,
  }) : _createPeerConnection = createPeerConnection,
       _postSdpOffer = postSdpOffer;

  final Future<RTCPeerConnection> Function(Map<String, dynamic> configuration)
  _createPeerConnection;

  final Future<String> Function(
    HttpClient client,
    String clientSecret,
    String offerSdp,
  )
  _postSdpOffer;

  @override
  Future<RealtimeConnection> connect(
    String clientSecret,
    RealtimeCancellation cancellation,
  ) async {
    final resources = RealtimeSetupRelease();
    // Active interruption: the sweep force-closes the signaling client (and
    // with it the pending HTTP request), the wrapper, the data channel and
    // the peer connection, which makes every await below fail fast. The
    // catch below awaits the memoized sweep, and a LATE resource — one that
    // materialized only after the sweep — is held by its own adopt(): this
    // connect future never resolves before every materialized resource has
    // actually finished closing.
    unawaited(cancellation.whenCancelled.then((_) => resources.releaseAll()));

    try {
      _throwIfCancelled(cancellation);
      // Adopted the instant the Future completes: a peer that materializes
      // only after cancellation swept is closed right there, and adopt()
      // resolves only once that close has finished.
      final peer = await resources.adopt(
        _createPeerConnection(<String, dynamic>{}),
        (RTCPeerConnection resource) => resource.close(),
      );
      _throwIfCancelled(cancellation);
      final channel = await resources.adopt(
        peer.resource.createDataChannel('oai-events', RTCDataChannelInit()),
        (RTCDataChannel resource) => resource.close(),
      );
      // The wrapper shares the exactly-once native closers with the
      // coordinator: whichever path closes first wins, none closes twice.
      // It owns the channel/peer callbacks from this instant, so an early
      // death during signaling becomes a controlled `opened == false` —
      // never an error parked in a not-yet-awaited future.
      final connection = WebRtcRealtimeConnection(
        peer.resource,
        channel.resource,
        closePeerConnection: peer.close,
        closeChannel: channel.close,
      );
      // Awaited for the same reason adopt() awaits: should this
      // registration lose a race against the sweep, connect may not resolve
      // before the wrapper has actually finished closing. (Before release
      // the returned future is already complete.)
      await resources.register(RealtimeSetupRelease.once(connection.close));
      _throwIfCancelled(cancellation);
      final offer = await peer.resource.createOffer();
      await peer.resource.setLocalDescription(offer);
      _throwIfCancelled(cancellation);
      final signalingClient = HttpClient();
      final closeSignalingClient = RealtimeSetupRelease.once(
        () async => signalingClient.close(force: true),
      );
      await resources.register(closeSignalingClient);
      final answerSdp = await _postSdpOffer(
        signalingClient,
        clientSecret,
        offer.sdp ?? '',
      );
      await closeSignalingClient();
      _throwIfCancelled(cancellation);
      await peer.resource.setRemoteDescription(
        RTCSessionDescription(answerSdp, 'answer'),
      );
      final opened = await connection.opened;
      _throwIfCancelled(cancellation);
      if (!opened) {
        // Controlled pre-commit failure: the session died before the
        // channel opened (released below, `network` for the caller).
        throw const SocketException('realtime session died before open');
      }
      return connection;
    } catch (_) {
      await resources.releaseAll();
      rethrow;
    }
  }
}

/// The official signaling exchange: the SDP offer goes up with the
/// ephemeral secret as the ONLY credential; the SDP answer comes back.
/// The [client] is owned by the caller so an abort can force-close it,
/// killing the pending request.
Future<String> _postOffer(
  HttpClient client,
  String clientSecret,
  String offerSdp,
) async {
  final request = await client.postUrl(Uri.parse(_callsEndpoint));
  request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $clientSecret');
  request.headers.contentType = ContentType('application', 'sdp');
  request.write(offerSdp);
  final response = await request.close();
  final body = await utf8.decoder.bind(response).join();
  if (response.statusCode < 200 || response.statusCode >= 300) {
    // Status code only — the body is never surfaced.
    throw HttpException('realtime signaling failed: ${response.statusCode}');
  }
  return body;
}

void _throwIfCancelled(RealtimeCancellation cancellation) {
  if (cancellation.isCancelled) {
    throw const RealtimeConnectCancelled();
  }
}

/// Package-internal wrapper that owns one live session's channel/peer
/// callbacks. Directly instantiable by the transport's tests; never
/// exported — not public API.
class WebRtcRealtimeConnection implements RealtimeConnection {
  /// [closePeerConnection]/[closeChannel] let the transport share its
  /// exactly-once closers so the coordinator and this wrapper can never
  /// double-close a native resource; without them (wrapper-level tests)
  /// the native objects are closed directly.
  WebRtcRealtimeConnection(
    this._peerConnection,
    this._channel, {
    Future<void> Function()? closePeerConnection,
    Future<void> Function()? closeChannel,
  }) : _closePeerConnectionOverride = closePeerConnection,
       _closeChannelOverride = closeChannel {
    _channel.onMessage = (RTCDataChannelMessage message) {
      if (!message.isBinary && !_events.isClosed) {
        _events.add(message.text);
      }
    };
    _channel.onDataChannelState = (RTCDataChannelState state) {
      switch (state) {
        case RTCDataChannelState.RTCDataChannelOpen:
          if (!_opened.isCompleted) {
            _opened.complete(true);
          }
        case RTCDataChannelState.RTCDataChannelClosing:
        case RTCDataChannelState.RTCDataChannelClosed:
          _handleDead();
        case RTCDataChannelState.RTCDataChannelConnecting:
          break;
      }
    };
    _peerConnection.onConnectionState = (RTCPeerConnectionState state) {
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          _handleDead();
        case RTCPeerConnectionState.RTCPeerConnectionStateNew:
        case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          break;
      }
    };
  }

  final RTCPeerConnection _peerConnection;
  final RTCDataChannel _channel;
  final Future<void> Function()? _closePeerConnectionOverride;
  final Future<void> Function()? _closeChannelOverride;
  final StreamController<String> _events = StreamController<String>();

  /// Completes `true` when the `oai-events` channel opens, `false` when the
  /// session dies (or is closed) first. Deliberately a value, NEVER an
  /// error: an early death before anyone awaits readiness must not park an
  /// unhandled error in this future.
  final Completer<bool> _opened = Completer<bool>();

  /// Memoized close: concurrent callers await the same actual teardown —
  /// nobody returns ahead of it.
  Future<void>? _closing;

  /// Whether the channel reached open — see [_opened].
  Future<bool> get opened => _opened.future;

  /// The channel or peer connection died: resolve a not-yet-open session to
  /// `false` and end the event stream (EOF) for the send operation to
  /// classify by its commit boundary.
  void _handleDead() {
    if (!_opened.isCompleted) {
      _opened.complete(false);
    }
    if (!_events.isClosed) {
      unawaited(_events.close());
    }
  }

  @override
  Stream<String> get events => _events.stream;

  @override
  Future<void> send(String message) =>
      _channel.send(RTCDataChannelMessage(message));

  @override
  Future<void> close() => _closing ??= _closeOnce();

  Future<void> _closeOnce() async {
    // Deterministic: an explicit close is a dead session even if the native
    // side never delivers another state callback.
    _handleDead();
    final closeChannel = _closeChannelOverride;
    if (closeChannel != null) {
      await closeChannel();
    } else {
      try {
        await _channel.close();
      } catch (_) {}
    }
    final closePeerConnection = _closePeerConnectionOverride;
    if (closePeerConnection != null) {
      await closePeerConnection();
    } else {
      try {
        await _peerConnection.close();
      } catch (_) {}
    }
  }
}
