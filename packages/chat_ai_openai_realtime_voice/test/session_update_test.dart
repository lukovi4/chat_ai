// Required test 6 (structure half): the single session.update the session ever
// sends has the exact approved GA shape and carries the constructor values.
import 'package:chat_ai_openai_realtime_voice/src/voice_session_update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, Object?> build() => buildRealtimeVoiceSessionUpdate(
    model: 'gpt-realtime-2.1',
    voice: 'marin',
    instructions: 'be brief',
    maxOutputTokens: 4096,
  );

  test('session.update has the exact approved GA structure', () {
    final update = build();
    expect(update['type'], 'session.update');

    final session = update['session']! as Map<String, Object?>;
    expect(session['type'], 'realtime');
    expect(session['model'], 'gpt-realtime-2.1');
    expect(session['output_modalities'], <String>['audio']);
    expect(session['instructions'], 'be brief');
    expect(session['max_output_tokens'], 4096);
    // tracing is explicitly disabled (null) — present but null.
    expect(session.containsKey('tracing'), isTrue);
    expect(session['tracing'], isNull);

    final audio = session['audio']! as Map<String, Object?>;
    final input = audio['input']! as Map<String, Object?>;
    final turn = input['turn_detection']! as Map<String, Object?>;
    expect(turn['type'], 'semantic_vad');
    expect(turn['eagerness'], 'low');
    expect(turn['create_response'], true);
    expect(turn['interrupt_response'], true);

    final output = audio['output']! as Map<String, Object?>;
    expect(output['voice'], 'marin');
  });

  test('session.update carries no unexpected top-level session keys', () {
    final session = build()['session']! as Map<String, Object?>;
    expect(session.keys.toSet(), <String>{
      'type',
      'model',
      'output_modalities',
      'instructions',
      'max_output_tokens',
      'tracing',
      'audio',
    });
  });

  test('the builder reflects the constructor model/voice/maxOutputTokens', () {
    final update = buildRealtimeVoiceSessionUpdate(
      model: 'other-model',
      voice: 'cedar',
      instructions: 'system prompt text',
      maxOutputTokens: 512,
    );
    final session = update['session']! as Map<String, Object?>;
    expect(session['model'], 'other-model');
    expect(session['max_output_tokens'], 512);
    expect(session['instructions'], 'system prompt text');
    final audio = session['audio']! as Map<String, Object?>;
    expect((audio['output']! as Map<String, Object?>)['voice'], 'cedar');
  });
}
