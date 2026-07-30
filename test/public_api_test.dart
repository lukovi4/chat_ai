// Public-API compile test: it imports ONLY the public entry point — no `src/`
// imports — and references every type this foundation increment exports. If a
// public type stops being exported (or an internal one leaks in), this file
// fails to compile. Also pins the export boundary: the testing-only entry
// stays empty for now and is never re-exported from the main barrel.
import 'dart:io';
import 'dart:typed_data';

import 'package:chat_ai/chat_ai.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final createdAt = DateTime.utc(2026, 7, 10, 9, 15);

  test('persisted models are public', () {
    final conversation = Conversation(
      messages: [
        Message(
          id: 'u-1',
          role: MessageRole.user,
          parts: [
            const ContentPart.text('hi'),
            ContentPart.image(Uint8List.fromList([1])),
          ],
          status: MessageStatus.sent,
          attemptKey: 'k-1',
          createdAt: createdAt,
        ),
      ],
    );
    expect(conversation.schemaVersion, 1);
    // The five sealed cases are addressable as public types, and both
    // spellings construct them (union constructor + case-class constructor).
    expect(const ContentPart.text('t'), isA<TextPart>());
    expect(ImagePart(Uint8List(0)), isA<ContentPart>());
    expect(const ToolCallPart('c', 'n', {}), isA<ContentPart>());
    expect(const ToolResultPart('c', 'ok', false), isA<ContentPart>());
    expect(ProviderOpaquePart('openai', Uint8List(0)), isA<ContentPart>());
    // JSON is on the public surface (Conversation is the read boundary).
    expect(Conversation.fromJson(conversation.toJson()), conversation);
    // Enums are public with their full catalogues.
    expect(MessageRole.values, hasLength(3));
    expect(MessageStatus.values, hasLength(6));
  });

  test('ephemeral state and failure catalogue are public', () {
    const states = <ConversationState>[
      ConversationState.idle(),
      ConversationState.sending(),
      ConversationState.awaitingTool(ToolCall(id: 'c', name: 'n', args: {})),
      ConversationState.streaming(),
      ConversationState.done(usage: Usage(inputTokens: 1, outputTokens: 2)),
      ConversationState.failed(FailureCause.network, FailurePhase.sending),
      ConversationState.cancelled(),
    ];
    expect(states[0], isA<Idle>());
    expect(states[1], isA<Sending>());
    expect(states[2], isA<AwaitingTool>());
    expect(states[3], isA<Streaming>());
    expect(states[4], isA<Done>());
    expect(states[5], isA<Failed>());
    expect(states[6], isA<Cancelled>());
    expect(FailureCause.values, hasLength(10));
    expect(FailurePhase.values, hasLength(2));
  });

  test('configuration values are public', () {
    const profile = BotProfile(
      id: 'premium',
      systemPrompt: 'be kind',
      tools: [Tool(name: 'searchNotes', description: 'd', parameters: {})],
    );
    expect(profile.tools.single.name, 'searchNotes');
    const ToolCall(id: 'c1', name: 'searchNotes', args: {'q': 'x'});
    const ToolResult(content: '3 notes', isError: false);
    const options = ImageSendOptions();
    expect(options.maxImagesPerMessage, 4);
  });

  test(
    'OnToolCall typedef is public with the exact V1_SPEC §5 signature',
    () async {
      // A function with the exact shape is assignable to the typedef…
      Future<ToolResult> resolver(ToolCall call) async =>
          ToolResult(content: 'ran ${call.name}', isError: false);
      final OnToolCall onToolCall = resolver;
      expect(onToolCall, isA<OnToolCall>());
      expect(onToolCall, isA<Future<ToolResult> Function(ToolCall)>());

      // …and invoking it returns a working Future<ToolResult>.
      final Future<ToolResult> pending = onToolCall(
        const ToolCall(id: 'c1', name: 'searchNotes', args: {'q': 'x'}),
      );
      expect(
        await pending,
        const ToolResult(content: 'ran searchNotes', isError: false),
      );
    },
  );

  test('backend boundary types are public', () {
    final request = ChatRequest(
      botId: 'premium',
      system: 'be kind',
      messages: const [],
      tools: const [],
      idempotencyKey: 'key-1',
    );
    expect(request.wireVersion, 1);
    const events = <BackendEvent>[
      BackendEvent.accepted(),
      BackendEvent.delta('t'),
      BackendEvent.toolCall(ToolCall(id: 'c', name: 'n', args: {})),
      BackendEvent.done(),
      BackendEvent.error(FailureCause.upstream),
      BackendEvent.conflict(),
      BackendEvent.gone(),
    ];
    expect(events[0], isA<Accepted>());
    expect(events[1], isA<Delta>());
    expect(events[2], isA<ToolCallEvent>());
    expect(events[3], isA<DoneEvent>());
    expect(events[4], isA<ErrorEvent>());
    expect(events[5], isA<ConflictEvent>());
    expect(events[6], isA<GoneEvent>());
    expect(
      BackendEvent.providerState(ProviderOpaquePart('openai', Uint8List(0))),
      isA<ProviderStateEvent>(),
    );
  });

  test(
    'the optional durable capability is public with its exact shape',
    () async {
      // A backend implementing the capability is assignable to both the legacy
      // `ChatBackend` parameter and the durable contract; the three methods have
      // exactly the approved signatures.
      final backend = _StubDurableBackend();
      final ChatBackend legacy = backend;
      expect(legacy, isA<DurableChatBackend>());
      expect(
        backend.startReply,
        isA<Stream<BackendEvent> Function(String, ChatRequest)>(),
      );
      expect(
        backend.attachReply,
        isA<Future<Stream<BackendEvent>?> Function(String)>(),
      );
      expect(backend.cancelReply, isA<Future<void> Function(String)>());

      // The async entry point: same parameters as the constructor, and with a
      // legacy backend it is the constructor.
      final session = await ChatSession.open(
        backend: _StubBackend(),
        botProfile: const BotProfile(id: 'b', systemPrompt: 's', tools: []),
      );
      expect(session.state, isA<Idle>());
      await session.dispose();
    },
  );

  test('the chat widgets, ChatTheme and the §3/§7 widget contracts are '
      'public with their exact shapes', () async {
    // Enums with their closed §7 catalogues.
    expect(AvatarSide.values, [AvatarSide.leading, AvatarSide.trailing]);
    expect(TimestampPosition.values, [
      TimestampPosition.none,
      TimestampPosition.belowBubble,
    ]);

    // ChatTheme: a const value class whose 20 fields are all assignable.
    const theme = ChatTheme(
      backgroundColor: Color(0xFF000001),
      userBubbleColor: Color(0xFF000002),
      assistantBubbleColor: Color(0xFF000003),
      iconColor: Color(0xFF000004),
      errorColor: Color(0xFF000005),
      inputFillColor: Color(0xFF000006),
      messageListPadding: EdgeInsets.all(1),
      bubblePadding: EdgeInsets.all(2),
      inputBarPadding: EdgeInsets.all(3),
      messageSpacing: 4,
      userTextStyle: TextStyle(fontSize: 10),
      assistantTextStyle: TextStyle(fontSize: 11),
      timestampTextStyle: TextStyle(fontSize: 12),
      errorTextStyle: TextStyle(fontSize: 13),
      inputTextStyle: TextStyle(fontSize: 14),
      hintTextStyle: TextStyle(fontSize: 15),
      userBubbleShape: RoundedRectangleBorder(),
      assistantBubbleShape: StadiumBorder(),
      maxBubbleWidthFactor: 0.9,
      imageThumbnailSize: Size(5, 6),
    );
    expect(theme.maxBubbleWidthFactor, 0.9);
    expect(const ChatTheme().backgroundColor, isNull);

    // The §3 builder/callback typedefs: functions with the exact shapes are
    // assignable to each typedef (the OnToolCall pattern above).
    Widget buildAvatar(BuildContext context, MessageRole role) =>
        const SizedBox();
    final AvatarBuilder avatarBuilder = buildAvatar;
    expect(avatarBuilder, isA<Widget Function(BuildContext, MessageRole)>());
    Widget buildThinking(BuildContext context) => const SizedBox();
    final ThinkingBuilder thinkingBuilder = buildThinking;
    expect(thinkingBuilder, isA<Widget Function(BuildContext)>());
    Widget buildError(
      BuildContext context,
      FailureCause cause,
      VoidCallback? retry,
    ) => const SizedBox();
    final ErrorBuilder errorBuilder = buildError;
    expect(
      errorBuilder,
      isA<Widget Function(BuildContext, FailureCause, VoidCallback?)>(),
    );
    Widget? buildPart(
      BuildContext context,
      Message message,
      ContentPart part,
    ) => null;
    final PartBuilder partBuilder = buildPart;
    expect(
      partBuilder,
      isA<Widget? Function(BuildContext, Message, ContentPart)>(),
    );
    Widget buildEmptyReply(BuildContext context, VoidCallback regenerate) =>
        const SizedBox();
    final EmptyReplyBuilder emptyReplyBuilder = buildEmptyReply;
    expect(
      emptyReplyBuilder,
      isA<Widget Function(BuildContext, VoidCallback)>(),
    );
    Future<List<Uint8List>> pickImages() async => <Uint8List>[];
    final OnAttach onAttach = pickImages;
    expect(onAttach, isA<Future<List<Uint8List>> Function()>());
    Future<String?> dictate() async => null;
    final OnMic onMic = dictate;
    expect(onMic, isA<Future<String?> Function()>());
    void tapImage(Uint8List bytes) {}
    final OnImageTap onImageTap = tapImage;
    expect(onImageTap, isA<void Function(Uint8List)>());

    // The three widgets construct with their full §7 parameter sets.
    final session = ChatSession(
      backend: _StubBackend(),
      botProfile: const BotProfile(id: 'b', systemPrompt: 's', tools: []),
    );
    final bubble = MessageBubble(
      message: Message(
        id: 'a-1',
        role: MessageRole.assistant,
        parts: const [ContentPart.text('hi')],
        status: MessageStatus.complete,
        attemptKey: 'k-1',
        createdAt: createdAt,
      ),
      theme: theme,
      markdown: false,
      partBuilder: partBuilder,
      onImageTap: onImageTap,
    );
    expect(bubble.markdown, isFalse);
    final messageList = ChatMessageList(
      session: session,
      failureText: (cause) => cause.name,
      theme: theme,
      ownMessagesRight: false,
      showAvatars: true,
      avatarSide: AvatarSide.trailing,
      timestamps: TimestampPosition.belowBubble,
      markdown: false,
      avatarBuilder: avatarBuilder,
      thinkingBuilder: thinkingBuilder,
      errorBuilder: errorBuilder,
      partBuilder: partBuilder,
      emptyReplyBuilder: emptyReplyBuilder,
      onImageTap: onImageTap,
    );
    expect(messageList.session, same(session));
    final inputBar = ChatInputBar(
      session: session,
      theme: theme,
      hint: 'ask',
      onAttach: onAttach,
      onMic: onMic,
      maxAttachments: 2,
    );
    expect(inputBar.maxAttachments, 2);
    await session.dispose();
  });

  test('the export boundary keeps internals and testing surface out', () {
    final barrel = File('lib/chat_ai.dart').readAsStringSync();
    // No testing-only surface in the production barrel.
    expect(barrel.contains("export 'testing.dart'"), isFalse);
    expect(barrel.contains('src/testing'), isFalse);
    // Internal helpers stay internal.
    expect(barrel.contains('conversation_invariants'), isFalse);
    expect(barrel.contains('utc_date_time_converter'), isFalse);
    // Production transports moved to the companion adapter packages: the
    // core barrel no longer exports FirebaseChatBackend (or any transport).
    expect(barrel.contains('firebase_chat_backend'), isFalse);
    expect(barrel.contains('firebaseChatBackendForTesting'), isFalse);

    // The Core façade is exported selectively too: the session + checkpoint
    // typedef only — the command-disposition bridge and the internal test
    // seam never reach the public surface (V1_SPEC §3).
    expect(barrel.contains('show ChatSession, ConversationCheckpoint'), isTrue);
    expect(barrel.contains('chatSessionForTesting'), isFalse);
    expect(barrel.contains('sendWithDisposition'), isFalse);
    expect(barrel.contains('ChatCommandDisposition'), isFalse);

    // The widgets are exported selectively: the three widget classes and the
    // ChatTheme value class only — the package-internal theme
    // resolver/validation helpers and the imageOptions bridge never reach
    // the public surface, and no gpt_markdown type leaks through the barrel.
    expect(barrel.contains('show ChatInputBar'), isTrue);
    expect(barrel.contains('show ChatMessageList'), isTrue);
    expect(barrel.contains('show ChatTheme'), isTrue);
    expect(barrel.contains('show MessageBubble'), isTrue);
    expect(
      barrel.contains("export 'src/widgets/widget_contracts.dart'"),
      isTrue,
    );
    expect(barrel.contains('imageOptionsForWidgets'), isFalse);
    expect(barrel.contains('errorRecoveryForWidgets'), isFalse);
    expect(barrel.contains('ChatErrorRecovery'), isFalse);
    expect(barrel.contains('ChatThemeResolution'), isFalse);
    expect(barrel.contains('checkChatTheme'), isFalse);
    expect(barrel.contains('gpt_markdown'), isFalse);

    // The durable extension adds exactly one public type to the barrel: the
    // capability. The Core's durable internals stay unexported.
    expect(
      barrel.contains("export 'src/backend/durable_chat_backend.dart'"),
      isTrue,
    );
    expect(barrel.contains('_startAttachedReply'), isFalse);

    // The testing entry exports exactly the two scriptable fakes (V1_SPEC §10
    // and its durable counterpart) — no capture seam, and never re-exported
    // from the main barrel.
    final testing = File('lib/testing.dart').readAsStringSync();
    expect(
      testing.contains('show FakeChatBackend, FakeDurableChatBackend'),
      isTrue,
    );
    expect(testing.contains('capturedRequestsOf'), isFalse);
    expect(barrel.contains('FakeChatBackend'), isFalse);
    expect(barrel.contains('FakeDurableChatBackend'), isFalse);
  });
}

/// A durable transport stub: the public capability is implementable from the
/// public surface alone (this file imports no `src/` and no testing entry).
class _StubDurableBackend implements DurableChatBackend {
  @override
  Stream<BackendEvent> send(ChatRequest request) => const Stream.empty();

  @override
  Stream<BackendEvent> startReply(String replyId, ChatRequest request) =>
      const Stream.empty();

  @override
  Future<Stream<BackendEvent>?> attachReply(String replyId) async => null;

  @override
  Future<void> cancelReply(String replyId) async {}
}

/// A minimal inert transport: enough to construct a [ChatSession] through
/// the public surface alone — this file deliberately imports no `src/` and
/// no testing entry.
class _StubBackend implements ChatBackend {
  @override
  Stream<BackendEvent> send(ChatRequest request) => const Stream.empty();
}
