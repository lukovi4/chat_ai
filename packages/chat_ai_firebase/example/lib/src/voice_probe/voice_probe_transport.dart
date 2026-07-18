// The probe's WebRTC transport (Increment-0 iOS spike): ONE speech-to-speech
// session device → OpenAI Realtime. Audio-only local capture, a single
// `oai-events` data channel, official SDP signaling, remote audio played by
// flutter_webrtc's own engine. Adapted from the removed production WebRTC
// transport's signaling / cancellation / exactly-once cleanup ideas.
//
// It exposes only what the controller drives; raw SDP, the client secret and
// raw event text never leave this file. Decoded events are surfaced as maps;
// an undecodable frame is dropped silently.
//
// No retry, no reconnect. One connect attempt owns every resource through a
// ProbeRelease the instant it exists, so a cancel mid-signaling closes even a
// resource that materializes after the sweep.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'probe_cancellation.dart';
import 'probe_release.dart';

const String _callsEndpoint = 'https://api.openai.com/v1/realtime/calls';

/// The narrow surface the controller uses. A fake implementation drives the
/// controller's money-safe/lifecycle tests without any native WebRTC.
abstract class VoiceProbeTransport {
  /// Decoded `oai-events` (JSON objects only). Broadcast; EOF on session death.
  Stream<Map<String, Object?>> get events;

  /// The single local (user) audio track id — valid after [connect].
  String get localAudioTrackId;

  /// Completes with the remote (assistant) audio track id once it arrives.
  Future<String> get remoteAudioTrackId;

  /// One attempt: audio-only getUserMedia → peer → add local track (disabled)
  /// → `oai-events` DC → offer → one signaling POST → answer → DC open. Throws
  /// on any failure or cancellation; never retries.
  Future<void> connect(String clientSecret, ProbeCancellation cancellation);

  /// Configures the iOS audio session for simultaneous capture + playout via
  /// flutter_webrtc's public API, BEFORE the local track is enabled. Throws
  /// [VoiceProbeAudioSessionException] on failure (coarse; no native detail).
  Future<void> configureAudioSession();

  /// Enables/disables the one local audio track.
  void setLocalTrackEnabled(bool enabled);

  /// Sends one client event as JSON over the data channel.
  Future<void> send(Map<String, Object?> event);

  /// Exactly-once teardown of channel, local track/stream, peer and http.
  Future<void> close();
}

/// Thrown for a pre-open connect failure; carries no SDP/secret/detail.
class VoiceProbeConnectException implements Exception {
  const VoiceProbeConnectException();
  @override
  String toString() => 'VoiceProbeConnectException';
}

/// Thrown when a connect is interrupted by cancellation.
class VoiceProbeConnectCancelled implements Exception {
  const VoiceProbeConnectCancelled();
  @override
  String toString() => 'VoiceProbeConnectCancelled';
}

/// Thrown when the audio-only local capture cannot be obtained (includes a
/// denied microphone permission). Carries no native detail.
class VoiceProbeMicException implements Exception {
  const VoiceProbeMicException();
  @override
  String toString() => 'VoiceProbeMicException';
}

/// Thrown when the iOS audio session could not be configured. Coarse; carries
/// no native detail.
class VoiceProbeAudioSessionException implements Exception {
  const VoiceProbeAudioSessionException();
  @override
  String toString() => 'VoiceProbeAudioSessionException';
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

/// The one narrow injectable seam allowed for the audio session: tests provide
/// a no-op/recording function so the real (platform-channel) Helper calls are
/// never invoked off-device. Not an audio abstraction.
typedef AudioSessionConfigurator = Future<void> Function();

class WebRtcVoiceProbeTransport implements VoiceProbeTransport {
  WebRtcVoiceProbeTransport({
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

  final ProbeRelease _release = ProbeRelease();
  final StreamController<Map<String, Object?>> _events =
      StreamController<Map<String, Object?>>.broadcast();
  final Completer<bool> _opened = Completer<bool>();
  final Completer<String> _remoteAudioTrackId = Completer<String>();

  MediaStreamTrack? _localTrack;
  RTCDataChannel? _channel;
  Future<void>? _closing;

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  String get localAudioTrackId {
    final id = _localTrack?.id;
    if (id == null) {
      throw StateError('local track not ready');
    }
    return id;
  }

  @override
  Future<String> get remoteAudioTrackId => _remoteAudioTrackId.future;

  @override
  Future<void> connect(
    String clientSecret,
    ProbeCancellation cancellation,
  ) async {
    // Active interruption: a cancel sweeps every owned resource, failing the
    // awaits below fast; a resource that materializes only after the sweep is
    // adopted and closed on the spot.
    unawaited(cancellation.whenCancelled.then((_) => _release.releaseAll()));
    try {
      _throwIfCancelled(cancellation);

      // 1. Audio-only local capture — exactly one microphone owner (flutter_webrtc).
      final MediaStream stream;
      try {
        stream = await _release.adopt(
          _getUserMedia(<String, dynamic>{'audio': true, 'video': false}),
          (MediaStream s) => s.dispose(),
        );
      } on VoiceProbeConnectCancelled {
        rethrow;
      } catch (_) {
        // A denied permission or capture failure — never the native detail.
        throw const VoiceProbeMicException();
      }
      _throwIfCancelled(cancellation);
      final audioTracks = stream.getAudioTracks();
      if (audioTracks.isEmpty) {
        throw const VoiceProbeMicException();
      }
      final local = audioTracks.first;
      // Held disabled until the whole session (writers + remote track) is ready.
      local.enabled = false;
      _localTrack = local;
      await _release.register(() async {
        try {
          await local.stop();
        } catch (_) {}
      });

      // 2. Peer connection.
      final peer = await _release.adopt(
        _createPeerConnection(_rtcConfiguration),
        (RTCPeerConnection p) => p.close(),
      );
      _throwIfCancelled(cancellation);
      peer.onTrack = (RTCTrackEvent event) {
        if (event.track.kind == 'audio' && !_remoteAudioTrackId.isCompleted) {
          final id = event.track.id;
          if (id != null) {
            _remoteAudioTrackId.complete(id);
          }
        }
      };
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

      // 5. Offer.
      final offer = await peer.createOffer();
      await peer.setLocalDescription(offer);
      _throwIfCancelled(cancellation);

      // 6. Official signaling: exactly one POST, secret as the only credential.
      final signalingClient = HttpClient();
      final closeSignaling = _onceClose(
        () async => signalingClient.close(force: true),
      );
      await _release.register(closeSignaling);
      final answerSdp = await _postSdpOffer(
        signalingClient,
        clientSecret,
        offer.sdp ?? '',
      );
      await closeSignaling();
      _throwIfCancelled(cancellation);
      await peer.setRemoteDescription(
        RTCSessionDescription(answerSdp, 'answer'),
      );

      // 7. Wait for the channel to open (or a pre-open death).
      final opened = await _opened.future;
      _throwIfCancelled(cancellation);
      if (!opened) {
        throw const VoiceProbeConnectException();
      }
    } catch (_) {
      await _release.releaseAll();
      rethrow;
    }
  }

  @override
  Future<void> configureAudioSession() async {
    try {
      await _audioSessionConfigurator();
    } catch (_) {
      // Coarse only — never a native detail.
      throw const VoiceProbeAudioSessionException();
    }
  }

  @override
  void setLocalTrackEnabled(bool enabled) {
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

  void _throwIfCancelled(ProbeCancellation cancellation) {
    if (cancellation.isCancelled) {
      throw const VoiceProbeConnectCancelled();
    }
  }

  static const Map<String, dynamic> _rtcConfiguration = <String, dynamic>{
    'iceServers': <Map<String, dynamic>>[],
  };

  static Future<MediaStream> _defaultGetUserMedia(
    Map<String, dynamic> constraints,
  ) => navigator.mediaDevices.getUserMedia(constraints);

  /// The minimal public flutter_webrtc 1.5.2 sequence for a simultaneous
  /// capture + playout voice route, in the order its native implementation
  /// expects: set the play-and-record / voice-chat configuration
  /// (`localAndRemote`, prefer-speaker), activate the RTC audio session (with
  /// recording, since a local audio track exists), then route to the speaker
  /// unless a Bluetooth device is actually connected.
  static Future<void> _defaultConfigureAudioSession() async {
    await Helper.setAppleAudioIOMode(
      AppleAudioIOMode.localAndRemote,
      preferSpeakerOutput: true,
    );
    await Helper.ensureAudioSession();
    await Helper.setSpeakerphoneOnButPreferBluetooth();
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
  final body = await utf8.decoder.bind(response).join();
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw const VoiceProbeConnectException();
  }
  return body;
}
