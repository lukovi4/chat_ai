// Readiness lifecycle of the production connection wrapper (defect 3 /
// regression 5): an early data-channel or peer failure — before anything
// awaits readiness — resolves `opened` to a controlled `false`. It is a
// value, never an error, so nothing can park an unhandled error in a
// not-yet-awaited future; resources close exactly once.

import 'package:chat_ai_openai_realtime/src/webrtc_realtime_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class _FakePeerConnection extends RTCPeerConnection {
  int closeCalls = 0;

  @override
  Future<void> close() async {
    closeCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeDataChannel extends RTCDataChannel {
  int closeCalls = 0;
  final List<RTCDataChannelMessage> sent = <RTCDataChannelMessage>[];

  @override
  RTCDataChannelState? get state => null;

  @override
  int? get id => 0;

  @override
  String? get label => 'oai-events';

  @override
  int? get bufferedAmount => 0;

  @override
  Future<void> send(RTCDataChannelMessage message) async {
    sent.add(message);
  }

  @override
  Future<void> close() async {
    closeCalls++;
  }
}

void main() {
  test('an early channel death before anyone awaits readiness resolves '
      'opened to false — no unhandled error, resources close once '
      '(regression 5)', () async {
    final peer = _FakePeerConnection();
    final channel = _FakeDataChannel();
    final connection = WebRtcRealtimeConnection(peer, channel);

    // The session dies while signaling is still in flight — nothing has
    // awaited `opened` yet. Were this a completeError, the error would sit
    // unhandled in the zone; as a value it is inert.
    channel.onDataChannelState!(RTCDataChannelState.RTCDataChannelClosed);
    await pumpEventQueue();

    expect(await connection.opened, isFalse); // controlled outcome
    // The event stream ended cleanly (EOF), no error.
    expect(await connection.events.toList(), isEmpty);

    await connection.close();
    await connection.close(); // idempotent
    expect(channel.closeCalls, 1);
    expect(peer.closeCalls, 1);
  });

  test('an early peer-connection failure is equally controlled', () async {
    final peer = _FakePeerConnection();
    final channel = _FakeDataChannel();
    final connection = WebRtcRealtimeConnection(peer, channel);

    peer.onConnectionState!(
      RTCPeerConnectionState.RTCPeerConnectionStateFailed,
    );
    await pumpEventQueue();

    expect(await connection.opened, isFalse);
    await connection.close();
    expect(channel.closeCalls, 1);
    expect(peer.closeCalls, 1);
  });

  test('a healthy open resolves opened to true; an explicit close resolves '
      'a still-pending readiness deterministically', () async {
    final peer = _FakePeerConnection();
    final channel = _FakeDataChannel();
    final connection = WebRtcRealtimeConnection(peer, channel);
    channel.onDataChannelState!(RTCDataChannelState.RTCDataChannelOpen);
    expect(await connection.opened, isTrue);

    // A never-opened session closed explicitly: readiness resolves false
    // even if the native side never fires another state callback.
    final closedPeer = _FakePeerConnection();
    final closedChannel = _FakeDataChannel();
    final closedConnection = WebRtcRealtimeConnection(
      closedPeer,
      closedChannel,
    );
    await closedConnection.close();
    expect(await closedConnection.opened, isFalse);
    expect(closedChannel.closeCalls, 1);
    expect(closedPeer.closeCalls, 1);
  });
}
