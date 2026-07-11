import 'package:freezed_annotation/freezed_annotation.dart';

import '../models/message.dart';
import '../models/tool.dart';

part 'chat_request.freezed.dart';

/// One frozen backend request — a single leg of a reply (V1_SPEC §8).
///
/// [messages] is the assembled context (`[system] + [prior] + [new]`,
/// filtering per V1_SPEC §6) reusing the storage JSON of [Message] on the
/// wire — one serializer, no second mapper. [idempotencyKey] is a UUID v4 per
/// attempt / per leg (ADR 0004) and rides as the `Idempotency-Key` header,
/// not in the body. [wireVersion] is protocol-only and excluded from the
/// provider-effective request/hash (V1_SPEC §6).
///
/// The Core freezes the serialized request for the lifetime of an Attempt:
/// every silent retry re-sends it byte-identical.
@freezed
abstract class ChatRequest with _$ChatRequest {
  const factory ChatRequest({
    @Default(1) int wireVersion,
    required String botId,
    required String system,
    required List<Message> messages,
    required List<Tool> tools,
    required String idempotencyKey,
  }) = _ChatRequest;
}
