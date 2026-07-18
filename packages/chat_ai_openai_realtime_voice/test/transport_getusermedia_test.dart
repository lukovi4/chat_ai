// Required test 7: the session requests audio-only capture — audio:true,
// video:false — and video is never a live track.
// Required test 8 (transport half): the local microphone track is created
// DISABLED during connect (it is enabled only later, after session.updated).
import 'dart:async';

import 'package:chat_ai_openai_realtime_voice/src/voice_cancellation.dart';
import 'package:chat_ai_openai_realtime_voice/src/voice_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

void main() {
  test(
    'getUserMedia is audio-only and the local track is created disabled',
    () async {
      Map<String, dynamic>? captured;
      final track = _FakeTrack();
      final transport = WebRtcRealtimeVoiceTransport(
        getUserMedia: (constraints) async {
          captured = constraints;
          return _FakeStream(track);
        },
        createPeerConnectionFn: (_) async => _FakePeer(),
        postSdpOfferFn: (client, secret, offer) async => 'v=0\r\nanswer',
        // No real iOS audio route off-device.
        audioSessionConfigurator: () async {},
      );

      await transport.connect('secret', RealtimeVoiceCancellation());

      expect(captured, isNotNull);
      expect(captured!['audio'], isTrue);
      expect(captured!['video'], isFalse);
      expect(captured!.containsKey('video'), isTrue);

      // Created disabled — the only enabled write during connect is `false`, and
      // it is never enabled here.
      expect(track.enabledWrites, <bool>[false]);

      // Enabling later flips exactly this track.
      transport.setMicrophoneEnabled(true);
      expect(track.enabledWrites, <bool>[false, true]);

      await transport.close();
    },
  );
}

class _FakeStream implements MediaStream {
  _FakeStream(this._track);

  final _FakeTrack _track;

  @override
  List<MediaStreamTrack> getAudioTracks() => <MediaStreamTrack>[_track];

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTrack implements MediaStreamTrack {
  final List<bool> enabledWrites = <bool>[];

  @override
  String? get id => 'fake-local-id';

  @override
  String? get kind => 'audio';

  @override
  set enabled(bool? value) {
    if (value != null) {
      enabledWrites.add(value);
    }
  }

  @override
  Future<void> stop() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePeer implements RTCPeerConnection {
  @override
  set onTrack(void Function(RTCTrackEvent)? value) {}

  @override
  set onConnectionState(void Function(RTCPeerConnectionState)? value) {}

  @override
  Future<RTCDataChannel> createDataChannel(
    String label,
    RTCDataChannelInit dataChannelDict,
  ) async => _FakeChannel();

  @override
  Future<RTCSessionDescription> createOffer([
    Map<String, dynamic>? constraints,
  ]) async => RTCSessionDescription('v=0\r\noffer', 'offer');

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {}

  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {}

  @override
  Future<RTCRtpSender> addTrack(
    MediaStreamTrack track, [
    MediaStream? stream,
  ]) async => _FakeSender();

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeChannel implements RTCDataChannel {
  @override
  set onMessage(void Function(RTCDataChannelMessage)? value) {}

  @override
  set onDataChannelState(void Function(RTCDataChannelState)? value) {
    // Drive the channel open so connect resolves.
    scheduleMicrotask(
      () => value?.call(RTCDataChannelState.RTCDataChannelOpen),
    );
  }

  @override
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSender implements RTCRtpSender {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
