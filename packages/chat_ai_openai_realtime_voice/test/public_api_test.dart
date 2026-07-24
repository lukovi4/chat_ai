// Required public-API test: the barrel exports EXACTLY the fourteen approved
// declarations — the original ten, the typed assistant transcript delta and the
// three output-guardrail declarations — no more, no less, and every export is a
// `show` (nothing leaks). They are also referenced through the barrel import
// alone (no `src/` import) to prove they are genuinely public.
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
  test('the barrel exports exactly the fourteen approved declarations', () {
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
      'OpenAIRealtimeVoiceTranscript',
      'OpenAIRealtimeVoiceTranscriptDelta',
      'OpenAIRealtimeVoiceTranscriptRole',
      'OpenAIRealtimeVoiceRecording',
      'OpenAIRealtimeVoiceRecordingFailure',
      'OpenAIRealtimeVoiceRecordingRole',
      'OpenAIRealtimeVoiceGuardrailDecision',
      'OpenAIRealtimeVoiceOutputGuardrail',
      'OpenAIRealtimeVoiceGuardrailEvent',
    });
  });

  test('the exported session class exposes no `.forTesting` member', () {
    final source = File('lib/src/voice_session.dart').readAsStringSync();
    expect(
      source.contains('OpenAIRealtimeVoiceSession.forTesting'),
      isFalse,
      reason:
          'the test seam must be a package-internal top-level function, not a '
          'constructor/member on the exported class',
    );
    final barrel = File(
      'lib/chat_ai_openai_realtime_voice.dart',
    ).readAsStringSync();
    expect(barrel.contains('voiceSessionForTesting'), isFalse);
    expect(barrel.contains('forTesting'), isFalse);
  });

  test('the declarations are usable through the barrel import alone', () {
    const OpenAIRealtimeVoiceMode singleTurn =
        OpenAIRealtimeVoiceMode.singleTurn;
    const OpenAIRealtimeVoicePhase idle = OpenAIRealtimeVoicePhase.idle;
    const OpenAIRealtimeVoiceFailure mint = OpenAIRealtimeVoiceFailure.mint;
    // The two new coarse failure categories resolve through the barrel too.
    const OpenAIRealtimeVoiceFailure toolLimit =
        OpenAIRealtimeVoiceFailure.toolLoopLimit;
    const OpenAIRealtimeVoiceFailure guardrail =
        OpenAIRealtimeVoiceFailure.guardrail;
    const OpenAIRealtimeVoiceState state = OpenAIRealtimeVoiceState.idle();
    expect(singleTurn, OpenAIRealtimeVoiceMode.singleTurn);
    expect(idle, OpenAIRealtimeVoicePhase.idle);
    expect(mint, OpenAIRealtimeVoiceFailure.mint);
    expect(toolLimit, OpenAIRealtimeVoiceFailure.toolLoopLimit);
    expect(guardrail, OpenAIRealtimeVoiceFailure.guardrail);
    expect(state.phase, OpenAIRealtimeVoicePhase.idle);

    // The transcript declarations resolve through the barrel, now with turnId +
    // interrupted, plus the typed delta.
    const OpenAIRealtimeVoiceTranscriptRole role =
        OpenAIRealtimeVoiceTranscriptRole.user;
    const OpenAIRealtimeVoiceTranscript transcript =
        OpenAIRealtimeVoiceTranscript(
          role: OpenAIRealtimeVoiceTranscriptRole.assistant,
          turnId: 'turn-1',
          text: 'hi',
          interrupted: false,
        );
    const OpenAIRealtimeVoiceTranscriptDelta delta =
        OpenAIRealtimeVoiceTranscriptDelta(turnId: 'turn-1', delta: 'h');
    expect(role, OpenAIRealtimeVoiceTranscriptRole.user);
    expect(transcript.role, OpenAIRealtimeVoiceTranscriptRole.assistant);
    expect(transcript.turnId, 'turn-1');
    expect(transcript.text, 'hi');
    expect(transcript.interrupted, isFalse);
    expect(delta.turnId, 'turn-1');
    expect(delta.delta, 'h');

    // The guardrail declarations resolve through the barrel.
    const OpenAIRealtimeVoiceGuardrailDecision allow =
        OpenAIRealtimeVoiceGuardrailDecision.allow;
    const OpenAIRealtimeVoiceGuardrailDecision block =
        OpenAIRealtimeVoiceGuardrailDecision.block;
    const OpenAIRealtimeVoiceGuardrailEvent event =
        OpenAIRealtimeVoiceGuardrailEvent(turnId: 'turn-9');
    expect(allow, OpenAIRealtimeVoiceGuardrailDecision.allow);
    expect(block, OpenAIRealtimeVoiceGuardrailDecision.block);
    expect(event.turnId, 'turn-9');
    // The typedef is usable (a matching function is assignable to it).
    Future<OpenAIRealtimeVoiceGuardrailDecision> guard({
      required String turnId,
      required String accumulatedText,
    }) async => OpenAIRealtimeVoiceGuardrailDecision.allow;
    final OpenAIRealtimeVoiceOutputGuardrail typed = guard;
    expect(typed, isNotNull);

    final session = OpenAIRealtimeVoiceSession(
      clientSecretProvider: _AppSecretProvider(),
      botProfile: const BotProfile(
        id: 'bot',
        systemPrompt: 'be brief',
        tools: <Never>[],
      ),
      transcriptsEnabled: true,
      outputGuardrail: guard,
      safeReplacementInstructions: 'Say only that you cannot help with that.',
    );
    expect(session.state, const OpenAIRealtimeVoiceState.idle());
    expect(session.state.phase, OpenAIRealtimeVoicePhase.idle);
    expect(session.transcripts, isA<Stream<OpenAIRealtimeVoiceTranscript>>());
    // The delta stream is now TYPED (no old Stream<String>).
    expect(
      session.assistantTranscriptDeltas,
      isA<Stream<OpenAIRealtimeVoiceTranscriptDelta>>(),
    );
    expect(
      session.guardrailEvents,
      isA<Stream<OpenAIRealtimeVoiceGuardrailEvent>>(),
    );
    expect(session.interruptResponse(), isA<Future<void>>());
    session.dispose();
  });

  test('the transcript / delta declarations have value equality', () {
    const a = OpenAIRealtimeVoiceTranscript(
      role: OpenAIRealtimeVoiceTranscriptRole.user,
      turnId: 't1',
      text: 'hello',
      interrupted: false,
    );
    const b = OpenAIRealtimeVoiceTranscript(
      role: OpenAIRealtimeVoiceTranscriptRole.user,
      turnId: 't1',
      text: 'hello',
      interrupted: false,
    );
    const c = OpenAIRealtimeVoiceTranscript(
      role: OpenAIRealtimeVoiceTranscriptRole.assistant,
      turnId: 't1',
      text: 'hello',
      interrupted: false,
    );
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a == c, isFalse);
    // toString names the role/turnId/interrupted and the text LENGTH only.
    expect(a.toString().contains('hello'), isFalse);
    expect(a.toString().contains('user'), isTrue);
    expect(a.toString().contains('t1'), isTrue);

    const d1 = OpenAIRealtimeVoiceTranscriptDelta(turnId: 't1', delta: 'ab');
    const d2 = OpenAIRealtimeVoiceTranscriptDelta(turnId: 't1', delta: 'ab');
    const d3 = OpenAIRealtimeVoiceTranscriptDelta(turnId: 't2', delta: 'ab');
    expect(d1, d2);
    expect(d1.hashCode, d2.hashCode);
    expect(d1 == d3, isFalse);
    // The delta toString never leaks the delta content.
    expect(d1.toString().contains('ab'), isFalse);
    expect(d1.toString().contains('t1'), isTrue);
  });

  test('the recording declarations are usable through the barrel', () {
    const OpenAIRealtimeVoiceRecordingRole userRole =
        OpenAIRealtimeVoiceRecordingRole.user;
    const OpenAIRealtimeVoiceRecording recording = OpenAIRealtimeVoiceRecording(
      role: OpenAIRealtimeVoiceRecordingRole.assistant,
      turnId: 'turn-2',
      filePath: '/tmp/a.m4a',
      transcript: 'hi',
      interrupted: true,
    );
    const OpenAIRealtimeVoiceRecordingFailure failure =
        OpenAIRealtimeVoiceRecordingFailure(
          role: OpenAIRealtimeVoiceRecordingRole.user,
          turnId: 'turn-3',
        );
    expect(userRole, OpenAIRealtimeVoiceRecordingRole.user);
    expect(recording.role, OpenAIRealtimeVoiceRecordingRole.assistant);
    expect(recording.turnId, 'turn-2');
    expect(recording.filePath, '/tmp/a.m4a');
    expect(recording.transcript, 'hi');
    expect(recording.interrupted, isTrue);
    expect(failure.role, OpenAIRealtimeVoiceRecordingRole.user);
    expect(failure.turnId, 'turn-3');

    final session = OpenAIRealtimeVoiceSession(
      clientSecretProvider: _AppSecretProvider(),
      botProfile: const BotProfile(
        id: 'bot',
        systemPrompt: 'be brief',
        tools: <Never>[],
      ),
      recordingEnabled: true,
      recordingDirectoryPath: '/tmp/recordings',
    );
    expect(session.recordings, isA<Stream<OpenAIRealtimeVoiceRecording>>());
    expect(
      session.recordingFailures,
      isA<Stream<OpenAIRealtimeVoiceRecordingFailure>>(),
    );
    session.dispose();
  });

  test('recording/failure toString is privacy-safe (no path/transcript)', () {
    const recording = OpenAIRealtimeVoiceRecording(
      role: OpenAIRealtimeVoiceRecordingRole.user,
      turnId: 'turn-4',
      filePath: '/private/var/secret-audio-12345.m4a',
      transcript: 'my confidential spoken words',
      interrupted: false,
    );
    final text = recording.toString();
    expect(text.contains('secret-audio-12345'), isFalse);
    expect(text.contains('/private/var'), isFalse);
    expect(text.contains('.m4a'), isFalse);
    expect(text.contains('confidential'), isFalse);
    expect(text.contains('user'), isTrue);
    expect(text.contains('interrupted'), isTrue);
    expect(text.contains('hasTranscript'), isTrue);
    expect(text.contains('turn-4'), isTrue);

    const failure = OpenAIRealtimeVoiceRecordingFailure(
      role: OpenAIRealtimeVoiceRecordingRole.assistant,
      turnId: 'turn-5',
    );
    expect(failure.toString().contains('assistant'), isTrue);
    expect(failure.toString().contains('turn-5'), isTrue);
  });
}
