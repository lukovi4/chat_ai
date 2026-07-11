import 'package:freezed_annotation/freezed_annotation.dart';

import '../models/failure.dart';
import '../models/tool.dart';
import '../models/usage.dart';

part 'conversation_state.freezed.dart';

/// The session's coarse public phase (CONTEXT.md §Conversation State,
/// V1_SPEC §4/§5). Ephemeral — never serialized.
///
/// ```
/// Idle → Sending → Streaming → Done
///             ↑               ↘ Failed / Cancelled
///             └── AwaitingTool ←┘
/// ```
///
/// [Done] / [Failed] / [Cancelled] are terminal **for the current reply
/// only**; any command re-enters [Sending]. A sealed union: adding a phase
/// breaks only strict consumers, soft ones (a default branch) are unaffected
/// (V1_SPEC §0).
///
/// `copyWith` is off: the spec-pinned field name `call` (V1_SPEC §5) collides
/// with the generated copyWith's `call` method, and phases are consumed via
/// pattern matching, never edited.
@Freezed(copyWith: false)
sealed class ConversationState with _$ConversationState {
  /// No reply in flight (also the constructed state).
  const factory ConversationState.idle() = Idle;

  /// A command is dispatched; no token has arrived yet.
  const factory ConversationState.sending() = Sending;

  /// The bot requested an app Tool; the app's `onToolCall` is running.
  const factory ConversationState.awaitingTool(ToolCall call) = AwaitingTool;

  /// Tokens are arriving on the Token Stream.
  const factory ConversationState.streaming() = Streaming;

  /// Terminal: the reply is complete. [usage] is the SUM over all legs of the
  /// reply (V1_SPEC §8); `usageRaw` is kept only for single-leg replies.
  const factory ConversationState.done({Usage? usage}) = Done;

  /// Terminal: a failure surfaced as data — the machine [cause], the
  /// [phase] it broke in, and an optional raw [developerDetail] for logs
  /// only, never shown to the user.
  const factory ConversationState.failed(
    FailureCause cause,
    FailurePhase phase, {
    String? developerDetail,
  }) = Failed;

  /// Terminal: the user cancelled; any streamed partial is kept.
  const factory ConversationState.cancelled() = Cancelled;
}
