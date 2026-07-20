// Required test 15: the recorder method channel carries COMMANDS + safe scalar
// metadata ONLY. No PCM, audio buffer, byte list or base64 string ever crosses
// it in either direction — the native side attaches to the existing WebRTC track
// as an RTCAudioRenderer and keeps all audio on the iOS side. The only value
// that comes back is a finished file path (a plain string).
//
// PHYSICAL-SMOKE / NATIVE GATES (task_2). The following are properties of the
// iOS ObjC writer (ChatAiRealtimeVoiceRecorder) that a Dart unit test CANNOT
// honestly prove — a fake recorder returning different strings would be a lie,
// not evidence. They are verified only by the physical iOS recording smoke and
// are listed here so the gap is explicit, never hidden:
//   - the on-disk final/temp names are per-segment NSUUIDs (collision-resistant
//     across sessions, factory instances and app launches);
//   - the temp→final promotion is a NO-OVERWRITE `moveItemAtURL:` — a finished,
//     already-published file is never deleted or replaced; a collision/move
//     error yields a failure and drops only this writer's own temp;
//   - every Core Audio OSStatus is checked (create/convert/bitrate set+readback/
//     write/dispose/move) and the finished file is validated as AAC-LC / M4A /
//     16 kHz / mono with a non-zero frame count before publication;
//   - finalize (drain / dispose / validate / move) runs on the writer's serial
//     queue and never blocks the main iOS thread; FlutterResult is delivered
//     once on the main queue.
// The Dart-observable HALVES of these guarantees ARE unit-tested: the collision
// fix's process-unique segment ids (recording_test.dart), the failure→coarse
// recordingFailure contract, and the command/args-only channel below.
import 'package:chat_ai_openai_realtime_voice/src/voice_recorder.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(kVoiceRecorderChannel);
  final calls = <MethodCall>[];
  Future<Object?> Function(MethodCall call)? handler;

  setUp(() {
    calls.clear();
    handler = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return handler?.call(call);
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  NativeRealtimeVoiceRecorder makeRecorder({bool isRemote = false}) =>
      NativeRealtimeVoiceRecorder(
        channel: channel,
        writerId: isRemote ? 'assistant-0' : 'user-0',
        isRemote: isRemote,
        directoryPath: '/rec',
      );

  bool isSafeScalar(Object? v) => v is String || v is bool || v is int;

  test('every command argument is a safe scalar — never audio bytes', () async {
    handler = (call) async {
      if (call.method == 'endSegment') {
        return <Object?, Object?>{
          'ok': true,
          'filePath': '/rec/user-0-seg.m4a',
        };
      }
      return null;
    };

    final recorder = makeRecorder();
    await recorder.attach(trackId: 'local-track-1');
    await recorder.beginSegment('user-seg-0');
    await recorder.endSegment('user-seg-0');
    await recorder.close();

    expect(calls.map((c) => c.method).toList(), <String>[
      'attach',
      'beginSegment',
      'endSegment',
      'close',
    ]);

    for (final call in calls) {
      final args = call.arguments;
      expect(args, isA<Map<Object?, Object?>>(), reason: call.method);
      final map = (args as Map).cast<Object?, Object?>();
      for (final entry in map.entries) {
        // Keys are plain command/metadata names.
        expect(entry.key, isA<String>());
        final key = entry.key! as String;
        expect(
          key,
          isNot(anyOf(contains('pcm'), contains('audio'), contains('base64'))),
          reason: 'no audio-carrying argument key',
        );
        // Values are only safe scalars — never a byte buffer or a list.
        expect(entry.value, isNot(isA<Uint8List>()), reason: key);
        expect(entry.value, isNot(isA<List<Object?>>()), reason: key);
        expect(
          isSafeScalar(entry.value),
          isTrue,
          reason: '$key => ${entry.value}',
        );
      }
    }

    // The attach command carries exactly the fixed speech-recording format.
    final attach = calls.first.arguments as Map;
    expect(attach['directoryPath'], '/rec');
    expect(attach['sampleRate'], 16000);
    expect(attach['numChannels'], 1);
    expect(attach['bitRate'], 32000);
    expect(attach['trackId'], 'local-track-1');
    expect(attach['isRemote'], false);
  });

  test('endSegment returns the app-owned path for a valid result', () async {
    handler = (call) async => <Object?, Object?>{
      'ok': true,
      'filePath': '/rec/assistant-0-seg.m4a',
    };
    final recorder = makeRecorder(isRemote: true);
    final result = await recorder.endSegment('assistant-seg-1');
    expect(result.ok, isTrue);
    expect(result.filePath, '/rec/assistant-0-seg.m4a');
    // The only value returned across the channel is a plain path string.
    expect(result.filePath, isA<String>());
  });

  test('endSegment maps an invalid / empty result to a failure', () async {
    handler = (call) async => <Object?, Object?>{'ok': false};
    final recorder = makeRecorder();
    final result = await recorder.endSegment('user-seg-0');
    expect(result.ok, isFalse);
    expect(result.filePath, isNull);
  });

  test('endSegment never throws on a platform failure', () async {
    handler = (call) async => throw PlatformException(code: 'writer_failed');
    final recorder = makeRecorder();
    final result = await recorder.endSegment('user-seg-0');
    expect(result.ok, isFalse);
    expect(result.filePath, isNull);
  });

  test('attach surfaces a platform failure as a coarse exception', () async {
    handler = (call) async => throw PlatformException(code: 'track_not_found');
    final recorder = makeRecorder();
    await expectLater(
      recorder.attach(trackId: 'local-track-1'),
      throwsA(isA<RealtimeVoiceRecorderException>()),
    );
  });

  test('close swallows a native failure (teardown must not throw)', () async {
    handler = (call) async => throw PlatformException(code: 'boom');
    final recorder = makeRecorder();
    await recorder.close(); // must not throw
    // A second close is a no-op (idempotent) and issues no further call.
    final before = calls.length;
    await recorder.close();
    expect(calls.length, before);
  });
}
