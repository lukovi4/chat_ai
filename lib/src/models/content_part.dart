import 'dart:convert';
import 'dart:typed_data';

import 'package:freezed_annotation/freezed_annotation.dart';

part 'content_part.freezed.dart';

/// One piece of a [Message]'s content (CONTEXT.md §Message, V1_SPEC §5).
///
/// A sealed union with the storage-JSON discriminator `"type"`
/// (`text | image | toolCall | toolResult | providerOpaque`). The `file` kind
/// is reserved in CONTEXT.md but NOT in v1 — it arrives later as a new union
/// case, breaking only strict consumers (V1_SPEC §0).
///
/// JSON is hand-written (not codegen) because the wire shape is pinned exactly:
/// `ImagePart` always serializes as `mimeType: image/jpeg` + base64 `data`,
/// `ProviderOpaquePart.data` is base64, and an unknown `"type"` must be a read
/// error (V1_SPEC §5 "Read policy").
@Freezed(fromJson: false, toJson: false)
sealed class ContentPart with _$ContentPart {
  const ContentPart._();

  /// Visible text (V1_SPEC §5).
  const factory ContentPart.text(String text) = TextPart;

  /// A processed JPEG image, already resized by the Core to the configured
  /// `maxLongEdge` (V1_SPEC §5, §11). Serializes as base64 with the constant
  /// `mimeType: image/jpeg`.
  const factory ContentPart.image(Uint8List bytes) = ImagePart;

  /// The bot's request to run an app Tool; [toolCallId] is the provider's call
  /// id normalized by the backend (the chat_ai_firebase SERVER-CONTRACT §7)
  /// and pairs this part with its [ToolResultPart].
  const factory ContentPart.toolCall(
    String toolCallId,
    String name,
    Map<String, dynamic> args,
  ) = ToolCallPart;

  /// The app's answer to the [ToolCallPart] with the same [toolCallId].
  const factory ContentPart.toolResult(
    String toolCallId,
    String content,
    bool isError,
  ) = ToolResultPart;

  /// Hidden provider-continuity state: persisted, sent back only to the same
  /// [provider] (`openai` or `anthropic`), never rendered/built and never on
  /// the Token Stream (V1_SPEC §5).
  const factory ContentPart.providerOpaque(String provider, Uint8List data) =
      ProviderOpaquePart;

  /// Reads the exact storage JSON of V1_SPEC §5. Unknown JSON *fields* are
  /// ignored by construction (only the pinned keys are read); an unknown
  /// `"type"`, a non-JPEG image `mimeType` or an unknown opaque `provider` is
  /// a read error.
  factory ContentPart.fromJson(Map<String, dynamic> json) {
    final Object? type = json['type'];
    switch (type) {
      case 'text':
        return ContentPart.text(json['text'] as String);
      case 'image':
        final Object? mimeType = json['mimeType'];
        if (mimeType != 'image/jpeg') {
          throw FormatException(
            'ImagePart mimeType must be "image/jpeg", got: $mimeType',
          );
        }
        return ContentPart.image(base64Decode(json['data'] as String));
      case 'toolCall':
        return ContentPart.toolCall(
          json['toolCallId'] as String,
          json['name'] as String,
          (json['args'] as Map<Object?, Object?>).cast<String, dynamic>(),
        );
      case 'toolResult':
        return ContentPart.toolResult(
          json['toolCallId'] as String,
          json['content'] as String,
          json['isError'] as bool,
        );
      case 'providerOpaque':
        final provider = json['provider'] as String;
        if (provider != 'openai' && provider != 'anthropic') {
          throw FormatException(
            'ProviderOpaquePart.provider must be "openai" or "anthropic", '
            'got: "$provider"',
          );
        }
        return ContentPart.providerOpaque(
          provider,
          base64Decode(json['data'] as String),
        );
      default:
        throw FormatException('Unknown ContentPart type: $type');
    }
  }

  /// Writes the exact storage JSON of V1_SPEC §5 (discriminator `"type"`,
  /// base64 binary payloads, constant `mimeType: image/jpeg`).
  Map<String, dynamic> toJson() => switch (this) {
    TextPart(:final text) => {'type': 'text', 'text': text},
    ImagePart(:final bytes) => {
      'type': 'image',
      'mimeType': 'image/jpeg',
      'data': base64Encode(bytes),
    },
    ToolCallPart(:final toolCallId, :final name, :final args) => {
      'type': 'toolCall',
      'toolCallId': toolCallId,
      'name': name,
      'args': args,
    },
    ToolResultPart(:final toolCallId, :final content, :final isError) => {
      'type': 'toolResult',
      'toolCallId': toolCallId,
      'content': content,
      'isError': isError,
    },
    ProviderOpaquePart(:final provider, :final data) => {
      'type': 'providerOpaque',
      'provider': provider,
      'data': base64Encode(data),
    },
  };
}
