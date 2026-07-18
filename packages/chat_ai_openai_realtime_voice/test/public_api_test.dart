// Required test 1: the public barrel exports EXACTLY the five approved
// declarations — no more, no less — and every export is a `show` (nothing
// leaks). The five are also referenced through the barrel import alone (no
// `src/` import) to prove they are genuinely public.
import 'dart:io';

import 'package:chat_ai/chat_ai.dart' show BotProfile;
import 'package:chat_ai_openai_realtime/chat_ai_openai_realtime.dart'
    show ClientSecretProvider;
import 'package:chat_ai_openai_realtime_voice/chat_ai_openai_realtime_voice.dart';
import 'package:flutter_test/flutter_test.dart';

class _AppSecretProvider implements ClientSecretProvider {
  @override
  Future<String> getClientSecret({required String botId}) async => 'secret';
}

void main() {
  test('the barrel exports exactly the five approved declarations', () {
    final source = File(
      'lib/chat_ai_openai_realtime_voice.dart',
    ).readAsStringSync();

    // Every export must be a `show` (no unrestricted re-export).
    final exportCount = RegExp(r'\bexport\b').allMatches(source).length;
    final showExports = RegExp(
      r'''export\s+'[^']+'\s+show\s+([^;]+);''',
      dotAll: true,
    ).allMatches(source).toList();
    expect(
      showExports.length,
      exportCount,
      reason: 'every export must use a `show` clause',
    );

    final exported = <String>{};
    for (final match in showExports) {
      for (final name in match.group(1)!.split(',')) {
        final trimmed = name.trim();
        if (trimmed.isNotEmpty) {
          exported.add(trimmed);
        }
      }
    }

    expect(exported, <String>{
      'OpenAIRealtimeVoiceSession',
      'OpenAIRealtimeVoiceMode',
      'OpenAIRealtimeVoicePhase',
      'OpenAIRealtimeVoiceState',
      'OpenAIRealtimeVoiceFailure',
    });
  });

  test('the exported session class exposes no `.forTesting` member', () {
    // Regression (defect 5): the test seam must live in a package-internal
    // top-level function, never as a member of the exported class.
    final source = File('lib/src/voice_session.dart').readAsStringSync();
    expect(
      source.contains('OpenAIRealtimeVoiceSession.forTesting'),
      isFalse,
      reason:
          'the test seam must be a package-internal top-level function, not a '
          'constructor/member on the exported class',
    );
    // The barrel must not re-export the internal test seam either.
    final barrel = File(
      'lib/chat_ai_openai_realtime_voice.dart',
    ).readAsStringSync();
    expect(barrel.contains('voiceSessionForTesting'), isFalse);
    expect(barrel.contains('forTesting'), isFalse);
  });

  test('the five declarations are usable through the barrel import alone', () {
    // Types resolve.
    const OpenAIRealtimeVoiceMode singleTurn =
        OpenAIRealtimeVoiceMode.singleTurn;
    const OpenAIRealtimeVoicePhase idle = OpenAIRealtimeVoicePhase.idle;
    const OpenAIRealtimeVoiceFailure mint = OpenAIRealtimeVoiceFailure.mint;
    const OpenAIRealtimeVoiceState state = OpenAIRealtimeVoiceState.idle();
    expect(singleTurn, OpenAIRealtimeVoiceMode.singleTurn);
    expect(idle, OpenAIRealtimeVoicePhase.idle);
    expect(mint, OpenAIRealtimeVoiceFailure.mint);
    expect(state.phase, OpenAIRealtimeVoicePhase.idle);

    // The session constructs through its public constructor.
    final session = OpenAIRealtimeVoiceSession(
      clientSecretProvider: _AppSecretProvider(),
      botProfile: const BotProfile(
        id: 'bot',
        systemPrompt: 'be brief',
        tools: <Never>[],
      ),
    );
    expect(session.state, const OpenAIRealtimeVoiceState.idle());
    expect(session.state.phase, OpenAIRealtimeVoicePhase.idle);
  });
}
