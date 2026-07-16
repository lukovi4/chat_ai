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
}
