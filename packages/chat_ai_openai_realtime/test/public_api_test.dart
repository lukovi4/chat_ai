// Public API regression (defect 1): the documented constructor must be
// callable by an external consumer through the barrel import alone — no
// `src/` imports here.

import 'package:chat_ai/chat_ai.dart';
import 'package:chat_ai_openai_realtime/chat_ai_openai_realtime.dart';
import 'package:flutter_test/flutter_test.dart';

class _AppSecretProvider implements ClientSecretProvider {
  @override
  Future<String> getClientSecret({required String botId}) async =>
      'fake-ephemeral-secret';
}

void main() {
  test('OpenAIRealtimeChatBackend is constructible via the public '
      '`clientSecretProvider:` parameter and is a ChatBackend', () {
    final backend = OpenAIRealtimeChatBackend(
      clientSecretProvider: _AppSecretProvider(),
    );
    expect(backend, isA<ChatBackend>());
  });

  test('the optional `model:` parameter is accepted and defaults keep '
      'existing call sites compiling', () {
    // Existing call site (no model) still compiles and constructs.
    final withDefault = OpenAIRealtimeChatBackend(
      clientSecretProvider: _AppSecretProvider(),
    );
    // The new optional parameter is accepted.
    final withModel = OpenAIRealtimeChatBackend(
      clientSecretProvider: _AppSecretProvider(),
      model: 'gpt-realtime-2.1',
    );
    expect(withDefault, isA<ChatBackend>());
    expect(withModel, isA<ChatBackend>());
  });

  test('a whitespace-only model is rejected at construction (before any '
      'token request or network I/O)', () {
    expect(
      () => OpenAIRealtimeChatBackend(
        clientSecretProvider: _AppSecretProvider(),
        model: '   ',
      ),
      throwsArgumentError,
    );
    expect(
      () => OpenAIRealtimeChatBackend(
        clientSecretProvider: _AppSecretProvider(),
        model: '',
      ),
      throwsArgumentError,
    );
  });

  test('maxOutputTokens: 1 and 4096 are accepted; 0, negative and 4097 are '
      'rejected synchronously at construction (test 3)', () {
    for (final ok in [1, 128, 4096]) {
      expect(
        OpenAIRealtimeChatBackend(
          clientSecretProvider: _AppSecretProvider(),
          maxOutputTokens: ok,
        ),
        isA<ChatBackend>(),
        reason: '$ok',
      );
    }
    for (final bad in [0, -1, 4097]) {
      expect(
        () => OpenAIRealtimeChatBackend(
          clientSecretProvider: _AppSecretProvider(),
          maxOutputTokens: bad,
        ),
        throwsArgumentError,
        reason: '$bad',
      );
    }
  });

  test('responseIdleTimeout must be strictly greater than Duration.zero '
      '(test 4)', () {
    expect(
      OpenAIRealtimeChatBackend(
        clientSecretProvider: _AppSecretProvider(),
        responseIdleTimeout: const Duration(milliseconds: 1),
      ),
      isA<ChatBackend>(),
    );
    for (final bad in [Duration.zero, const Duration(seconds: -1)]) {
      expect(
        () => OpenAIRealtimeChatBackend(
          clientSecretProvider: _AppSecretProvider(),
          responseIdleTimeout: bad,
        ),
        throwsArgumentError,
        reason: '$bad',
      );
    }
  });
}
