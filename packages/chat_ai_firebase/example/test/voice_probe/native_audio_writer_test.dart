import 'package:example/src/voice_probe/native_audio_writer.dart';
import 'package:example/src/voice_probe/probe_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late MockWriterChannel mock;

  setUp(() {
    mock = MockWriterChannel(kVoiceProbeWriterChannel);
  });

  tearDown(() => mock.dispose());

  // Required test 11: no PCM / audio bytes / base64 ever cross the channel —
  // only command scalars (writerId, isRemote, trackId).
  test('the channel carries commands only — never audio bytes', () async {
    final factory = NativeAudioWriterFactory();
    final user = factory.create(isRemote: false);
    final assistant = factory.create(isRemote: true);

    await user.start(trackId: 'local-track');
    await assistant.start(trackId: 'remote-track');
    await user.finalize();
    await assistant.finalize();
    await user.play();
    await user.close();

    expect(mock.calls, isNotEmpty);
    for (final call in mock.calls) {
      final args = call.arguments;
      expect(args, isA<Map>());
      final map = args as Map;
      for (final entry in map.entries) {
        // No binary payloads of any shape.
        expect(entry.value, isNot(isA<Uint8List>()), reason: '${entry.key}');
        expect(entry.value, isNot(isA<List<int>>()), reason: '${entry.key}');
        expect(entry.value, isNot(isA<ByteData>()), reason: '${entry.key}');
      }
      // Only the known command keys appear.
      expect(
        map.keys.toSet().difference(<Object?>{
          'writerId',
          'isRemote',
          'trackId',
        }),
        isEmpty,
      );
    }
  });

  // Required tests 9 & 10: the local writer receives only the local track id;
  // the remote writer receives only the remote track id.
  test('local writer gets local id, remote writer gets remote id', () async {
    final factory = NativeAudioWriterFactory();
    final user = factory.create(isRemote: false);
    final assistant = factory.create(isRemote: true);

    await user.start(trackId: 'local-track');
    await assistant.start(trackId: 'remote-track');

    final starts = mock.callsFor('start');
    final localStart = starts.firstWhere(
      (c) => (c.arguments as Map)['isRemote'] == false,
    );
    final remoteStart = starts.firstWhere(
      (c) => (c.arguments as Map)['isRemote'] == true,
    );
    expect((localStart.arguments as Map)['trackId'], 'local-track');
    expect((remoteStart.arguments as Map)['trackId'], 'remote-track');
  });

  // A writer failure surfaces a non-throwing result with only counters + a
  // stable status enum — no path, track id or native description.
  test('writer failure surfaces a safe status with no native detail', () async {
    mock.finalizeOk = false;
    mock.finalizeFailStatus = 'noFrames';
    final writer = NativeAudioWriterFactory().create(isRemote: false);
    await writer.start(trackId: 'local-track');

    final result = await writer.finalize();
    expect(result.ok, isFalse);
    expect(result.artifact, isNull);
    expect(result.diagnostics.status, WriterStatus.noFrames);
    // The diagnostics carry only counters + an enum — never a string blob.
    expect(result.diagnostics.callbackCount, isA<int>());
    expect(result.diagnostics.writtenFrames, isA<int>());
  });

  // A zero-duration finalize is never a ready artifact.
  test('zero-duration finalize is a failed result, not an artifact', () async {
    mock.finalizeDurationMs = 0;
    final writer = NativeAudioWriterFactory().create(isRemote: false);
    await writer.start(trackId: 'local-track');

    final result = await writer.finalize();
    expect(result.ok, isFalse);
    expect(result.artifact, isNull);
  });

  // Defect 8 (facade half): the native controlled-failure code for starting a
  // closed writer surfaces as a stable code, never a false success.
  test('a native writer_closed start error maps to a stable code', () async {
    mock.failStartContaining = 'user';
    mock.failStartCode = 'writer_closed';
    final writer = NativeAudioWriterFactory().create(isRemote: false);
    Object? caught;
    try {
      await writer.start(trackId: 'local-track');
    } catch (e) {
      caught = e;
    }
    expect(caught, isA<VoiceProbeWriterException>());
    expect(
      (caught! as VoiceProbeWriterException).code,
      VoiceProbeErrorCode.writerFailed,
    );
  });

  test('start and finalize are idempotent / memoized', () async {
    final writer = NativeAudioWriterFactory().create(isRemote: false);
    await writer.start(trackId: 'local-track');
    await writer.start(trackId: 'local-track');
    final a = await writer.finalize();
    final b = await writer.finalize();
    expect(a.ok, isTrue);
    expect(a.artifact?.handle, b.artifact?.handle);
    expect(mock.callsFor('start').length, 1);
    expect(mock.callsFor('finalize').length, 1);
  });
}
