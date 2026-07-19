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
//
// Optional input transcription: when (and ONLY when) the app opts in, an
// `audio.input.transcription.model` is added so the SAME direct device → OpenAI
// Realtime session also returns final user transcripts. This is a SEPARATE ASR
// operation billed by OpenAI; no second network call is ever made. When
// disabled, the emitted map is byte-for-byte the original shape.
library;

/// Builds the exact `session.update` client event from the session's
/// constructor values. The structure is fixed; only [model], [voice],
/// [instructions], [maxOutputTokens] and the optional input transcription vary.
///
/// [instructions] is the bot's system prompt — carried on the wire only, never
/// logged, never surfaced in state or errors.
///
/// When [transcriptsEnabled] is false (the default) NO `transcription` key is
/// added, so the update is byte-for-byte identical to the no-transcript shape.
/// When true, `audio.input.transcription.model` is set to
/// [inputTranscriptionModel] and nothing else (no language/prompt/logprobs/
/// include). The caller is responsible for having rejected an empty model
/// synchronously before this builder is ever reached.
Map<String, Object?> buildRealtimeVoiceSessionUpdate({
  required String model,
  required String voice,
  required String instructions,
  required int maxOutputTokens,
  bool transcriptsEnabled = false,
  String inputTranscriptionModel = 'gpt-4o-mini-transcribe',
}) {
  final input = <String, Object?>{
    'turn_detection': <String, Object?>{
      'type': 'semantic_vad',
      'eagerness': 'low',
      'create_response': true,
      'interrupt_response': true,
    },
  };
  if (transcriptsEnabled) {
    input['transcription'] = <String, Object?>{
      'model': inputTranscriptionModel,
    };
  }
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
        'input': input,
        'output': <String, Object?>{'voice': voice},
      },
    },
  };
}
