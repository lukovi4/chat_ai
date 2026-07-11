import 'package:freezed_annotation/freezed_annotation.dart';

import 'conversation_invariants.dart';
import 'message.dart';

part 'conversation.freezed.dart';

/// The persisted snapshot the app stores (ADR 0002, V1_SPEC §5): a schema
/// version plus the ordered [messages]. Deliberately has **no id** — identity
/// and keys of stored conversations are the app's; the app wraps this snapshot
/// in its own record.
///
/// JSON is hand-written (not codegen) because `fromJson` is the v1 read
/// boundary: it accepts `schemaVersion == 1` only, wraps every decode failure
/// in a [FormatException], and checks all V1_SPEC §5 invariants before
/// returning. Bumping the version is a deliberate act with a migration note.
@Freezed(fromJson: false, toJson: false)
abstract class Conversation with _$Conversation {
  const Conversation._();

  const factory Conversation({
    @Default(1) int schemaVersion,
    required List<Message> messages,
  }) = _Conversation;

  /// The invariant-checked v1 reader (V1_SPEC §5 "Read policy").
  ///
  /// Unknown JSON *fields* are ignored; an unknown part `"type"`, `role`,
  /// `status`, a `schemaVersion != 1` or a violated invariant throws
  /// [FormatException].
  factory Conversation.fromJson(Map<String, dynamic> json) {
    final Object? version = json['schemaVersion'];
    if (version != 1) {
      throw FormatException(
        'Unsupported Conversation schemaVersion: $version '
        '(the v1 reader accepts 1 only)',
      );
    }
    final List<Message> messages;
    try {
      messages = [
        for (final Object? raw in json['messages'] as List<Object?>)
          Message.fromJson(raw as Map<String, dynamic>),
      ];
    } on FormatException {
      rethrow;
    } catch (error) {
      // At the read boundary a bad cast / unknown enum value is malformed
      // *data*, not a programming error — normalize to FormatException.
      throw FormatException('Malformed Conversation JSON: $error');
    }
    final conversation = Conversation(messages: messages);
    checkConversationInvariants(conversation);
    return conversation;
  }

  /// Storage JSON per V1_SPEC §5 (`schemaVersion` + `messages`).
  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'messages': [for (final message in messages) message.toJson()],
  };
}
