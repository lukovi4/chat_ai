import 'package:freezed_annotation/freezed_annotation.dart';

import 'content_part.dart';
import 'utc_date_time_converter.dart';

part 'message.freezed.dart';
part 'message.g.dart';

/// Who authored a [Message] (V1_SPEC §5). There is NO `tool` role in v1: tool
/// calls and results live as parts *inside* the assistant Message, so history
/// can never separate a call from its result.
enum MessageRole { user, assistant, system }

/// Lifecycle of a single [Message] (CONTEXT.md §Message Status, V1_SPEC §5).
///
/// `sending | sent | failed` belong to `user` Messages,
/// `streaming | complete | interrupted` to `assistant` Messages; `system`
/// Messages are always `complete`. Enum names are the exact wire strings.
enum MessageStatus { sending, sent, failed, streaming, complete, interrupted }

/// One turn of the Conversation (V1_SPEC §5).
///
/// [id] is a UUID v4 minted by the Core at creation — the address for
/// `resend(id)` / `editAndResend(id, …)` and the app's own UI/DB row key; a
/// loaded history must carry it. [attemptKey] is the persisted
/// Idempotency-Key: the send's key on a user Message, the current/last leg's
/// key on an assistant Message; `null` only on `system` Messages (and omitted
/// from JSON when null). [createdAt] is stamped by the Core and stored as
/// ISO-8601 UTC.
@freezed
abstract class Message with _$Message {
  // The constructor is where freezed reads json_serializable config; the
  // analyzer does not know that (freezed's documented pattern).
  // ignore: invalid_annotation_target
  @JsonSerializable(explicitToJson: true)
  const factory Message({
    required String id,
    required MessageRole role,
    required List<ContentPart> parts,
    required MessageStatus status,
    @JsonKey(includeIfNull: false) String? attemptKey,
    @UtcDateTimeConverter() required DateTime createdAt,
  }) = _Message;

  /// Storage JSON per V1_SPEC §5. Unknown fields are ignored; unknown `role` /
  /// `status` / part `type` values are read errors. The *invariant-checked*
  /// read boundary is `Conversation.fromJson` — this raw reader is also reused
  /// verbatim by the wire request (§6: one serializer, no second mapper).
  factory Message.fromJson(Map<String, dynamic> json) =>
      _$MessageFromJson(json);
}
