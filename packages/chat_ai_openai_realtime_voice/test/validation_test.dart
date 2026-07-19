// Required test 2: synchronous constructor validation of model, voice,
// maxOutputTokens (1..4096) and a strictly-positive responseIdleTimeout.
// Required test 3: a non-empty botProfile.tools is rejected BEFORE the provider
// or any network I/O is touched.
import 'package:chat_ai/chat_ai.dart' show BotProfile, Tool;
import 'package:chat_ai_openai_realtime_voice/chat_ai_openai_realtime_voice.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  OpenAIRealtimeVoiceSession build({
    String model = 'gpt-realtime-2.1',
    String voice = 'marin',
    int maxOutputTokens = 4096,
    Duration responseIdleTimeout = const Duration(seconds: 60),
    List<Tool> tools = const <Tool>[],
    FakeClientSecretProvider? provider,
    bool transcriptsEnabled = false,
    String inputTranscriptionModel = 'gpt-4o-mini-transcribe',
  }) {
    return OpenAIRealtimeVoiceSession(
      clientSecretProvider: provider ?? FakeClientSecretProvider(),
      botProfile: BotProfile(id: 'bot', systemPrompt: 'be brief', tools: tools),
      model: model,
      voice: voice,
      maxOutputTokens: maxOutputTokens,
      responseIdleTimeout: responseIdleTimeout,
      transcriptsEnabled: transcriptsEnabled,
      inputTranscriptionModel: inputTranscriptionModel,
    );
  }

  test('an empty or whitespace-only model is rejected at construction', () {
    expect(() => build(model: ''), throwsArgumentError);
    expect(() => build(model: '   '), throwsArgumentError);
  });

  test('an empty or whitespace-only voice is rejected at construction', () {
    expect(() => build(voice: ''), throwsArgumentError);
    expect(() => build(voice: '   '), throwsArgumentError);
  });

  test('maxOutputTokens: 1 and 4096 accepted; 0, negative, 4097 rejected', () {
    for (final ok in <int>[1, 256, 4096]) {
      expect(build(maxOutputTokens: ok), isA<OpenAIRealtimeVoiceSession>());
    }
    for (final bad in <int>[0, -1, 4097]) {
      expect(
        () => build(maxOutputTokens: bad),
        throwsArgumentError,
        reason: '$bad',
      );
    }
  });

  test('responseIdleTimeout must be strictly greater than Duration.zero', () {
    expect(
      build(responseIdleTimeout: const Duration(milliseconds: 1)),
      isA<OpenAIRealtimeVoiceSession>(),
    );
    for (final bad in <Duration>[Duration.zero, const Duration(seconds: -1)]) {
      expect(
        () => build(responseIdleTimeout: bad),
        throwsArgumentError,
        reason: '$bad',
      );
    }
  });

  test('an empty botProfile.tools constructs fine', () {
    expect(build(), isA<OpenAIRealtimeVoiceSession>());
  });

  test('a non-empty botProfile.tools is rejected before the provider', () {
    final provider = FakeClientSecretProvider();
    expect(
      () => build(
        provider: provider,
        tools: <Tool>[
          const Tool(
            name: 'get_time',
            description: 'time',
            parameters: <String, dynamic>{'type': 'object'},
          ),
        ],
      ),
      throwsArgumentError,
    );
    // The rejection happened synchronously, before any mint.
    expect(provider.calls, 0);
  });

  // Required test 2 (validation half): an empty input transcription model is
  // rejected synchronously — before the provider/network — but only when
  // transcripts are enabled.
  test(
    'an empty transcription model is rejected before the provider when enabled',
    () {
      final provider = FakeClientSecretProvider();
      for (final bad in <String>['', '   ']) {
        expect(
          () => build(
            provider: provider,
            transcriptsEnabled: true,
            inputTranscriptionModel: bad,
          ),
          throwsArgumentError,
          reason: '"$bad"',
        );
      }
      // The rejection happened synchronously, before any mint.
      expect(provider.calls, 0);
    },
  );

  test('transcriptsEnabled true with a non-empty model constructs fine', () {
    expect(
      build(transcriptsEnabled: true, inputTranscriptionModel: 'whisper-1'),
      isA<OpenAIRealtimeVoiceSession>(),
    );
    // The default transcription model is also accepted.
    expect(build(transcriptsEnabled: true), isA<OpenAIRealtimeVoiceSession>());
  });

  test('an empty transcription model is ignored while transcripts are off', () {
    // transcriptsEnabled defaults to false, so the model is never validated.
    expect(
      build(inputTranscriptionModel: ''),
      isA<OpenAIRealtimeVoiceSession>(),
    );
  });
}
