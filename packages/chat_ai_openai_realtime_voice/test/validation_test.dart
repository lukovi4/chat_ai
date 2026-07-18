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
  }) {
    return OpenAIRealtimeVoiceSession(
      clientSecretProvider: provider ?? FakeClientSecretProvider(),
      botProfile: BotProfile(id: 'bot', systemPrompt: 'be brief', tools: tools),
      model: model,
      voice: voice,
      maxOutputTokens: maxOutputTokens,
      responseIdleTimeout: responseIdleTimeout,
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
}
