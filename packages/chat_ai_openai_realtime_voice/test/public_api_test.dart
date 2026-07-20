// Required test 1 / 14: the public barrel exports EXACTLY the ten approved
// declarations — the original five, the two transcript declarations and the
// three recording declarations — no more, no less, and every export is a `show`
// (nothing leaks). They are also referenced through the barrel import alone (no
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
  test('the barrel exports exactly the ten approved declarations', () {
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
      'OpenAIRealtimeVoiceTranscriptRole',
      'OpenAIRealtimeVoiceRecording',
      'OpenAIRealtimeVoiceRecordingFailure',
      'OpenAIRealtimeVoiceRecordingRole',
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

  test('the seven declarations are usable through the barrel import alone', () {
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

    // The two transcript declarations resolve through the barrel too.
    const OpenAIRealtimeVoiceTranscriptRole role =
        OpenAIRealtimeVoiceTranscriptRole.user;
    const OpenAIRealtimeVoiceTranscript transcript =
        OpenAIRealtimeVoiceTranscript(
          role: OpenAIRealtimeVoiceTranscriptRole.assistant,
          text: 'hi',
        );
    expect(role, OpenAIRealtimeVoiceTranscriptRole.user);
    expect(transcript.role, OpenAIRealtimeVoiceTranscriptRole.assistant);
    expect(transcript.text, 'hi');

    // The session constructs through its public constructor, including the two
    // opt-in transcript parameters, and exposes the transcripts stream.
    final session = OpenAIRealtimeVoiceSession(
      clientSecretProvider: _AppSecretProvider(),
      botProfile: const BotProfile(
        id: 'bot',
        systemPrompt: 'be brief',
        tools: <Never>[],
      ),
      transcriptsEnabled: true,
    );
    expect(session.state, const OpenAIRealtimeVoiceState.idle());
    expect(session.state.phase, OpenAIRealtimeVoicePhase.idle);
    expect(session.transcripts, isA<Stream<OpenAIRealtimeVoiceTranscript>>());
    // The two new members are reachable through the barrel with plain types
    // (no new export/declaration): a String delta stream and a Future<void>
    // interrupt. interruptResponse() before start() is a completed no-op.
    expect(session.assistantTranscriptDeltas, isA<Stream<String>>());
    expect(session.interruptResponse(), isA<Future<void>>());
    session.dispose();
  });

  test('the two transcript declarations have value equality', () {
    const a = OpenAIRealtimeVoiceTranscript(
      role: OpenAIRealtimeVoiceTranscriptRole.user,
      text: 'hello',
    );
    const b = OpenAIRealtimeVoiceTranscript(
      role: OpenAIRealtimeVoiceTranscriptRole.user,
      text: 'hello',
    );
    const c = OpenAIRealtimeVoiceTranscript(
      role: OpenAIRealtimeVoiceTranscriptRole.assistant,
      text: 'hello',
    );
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a == c, isFalse);
    // toString names the role and the text LENGTH only — never the content.
    expect(a.toString().contains('hello'), isFalse);
    expect(a.toString().contains('user'), isTrue);
  });

  // Required test 14 (recording half): the three recording declarations resolve
  // through the barrel and the session exposes both recording streams, opt-in
  // through the two new constructor parameters.
  test('the recording declarations are usable through the barrel', () {
    const OpenAIRealtimeVoiceRecordingRole userRole =
        OpenAIRealtimeVoiceRecordingRole.user;
    const OpenAIRealtimeVoiceRecording recording = OpenAIRealtimeVoiceRecording(
      role: OpenAIRealtimeVoiceRecordingRole.assistant,
      filePath: '/tmp/a.m4a',
      transcript: 'hi',
      interrupted: true,
    );
    const OpenAIRealtimeVoiceRecordingFailure failure =
        OpenAIRealtimeVoiceRecordingFailure(
          role: OpenAIRealtimeVoiceRecordingRole.user,
        );
    expect(userRole, OpenAIRealtimeVoiceRecordingRole.user);
    expect(recording.role, OpenAIRealtimeVoiceRecordingRole.assistant);
    expect(recording.filePath, '/tmp/a.m4a');
    expect(recording.transcript, 'hi');
    expect(recording.interrupted, isTrue);
    expect(failure.role, OpenAIRealtimeVoiceRecordingRole.user);

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

  // Required test 14 (privacy half): the recording objects' toString() never
  // leaks the file path or the transcript content.
  test('recording toString is privacy-safe (no path, no transcript)', () {
    const recording = OpenAIRealtimeVoiceRecording(
      role: OpenAIRealtimeVoiceRecordingRole.user,
      filePath: '/private/var/secret-audio-12345.m4a',
      transcript: 'my confidential spoken words',
      interrupted: false,
    );
    final text = recording.toString();
    expect(text.contains('secret-audio-12345'), isFalse);
    expect(text.contains('/private/var'), isFalse);
    expect(text.contains('.m4a'), isFalse);
    expect(text.contains('confidential'), isFalse);
    // It still exposes the coarse, safe fields.
    expect(text.contains('user'), isTrue);
    expect(text.contains('interrupted'), isTrue);
    expect(text.contains('hasTranscript'), isTrue);

    const failure = OpenAIRealtimeVoiceRecordingFailure(
      role: OpenAIRealtimeVoiceRecordingRole.assistant,
    );
    expect(failure.toString().contains('assistant'), isTrue);
  });
}
