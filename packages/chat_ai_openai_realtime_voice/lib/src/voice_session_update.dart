// The single `session.update` a voice session ever sends. A pure builder so a
// test can pin the exact GA structure without a live session. The session
// sends this map exactly once, right after `session.created`, and never
// mutates or resends it.
//
// Deliberate money-safe / privacy shape:
// - output modality is audio only;
// - `semantic_vad` (eagerness `low`) with `create_response: true` makes the
//   server create the one response by itself — the client never sends the
//   FIRST `response.create` (tool continuations and the guardrail replacement
//   are the only allowed client-issued responses);
// - `interrupt_response: true` lets the server itself cancel a response and
//   truncate unplayed audio on a barge-in — the client sends no redundant
//   `response.cancel`/`response.truncate`;
// - `max_output_tokens` is finite (bounds one paid response);
// - `truncation: "disabled"` — on a context overflow the server deletes
//   nothing automatically; this package never silently drops history;
// - `tracing` is explicitly null (disabled) — no content tracing.
//
// Optional input transcription: when (and ONLY when) the app opts in, an
// `audio.input.transcription.model` is added so the SAME direct device → OpenAI
// Realtime session also returns final user transcripts. This is a SEPARATE ASR
// operation billed by OpenAI; no second network call is ever made. When
// disabled, the emitted map carries no transcription key.
//
// Optional tools: when (and ONLY when) [tools] is non-empty, the function
// declarations plus `tool_choice: "auto"` and `parallel_tool_calls: false` are
// added at the session level. When [tools] is empty the map carries none of
// those keys, so the no-tools payload stays semantically the prior shape (aside
// from the always-present `truncation: "disabled"`).
library;

import 'package:chat_ai/chat_ai.dart' show Tool;

/// Builds the exact `session.update` client event from the session's
/// constructor values. The structure is fixed; only [model], [voice],
/// [instructions], [maxOutputTokens], the optional input transcription and the
/// optional [tools] vary.
///
/// [instructions] is the bot's system prompt — carried on the wire only, never
/// logged, never surfaced in state or errors.
///
/// When [transcriptsEnabled] is false (the default) NO `transcription` key is
/// added. When true, `audio.input.transcription.model` is set to
/// [inputTranscriptionModel] and nothing else (no language/prompt/logprobs/
/// include). The caller is responsible for having rejected an empty model
/// synchronously before this builder is ever reached.
///
/// When [tools] is empty (the default) NO `tools`/`tool_choice`/
/// `parallel_tool_calls` keys are added. When non-empty each tool is emitted as
/// `{type: function, name, description, parameters}` (the already-accepted
/// Realtime tool shape) alongside `tool_choice: "auto"` and
/// `parallel_tool_calls: false`. The caller is responsible for having validated
/// the declarations synchronously before this builder is ever reached.
Map<String, Object?> buildRealtimeVoiceSessionUpdate({
  required String model,
  required String voice,
  required String instructions,
  required int maxOutputTokens,
  bool transcriptsEnabled = false,
  String inputTranscriptionModel = 'gpt-4o-mini-transcribe',
  List<Tool> tools = const <Tool>[],
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
  final session = <String, Object?>{
    'type': 'realtime',
    'model': model,
    'output_modalities': <String>['audio'],
    'instructions': instructions,
    'max_output_tokens': maxOutputTokens,
    // On context overflow the server truncates nothing automatically; this
    // package never silently deletes history.
    'truncation': 'disabled',
    'tracing': null,
    'audio': <String, Object?>{
      'input': input,
      'output': <String, Object?>{'voice': voice},
    },
  };
  if (tools.isNotEmpty) {
    session['tools'] = <Map<String, Object?>>[
      for (final tool in tools)
        <String, Object?>{
          'type': 'function',
          'name': tool.name,
          'description': tool.description,
          'parameters': tool.parameters,
        },
    ];
    session['tool_choice'] = 'auto';
    session['parallel_tool_calls'] = false;
  }
  return <String, Object?>{'type': 'session.update', 'session': session};
}
