import 'dart:async';

import 'package:flutter/material.dart';

import '../core/chat_session.dart';
import '../models/content_part.dart';
import '../models/failure.dart';
import '../models/message.dart';
import '../state/conversation_state.dart';
import 'chat_theme.dart';
import 'message_bubble.dart';
import 'widget_contracts.dart';

/// The message list of the active Conversation (V1_SPEC §7,
/// docs/widgets-spec.md): subscribes to `session.states` and
/// `session.tokens` and reads `session.snapshot` on every event.
///
/// Owns the thinking placeholder, the failure row, the resend/regenerate
/// actions, the empty-reply action and **all outer bubble alignment**:
/// assistant/system Messages are left-aligned; user Messages are
/// right-aligned when [ownMessagesRight] is true and left-aligned otherwise
/// ([MessageBubble] never positions itself).
///
/// The list stays glued to the bottom on new Messages/tokens only if the
/// user was already at the bottom; a user who scrolled up is never pulled
/// back down by streaming. The scroll controller is private — no public
/// scroll/controller API in v1.
class ChatMessageList extends StatefulWidget {
  const ChatMessageList({
    super.key,
    required this.session,
    required this.failureText,
    this.theme = const ChatTheme(),
    this.ownMessagesRight = true,
    this.showAvatars = false,
    this.avatarSide = AvatarSide.leading,
    this.timestamps = TimestampPosition.none,
    this.markdown = true,
    this.avatarBuilder,
    this.thinkingBuilder,
    this.errorBuilder,
    this.partBuilder,
    this.emptyReplyBuilder,
    this.onImageTap,
  });

  /// The one open Conversation this list observes.
  final ChatSession session;

  /// The app's `cause → string` mapping — the package ships zero user-facing
  /// strings, so the failure row's text always comes from here (or the app
  /// replaces the row entirely with [errorBuilder], and this is not called).
  final String Function(FailureCause cause) failureText;

  /// Look overrides; null fields derive from the app `Theme` (§7).
  final ChatTheme theme;

  /// User Messages on the right (default) or on the left.
  final bool ownMessagesRight;

  /// Show an avatar next to every bubble (default off).
  final bool showAvatars;

  /// Which side of the bubble the avatar sits on.
  final AvatarSide avatarSide;

  /// Timestamp placement (default none).
  final TimestampPosition timestamps;

  /// Markdown rendering of assistant text (§7); user/system always plain.
  final bool markdown;

  /// Replaces the default `Icons.person` avatar.
  final AvatarBuilder? avatarBuilder;

  /// Replaces the default pulsing `···` placeholder.
  final ThinkingBuilder? thinkingBuilder;

  /// Replaces the failure row entirely; [failureText] is then unused.
  final ErrorBuilder? errorBuilder;

  /// Per-part rendering override, forwarded to every [MessageBubble].
  final PartBuilder? partBuilder;

  /// Replaces the compact regenerate icon-button of an empty reply.
  final EmptyReplyBuilder? emptyReplyBuilder;

  /// Tap on a rendered image part; null = tap does nothing.
  final OnImageTap? onImageTap;

  @override
  State<ChatMessageList> createState() => _ChatMessageListState();
}

class _ChatMessageListState extends State<ChatMessageList> {
  final ScrollController _scrollController = ScrollController();
  StreamSubscription<ConversationState>? _statesSubscription;
  StreamSubscription<String>? _tokensSubscription;

  @override
  void initState() {
    super.initState();
    _subscribe();
    // Open at the latest turn: the very first laid-out frame starts glued to
    // the bottom, like every subsequent at-bottom update.
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
  }

  @override
  void didUpdateWidget(ChatMessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.session, oldWidget.session)) {
      _unsubscribe();
      _subscribe();
    }
  }

  @override
  void dispose() {
    _unsubscribe();
    _scrollController.dispose();
    super.dispose();
  }

  void _subscribe() {
    _statesSubscription = widget.session.states.listen(
      (_) => _onSessionEvent(),
    );
    _tokensSubscription = widget.session.tokens.listen(
      (_) => _onSessionEvent(),
    );
  }

  void _unsubscribe() {
    _statesSubscription?.cancel();
    _statesSubscription = null;
    _tokensSubscription?.cancel();
    _tokensSubscription = null;
  }

  /// Every session event re-reads `session.snapshot`/`session.state` through
  /// a plain rebuild. Sticky-bottom: whether the user sits at the bottom is
  /// decided BEFORE the new content lays out; only then is the (grown) list
  /// glued back — a user who scrolled up is never pulled down.
  void _onSessionEvent() {
    if (!mounted) {
      return;
    }
    final wasAtBottom = _isAtBottom;
    setState(() {});
    if (wasAtBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
    }
  }

  bool get _isAtBottom {
    if (!_scrollController.hasClients) {
      return true;
    }
    final position = _scrollController.position;
    return position.pixels >= position.maxScrollExtent - 1.0;
  }

  void _jumpToBottom() {
    if (!mounted || !_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    if (position.pixels < position.maxScrollExtent) {
      _scrollController.jumpTo(position.maxScrollExtent);
    }
  }

  @override
  Widget build(BuildContext context) {
    checkChatTheme(widget.theme);
    final resolution = ChatThemeResolution.of(context, widget.theme);
    final messages = widget.session.snapshot.messages;
    final state = widget.session.state;

    final rows = <Widget>[];
    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      final isLast = i == messages.length - 1;
      if (_isEmptyReply(context, message)) {
        // A valid empty reply draws no bubble; in its place — the compact
        // regenerate action ("paid = explicit tap"), only at the tail where
        // `regenerate` addresses this reply. An older empty reply stays in
        // history/serialization but renders nothing.
        if (isLast) {
          rows.add(_emptyReplyRow(context, resolution));
        }
        continue;
      }
      rows.add(
        _messageRow(context, resolution, message, isLast: isLast, state: state),
      );
    }
    // Sending and AwaitingTool share one minimal thinking visual (§7: the
    // v1 simplification — AwaitingTool is indistinguishable).
    if (state is Sending || state is AwaitingTool) {
      rows.add(_thinkingRow(context, resolution));
    }
    if (state is Failed) {
      rows.add(_errorRow(context, resolution, state));
    }

    return ColoredBox(
      color: resolution.backgroundColor,
      child: ListView.separated(
        controller: _scrollController,
        padding: resolution.messageListPadding,
        itemCount: rows.length,
        separatorBuilder: (_, _) => SizedBox(height: resolution.messageSpacing),
        itemBuilder: (_, index) => rows[index],
      ),
    );
  }

  /// Mirrors [MessageBubble]'s no-bubble rule exactly: a `complete`
  /// assistant Message whose parts produce no visible rendering — no
  /// text/image, and no tool part the app's [ChatMessageList.partBuilder]
  /// chose to render (`ProviderOpaquePart` is never offered).
  bool _isEmptyReply(BuildContext context, Message message) {
    if (message.role != MessageRole.assistant ||
        message.status != MessageStatus.complete) {
      return false;
    }
    for (final part in message.parts) {
      if (part is TextPart || part is ImagePart) {
        return false;
      }
      if (part is ProviderOpaquePart) {
        continue;
      }
      if (widget.partBuilder?.call(context, message, part) != null) {
        return false;
      }
    }
    return true;
  }

  Widget _messageRow(
    BuildContext context,
    ChatThemeResolution resolution,
    Message message, {
    required bool isLast,
    required ConversationState state,
  }) {
    final leftAligned =
        message.role != MessageRole.user || !widget.ownMessagesRight;

    // The message-attached recovery action (one Core command, no retry
    // logic): resend only on the LAST failed user Message (an older one is
    // a Core no-op and gets no button), regenerate on the LAST interrupted
    // reply. While the state is Failed the failure row carries the action,
    // so the tail bubble never shows a second identical button.
    VoidCallback? action;
    if (isLast && state is! Failed) {
      if (message.role == MessageRole.user &&
          message.status == MessageStatus.failed) {
        action = () {
          widget.session.resend(message.id);
        };
      } else if (message.role == MessageRole.assistant &&
          message.status == MessageStatus.interrupted) {
        action = () {
          widget.session.regenerate();
        };
      }
    }

    final bubble = Flexible(
      child: MessageBubble(
        message: message,
        theme: widget.theme,
        markdown: widget.markdown,
        partBuilder: widget.partBuilder,
        onImageTap: widget.onImageTap,
      ),
    );
    final actionButton = action == null
        ? null
        : IconButton(
            onPressed: action,
            icon: Icon(Icons.refresh, color: resolution.iconColor),
          );
    Widget row = Row(
      mainAxisSize: MainAxisSize.min,
      children: leftAligned ? [bubble, ?actionButton] : [?actionButton, bubble],
    );

    if (widget.timestamps == TimestampPosition.belowBubble) {
      row = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: leftAligned
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.end,
        children: [
          row,
          Text(
            _formatTimestamp(context, message.createdAt),
            style: resolution.timestampTextStyle,
          ),
        ],
      );
    }

    if (widget.showAvatars) {
      final avatar =
          widget.avatarBuilder?.call(context, message.role) ??
          CircleAvatar(
            radius: 16,
            child: Icon(Icons.person, size: 20, color: resolution.iconColor),
          );
      row = Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: widget.avatarSide == AvatarSide.leading
            ? [avatar, Flexible(child: row)]
            : [Flexible(child: row), avatar],
      );
    }

    return Align(
      alignment: leftAligned ? Alignment.centerLeft : Alignment.centerRight,
      child: row,
    );
  }

  /// `createdAt` in local time, formatted by the ambient Flutter/Material
  /// locale — no package-owned format strings.
  String _formatTimestamp(BuildContext context, DateTime createdAt) =>
      MaterialLocalizations.of(context).formatTimeOfDay(
        TimeOfDay.fromDateTime(createdAt.toLocal()),
        alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
      );

  Widget _thinkingRow(BuildContext context, ChatThemeResolution resolution) {
    final indicator =
        widget.thinkingBuilder?.call(context) ??
        Material(
          color: resolution.assistantBubbleColor,
          shape: resolution.assistantBubbleShape,
          child: Padding(
            padding: resolution.bubblePadding,
            child: _PulsingDots(style: resolution.assistantTextStyle),
          ),
        );
    return Align(alignment: Alignment.centerLeft, child: indicator);
  }

  Widget _emptyReplyRow(BuildContext context, ChatThemeResolution resolution) {
    void regenerate() {
      widget.session.regenerate();
    }

    final action =
        widget.emptyReplyBuilder?.call(context, regenerate) ??
        IconButton(
          onPressed: regenerate,
          icon: Icon(Icons.refresh, color: resolution.iconColor),
        );
    return Align(alignment: Alignment.centerLeft, child: action);
  }

  Widget _errorRow(
    BuildContext context,
    ChatThemeResolution resolution,
    Failed failed,
  ) {
    // The row's one action is the Core-computed recovery target of THIS
    // `Failed` (V1_SPEC §7) — never inferred from history: a pre-Message
    // rejection carries `none`, so the row shows the failure without a retry
    // control. One Core command, no retry logic in the widget.
    final recovery = errorRecoveryForWidgets(widget.session);
    final VoidCallback? action;
    switch (recovery.kind) {
      case ChatErrorRecovery.resend:
        final id = recovery.messageId;
        action = id == null ? null : () => widget.session.resend(id);
      case ChatErrorRecovery.regenerate:
        action = () => widget.session.regenerate();
      case ChatErrorRecovery.none:
        action = null;
    }

    final errorBuilder = widget.errorBuilder;
    if (errorBuilder != null) {
      // The app draws the whole failure surface itself; `failureText` is
      // deliberately not consulted. `action` is passed through verbatim —
      // `null` when there is no valid recovery (never a fabricated no-op).
      return Align(
        alignment: Alignment.centerLeft,
        child: errorBuilder(context, failed.cause, action),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 4,
        children: [
          Icon(Icons.error_outline, size: 16, color: resolution.errorColor),
          Flexible(
            child: Text(
              widget.failureText(failed.cause),
              style: resolution.errorTextStyle,
            ),
          ),
          if (action != null)
            IconButton(
              onPressed: action,
              icon: Icon(Icons.refresh, color: resolution.iconColor),
            ),
        ],
      ),
    );
  }
}

/// The minimal thinking visual (§7): one pulsing `···` in the assistant
/// text style — Sending and AwaitingTool render identically.
class _PulsingDots extends StatefulWidget {
  const _PulsingDots({required this.style});

  final TextStyle style;

  @override
  State<_PulsingDots> createState() => _PulsingDotsState();
}

class _PulsingDotsState extends State<_PulsingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _controller.drive(Tween(begin: 0.3, end: 1.0)),
    child: Text('···', style: widget.style),
  );
}
