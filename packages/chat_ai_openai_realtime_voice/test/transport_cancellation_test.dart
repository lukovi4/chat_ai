// Defect (P1): production WebRTC-transport cancellation at EVERY setup boundary,
// driven through the transport's existing narrow injection seams (getUserMedia
// / createPeerConnection / postSdpOffer / audio configurator) plus the fake
// peer's per-method gates. A single RealtimeVoiceRelease unit test is not
// enough — these exercise the real connect() orchestration: for each boundary
// no later stage runs, and the late stream/peer/channel each close exactly
// once. No networking framework, production dependency or native code.
import 'dart:async';

import 'package:chat_ai_openai_realtime_voice/src/voice_cancellation.dart';
import 'package:chat_ai_openai_realtime_voice/src/voice_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'fakes.dart' show pumpEventLoop;

/// Builds a real [WebRtcRealtimeVoiceTransport] whose every setup stage can be
/// gated, and whose shared fake stream/peer/channel expose close/dispose
/// counters for exact-once assertions.
class _Harness {
  _Harness({
    this.gumGate,
    this.peerGate,
    this.addTrackGate,
    this.dcGate,
    this.createOfferGate,
    this.setLocalGate,
    this.signalingGate,
    this.setRemoteGate,
    this.audioGate,
    this.channelAutoOpen = true,
    this.audioThrows = false,
    this.streamOnDispose,
  });

  final Completer<void>? gumGate;
  final Completer<void>? peerGate;
  final Completer<void>? addTrackGate;
  final Completer<void>? dcGate;
  final Completer<void>? createOfferGate;
  final Completer<void>? setLocalGate;
  final Completer<void>? signalingGate;
  final Completer<void>? setRemoteGate;
  final Completer<void>? audioGate;
  final bool channelAutoOpen;
  final bool audioThrows;
  final Future<void> Function()? streamOnDispose;

  int gumCalls = 0;
  int peerCreateCalls = 0;
  int signalingCalls = 0;
  int audioCalls = 0;

  late final _FakeStream stream = _FakeStream(onDispose: streamOnDispose);
  late final _FakePeer peer = _FakePeer(
    addTrackGate: addTrackGate,
    dcGate: dcGate,
    createOfferGate: createOfferGate,
    setLocalGate: setLocalGate,
    setRemoteGate: setRemoteGate,
    channelAutoOpen: channelAutoOpen,
  );

  WebRtcRealtimeVoiceTransport build() => WebRtcRealtimeVoiceTransport(
    getUserMedia: (_) async {
      gumCalls++;
      if (gumGate != null) await gumGate!.future;
      return stream;
    },
    createPeerConnectionFn: (_) async {
      peerCreateCalls++;
      if (peerGate != null) await peerGate!.future;
      return peer;
    },
    postSdpOfferFn: (_, _, _) async {
      signalingCalls++;
      if (signalingGate != null) await signalingGate!.future;
      return 'v=0\r\nanswer';
    },
    audioSessionConfigurator: () async {
      audioCalls++;
      if (audioGate != null) await audioGate!.future;
      if (audioThrows) throw StateError('audio boom');
    },
  );
}

/// Starts connect(), lets it reach the gated boundary, cancels, opens the gate
/// (if any) and asserts connect() unwinds with [RealtimeVoiceConnectCancelled].
Future<void> _driveCancel(_Harness h, [Completer<void>? gate]) async {
  final cancellation = RealtimeVoiceCancellation();
  final transport = h.build();
  final f = transport.connect('secret', cancellation);
  await pumpEventLoop();
  cancellation.cancel();
  gate?.complete();
  await expectLater(f, throwsA(isA<RealtimeVoiceConnectCancelled>()));
}

void main() {
  // ---- Boundary matrix: no later stage runs after cancel -----------------

  test(
    'boundary getUserMedia: no peer/signaling/audio; stream closed once',
    () async {
      final gate = Completer<void>();
      final h = _Harness(gumGate: gate);
      await _driveCancel(h, gate);
      expect(h.peerCreateCalls, 0);
      expect(h.signalingCalls, 0);
      expect(h.audioCalls, 0);
      expect(h.stream.disposeCalls, 1);
    },
  );

  test(
    'boundary peer creation: no addTrack/DC/offer/signaling/audio',
    () async {
      final gate = Completer<void>();
      final h = _Harness(peerGate: gate);
      await _driveCancel(h, gate);
      expect(h.peer.addTrackCalls, 0);
      expect(h.peer.createDataChannelCalls, 0);
      expect(h.peer.createOfferCalls, 0);
      expect(h.peer.setLocalCalls, 0);
      expect(h.peer.setRemoteCalls, 0);
      expect(h.signalingCalls, 0);
      expect(h.audioCalls, 0);
      // Late stream + peer each closed exactly once; channel never created.
      expect(h.stream.disposeCalls, 1);
      expect(h.peer.closeCalls, 1);
      expect(h.peer.createDataChannelCalls, 0);
    },
  );

  test('boundary addTrack: no DataChannel/offer/signaling/audio', () async {
    final gate = Completer<void>();
    final h = _Harness(addTrackGate: gate);
    await _driveCancel(h, gate);
    expect(h.peer.addTrackCalls, 1); // reached, then gated
    expect(h.peer.createDataChannelCalls, 0);
    expect(h.peer.createOfferCalls, 0);
    expect(h.peer.setLocalCalls, 0);
    expect(h.peer.setRemoteCalls, 0);
    expect(h.signalingCalls, 0);
    expect(h.audioCalls, 0);
    expect(h.stream.disposeCalls, 1);
    expect(h.peer.closeCalls, 1);
  });

  test(
    'boundary DataChannel creation: no offer/signaling/audio; channel closed once',
    () async {
      final gate = Completer<void>();
      final h = _Harness(dcGate: gate);
      await _driveCancel(h, gate);
      expect(h.peer.createDataChannelCalls, 1);
      expect(h.peer.createOfferCalls, 0);
      expect(h.peer.setLocalCalls, 0);
      expect(h.peer.setRemoteCalls, 0);
      expect(h.signalingCalls, 0);
      expect(h.audioCalls, 0);
      expect(h.stream.disposeCalls, 1);
      expect(h.peer.closeCalls, 1);
      expect(h.peer.channel.closeCalls, 1);
    },
  );

  test('boundary createOffer: no setLocal/signaling/setRemote/audio', () async {
    final gate = Completer<void>();
    final h = _Harness(createOfferGate: gate);
    await _driveCancel(h, gate);
    expect(h.peer.createOfferCalls, 1);
    expect(h.peer.setLocalCalls, 0);
    expect(h.signalingCalls, 0);
    expect(h.peer.setRemoteCalls, 0);
    expect(h.audioCalls, 0);
    _expectAllClosedOnce(h);
  });

  test('boundary setLocalDescription: no signaling/setRemote/audio', () async {
    final gate = Completer<void>();
    final h = _Harness(setLocalGate: gate);
    await _driveCancel(h, gate);
    expect(h.peer.setLocalCalls, 1);
    expect(h.signalingCalls, 0);
    expect(h.peer.setRemoteCalls, 0);
    expect(h.audioCalls, 0);
    _expectAllClosedOnce(h);
  });

  test(
    'boundary signaling: no setRemote/audio; POST reached then gated',
    () async {
      final gate = Completer<void>();
      final h = _Harness(signalingGate: gate);
      await _driveCancel(h, gate);
      expect(h.signalingCalls, 1);
      expect(h.peer.setRemoteCalls, 0);
      expect(h.audioCalls, 0);
      _expectAllClosedOnce(h);
    },
  );

  test('boundary setRemoteDescription: no audio', () async {
    final gate = Completer<void>();
    final h = _Harness(setRemoteGate: gate);
    await _driveCancel(h, gate);
    expect(h.peer.setRemoteCalls, 1);
    expect(h.audioCalls, 0);
    _expectAllClosedOnce(h);
  });

  test(
    'boundary DataChannel open: no audio; all resources closed once',
    () async {
      // channelAutoOpen: false → connect parks on the open wait until cancel.
      final h = _Harness(channelAutoOpen: false);
      await _driveCancel(
        h,
      ); // no gate — cancel drives the closed-state teardown
      expect(h.audioCalls, 0);
      _expectAllClosedOnce(h);
    },
  );

  test(
    'boundary audio configurator: reached then gated; closed once',
    () async {
      final gate = Completer<void>();
      final h = _Harness(audioGate: gate);
      await _driveCancel(h, gate);
      expect(h.audioCalls, 1);
      _expectAllClosedOnce(h);
    },
  );

  test(
    'boundary audio configurator that throws still unwinds on cancel',
    () async {
      final gate = Completer<void>();
      final h = _Harness(audioGate: gate, audioThrows: true);
      await _driveCancel(h, gate);
      expect(h.audioCalls, 1);
      _expectAllClosedOnce(h);
    },
  );

  // ---- Late-close discipline ---------------------------------------------

  test(
    'a gated late close holds connect() unfinished until it resolves',
    () async {
      final gumGate = Completer<void>();
      final disposeGate = Completer<void>();
      var disposed = false;
      final h = _Harness(
        gumGate: gumGate,
        streamOnDispose: () async {
          await disposeGate.future;
          disposed = true;
        },
      );
      final cancellation = RealtimeVoiceCancellation();
      final transport = h.build();

      var completed = false;
      final f = transport
          .connect('secret', cancellation)
          .then<void>((_) {}, onError: (_) {})
          .whenComplete(() => completed = true);

      await pumpEventLoop();
      cancellation.cancel();
      gumGate.complete(); // late stream materializes; its close is gated.
      await pumpEventLoop();
      expect(completed, isFalse);
      expect(disposed, isFalse);

      disposeGate.complete();
      await f;
      expect(completed, isTrue);
      expect(disposed, isTrue);
      // The late stream closed exactly once.
      expect(h.stream.disposeCalls, 1);
    },
  );

  test('a throwing late close does not escape to the Zone', () async {
    final gumGate = Completer<void>();
    final h = _Harness(
      gumGate: gumGate,
      streamOnDispose: () async => throw StateError('late close boom'),
    );
    final cancellation = RealtimeVoiceCancellation();
    final transport = h.build();
    final f = transport.connect('secret', cancellation);
    await pumpEventLoop();
    cancellation.cancel();
    gumGate.complete();
    // The throwing late close is swallowed by the release guard; nothing
    // escapes (this test fails on any unhandled async error).
    await expectLater(f, throwsA(isA<RealtimeVoiceConnectCancelled>()));
    expect(h.stream.disposeCalls, 1);
  });
}

void _expectAllClosedOnce(_Harness h) {
  expect(h.stream.disposeCalls, 1, reason: 'stream closed once');
  expect(h.peer.closeCalls, 1, reason: 'peer closed once');
  expect(h.peer.channel.closeCalls, 1, reason: 'channel closed once');
}

class _FakeStream implements MediaStream {
  _FakeStream({this.onDispose});

  final Future<void> Function()? onDispose;
  final _FakeTrack track = _FakeTrack();
  int disposeCalls = 0;

  @override
  List<MediaStreamTrack> getAudioTracks() => <MediaStreamTrack>[track];

  @override
  Future<void> dispose() async {
    disposeCalls++;
    if (onDispose != null) {
      await onDispose!();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTrack implements MediaStreamTrack {
  int stopCalls = 0;

  @override
  String? get id => 'local';

  @override
  String? get kind => 'audio';

  @override
  set enabled(bool? value) {}

  @override
  Future<void> stop() async {
    stopCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePeer implements RTCPeerConnection {
  _FakePeer({
    this.addTrackGate,
    this.dcGate,
    this.createOfferGate,
    this.setLocalGate,
    this.setRemoteGate,
    required this.channelAutoOpen,
  });

  final Completer<void>? addTrackGate;
  final Completer<void>? dcGate;
  final Completer<void>? createOfferGate;
  final Completer<void>? setLocalGate;
  final Completer<void>? setRemoteGate;
  final bool channelAutoOpen;

  late final _FakeChannel channel = _FakeChannel(autoOpen: channelAutoOpen);

  int addTrackCalls = 0;
  int createDataChannelCalls = 0;
  int createOfferCalls = 0;
  int setLocalCalls = 0;
  int setRemoteCalls = 0;
  int closeCalls = 0;

  @override
  set onTrack(void Function(RTCTrackEvent)? value) {}

  @override
  set onConnectionState(void Function(RTCPeerConnectionState)? value) {}

  @override
  Future<RTCRtpSender> addTrack(
    MediaStreamTrack track, [
    MediaStream? stream,
  ]) async {
    addTrackCalls++;
    if (addTrackGate != null) await addTrackGate!.future;
    return _FakeSender();
  }

  @override
  Future<RTCDataChannel> createDataChannel(
    String label,
    RTCDataChannelInit dataChannelDict,
  ) async {
    createDataChannelCalls++;
    if (dcGate != null) await dcGate!.future;
    return channel;
  }

  @override
  Future<RTCSessionDescription> createOffer([
    Map<String, dynamic>? constraints,
  ]) async {
    createOfferCalls++;
    if (createOfferGate != null) await createOfferGate!.future;
    return RTCSessionDescription('v=0\r\noffer', 'offer');
  }

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {
    setLocalCalls++;
    if (setLocalGate != null) await setLocalGate!.future;
  }

  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {
    setRemoteCalls++;
    if (setRemoteGate != null) await setRemoteGate!.future;
  }

  @override
  Future<void> close() async {
    closeCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeChannel implements RTCDataChannel {
  _FakeChannel({required this.autoOpen});

  final bool autoOpen;
  int closeCalls = 0;
  void Function(RTCDataChannelState)? _stateCb;

  @override
  set onMessage(void Function(RTCDataChannelMessage)? value) {}

  @override
  set onDataChannelState(void Function(RTCDataChannelState)? value) {
    _stateCb = value;
    if (autoOpen && value != null) {
      scheduleMicrotask(() => value(RTCDataChannelState.RTCDataChannelOpen));
    }
  }

  @override
  Future<void> close() async {
    closeCalls++;
    // Real WebRTC fires a closed state on close → let the transport observe the
    // pre-open death and settle its open wait.
    _stateCb?.call(RTCDataChannelState.RTCDataChannelClosed);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSender implements RTCRtpSender {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
