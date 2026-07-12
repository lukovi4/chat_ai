// Image preprocessing and its gates (V1_SPEC §4/§5/§11, test contract
// §12.12): the Core count limit, malformed input, real off-isolate resize,
// the 10 MB payload gate and dispose-invalidation.
import 'dart:typed_data';

import 'package:chat_ai/chat_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'chat_session_test_utils.dart';

void main() {
  test('a raw image count above the session limit is rejected: no phase '
      'change, no Message, no key, no checkpoint, no backend', () async {
    final fake = FakeChatBackend()..reply('never dispatched');
    var checkpoints = 0;
    var processed = 0;
    final session = makeSession(
      backend: fake,
      time: FakeTime(),
      imageOptions: const ImageSendOptions(maxImagesPerMessage: 2),
      checkpoint: (snapshot) async => checkpoints++,
      processImage: (raw, options) async {
        processed++;
        return raw;
      },
    );
    final disposition = await sendWithDisposition(
      session,
      'too many',
      images: [
        for (var i = 0; i < 3; i++) Uint8List.fromList([i]),
      ],
    );
    await pumpEventQueue();

    expect(disposition, ChatCommandDisposition.rejected);
    expect(
      session.state,
      const ConversationState.idle(),
      reason: 'no public phase change',
    );
    expect(session.snapshot.messages, isEmpty);
    expect(checkpoints, 0);
    expect(processed, 0);
    expect(capturedRequestsOf(fake), isEmpty);
    // The session stays usable.
    await session.send('fine');
    await waitForState(session, (s) => s is Done);
  });

  test('malformed image bytes: rejected + Failed(upstream, sending, '
      'malformed-image), no Message/key/checkpoint/backend', () async {
    final fake = FakeChatBackend()..reply('never dispatched');
    var checkpoints = 0;
    final session = makeSession(
      backend: fake,
      // The REAL pipeline (compute + package:image) — undecodable bytes.
      checkpoint: (snapshot) async => checkpoints++,
    );
    final disposition = await sendWithDisposition(
      session,
      'broken picture',
      images: [
        Uint8List.fromList([0, 1, 2, 3, 4]),
      ],
    );

    expect(disposition, ChatCommandDisposition.rejected);
    final state = session.state;
    expect(state, isA<Failed>());
    expect((state as Failed).cause, FailureCause.upstream);
    expect(state.phase, FailurePhase.sending);
    expect(state.developerDetail, 'malformed-image');
    expect(session.snapshot.messages, isEmpty);
    expect(checkpoints, 0);
    expect(capturedRequestsOf(fake), isEmpty);
  });

  test('the real pipeline resizes to the long edge off the UI isolate and '
      're-encodes as JPEG', () async {
    final fake = FakeChatBackend()..reply('nice photo');
    final session = makeSession(
      backend: fake,
      imageOptions: const ImageSendOptions(maxLongEdge: 64, jpegQuality: 80),
    );
    // A 128×32 PNG: the long edge must land on 64, the short one on 16.
    final source = img.Image(width: 128, height: 32);
    img.fill(source, color: img.ColorRgb8(200, 40, 40));
    final png = Uint8List.fromList(img.encodePng(source));

    await session.send('look', images: [png]);
    await waitForState(session, (s) => s is Done);

    final part = session.snapshot.messages.first.parts
        .whereType<ImagePart>()
        .single;
    // JPEG magic bytes, decodable, resized.
    expect(part.bytes[0], 0xFF);
    expect(part.bytes[1], 0xD8);
    final decoded = img.decodeJpg(part.bytes)!;
    expect(decoded.width, 64);
    expect(decoded.height, 16);
  });

  test('an image already within the long edge is not upscaled', () async {
    final fake = FakeChatBackend()..reply('ok');
    final session = makeSession(
      backend: fake,
      imageOptions: const ImageSendOptions(maxLongEdge: 2048),
    );
    final source = img.Image(width: 40, height: 20);
    img.fill(source, color: img.ColorRgb8(10, 200, 10));
    await session.send(
      'small',
      images: [Uint8List.fromList(img.encodePng(source))],
    );
    await waitForState(session, (s) => s is Done);
    final part = session.snapshot.messages.first.parts
        .whereType<ImagePart>()
        .single;
    final decoded = img.decodeJpg(part.bytes)!;
    expect(decoded.width, 40);
    expect(decoded.height, 20);
  });

  test('an image-only Message (no text) is valid', () async {
    final fake = FakeChatBackend()..reply('what a picture');
    final session = makeSession(
      backend: fake,
      time: FakeTime(),
      processImage: (raw, options) async => raw,
    );
    await session.send(
      '',
      images: [
        Uint8List.fromList([7]),
      ],
    );
    await waitForState(session, (s) => s is Done);
    final user = session.snapshot.messages.first;
    expect(user.parts.whereType<TextPart>(), isEmpty);
    expect(user.parts.whereType<ImagePart>(), hasLength(1));
    expect(capturedRequestsOf(fake).single.messages.first.parts, hasLength(1));
  });

  test(
    'a post-resize request body over 10 MiB: rejected + '
    'Failed(contextTooLong, sending, payload-too-large), no Message/backend',
    () async {
      final fake = FakeChatBackend()..reply('never dispatched');
      var checkpoints = 0;
      final session = makeSession(
        backend: fake,
        time: FakeTime(),
        checkpoint: (snapshot) async => checkpoints++,
        // The "processed" image alone is 9 MiB; base64 (+1/3) pushes the
        // encoded body over the 10 MiB ceiling.
        processImage: (raw, options) async => Uint8List(9 * 1024 * 1024),
      );
      final disposition = await sendWithDisposition(
        session,
        'huge',
        images: [
          Uint8List.fromList([1]),
        ],
      );

      expect(disposition, ChatCommandDisposition.rejected);
      final state = session.state;
      expect(state, isA<Failed>());
      expect((state as Failed).cause, FailureCause.contextTooLong);
      expect(state.phase, FailurePhase.sending);
      expect(state.developerDetail, 'payload-too-large');
      expect(session.snapshot.messages, isEmpty, reason: 'no Message, no key');
      expect(checkpoints, 0);
      expect(capturedRequestsOf(fake), isEmpty);
    },
  );

  test('a body under the ceiling passes the gate', () async {
    final fake = FakeChatBackend()..reply('fits');
    final session = makeSession(
      backend: fake,
      time: FakeTime(),
      processImage: (raw, options) async => Uint8List(1024 * 1024),
    );
    expect(
      await sendWithDisposition(
        session,
        'ok',
        images: [
          Uint8List.fromList([1]),
        ],
      ),
      ChatCommandDisposition.accepted,
    );
    await waitForState(session, (s) => s is Done);
  });
}
