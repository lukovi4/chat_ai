import 'dart:async';

import 'package:example/src/voice_probe/probe_cancellation.dart';
import 'package:example/src/voice_probe/voice_probe_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

void main() {
  // Required test 1: the probe requests audio-only capture — audio:true,
  // video:false — and video is never requested.
  test('getUserMedia is audio-only (audio:true, video:false)', () async {
    Map<String, dynamic>? captured;
    final transport = WebRtcVoiceProbeTransport(
      getUserMedia: (constraints) async {
        captured = constraints;
        return _FakeStream();
      },
      createPeerConnectionFn: (_) async => _FakePeer(),
      postSdpOfferFn: (client, secret, offer) async => 'v=0\r\nanswer',
    );

    await transport.connect('secret', ProbeCancellation());

    expect(captured, isNotNull);
    expect(captured!['audio'], isTrue);
    expect(captured!['video'], isFalse);
    // The only media acquisition requested no video track.
    expect(captured!.containsKey('video'), isTrue);
    expect(transport.localAudioTrackId, 'fake-local-id');

    await transport.close();
  });
}

class _FakeStream implements MediaStream {
  final _FakeTrack _track = _FakeTrack();

  @override
  List<MediaStreamTrack> getAudioTracks() => <MediaStreamTrack>[_track];

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTrack implements MediaStreamTrack {
  @override
  String? get id => 'fake-local-id';

  @override
  String? get kind => 'audio';

  @override
  set enabled(bool? value) {}

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
