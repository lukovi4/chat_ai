// Production transport orchestration (corrective regressions 1 and 2): a
// resource whose creation Future completes only AFTER cancellation swept is
// still owned and closed exactly once — a late peer connection, a late data
// channel — while downstream steps (data channel creation, SDP signaling)
// never start. Uses only the package-internal factory seam; no network, no
// platform channels.

import 'dart:async';
import 'dart:io';

import 'package:chat_ai_openai_realtime/src/realtime_transport.dart';
import 'package:chat_ai_openai_realtime/src/webrtc_realtime_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class _OrchestrationChannel extends RTCDataChannel {
  /// When set, close() suspends on this gate (a delayed native close).
  Completer<void>? closeGate;
  int closeCalls = 0;

  @override
  RTCDataChannelState? get state => null;

  @override
  int? get id => 0;

  @override
  String? get label => 'oai-events';

  @override
  int? get bufferedAmount => 0;

  @override
  Future<void> send(RTCDataChannelMessage message) async {}

  @override
  Future<void> close() {
    closeCalls++;
    final gate = closeGate;
    if (gate != null) {
      return gate.future;
    }
    return Future<void>.value();
  }
}

class _OrchestrationPeer extends RTCPeerConnection {
  _OrchestrationPeer({this.dataChannelGate});

  /// When set, createDataChannel() suspends on this gate instead of
  /// returning [channel] immediately.
  final Completer<RTCDataChannel>? dataChannelGate;

  /// When set, close() suspends on this gate (a delayed native close).
  Completer<void>? closeGate;

  /// When set, close() throws it (after counting the call).
  Object? closeError;

  final _OrchestrationChannel channel = _OrchestrationChannel();
  int createDataChannelCalls = 0;
  int closeCalls = 0;

  @override
  Future<RTCDataChannel> createDataChannel(
    String label,
    RTCDataChannelInit dataChannelDict,
  ) {
    createDataChannelCalls++;
    final gate = dataChannelGate;
    if (gate != null) {
      return gate.future;
    }
    return Future<RTCDataChannel>.value(channel);
  }

  @override
  Future<RTCSessionDescription> createOffer([
    Map<String, dynamic> constraints = const <String, dynamic>{},
  ]) async => RTCSessionDescription('offer-sdp', 'offer');

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {}

  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {}

  @override
  Future<void> close() {
    closeCalls++;
    final closeError = this.closeError;
    if (closeError != null) {
      throw closeError;
    }
    final gate = closeGate;
    if (gate != null) {
      return gate.future;
    }
    return Future<void>.value();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Tracks whether [future] has settled (value or error) without letting an
/// error escape.
bool Function() settledFlag(Future<Object?> future) {
  var settled = false;
  unawaited(
    future
        .then<void>((_) {}, onError: (Object _) {})
        .whenComplete(() => settled = true),
  );
  return () => settled;
}

void main() {
  test('cancel while createPeerConnection is pending: the late peer is '
      'still owned and closed exactly once; nothing downstream starts '
      '(regression 1)', () async {
    final peer = _OrchestrationPeer();
    final peerGate = Completer<RTCPeerConnection>();
    var sdpPosts = 0;
    final transport = WebRtcRealtimeTransport.forTesting(
      createPeerConnection: (_) => peerGate.future,
      postSdpOffer: (HttpClient client, String secret, String sdp) async {
        sdpPosts++;
        return 'answer-sdp';
      },
    );
    final cancellation = RealtimeCancellation();

    final connectFuture = transport.connect('fake-secret', cancellation);
    await pumpEventQueue(); // suspended inside createPeerConnection

    cancellation.cancel(); // the sweep sees no peer yet
    await pumpEventQueue();
    expect(peer.closeCalls, 0); // nothing existed to close — yet

    peerGate.complete(peer); // the peer materializes AFTER the sweep
    await expectLater(connectFuture, throwsA(isA<RealtimeConnectCancelled>()));
    await pumpEventQueue();

    expect(peer.closeCalls, 1); // adopted and closed exactly once
    expect(peer.createDataChannelCalls, 0);
    expect(sdpPosts, 0);
  });

  test('cancel while createDataChannel is pending: the late channel is not '
      'orphaned; channel and peer close exactly once; signaling never '
      'starts (regression 2)', () async {
    final channelGate = Completer<RTCDataChannel>();
    final peer = _OrchestrationPeer(dataChannelGate: channelGate);
    var sdpPosts = 0;
    final transport = WebRtcRealtimeTransport.forTesting(
      createPeerConnection: (_) async => peer,
      postSdpOffer: (HttpClient client, String secret, String sdp) async {
        sdpPosts++;
        return 'answer-sdp';
      },
    );
    final cancellation = RealtimeCancellation();

    final connectFuture = transport.connect('fake-secret', cancellation);
    await pumpEventQueue(); // suspended inside createDataChannel
    expect(peer.createDataChannelCalls, 1);

    cancellation.cancel();
    await pumpEventQueue();
    expect(peer.closeCalls, 1); // the sweep released the adopted peer

    channelGate.complete(peer.channel); // the channel materializes late
    await expectLater(connectFuture, throwsA(isA<RealtimeConnectCancelled>()));
    await pumpEventQueue();

    expect(peer.channel.closeCalls, 1); // owned and closed exactly once
    expect(peer.closeCalls, 1); // and never a double close of the peer
    expect(sdpPosts, 0);
  });

  test('a late peer with a DELAYED close holds the connect future: it '
      'resolves only after the real native close finishes (increment-3 '
      'regression 2)', () async {
    final peer = _OrchestrationPeer()..closeGate = Completer<void>();
    final peerGate = Completer<RTCPeerConnection>();
    var sdpPosts = 0;
    final transport = WebRtcRealtimeTransport.forTesting(
      createPeerConnection: (_) => peerGate.future,
      postSdpOffer: (HttpClient client, String secret, String sdp) async {
        sdpPosts++;
        return 'answer-sdp';
      },
    );
    final cancellation = RealtimeCancellation();

    final connectFuture = transport.connect('fake-secret', cancellation);
    final connectSettled = settledFlag(connectFuture);
    await pumpEventQueue(); // suspended inside createPeerConnection

    cancellation.cancel(); // the sweep sees no peer yet
    await pumpEventQueue();

    peerGate.complete(peer); // the peer materializes AFTER the sweep
    await pumpEventQueue();
    expect(peer.closeCalls, 1); // its close started immediately…
    // …and while that close is still running, connect MUST NOT resolve.
    expect(connectSettled(), isFalse);
    expect(peer.createDataChannelCalls, 0);
    expect(sdpPosts, 0);

    peer.closeGate!.complete(); // the native close actually finishes
    await expectLater(connectFuture, throwsA(isA<RealtimeConnectCancelled>()));
    expect(peer.closeCalls, 1); // exactly once
  });

  test('a late data channel with a DELAYED close holds the connect future; '
      'channel and peer close exactly once, signaling never starts '
      '(increment-3 regression 3)', () async {
    final channelGate = Completer<RTCDataChannel>();
    final peer = _OrchestrationPeer(dataChannelGate: channelGate);
    peer.channel.closeGate = Completer<void>();
    var sdpPosts = 0;
    final transport = WebRtcRealtimeTransport.forTesting(
      createPeerConnection: (_) async => peer,
      postSdpOffer: (HttpClient client, String secret, String sdp) async {
        sdpPosts++;
        return 'answer-sdp';
      },
    );
    final cancellation = RealtimeCancellation();

    final connectFuture = transport.connect('fake-secret', cancellation);
    final connectSettled = settledFlag(connectFuture);
    await pumpEventQueue(); // suspended inside createDataChannel

    cancellation.cancel();
    await pumpEventQueue();
    expect(peer.closeCalls, 1); // the sweep released the adopted peer

    channelGate.complete(peer.channel); // the channel materializes late
    await pumpEventQueue();
    expect(peer.channel.closeCalls, 1); // its close started immediately…
    // …and connect does not resolve ahead of that delayed close.
    expect(connectSettled(), isFalse);
    expect(sdpPosts, 0);

    peer.channel.closeGate!.complete();
    await expectLater(connectFuture, throwsA(isA<RealtimeConnectCancelled>()));
    expect(peer.channel.closeCalls, 1); // exactly once
    expect(peer.closeCalls, 1); // and never a double close of the peer
    expect(sdpPosts, 0);
  });

  test('a late closer that THROWS stays swallowed: no unhandled zone error, '
      'connect keeps its controlled cancellation outcome (increment-3 '
      'regression 4)', () async {
    final peer = _OrchestrationPeer()
      ..closeError = StateError('native close defect');
    final peerGate = Completer<RTCPeerConnection>();
    final transport = WebRtcRealtimeTransport.forTesting(
      createPeerConnection: (_) => peerGate.future,
      postSdpOffer: (HttpClient client, String secret, String sdp) async =>
          'answer-sdp',
    );
    final cancellation = RealtimeCancellation();

    final connectFuture = transport.connect('fake-secret', cancellation);
    await pumpEventQueue();
    cancellation.cancel();
    await pumpEventQueue();

    peerGate.complete(peer); // late peer whose close throws
    // The defect is swallowed; the outcome stays the controlled
    // cancellation failure — an unhandled zone error would fail this test.
    await expectLater(connectFuture, throwsA(isA<RealtimeConnectCancelled>()));
    await pumpEventQueue();
    expect(peer.closeCalls, 1);
    expect(peer.createDataChannelCalls, 0);
  });

  test('a healthy orchestration connects, and closing the returned '
      'connection closes each native resource exactly once', () async {
    final peer = _OrchestrationPeer();
    var sdpPosts = 0;
    final transport = WebRtcRealtimeTransport.forTesting(
      createPeerConnection: (_) async => peer,
      postSdpOffer: (HttpClient client, String secret, String sdp) async {
        sdpPosts++;
        expect(sdp, 'offer-sdp');
        return 'answer-sdp';
      },
    );
    final cancellation = RealtimeCancellation();

    final connectFuture = transport.connect('fake-secret', cancellation);
    await pumpEventQueue(); // awaiting channel readiness
    peer.channel.onDataChannelState!(RTCDataChannelState.RTCDataChannelOpen);
    final connection = await connectFuture;
    expect(sdpPosts, 1);

    await connection.close();
    await connection.close(); // wrapper close is memoized
    // The wrapper and the coordinator share exactly-once closers: one
    // native close per resource, no matter which path runs.
    expect(peer.channel.closeCalls, 1);
    expect(peer.closeCalls, 1);
  });

  test('cancellation after a successful connect still tears the session '
      'down without double-closing', () async {
    final peer = _OrchestrationPeer();
    final transport = WebRtcRealtimeTransport.forTesting(
      createPeerConnection: (_) async => peer,
      postSdpOffer: (HttpClient client, String secret, String sdp) async =>
          'answer-sdp',
    );
    final cancellation = RealtimeCancellation();

    final connectFuture = transport.connect('fake-secret', cancellation);
    await pumpEventQueue();
    peer.channel.onDataChannelState!(RTCDataChannelState.RTCDataChannelOpen);
    final connection = await connectFuture;

    cancellation.cancel(); // the coordinator sweeps the live session
    await pumpEventQueue();
    expect(peer.channel.closeCalls, 1);
    expect(peer.closeCalls, 1);

    await connection.close(); // late owner-side close: still exactly once
    expect(peer.channel.closeCalls, 1);
    expect(peer.closeCalls, 1);
  });
}
