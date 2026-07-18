import 'package:example/src/voice_probe/session_update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Required test 5: session.update has the exact approved GA structure —
  // audio output, semantic_vad low with create_response/interrupt_response,
  // a finite max_output_tokens and disabled (null) tracing.
  test('session.update has the exact approved GA structure', () {
    final update = buildVoiceProbeSessionUpdate();

    expect(update['type'], 'session.update');
    final session = update['session']! as Map<String, Object?>;
    expect(session['type'], 'realtime');
    expect(session['model'], 'gpt-realtime-2.1');
    expect(session['output_modalities'], <String>['audio']);
    expect(session['instructions'], isA<String>());
    expect((session['instructions']! as String).isNotEmpty, isTrue);

    // Finite, bounded output — one paid response can never run away.
    expect(session['max_output_tokens'], 256);

    // Tracing is present AND null (explicitly disabled), never omitted.
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
    final session =
        buildVoiceProbeSessionUpdate()['session']! as Map<String, Object?>;
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
}
