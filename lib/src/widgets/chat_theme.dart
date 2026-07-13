import 'package:flutter/material.dart';

/// The look of the three chat widgets (V1_SPEC §7): a plain immutable
/// **const** value class — no codegen, no `copyWith`, no `ThemeExtension`.
///
/// Every field is nullable; null = derived from the app `Theme` at build
/// time (the exact defaults are the §7 table, resolved by the package-
/// internal [ChatThemeResolution]). There are no separate text-color fields
/// (color rides in the `TextStyle`s) and no tail/animation/icon/controller/
/// scroll fields — a bubble tail is a custom [ShapeBorder].
///
/// Constraint violations (`0 < maxBubbleWidthFactor <= 1`,
/// `messageSpacing >= 0`, `imageThumbnailSize` sides `> 0`) throw
/// [ArgumentError] during widget build, before rendering or invoking any
/// callback — identically in debug and release, never a debug-only `assert`
/// or a silent clamp.
@immutable
class ChatTheme {
  const ChatTheme({
    this.backgroundColor,
    this.userBubbleColor,
    this.assistantBubbleColor,
    this.iconColor,
    this.errorColor,
    this.inputFillColor,
    this.messageListPadding,
    this.bubblePadding,
    this.inputBarPadding,
    this.messageSpacing,
    this.userTextStyle,
    this.assistantTextStyle,
    this.timestampTextStyle,
    this.errorTextStyle,
    this.inputTextStyle,
    this.hintTextStyle,
    this.userBubbleShape,
    this.assistantBubbleShape,
    this.maxBubbleWidthFactor,
    this.imageThumbnailSize,
  });

  /// Message-list background. Null = `colorScheme.surface`.
  final Color? backgroundColor;

  /// User bubble fill. Null = `colorScheme.primaryContainer`.
  final Color? userBubbleColor;

  /// Assistant (and system) bubble fill. Null =
  /// `colorScheme.surfaceContainerHighest`.
  final Color? assistantBubbleColor;

  /// Built-in action/marker icons. Null = `colorScheme.onSurfaceVariant`.
  final Color? iconColor;

  /// Failure icon/marker color. Null = `colorScheme.error`.
  final Color? errorColor;

  /// Input field fill. Null = `colorScheme.surfaceContainerHighest`.
  final Color? inputFillColor;

  /// Around the whole message list. Null = `EdgeInsets.all(12)`.
  final EdgeInsetsGeometry? messageListPadding;

  /// Inside every bubble. Null =
  /// `EdgeInsets.symmetric(horizontal: 12, vertical: 8)`.
  final EdgeInsetsGeometry? bubblePadding;

  /// Around the input bar. Null = `EdgeInsets.all(8)`.
  final EdgeInsetsGeometry? inputBarPadding;

  /// Vertical gap between messages. Null = `8`; must be `>= 0`.
  final double? messageSpacing;

  /// User text. Null = `textTheme.bodyMedium` + `onPrimaryContainer`.
  final TextStyle? userTextStyle;

  /// Assistant (and system) text. Null = `textTheme.bodyMedium` +
  /// `onSurface`.
  final TextStyle? assistantTextStyle;

  /// Timestamps. Null = `textTheme.bodySmall` + `onSurfaceVariant`.
  final TextStyle? timestampTextStyle;

  /// The failure row's text. Null = `textTheme.bodySmall` + `error`.
  final TextStyle? errorTextStyle;

  /// Input field text. Null = `textTheme.bodyLarge` + `onSurface`.
  final TextStyle? inputTextStyle;

  /// Input placeholder text. Null = `textTheme.bodyLarge` +
  /// `onSurfaceVariant`.
  final TextStyle? hintTextStyle;

  /// User bubble shape (a tail = a custom shape). Null =
  /// `RoundedRectangleBorder`, radius 16.
  final ShapeBorder? userBubbleShape;

  /// Assistant (and system) bubble shape. Null = `RoundedRectangleBorder`,
  /// radius 16.
  final ShapeBorder? assistantBubbleShape;

  /// Bubble max width as a share of the available width. Null = `0.8`;
  /// must satisfy `0 < maxBubbleWidthFactor <= 1`.
  final double? maxBubbleWidthFactor;

  /// Rendered image thumbnails (bubbles and input previews). Null =
  /// `Size(160, 160)`; both sides must be `> 0`.
  final Size? imageThumbnailSize;
}

/// Package-internal release-safe validation (V1_SPEC §7): called by every
/// package widget at the top of `build`, before any rendering or callback.
/// Never exported from `package:chat_ai/chat_ai.dart`.
void checkChatTheme(ChatTheme theme) {
  final maxBubbleWidthFactor = theme.maxBubbleWidthFactor;
  if (maxBubbleWidthFactor != null &&
      !(maxBubbleWidthFactor > 0 && maxBubbleWidthFactor <= 1)) {
    throw ArgumentError.value(
      maxBubbleWidthFactor,
      'maxBubbleWidthFactor',
      'must satisfy 0 < maxBubbleWidthFactor <= 1',
    );
  }
  final messageSpacing = theme.messageSpacing;
  if (messageSpacing != null && !(messageSpacing >= 0)) {
    throw ArgumentError.value(messageSpacing, 'messageSpacing', 'must be >= 0');
  }
  final imageThumbnailSize = theme.imageThumbnailSize;
  if (imageThumbnailSize != null &&
      !(imageThumbnailSize.width > 0 && imageThumbnailSize.height > 0)) {
    throw ArgumentError.value(
      imageThumbnailSize,
      'imageThumbnailSize',
      'width and height must be > 0',
    );
  }
}

/// Package-internal resolution of the §7 null-defaults against the ambient
/// [Theme]: one non-null value per [ChatTheme] field, computed at build
/// time. A minimal value holder — no logic beyond the defaults table; never
/// exported from `package:chat_ai/chat_ai.dart`.
class ChatThemeResolution {
  factory ChatThemeResolution.of(BuildContext context, ChatTheme theme) {
    final themeData = Theme.of(context);
    final colors = themeData.colorScheme;
    final text = themeData.textTheme;
    final bodyMedium = text.bodyMedium ?? const TextStyle();
    final bodySmall = text.bodySmall ?? const TextStyle();
    final bodyLarge = text.bodyLarge ?? const TextStyle();
    return ChatThemeResolution._(
      backgroundColor: theme.backgroundColor ?? colors.surface,
      userBubbleColor: theme.userBubbleColor ?? colors.primaryContainer,
      assistantBubbleColor:
          theme.assistantBubbleColor ?? colors.surfaceContainerHighest,
      iconColor: theme.iconColor ?? colors.onSurfaceVariant,
      errorColor: theme.errorColor ?? colors.error,
      inputFillColor: theme.inputFillColor ?? colors.surfaceContainerHighest,
      messageListPadding: theme.messageListPadding ?? const EdgeInsets.all(12),
      bubblePadding:
          theme.bubblePadding ??
          const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      inputBarPadding: theme.inputBarPadding ?? const EdgeInsets.all(8),
      messageSpacing: theme.messageSpacing ?? 8,
      userTextStyle:
          theme.userTextStyle ??
          bodyMedium.copyWith(color: colors.onPrimaryContainer),
      assistantTextStyle:
          theme.assistantTextStyle ??
          bodyMedium.copyWith(color: colors.onSurface),
      timestampTextStyle:
          theme.timestampTextStyle ??
          bodySmall.copyWith(color: colors.onSurfaceVariant),
      errorTextStyle:
          theme.errorTextStyle ?? bodySmall.copyWith(color: colors.error),
      inputTextStyle:
          theme.inputTextStyle ?? bodyLarge.copyWith(color: colors.onSurface),
      hintTextStyle:
          theme.hintTextStyle ??
          bodyLarge.copyWith(color: colors.onSurfaceVariant),
      userBubbleShape: theme.userBubbleShape ?? _defaultBubbleShape,
      assistantBubbleShape: theme.assistantBubbleShape ?? _defaultBubbleShape,
      maxBubbleWidthFactor: theme.maxBubbleWidthFactor ?? 0.8,
      imageThumbnailSize: theme.imageThumbnailSize ?? const Size(160, 160),
    );
  }

  const ChatThemeResolution._({
    required this.backgroundColor,
    required this.userBubbleColor,
    required this.assistantBubbleColor,
    required this.iconColor,
    required this.errorColor,
    required this.inputFillColor,
    required this.messageListPadding,
    required this.bubblePadding,
    required this.inputBarPadding,
    required this.messageSpacing,
    required this.userTextStyle,
    required this.assistantTextStyle,
    required this.timestampTextStyle,
    required this.errorTextStyle,
    required this.inputTextStyle,
    required this.hintTextStyle,
    required this.userBubbleShape,
    required this.assistantBubbleShape,
    required this.maxBubbleWidthFactor,
    required this.imageThumbnailSize,
  });

  static const ShapeBorder _defaultBubbleShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(16)),
  );

  final Color backgroundColor;
  final Color userBubbleColor;
  final Color assistantBubbleColor;
  final Color iconColor;
  final Color errorColor;
  final Color inputFillColor;
  final EdgeInsetsGeometry messageListPadding;
  final EdgeInsetsGeometry bubblePadding;
  final EdgeInsetsGeometry inputBarPadding;
  final double messageSpacing;
  final TextStyle userTextStyle;
  final TextStyle assistantTextStyle;
  final TextStyle timestampTextStyle;
  final TextStyle errorTextStyle;
  final TextStyle inputTextStyle;
  final TextStyle hintTextStyle;
  final ShapeBorder userBubbleShape;
  final ShapeBorder assistantBubbleShape;
  final double maxBubbleWidthFactor;
  final Size imageThumbnailSize;
}
