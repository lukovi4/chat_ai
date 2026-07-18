// The single `session.update` the voice probe ever sends (Increment-0 iOS
// spike). Pure builder so the harness test can pin the exact GA structure
// without a live session. The probe sends this map exactly once, right after
// `session.created`, and never mutates it.
//
// Deliberate money-safe / privacy shape:
// - output modality is audio only;
// - `semantic_vad` with `create_response: true` makes the server create the
//   one response by itself — the probe never sends `response.create`;
// - `max_output_tokens` is finite (bounds one paid response);
// - `tracing` is explicitly null (disabled) — no content tracing.
library;

/// The short, safe smoke instruction. Never logged; only its presence in the
/// built map is asserted by tests.
const String kVoiceProbeInstruction =
    'Короткая smoke-инструкция: ответить одной короткой spoken-фразой.';

/// Builds the exact `session.update` client event. The structure is fixed;
/// only the [instruction] text is a parameter (defaulted) so a test can build
/// it without hard-coding the string twice.
Map<String, Object?> buildVoiceProbeSessionUpdate({
  String instruction = kVoiceProbeInstruction,
}) {
  return <String, Object?>{
    'type': 'session.update',
    'session': <String, Object?>{
      'type': 'realtime',
      'model': 'gpt-realtime-2.1',
      'output_modalities': <String>['audio'],
      'instructions': instruction,
      'max_output_tokens': 256,
      'tracing': null,
      'audio': <String, Object?>{
        'input': <String, Object?>{
          'turn_detection': <String, Object?>{
            'type': 'semantic_vad',
            'eagerness': 'low',
            'create_response': true,
            'interrupt_response': true,
          },
        },
        'output': <String, Object?>{'voice': 'marin'},
      },
    },
  };
}
