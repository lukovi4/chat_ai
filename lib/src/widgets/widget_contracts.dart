import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../models/content_part.dart';
import '../models/failure.dart';
import '../models/message.dart';

/// Which side of a bubble the avatar sits on (V1_SPEC §7).
enum AvatarSide { leading, trailing }

/// Where a Message's `createdAt` is shown (V1_SPEC §7): [none] shows
/// nothing; [belowBubble] shows local time in the ambient Flutter/Material
/// locale format.
enum TimestampPosition { none, belowBubble }

/// Replaces the default `Icons.person` avatar for [MessageRole] (V1_SPEC §3).
typedef AvatarBuilder = Widget Function(BuildContext, MessageRole);

/// Replaces the default pulsing `···` thinking placeholder (V1_SPEC §3).
typedef ThinkingBuilder = Widget Function(BuildContext);

/// Replaces the failure row entirely (V1_SPEC §3/§7): the app draws its own
/// error UI off the machine [FailureCause]. [retry] is the row's one Core
/// action (resend/regenerate, per the current `Failed`'s recovery target) —
/// **`null` means there is no valid recovery** (a pre-Message rejection), so
/// the app shows no retry control. The package never passes a no-op callback.
typedef ErrorBuilder =
    Widget Function(BuildContext, FailureCause, VoidCallback? retry);

/// Replaces the rendering of one [ContentPart] (V1_SPEC §3/§7): every
/// `TextPart`/`ImagePart`/`ToolCallPart`/`ToolResultPart` is offered here
/// first; return null = "use the default rendering" (the tool parts' default
/// is hidden). `ProviderOpaquePart` is never offered.
typedef PartBuilder = Widget? Function(BuildContext, Message, ContentPart);

/// Replaces the compact regenerate icon-button drawn in place of an empty
/// `complete` reply (V1_SPEC §3/§7).
typedef EmptyReplyBuilder =
    Widget Function(BuildContext, VoidCallback regenerate);

/// The app's image picker (V1_SPEC §3): returns raw picker bytes;
/// `[]` = user cancelled the picker.
typedef OnAttach = Future<List<Uint8List>> Function();

/// The app's dictation glue (V1_SPEC §3): `null` = nothing dictated; a
/// non-empty result is inserted at the input's selection, never sent.
typedef OnMic = Future<String?> Function();

/// Tap on a rendered image part (V1_SPEC §3): full-screen viewing is the
/// app's; `null` on the widget = tap does nothing.
typedef OnImageTap = void Function(Uint8List bytes);
