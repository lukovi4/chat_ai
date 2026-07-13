import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/chat_session.dart';
import '../state/conversation_state.dart';
import 'chat_theme.dart';
import 'widget_contracts.dart';

/// The input bar (V1_SPEC §7, docs/widgets-spec.md): owns its draft text and
/// image previews — no public controller/focus/keyboard API in v1.
///
/// Buttons follow the "button in the package, picker in the app" pattern:
/// [onAttach]/[onMic] absent = no button. Send flips to stop
/// (`session.cancel`) in Sending/AwaitingTool/Streaming — every phase where
/// the Core promises cancel. The draft and previews are cleared only on the
/// Core's package-internal `accepted` disposition; a busy/empty no-op and a
/// preprocessing/checkpoint rejection keep both.
class ChatInputBar extends StatefulWidget {
  const ChatInputBar({
    super.key,
    required this.session,
    this.theme = const ChatTheme(),
    this.hint,
    this.onAttach,
    this.onMic,
    this.maxAttachments,
  });

  /// The one open Conversation this bar sends into.
  final ChatSession session;

  /// Look overrides; null fields derive from the app `Theme` (§7).
  final ChatTheme theme;

  /// Input placeholder; null = an empty placeholder, no default text.
  final String? hint;

  /// The app's image picker; null = no attach button.
  final OnAttach? onAttach;

  /// The app's dictation glue; null = no mic button. A non-empty result is
  /// INSERTED at the current selection — never sent automatically.
  final OnMic? onMic;

  /// null = the session's `imageOptions` limit; non-null must be `> 0`
  /// (release-safe [ArgumentError] at build) and may only LOWER that limit:
  /// the effective cap is `min(maxAttachments, session limit)`.
  final int? maxAttachments;

  @override
  State<ChatInputBar> createState() => _ChatInputBarState();
}

class _ChatInputBarState extends State<ChatInputBar> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final List<Uint8List> _previews = [];
  StreamSubscription<ConversationState>? _statesSubscription;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(ChatInputBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.session, oldWidget.session)) {
      _statesSubscription?.cancel();
      _subscribe();
    }
  }

  @override
  void dispose() {
    _statesSubscription?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _subscribe() {
    // The send↔stop toggle tracks the public phase; the draft itself never
    // depends on session state.
    _statesSubscription = widget.session.states.listen((_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  /// Effective attachment cap (§7): `maxAttachments` may only lower the
  /// session's own `maxImagesPerMessage` (the Core re-checks its cap for
  /// direct API calls anyway).
  int get _effectiveCap {
    final sessionCap = imageOptionsForWidgets(
      widget.session,
    ).maxImagesPerMessage;
    final maxAttachments = widget.maxAttachments;
    return maxAttachments == null
        ? sessionCap
        : min(maxAttachments, sessionCap);
  }

  Future<void> _send() async {
    // Capture the initiating session: `sendWithDisposition` awaits
    // preprocessing/checkpoint, and the parent may swap `widget.session`
    // meanwhile. A late completion of the OLD session must never clear the
    // NEW session's draft/previews.
    final session = widget.session;
    final disposition = await sendWithDisposition(
      session,
      _controller.text,
      images: List.of(_previews),
    );
    if (!mounted ||
        !identical(widget.session, session) ||
        disposition != ChatCommandDisposition.accepted) {
      return;
    }
    setState(() {
      _controller.clear();
      _previews.clear();
    });
  }

  Future<void> _attach() async {
    // Capture the initiating session: a late picker result must not land in
    // another session's previews after a `widget.session` swap.
    final session = widget.session;
    final List<Uint8List> picked;
    try {
      picked = await widget.onAttach!();
    } catch (error, stackTrace) {
      // A callback exception keeps the draft/previews and is a developer
      // report, never a chat Failure (§7).
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'chat_ai',
          context: ErrorDescription('while awaiting the onAttach callback'),
        ),
      );
      return;
    }
    if (!mounted || !identical(widget.session, session) || picked.isEmpty) {
      return; // [] = the user cancelled the picker; nothing changes.
    }
    final remaining = _effectiveCap - _previews.length;
    if (remaining <= 0) {
      return;
    }
    // Over the remaining slots: keep the first images in source order.
    setState(() => _previews.addAll(picked.take(remaining)));
  }

  Future<void> _mic() async {
    // Capture the initiating session: a late dictation result must not be
    // inserted into another session's draft after a `widget.session` swap.
    final session = widget.session;
    final String? dictated;
    try {
      dictated = await widget.onMic!();
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'chat_ai',
          context: ErrorDescription('while awaiting the onMic callback'),
        ),
      );
      return;
    }
    if (!mounted ||
        !identical(widget.session, session) ||
        dictated == null ||
        dictated.isEmpty) {
      return;
    }
    // Insert at the current selection (replacing it), cursor after the
    // insert — mic never sends automatically.
    final value = _controller.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    _controller.value = TextEditingValue(
      text: value.text.replaceRange(selection.start, selection.end, dictated),
      selection: TextSelection.collapsed(
        offset: selection.start + dictated.length,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    checkChatTheme(widget.theme);
    final maxAttachments = widget.maxAttachments;
    if (maxAttachments != null && maxAttachments < 1) {
      throw ArgumentError.value(
        maxAttachments,
        'maxAttachments',
        'must be > 0',
      );
    }
    final resolution = ChatThemeResolution.of(context, widget.theme);
    final busy = switch (widget.session.state) {
      Sending() || AwaitingTool() || Streaming() => true,
      _ => false,
    };

    return Padding(
      padding: resolution.inputBarPadding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          if (_previews.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 8,
                children: [
                  for (var i = 0; i < _previews.length; i++)
                    _preview(i, resolution),
                ],
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (widget.onAttach != null)
                IconButton(
                  onPressed: _attach,
                  icon: Icon(Icons.attach_file, color: resolution.iconColor),
                ),
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  style: resolution.inputTextStyle,
                  minLines: 1,
                  maxLines: 5,
                  decoration: InputDecoration(
                    hintText: widget.hint ?? '',
                    hintStyle: resolution.hintTextStyle,
                    filled: true,
                    fillColor: resolution.inputFillColor,
                    isDense: true,
                    border: const OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(24)),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              if (widget.onMic != null)
                IconButton(
                  onPressed: _mic,
                  icon: Icon(Icons.mic, color: resolution.iconColor),
                ),
              if (busy)
                IconButton(
                  onPressed: widget.session.cancel,
                  icon: Icon(Icons.stop, color: resolution.iconColor),
                )
              else
                IconButton(
                  onPressed: _send,
                  icon: Icon(Icons.send, color: resolution.iconColor),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _preview(int index, ChatThemeResolution resolution) => Stack(
    children: [
      SizedBox(
        width: resolution.imageThumbnailSize.width,
        height: resolution.imageThumbnailSize.height,
        child: Image.memory(_previews[index], fit: BoxFit.cover),
      ),
      Positioned(
        top: 0,
        right: 0,
        child: IconButton(
          onPressed: () => setState(() => _previews.removeAt(index)),
          icon: Icon(Icons.close, color: resolution.iconColor),
        ),
      ),
    ],
  );
}
