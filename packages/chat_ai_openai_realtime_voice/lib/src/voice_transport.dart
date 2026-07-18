// The voice session's WebRTC transport: ONE speech-to-speech call
// device → OpenAI Realtime. Audio-only local capture, a single `oai-events`
// data channel, official SDP signaling, the remote assistant audio played by
// flutter_webrtc's own engine. Transport/signaling/cancellation/exactly-once
// cleanup ideas are adapted from the accepted iOS feasibility probe; only the
// really-needed ones are carried over.
//
// It exposes only what the session drives; raw SDP, the client secret and raw
// event text never leave this file. Decoded events are surfaced as maps; an
// undecodable frame is dropped silently.
//
// No retry, no reconnect. One connect attempt owns every resource through a
// [RealtimeVoiceRelease] the instant it exists, so a cancel mid-signaling
// closes even a resource that materializes after the sweep.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'voice_cancellation.dart';
import 'voice_release.dart';

const String _callsEndpoint = 'https://api.openai.com/v1/realtime/calls';

/// The narrow surface the session uses. A fake implementation drives the
/// session's money-safe/lifecycle tests without any native WebRTC.
abstract class RealtimeVoiceTransport {
  /// Decoded `oai-events` (JSON objects only). Broadcast; EOF on session death.
  Stream<Map<String, Object?>> get events;

  /// One attempt: audio-only getUserMedia → peer → add local track (disabled)
  /// → `oai-events` DC → offer → one signaling POST → answer → DC open. Throws
  /// on any failure or cancellation; never retries.
  Future<void> connect(
    String clientSecret,
    RealtimeVoiceCancellation cancellation,
  );

  /// Enables/disables the one local (microphone) audio track. Enabled only
  /// after a successful `session.updated`.
  void setMicrophoneEnabled(bool enabled);

  /// Sends one client event as JSON over the data channel.
  Future<void> send(Map<String, Object?> event);

  /// Exactly-once teardown of channel, local track/stream, peer and http.
  Future<void> close();
}

/// Thrown for a pre-open connect failure; carries no SDP/secret/detail.
class RealtimeVoiceConnectException implements Exception {
  const RealtimeVoiceConnectException();
  @override
  String toString() => 'RealtimeVoiceConnectException';
}

/// Thrown when a connect is interrupted by cancellation.
class RealtimeVoiceConnectCancelled implements Exception {
  const RealtimeVoiceConnectCancelled();
  @override
  String toString() => 'RealtimeVoiceConnectCancelled';
}

/// Thrown when the audio-only local capture cannot be obtained (includes a
/// denied microphone permission). Carries no native detail.
class RealtimeVoiceMicException implements Exception {
  const RealtimeVoiceMicException();
  @override
  String toString() => 'RealtimeVoiceMicException';
}

typedef GetUserMedia = Future<MediaStream> Function(Map<String, dynamic>);
typedef CreatePeerConnection =
    Future<RTCPeerConnection> Function(Map<String, dynamic> configuration);
typedef PostSdpOffer =
    Future<String> Function(
      HttpClient client,
      String clientSecret,
      String offerSdp,
    );

/// The one narrow injectable seam for the iOS audio route: tests provide a
/// no-op so the real (platform-channel) Helper calls are never invoked
/// off-device. Not an audio abstraction; best-effort and never fatal.
typedef AudioSessionConfigurator = Future<void> Function();

class WebRtcRealtimeVoiceTransport implements RealtimeVoiceTransport {
  WebRtcRealtimeVoiceTransport({
    GetUserMedia? getUserMedia,
    CreatePeerConnection? createPeerConnectionFn,
    PostSdpOffer? postSdpOfferFn,
    AudioSessionConfigurator? audioSessionConfigurator,
  }) : _getUserMedia = getUserMedia ?? _defaultGetUserMedia,
       _createPeerConnection = createPeerConnectionFn ?? createPeerConnection,
       _postSdpOffer = postSdpOfferFn ?? postSdpOffer,
       _audioSessionConfigurator =
           audioSessionConfigurator ?? _defaultConfigureAudioSession;

  final GetUserMedia _getUserMedia;
  final CreatePeerConnection _createPeerConnection;
  final PostSdpOffer _postSdpOffer;
  final AudioSessionConfigurator _audioSessionConfigurator;

  final RealtimeVoiceRelease _release = RealtimeVoiceRelease();
  final StreamController<Map<String, Object?>> _events =
      StreamController<Map<String, Object?>>.broadcast();
  final Completer<bool> _opened = Completer<bool>();

  MediaStreamTrack? _localTrack;
  RTCDataChannel? _channel;
  Future<void>? _closing;

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  Future<void> connect(
    String clientSecret,
    RealtimeVoiceCancellation cancellation,
  ) async {
    // Active interruption: a cancel sweeps every owned resource, failing the
    // awaits below fast; a resource that materializes only after the sweep is
    // adopted and closed on the spot (its adopt() future settles after close).
    unawaited(cancellation.whenCancelled.then((_) => _release.releaseAll()));
    try {
      _throwIfCancelled(cancellation);

      // 1. Audio-only local capture — exactly one microphone owner.
      final MediaStream stream;
      try {
        stream = await _release.adopt(
          _getUserMedia(<String, dynamic>{'audio': true, 'video': false}),
          (MediaStream s) => s.dispose(),
        );
      } on RealtimeVoiceConnectCancelled {
        rethrow;
      } catch (_) {
        // A denied permission or capture failure — never the native detail.
        throw const RealtimeVoiceMicException();
      }
      _throwIfCancelled(cancellation);
      final audioTracks = stream.getAudioTracks();
      if (audioTracks.isEmpty) {
        throw const RealtimeVoiceMicException();
      }
      final local = audioTracks.first;
      // Held disabled until a successful session.updated re-enables it.
      local.enabled = false;
      _localTrack = local;
      await _release.register(() async {
        try {
          await local.stop();
        } catch (_) {}
      });
      _throwIfCancelled(cancellation);

      // 2. Peer connection.
      final peer = await _release.adopt(
        _createPeerConnection(_rtcConfiguration),
        (RTCPeerConnection p) => p.close(),
      );
      _throwIfCancelled(cancellation);
      // The remote assistant audio track auto-plays via flutter_webrtc's own
      // engine — no renderer and no track id is needed by the session.
      peer.onTrack = (RTCTrackEvent _) {};
      peer.onConnectionState = (RTCPeerConnectionState state) {
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

      // 3. Send the local track to OpenAI.
      await peer.addTrack(local, stream);
      _throwIfCancelled(cancellation);

      // 4. The one `oai-events` data channel.
      final channel = await _release.adopt(
        peer.createDataChannel('oai-events', RTCDataChannelInit()),
        (RTCDataChannel c) => c.close(),
      );
      _channel = channel;
      channel.onMessage = (RTCDataChannelMessage message) {
        if (!message.isBinary) {
          _ingest(message.text);
        }
      };
      channel.onDataChannelState = (RTCDataChannelState state) {
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
      _throwIfCancelled(cancellation);

      // 5. Offer.
      final offer = await peer.createOffer();
      _throwIfCancelled(cancellation);
      await peer.setLocalDescription(offer);
      _throwIfCancelled(cancellation);

      // 6. Official signaling: exactly one POST, secret as the only credential.
      final signalingClient = HttpClient();
      final closeSignaling = _onceClose(
        () async => signalingClient.close(force: true),
      );
      await _release.register(closeSignaling);
      // The signaling POST never begins once cancellation has been observed.
      _throwIfCancelled(cancellation);
      final answerSdp = await _postSdpOffer(
        signalingClient,
        clientSecret,
        offer.sdp ?? '',
      );
      // The ephemeral secret is not retained past this exchange.
      await closeSignaling();
      _throwIfCancelled(cancellation);
      await peer.setRemoteDescription(
        RTCSessionDescription(answerSdp, 'answer'),
      );
      _throwIfCancelled(cancellation);

      // 7. Wait for the channel to open (or a pre-open death).
      final opened = await _opened.future;
      _throwIfCancelled(cancellation);
      if (!opened) {
        throw const RealtimeVoiceConnectException();
      }

      // 8. Best-effort iOS audio route so the remote voice is audible. Never
      // fatal to the connect — it uses only public flutter_webrtc API.
      try {
        await _audioSessionConfigurator();
      } catch (_) {}
      // A cancellation observed during (or across) the audio-session step must
      // still unwind — even when the configurator itself threw and was
      // swallowed — before connect() returns successfully.
      _throwIfCancelled(cancellation);
    } catch (_) {
      await _release.releaseAll();
      rethrow;
    }
  }

  @override
  void setMicrophoneEnabled(bool enabled) {
    _localTrack?.enabled = enabled;
  }

  @override
  Future<void> send(Map<String, Object?> event) async {
    final channel = _channel;
    if (channel == null) {
      throw StateError('channel not ready');
    }
    await channel.send(RTCDataChannelMessage(jsonEncode(event)));
  }

  @override
  Future<void> close() => _closing ??= _closeOnce();

  Future<void> _closeOnce() async {
    _handleDead();
    await _release.releaseAll();
    if (!_events.isClosed) {
      await _events.close();
    }
  }

  /// Decodes one event frame; only JSON objects are surfaced, and raw text is
  /// never retained. A malformed frame is dropped.
  void _ingest(String text) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return;
    }
    if (decoded is Map<String, Object?> && !_events.isClosed) {
      _events.add(decoded);
    }
  }

  void _handleDead() {
    if (!_opened.isCompleted) {
      _opened.complete(false);
    }
    if (!_events.isClosed) {
      unawaited(_events.close());
    }
  }

  void _throwIfCancelled(RealtimeVoiceCancellation cancellation) {
    if (cancellation.isCancelled) {
      throw const RealtimeVoiceConnectCancelled();
    }
  }

  static const Map<String, dynamic> _rtcConfiguration = <String, dynamic>{
    'iceServers': <Map<String, dynamic>>[],
  };

  static Future<MediaStream> _defaultGetUserMedia(
    Map<String, dynamic> constraints,
  ) => navigator.mediaDevices.getUserMedia(constraints);

  /// The minimal public flutter_webrtc 1.5.2 sequence for a simultaneous
  /// capture + playout voice route. `setAppleAudioIOMode`
  /// (`localAndRemote`, prefer-speaker) and `ensureAudioSession` are Apple
  /// audio-session APIs and are invoked ONLY on iOS; the speaker-vs-Bluetooth
  /// route is applied on both supported mobile platforms. No new public audio
  /// abstraction and no native code.
  static Future<void> _defaultConfigureAudioSession() async {
    if (Platform.isIOS) {
      await Helper.setAppleAudioIOMode(
        AppleAudioIOMode.localAndRemote,
        preferSpeakerOutput: true,
      );
      await Helper.ensureAudioSession();
    }
    if (Platform.isIOS || Platform.isAndroid) {
      await Helper.setSpeakerphoneOnButPreferBluetooth();
    }
  }
}

Future<void> Function() _onceClose(Future<void> Function() close) {
  Future<void>? running;
  return () => running ??= close();
}

/// The official signaling exchange (visible for the transport test): the SDP
/// offer goes up with the ephemeral secret as the ONLY credential and
/// `Content-Type: application/sdp`; the SDP answer comes back. Redirects are
/// never followed and there is no retry. Only the status code is ever
/// surfaced — never the body.
@visibleForTesting
Future<String> postSdpOffer(
  HttpClient client,
  String clientSecret,
  String offerSdp,
) async {
  final request = await client.postUrl(Uri.parse(_callsEndpoint));
  request.followRedirects = false;
  request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $clientSecret');
  request.headers.contentType = ContentType('application', 'sdp');
  request.write(offerSdp);
  final response = await request.close();
  if (response.statusCode < 200 || response.statusCode >= 300) {
    // Non-2xx: never listen to / decode / retain the response body — no
    // status, body or secret is surfaced. The stream is left untouched.
    throw const RealtimeVoiceConnectException();
  }
  // 2xx: read the SDP answer.
  return utf8.decoder.bind(response).join();
}
