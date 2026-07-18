// The single `session.update` a voice session ever sends. A pure builder so a
// test can pin the exact GA structure without a live session. The session
// sends this map exactly once, right after `session.created`, and never
// mutates or resends it.
//
// Deliberate money-safe / privacy shape:
// - output modality is audio only;
// - `semantic_vad` (eagerness `low`) with `create_response: true` makes the
//   server create the one response by itself — the client never sends
//   `response.create`;
// - `interrupt_response: true` lets the server itself cancel a response and
//   truncate unplayed audio on a barge-in — the client sends no redundant
//   `response.cancel`/`response.truncate`;
// - `max_output_tokens` is finite (bounds one paid response);
// - `tracing` is explicitly null (disabled) — no content tracing.
library;

/// Builds the exact `session.update` client event from the session's
/// constructor values. The structure is fixed; only [model], [voice],
/// [instructions] and [maxOutputTokens] vary.
///
/// [instructions] is the bot's system prompt — carried on the wire only, never
/// logged, never surfaced in state or errors.
Map<String, Object?> buildRealtimeVoiceSessionUpdate({
  required String model,
  required String voice,
  required String instructions,
  required int maxOutputTokens,
}) {
  return <String, Object?>{
    'type': 'session.update',
    'session': <String, Object?>{
      'type': 'realtime',
      'model': model,
      'output_modalities': <String>['audio'],
      'instructions': instructions,
      'max_output_tokens': maxOutputTokens,
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
        'output': <String, Object?>{'voice': voice},
      },
    },
  };
}
