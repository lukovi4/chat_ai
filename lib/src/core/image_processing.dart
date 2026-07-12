/// Internal image preprocessing (V1_SPEC §2/§11, CONTEXT §Image Attachment):
/// raw picker bytes → decoded → longest edge capped at
/// [ImageSendOptions.maxLongEdge] (never upscaled) → JPEG re-encode at
/// [ImageSendOptions.jpegQuality]. Not exported from the public barrel.
///
/// The work runs off the UI isolate via `compute`. Malformed/undecodable
/// input throws [FormatException]; the session maps it to
/// `Failed(upstream, sending, "malformed-image")` with no Message/key/
/// checkpoint/backend call (V1_SPEC §4).
///
/// Deliberately nothing else: no EXIF/media/storage/upload abstractions.
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

import '../models/image_send_options.dart';

/// Processes one raw image off the UI isolate.
Future<Uint8List> processChatImage(Uint8List raw, ImageSendOptions options) =>
    compute(_processChatImageJob, (
      raw: raw,
      maxLongEdge: options.maxLongEdge,
      jpegQuality: options.jpegQuality,
    ), debugLabel: 'chat_ai image preprocessing');

/// The isolate entry: decode → cap the longest edge → JPEG. Kept top-level so
/// `compute` can send it to a background isolate.
Uint8List _processChatImageJob(
  ({Uint8List raw, int maxLongEdge, int jpegQuality}) job,
) {
  final img.Image? decoded = img.decodeImage(job.raw);
  if (decoded == null) {
    throw const FormatException('undecodable image bytes');
  }
  img.Image sized = decoded;
  final int longEdge = decoded.width >= decoded.height
      ? decoded.width
      : decoded.height;
  if (longEdge > job.maxLongEdge) {
    sized = decoded.width >= decoded.height
        ? img.copyResize(
            decoded,
            width: job.maxLongEdge,
            interpolation: img.Interpolation.linear,
          )
        : img.copyResize(
            decoded,
            height: job.maxLongEdge,
            interpolation: img.Interpolation.linear,
          );
  }
  return Uint8List.fromList(img.encodeJpg(sized, quality: job.jpegQuality));
}
