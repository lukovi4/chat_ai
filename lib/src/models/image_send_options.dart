import 'package:freezed_annotation/freezed_annotation.dart';

part 'image_send_options.freezed.dart';

/// Per-session image sending knobs (V1_SPEC §5, defaults §11).
///
/// The Core resizes raw picker bytes to [maxLongEdge] px on the longest side,
/// re-encodes as JPEG at [jpegQuality], and enforces [maxImagesPerMessage] as
/// the source of truth (widgets may only lower it). Value-range validation
/// (`ArgumentError`, e.g. `maxImagesPerMessage > 0`) happens at session
/// construction (V1_SPEC §5) and ships with the ChatSession increment.
@freezed
abstract class ImageSendOptions with _$ImageSendOptions {
  const factory ImageSendOptions({
    @Default(2048) int maxLongEdge,
    @Default(85) int jpegQuality,
    @Default(4) int maxImagesPerMessage,
  }) = _ImageSendOptions;
}
