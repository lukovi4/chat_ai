// The public declarations of the OPTIONAL local audio-recording side channel.
//
// Recording is OFF by default. When the app opts in, the session writes ONE
// standalone file per spoken reply (never a single mixed session file) for both
// sides and surfaces each finished file — plus any per-side recording failure —
// on the two broadcast streams of [OpenAIRealtimeVoiceSession]. The files are in
// the SAME format as the standard `record_transcribe` speech profile: `.m4a`,
// AAC-LC, 16 kHz, mono, 32 kbit/s.
//
// A recording object carries only a coarse [OpenAIRealtimeVoiceRecordingRole],
// the local [turnId], the app-owned file path, an OPTIONAL final transcript and
// an [interrupted] flag. It deliberately exposes NO provider
// track/item/response/event ids, PCM, timestamps, usage, waveform, native status
// or playback handle. Its `toString()` never reveals the file path or the
// transcript, so the package can never leak either through an accidental log
// line. The package itself never logs or stores a path or a transcript — not
// even in debug/test.
//
// [turnId] is a LOCAL UUID v4 minted by the session (never an OpenAI id): the
// same [turnId] links this reply's recording (or failure) with its transcript
// and delta events.
library;

/// Which side of the conversation a recording (or a recording failure) belongs
/// to.
enum OpenAIRealtimeVoiceRecordingRole {
  /// The user's spoken reply, captured from the local microphone track.
  user,

  /// The assistant's spoken audio response, captured from the remote track.
  assistant,
}

/// One finished, validated audio file for a single spoken reply. Immutable and
/// intentionally minimal.
///
/// The file belongs to the application: the package hands the path over and
/// never deletes a successful file afterwards. The app alone decides whether to
/// play, keep, move or delete it.
class OpenAIRealtimeVoiceRecording {
  const OpenAIRealtimeVoiceRecording({
    required this.role,
    required this.turnId,
    required this.filePath,
    required this.transcript,
    required this.interrupted,
  });

  /// Whether this is the user's or the assistant's file.
  final OpenAIRealtimeVoiceRecordingRole role;

  /// The LOCAL reply id (UUID v4) this recording belongs to — the SAME id
  /// carried by the reply's transcript / delta events (and any recording
  /// failure). Never an OpenAI item/response id.
  final String turnId;

  /// The absolute path of the finished `.m4a` file, inside the directory the
  /// app supplied at construction. Never logged by the package.
  final String filePath;

  /// The final transcript of the SAME reply, or null. It is null whenever
  /// transcripts were disabled, or the transcription failed / timed out, or no
  /// valid transcript for this exact reply arrived. A successfully-received but
  /// empty final transcript is the empty string, not null.
  final String? transcript;

  /// True when the file holds only the fragment actually captured before a
  /// stop, cancel or barge-in cut the reply short; false for a naturally
  /// completed reply.
  final bool interrupted;

  /// A privacy-preserving description: it names the [role], the [turnId], the
  /// [interrupted] flag and only WHETHER a transcript is present — never the file
  /// path or the transcript content, so the package can never leak either
  /// through an accidental `toString()`.
  @override
  String toString() =>
      'OpenAIRealtimeVoiceRecording(role: $role, turnId: $turnId, '
      'interrupted: $interrupted, hasTranscript: ${transcript != null})';
}

/// A single per-side recording failure. It is a SIDE-CHANNEL signal only: it
/// never becomes an [OpenAIRealtimeVoiceState] failure, never ends the voice
/// session, never cancels the Response and never triggers a retry, reconnect or
/// re-mint. A failure for one side never prevents the other side's file.
///
/// It carries only the coarse [role] and the local [turnId] of the reply the
/// failure belongs to; no native status, OSStatus, path or detail is ever
/// attached. A failure is never anonymous — it always names the [turnId] of a
/// specific reply (a side whose native tap failed to attach surfaces its one
/// failure only once a concrete reply begins, tied to that reply's [turnId]).
class OpenAIRealtimeVoiceRecordingFailure {
  const OpenAIRealtimeVoiceRecordingFailure({
    required this.role,
    required this.turnId,
  });

  /// Which side's recording failed.
  final OpenAIRealtimeVoiceRecordingRole role;

  /// The LOCAL reply id (UUID v4) this failure belongs to — the SAME id the
  /// reply's transcript/delta/recording would carry. Never an OpenAI id.
  final String turnId;

  @override
  String toString() =>
      'OpenAIRealtimeVoiceRecordingFailure(role: $role, turnId: $turnId)';
}
