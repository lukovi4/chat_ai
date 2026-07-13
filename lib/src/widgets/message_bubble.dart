import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../models/content_part.dart';
import '../models/message.dart';
import 'chat_theme.dart';
import 'widget_contracts.dart';

/// Renders exactly one [Message] — its visible ContentParts and status
/// markers — and implements Copy (V1_SPEC §7, docs/widgets-spec.md).
///
/// Standalone boundaries: holds no `ChatSession` and never shows the failure
/// row, the thinking placeholder, resend/regenerate or the empty-reply
/// action; a `complete` assistant Message with no visible content draws no
/// bubble at all. A `system` Message renders as plain text in the assistant
/// visual style. Owns **no outer alignment** — it never wraps itself in
/// `Align`/a positioning `Row`; when used standalone, its parent positions
/// it (`ChatMessageList` owns all outer bubble alignment).
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    this.theme = const ChatTheme(),
    this.markdown = true,
    this.partBuilder,
    this.onImageTap,
  });

  /// The one Message to render.
  final Message message;

  /// Look overrides; null fields derive from the app `Theme` (§7).
  final ChatTheme theme;

  /// Markdown rendering of assistant `TextPart`s via `gpt_markdown`
  /// (default). `false` = plain text. User and system text is always plain.
  final bool markdown;

  /// Offered every visible/tool part first; null return = default rendering
  /// (the tool parts' default is hidden). Never sees `ProviderOpaquePart`.
  final PartBuilder? partBuilder;

  /// Tap on a rendered image part; null = tap does nothing.
  final OnImageTap? onImageTap;

  @override
  Widget build(BuildContext context) {
    checkChatTheme(theme);
    final resolution = ChatThemeResolution.of(context, theme);

    final children = <Widget>[];
    for (final part in message.parts) {
      // Hidden provider-continuity state: never rendered AND never offered
      // to the partBuilder (V1_SPEC §7).
      if (part is ProviderOpaquePart) {
        continue;
      }
      final custom = partBuilder?.call(context, message, part);
      if (custom != null) {
        children.add(custom);
        continue;
      }
      switch (part) {
        case TextPart(:final text):
          children.add(_textPart(text, resolution));
        case ImagePart(:final bytes):
          children.add(_imagePart(bytes, resolution));
        // Machine exchange, not bot text: hidden unless the app's
        // partBuilder chose to render it.
        case ToolCallPart():
        case ToolResultPart():
        case ProviderOpaquePart():
          break;
      }
    }

    // A valid empty reply (Done with nothing visible) draws no bubble; the
    // empty-reply action belongs to ChatMessageList, not here.
    if (message.role == MessageRole.assistant &&
        message.status == MessageStatus.complete &&
        children.isEmpty) {
      return const SizedBox.shrink();
    }

    final isUser = message.role == MessageRole.user;
    if (isUser && message.status == MessageStatus.failed) {
      children.add(
        Icon(Icons.error_outline, size: 16, color: resolution.errorColor),
      );
    }
    if (message.role == MessageRole.assistant &&
        message.status == MessageStatus.interrupted) {
      children.add(
        Icon(Icons.stop_circle_outlined, size: 16, color: resolution.iconColor),
      );
    }

    Widget bubble = Material(
      color: isUser
          ? resolution.userBubbleColor
          : resolution.assistantBubbleColor,
      shape: isUser
          ? resolution.userBubbleShape
          : resolution.assistantBubbleShape,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: resolution.bubblePadding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 4,
          children: children,
        ),
      ),
    );

    // Copy (§7): long-press joins the visible TextParts in order with "\n",
    // source text as-is (markdown included); image/tool/opaque parts are
    // never copied; no visible text = a no-op.
    final copyText = [
      for (final part in message.parts)
        if (part is TextPart) part.text,
    ].join('\n');
    bubble = GestureDetector(
      onLongPress: copyText.isEmpty
          ? null
          : () => Clipboard.setData(ClipboardData(text: copyText)),
      child: bubble,
    );

    // The `sending` marker: the bubble is dimmed until the send is accepted.
    if (isUser && message.status == MessageStatus.sending) {
      bubble = Opacity(opacity: 0.6, child: bubble);
    }

    // Cap the bubble at maxBubbleWidthFactor of the available width; the
    // bubble still sizes to its content below the cap.
    return LayoutBuilder(
      builder: (context, constraints) => ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: constraints.maxWidth.isFinite
              ? constraints.maxWidth * resolution.maxBubbleWidthFactor
              : double.infinity,
        ),
        child: bubble,
      ),
    );
  }

  Widget _textPart(String text, ChatThemeResolution resolution) {
    // Markdown applies ONLY to assistant TextParts (§7); user text is always
    // plain (accidental `*` must not become markup) and system text renders
    // plain in the assistant visual style.
    if (message.role == MessageRole.assistant && markdown) {
      return GptMarkdown(text, style: resolution.assistantTextStyle);
    }
    return Text(
      text,
      style: message.role == MessageRole.user
          ? resolution.userTextStyle
          : resolution.assistantTextStyle,
    );
  }

  Widget _imagePart(Uint8List bytes, ChatThemeResolution resolution) {
    final image = SizedBox(
      width: resolution.imageThumbnailSize.width,
      height: resolution.imageThumbnailSize.height,
      child: Image.memory(bytes, fit: BoxFit.cover),
    );
    final onImageTap = this.onImageTap;
    if (onImageTap == null) {
      return image;
    }
    return GestureDetector(onTap: () => onImageTap(bytes), child: image);
  }
}
