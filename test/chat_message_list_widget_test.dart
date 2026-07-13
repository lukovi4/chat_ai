// ChatMessageList widget contract (V1_SPEC §7, docs/widgets-spec.md): the
// session-observing list — state visuals, outer alignment, avatars,
// timestamps, the failure row, the tail recovery actions, the empty-reply
// action and the sticky-bottom scroll rule.
import 'dart:async';
import 'dart:typed_data';

import 'package:chat_ai/chat_ai.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_session_test_utils.dart';

const Tool searchTool = Tool(
  name: 'searchNotes',
  description: 'search the notes DB',
  parameters: {
    'type': 'object',
    'properties': {
      'period': {'type': 'string'},
    },
    'required': ['period'],
    'additionalProperties': false,
  },
);

String failureLabel(FailureCause cause) => 'failure:${cause.name}';

/// A 1×1 transparent PNG — enough bytes for a malformed-image regression send
/// (the processor is stubbed to throw, so the bytes are never decoded).
final Uint8List onePixelPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, //
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, //
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

/// A processor that fails every image — drives the Core's pre-Message
/// malformed-image rejection (`Failed(upstream, sending)` with no Message).
Future<Uint8List> Function(Uint8List, ImageSendOptions) throwingProcessor() =>
    (raw, options) async => throw const FormatException('bad image');

Widget wrapList(Widget list) => MaterialApp(home: Scaffold(body: list));

Finder bubbleOf(String text) =>
    find.ancestor(of: find.text(text), matching: find.byType(MessageBubble));

void main() {
  late FakeChatBackend fake;
  ChatSession? session;

  setUp(() {
    fake = FakeChatBackend();
    session = null;
  });

  tearDown(() {
    // Deliberately not awaited: the synchronous prefix of dispose() already
    // cancels every timer and backend subscription, and after the FakeAsync
    // test body has ended nobody can pump the cross-zone stream-close
    // microtasks its Future waits on — awaiting it here would hang.
    unawaited(session?.dispose() ?? Future<void>.value());
  });

  ChatSession openSession({
    Conversation? history,
    BotProfile botProfile = plainProfile,
    OnToolCall? onToolCall,
  }) => session = ChatSession(
    backend: fake,
    botProfile: botProfile,
    onToolCall: onToolCall,
    history: history,
  );

  ChatMessageList list(
    ChatSession session, {
    ChatTheme theme = const ChatTheme(),
    bool ownMessagesRight = true,
    bool showAvatars = false,
    AvatarSide avatarSide = AvatarSide.leading,
    TimestampPosition timestamps = TimestampPosition.none,
    bool markdown = false,
    AvatarBuilder? avatarBuilder,
    ThinkingBuilder? thinkingBuilder,
    ErrorBuilder? errorBuilder,
    PartBuilder? partBuilder,
    EmptyReplyBuilder? emptyReplyBuilder,
  }) => ChatMessageList(
    session: session,
    failureText: failureLabel,
    theme: theme,
    ownMessagesRight: ownMessagesRight,
    showAvatars: showAvatars,
    avatarSide: avatarSide,
    timestamps: timestamps,
    markdown: markdown,
    avatarBuilder: avatarBuilder,
    thinkingBuilder: thinkingBuilder,
    errorBuilder: errorBuilder,
    partBuilder: partBuilder,
    emptyReplyBuilder: emptyReplyBuilder,
  );

  group('state visuals', () {
    testWidgets('Idle renders the loaded history as bubbles', (tester) async {
      final session = openSession(
        history: Conversation(
          messages: [
            systemMessage('s-1', 'be kind'),
            userMessage('u-1', 'question'),
            assistantMessage('a-1', 'answer'),
          ],
        ),
      );
      await tester.pumpWidget(wrapList(list(session)));
      expect(find.byType(MessageBubble), findsNWidgets(3));
      expect(find.text('question'), findsOneWidget);
      expect(find.text('answer'), findsOneWidget);
      expect(find.text('···'), findsNothing);
      expect(find.byIcon(Icons.refresh), findsNothing);
    });

    testWidgets('Sending shows the pulsing ··· placeholder; a cancel there '
        'keeps the sent user Message with no failure row', (tester) async {
      fake.reply('late', tokenDelay: const Duration(seconds: 50));
      final session = openSession();
      await tester.pumpWidget(wrapList(list(session)));
      await session.send('hi');
      await tester.pump();
      expect(session.state, isA<Sending>());
      expect(find.text('···'), findsOneWidget);

      session.cancel();
      await tester.pump();
      expect(session.state, isA<Cancelled>());
      expect(find.text('···'), findsNothing);
      expect(find.textContaining('failure:'), findsNothing);
      expect(find.text('hi'), findsOneWidget);
    });

    testWidgets('streaming text grows out of tokens/snapshot and lands on '
        'Done with no placeholder left', (tester) async {
      fake.reply(
        'alpha beta gamma',
        tokenDelay: const Duration(milliseconds: 50),
      );
      final session = openSession();
      await tester.pumpWidget(wrapList(list(session)));
      await session.send('go');
      await tester.pump();
      expect(find.text('···'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 60));
      expect(session.state, isA<Streaming>());
      expect(find.text('alpha '), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 300));
      expect(session.state, isA<Done>());
      expect(find.text('alpha beta gamma'), findsOneWidget);
      expect(find.text('···'), findsNothing);
      expect(find.byIcon(Icons.refresh), findsNothing);
    });

    testWidgets('AwaitingTool shows the same ··· placeholder as Sending', (
      tester,
    ) async {
      fake.requestTool('searchNotes', args: {'period': 'week'});
      final gate = Completer<ToolResult>();
      final session = openSession(
        botProfile: const BotProfile(
          id: 'premium',
          systemPrompt: 'be kind',
          tools: [searchTool],
        ),
        onToolCall: (call) => gate.future,
      );
      await tester.pumpWidget(wrapList(list(session)));
      await session.send('find it');
      await tester.pump(const Duration(milliseconds: 20));
      expect(session.state, isA<AwaitingTool>());
      expect(find.text('···'), findsOneWidget);

      session.cancel();
      await tester.pump();
      expect(session.state, isA<Cancelled>());
      expect(find.text('···'), findsNothing);
    });

    testWidgets('thinkingBuilder replaces the default placeholder', (
      tester,
    ) async {
      fake.reply('late', tokenDelay: const Duration(seconds: 50));
      final session = openSession();
      await tester.pumpWidget(
        wrapList(
          list(session, thinkingBuilder: (context) => const Text('THINKING')),
        ),
      );
      await session.send('hi');
      await tester.pump();
      expect(find.text('THINKING'), findsOneWidget);
      expect(find.text('···'), findsNothing);
      session.cancel();
      await tester.pump();
    });

    testWidgets('a cancelled stream keeps the partial with the interrupted '
        'marker and a message-attached regenerate', (tester) async {
      fake.reply(
        'partial answer here',
        tokenDelay: const Duration(milliseconds: 50),
      );
      final session = openSession();
      await tester.pumpWidget(wrapList(list(session)));
      await session.send('go');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(session.state, isA<Streaming>());

      session.cancel();
      await tester.pump();
      expect(session.state, isA<Cancelled>());
      expect(find.text('partial '), findsOneWidget);
      expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsOneWidget);
      expect(find.textContaining('failure:'), findsNothing);
    });
  });

  group('outer alignment', () {
    final history = Conversation(
      messages: [
        systemMessage('s-1', 'sys'),
        userMessage('u-1', 'mine'),
        assistantMessage('a-1', 'theirs'),
      ],
    );

    testWidgets('ownMessagesRight=true: user right, assistant/system left', (
      tester,
    ) async {
      final session = openSession(history: history);
      await tester.pumpWidget(wrapList(list(session)));
      expect(tester.getTopRight(bubbleOf('mine')).dx, greaterThan(500));
      expect(tester.getTopLeft(bubbleOf('theirs')).dx, lessThan(300));
      expect(tester.getTopLeft(bubbleOf('sys')).dx, lessThan(300));
    });

    testWidgets('ownMessagesRight=false: user is left-aligned too', (
      tester,
    ) async {
      final session = openSession(history: history);
      await tester.pumpWidget(wrapList(list(session, ownMessagesRight: false)));
      expect(tester.getTopLeft(bubbleOf('mine')).dx, lessThan(300));
      expect(tester.getTopLeft(bubbleOf('theirs')).dx, lessThan(300));
    });
  });

  group('avatars', () {
    final history = Conversation(
      messages: [userMessage('u-1', 'mine'), assistantMessage('a-1', 'theirs')],
    );

    testWidgets('hidden by default; showAvatars draws the default person '
        'icon per bubble', (tester) async {
      final session = openSession(history: history);
      await tester.pumpWidget(wrapList(list(session)));
      expect(find.byIcon(Icons.person), findsNothing);

      await tester.pumpWidget(wrapList(list(session, showAvatars: true)));
      expect(find.byIcon(Icons.person), findsNWidgets(2));
    });

    testWidgets('avatarBuilder replaces the default per role', (tester) async {
      final session = openSession(history: history);
      await tester.pumpWidget(
        wrapList(
          list(
            session,
            showAvatars: true,
            avatarBuilder: (context, role) => Text('@${role.name}'),
          ),
        ),
      );
      expect(find.byIcon(Icons.person), findsNothing);
      expect(find.text('@user'), findsOneWidget);
      expect(find.text('@assistant'), findsOneWidget);
    });

    testWidgets('avatarSide places the avatar before or after the bubble', (
      tester,
    ) async {
      final session = openSession(
        history: Conversation(messages: [assistantMessage('a-1', 'theirs')]),
      );
      await tester.pumpWidget(wrapList(list(session, showAvatars: true)));
      final leadingAvatarX = tester.getTopLeft(find.byIcon(Icons.person)).dx;
      final bubbleX = tester.getTopLeft(bubbleOf('theirs')).dx;
      expect(leadingAvatarX, lessThan(bubbleX));

      await tester.pumpWidget(
        wrapList(
          list(session, showAvatars: true, avatarSide: AvatarSide.trailing),
        ),
      );
      final trailingAvatarX = tester.getTopLeft(find.byIcon(Icons.person)).dx;
      expect(
        trailingAvatarX,
        greaterThan(tester.getTopRight(bubbleOf('theirs')).dx - 1),
      );
    });
  });

  group('timestamps', () {
    testWidgets('none shows nothing; belowBubble shows createdAt in local '
        'Material-locale time', (tester) async {
      final localizations = DefaultMaterialLocalizations();
      String stamp(DateTime createdAt) => localizations.formatTimeOfDay(
        TimeOfDay.fromDateTime(createdAt.toLocal()),
      );
      final userStamp = stamp(DateTime.utc(2026, 7, 10, 9));
      final assistantStamp = stamp(DateTime.utc(2026, 7, 10, 9, 1));
      final history = Conversation(
        messages: [
          userMessage('u-1', 'mine'),
          assistantMessage('a-1', 'theirs'),
        ],
      );

      final session = openSession(history: history);
      await tester.pumpWidget(wrapList(list(session)));
      expect(find.text(userStamp), findsNothing);
      expect(find.text(assistantStamp), findsNothing);

      await tester.pumpWidget(
        wrapList(list(session, timestamps: TimestampPosition.belowBubble)),
      );
      expect(find.text(userStamp), findsOneWidget);
      expect(find.text(assistantStamp), findsOneWidget);
    });
  });

  group('failure row', () {
    testWidgets('default row: icon + failureText + the one resend action '
        'when the last Message is a failed user Message', (tester) async {
      fake.failWith(FailureCause.quota);
      fake.reply('recovered');
      final session = openSession();
      await tester.pumpWidget(wrapList(list(session)));
      await session.send('hi');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(session.state, isA<Failed>());
      expect(find.text('failure:quota'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsWidgets);
      // Exactly one action control: the row's; the failed bubble does not
      // duplicate it while the row is shown.
      expect(find.byIcon(Icons.refresh), findsOneWidget);

      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(session.state, isA<Done>());
      expect(find.text('recovered'), findsOneWidget);
      expect(find.text('failure:quota'), findsNothing);
    });

    testWidgets('a mid-stream break keeps the partial and the row action is '
        'regenerate', (tester) async {
      fake.breakAfterFirstToken();
      fake.reply('whole answer');
      final session = openSession();
      await tester.pumpWidget(wrapList(list(session)));
      await session.send('go');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(session.state, isA<Failed>());
      expect(find.text('partial'), findsOneWidget);
      expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);
      expect(find.text('failure:upstream'), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsOneWidget);

      // One Core command: regenerate recovers the reply; the partial is
      // replaced by the re-run leg.
      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(session.state, isA<Done>());
      expect(find.text('whole answer'), findsOneWidget);
      expect(find.text('partial'), findsNothing);
    });

    testWidgets('errorBuilder replaces the row entirely and failureText is '
        'not consulted', (tester) async {
      fake.failWith(FailureCause.auth);
      fake.reply('back in');
      var failureTextCalls = 0;
      final session = openSession();
      await tester.pumpWidget(
        wrapList(
          ChatMessageList(
            session: session,
            failureText: (cause) {
              failureTextCalls++;
              return 'unused';
            },
            markdown: false,
            errorBuilder: (context, cause, retry) =>
                TextButton(onPressed: retry, child: Text('E:${cause.name}')),
          ),
        ),
      );
      await session.send('hi');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(session.state, isA<Failed>());
      expect(find.text('E:auth'), findsOneWidget);
      expect(failureTextCalls, 0);
      // No default row: no failureText output and no row action button (the
      // failed bubble's own error MARKER is the bubble's, not the row's).
      expect(find.text('unused'), findsNothing);
      expect(find.byIcon(Icons.refresh), findsNothing);

      // The builder's retry is the same one Core action (resend here).
      await tester.tap(find.text('E:auth'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(session.state, isA<Done>());
      expect(find.text('back in'), findsOneWidget);
    });
  });

  group('error row uses the Core recovery target, never history', () {
    // A pre-Message rejection (malformed image) enters `Failed` WITHOUT
    // touching history — the tail keeps whatever was there. The error row
    // must show NO action, not resend/regenerate an unrelated older turn.
    ChatSession preMessageFailOver(List<Message> history) =>
        session = makeSession(
          backend: fake,
          history: Conversation(messages: history),
          processImage: throwingProcessor(),
        );

    Future<void> failWithBadImage(WidgetTester tester, ChatSession s) async {
      await s.send('new turn', images: [onePixelPng]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(s.state, isA<Failed>());
    }

    testWidgets('over an older interrupted reply: no regenerate of it', (
      tester,
    ) async {
      final session = preMessageFailOver([
        userMessage('u-1', 'go'),
        assistantMessage('a-1', 'partial', status: MessageStatus.interrupted),
      ]);
      await tester.pumpWidget(wrapList(list(session)));
      await failWithBadImage(tester, session);
      expect(find.text('failure:upstream'), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsNothing);
      expect(find.text('partial'), findsOneWidget); // history untouched
    });

    testWidgets('over an older failed user: no resend of it', (tester) async {
      final session = preMessageFailOver([
        userMessage('u-1', 'oops', status: MessageStatus.failed),
      ]);
      await tester.pumpWidget(wrapList(list(session)));
      // At rest the old failed user shows its own resend (message-attached).
      expect(find.byIcon(Icons.refresh), findsOneWidget);

      await failWithBadImage(tester, session);
      // Now `Failed` with recovery `none`: no resend of the unrelated turn.
      expect(find.byIcon(Icons.refresh), findsNothing);
      expect(find.text('failure:upstream'), findsOneWidget);
    });

    testWidgets('errorBuilder receives a null retry (never a no-op)', (
      tester,
    ) async {
      final session = preMessageFailOver([
        assistantMessage('a-1', 'done', status: MessageStatus.complete),
      ]);
      var called = false;
      VoidCallback? captured = () {};
      await tester.pumpWidget(
        wrapList(
          ChatMessageList(
            session: session,
            failureText: failureLabel,
            markdown: false,
            errorBuilder: (context, cause, retry) {
              called = true;
              captured = retry;
              return Text('E:${cause.name}');
            },
          ),
        ),
      );
      await failWithBadImage(tester, session);
      expect(called, isTrue);
      expect(captured, isNull);
      expect(find.text('E:upstream'), findsOneWidget);
    });

    testWidgets('a real pre-token failure targets the NEW anchor, not an '
        'older interrupted reply', (tester) async {
      fake.failWith(FailureCause.quota); // pre-stream failure of the new send
      final session = openSession(
        history: Conversation(
          messages: [
            userMessage('u-1', 'first'),
            assistantMessage(
              'a-1',
              'partial',
              status: MessageStatus.interrupted,
            ),
          ],
        ),
      );
      await tester.pumpWidget(wrapList(list(session)));
      await session.send('second');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(session.state, isA<Failed>());
      // Exactly one action — resend of the just-failed 'second', not
      // regenerate of the old 'partial'.
      expect(find.byIcon(Icons.refresh), findsOneWidget);

      fake.reply('ok');
      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(session.state, isA<Done>());
      expect(find.text('ok'), findsOneWidget);
      expect(find.text('partial'), findsOneWidget); // old reply still there
    });
  });

  group('tail recovery actions', () {
    testWidgets('resend appears only on the LAST failed user Message', (
      tester,
    ) async {
      // An older failed user Message with later history: resend there is a
      // Core no-op, so no button is drawn anywhere.
      final session = openSession(
        history: Conversation(
          messages: [
            userMessage('u-1', 'older', status: MessageStatus.failed),
            userMessage('u-2', 'newer'),
          ],
        ),
      );
      await tester.pumpWidget(wrapList(list(session)));
      expect(find.byIcon(Icons.refresh), findsNothing);
    });

    testWidgets('the last failed user Message gets the resend button', (
      tester,
    ) async {
      fake.reply('welcome');
      final session = openSession(
        history: Conversation(
          messages: [
            userMessage('u-1', 'fine'),
            assistantMessage('a-1', 'sure'),
            userMessage('u-2', 'oops', status: MessageStatus.failed),
          ],
        ),
      );
      await tester.pumpWidget(wrapList(list(session)));
      expect(find.byIcon(Icons.refresh), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);

      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(session.state, isA<Done>());
      expect(find.text('welcome'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsNothing);
    });

    testWidgets('regenerate appears on the last interrupted reply and '
        'recovers it; a visible complete reply gets none', (tester) async {
      fake.reply('whole');
      final session = openSession(
        history: Conversation(
          messages: [
            userMessage('u-1', 'go'),
            assistantMessage('a-1', 'part', status: MessageStatus.interrupted),
          ],
        ),
      );
      await tester.pumpWidget(wrapList(list(session)));
      expect(find.byIcon(Icons.refresh), findsOneWidget);
      expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);

      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(session.state, isA<Done>());
      expect(find.text('whole'), findsOneWidget);
      expect(find.text('part'), findsNothing);
      // The reply is now complete with visible content: no regenerate.
      expect(find.byIcon(Icons.refresh), findsNothing);
    });
  });

  group('empty reply', () {
    testWidgets('an empty complete reply draws no bubble — a compact '
        'regenerate icon-button takes its place and re-runs the turn', (
      tester,
    ) async {
      fake.reply('better');
      final session = openSession(
        history: Conversation(
          messages: [
            userMessage('u-1', 'go'),
            assistantMessage('a-1', '', parts: const []),
          ],
        ),
      );
      await tester.pumpWidget(wrapList(list(session)));
      expect(find.byType(MessageBubble), findsOneWidget); // the user only
      expect(find.byIcon(Icons.refresh), findsOneWidget);

      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(session.state, isA<Done>());
      expect(find.text('better'), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsNothing);
    });

    testWidgets('emptyReplyBuilder draws its own action', (tester) async {
      fake.reply('better');
      final session = openSession(
        history: Conversation(
          messages: [
            userMessage('u-1', 'go'),
            assistantMessage('a-1', '', parts: const []),
          ],
        ),
      );
      await tester.pumpWidget(
        wrapList(
          list(
            session,
            emptyReplyBuilder: (context, regenerate) => OutlinedButton(
              onPressed: regenerate,
              child: const Text('AGAIN'),
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.refresh), findsNothing);
      expect(find.text('AGAIN'), findsOneWidget);

      await tester.tap(find.text('AGAIN'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(session.state, isA<Done>());
      expect(find.text('better'), findsOneWidget);
    });

    testWidgets('an older empty reply stays in history but renders nothing '
        'and gets no action', (tester) async {
      final session = openSession(
        history: Conversation(
          messages: [
            userMessage('u-1', 'one'),
            assistantMessage('a-1', '', parts: const []),
            userMessage('u-2', 'two'),
            assistantMessage('a-2', 'fine'),
          ],
        ),
      );
      await tester.pumpWidget(wrapList(list(session)));
      expect(find.byType(MessageBubble), findsNWidgets(3));
      expect(find.byIcon(Icons.refresh), findsNothing);
      expect(session.snapshot.messages, hasLength(4));
    });
  });

  group('scroll', () {
    Conversation longHistory() => Conversation(
      messages: [
        for (var i = 0; i < 16; i++)
          i.isEven
              ? userMessage('u-$i', 'user line number $i')
              : assistantMessage('a-$i', 'bot line number $i'),
      ],
    );

    testWidgets('opens at the bottom and stays glued while streaming', (
      tester,
    ) async {
      fake.reply(
        'one two three four five six seven eight nine ten',
        tokenDelay: const Duration(milliseconds: 50),
      );
      final session = openSession(history: longHistory());
      await tester.pumpWidget(wrapList(list(session)));
      await tester.pump();
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      expect(position.maxScrollExtent, greaterThan(0));
      expect(position.pixels, position.maxScrollExtent);

      await session.send('more');
      await tester.pump();
      await tester.pump();
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 60));
        expect(position.pixels, position.maxScrollExtent);
      }
      expect(session.state, isA<Done>());
    });

    testWidgets('a user who scrolled up is never pulled back down', (
      tester,
    ) async {
      fake.reply(
        'one two three four five six seven eight nine ten',
        tokenDelay: const Duration(milliseconds: 50),
      );
      final session = openSession(history: longHistory());
      await tester.pumpWidget(wrapList(list(session)));
      await tester.pump();
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;

      await tester.drag(find.byType(ListView), const Offset(0, 300));
      await tester.pump();
      final parked = position.pixels;
      expect(parked, lessThan(position.maxScrollExtent));

      await session.send('more');
      await tester.pump();
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 60));
        expect(position.pixels, parked);
      }
      expect(session.state, isA<Done>());
      expect(position.pixels, parked);
    });
  });

  group('theme', () {
    testWidgets('background, spacing and list padding apply', (tester) async {
      const theme = ChatTheme(
        backgroundColor: Color(0xFF010203),
        messageSpacing: 20,
        messageListPadding: EdgeInsets.all(5),
      );
      final session = openSession(
        history: Conversation(
          messages: [userMessage('u-1', 'one'), assistantMessage('a-1', 'two')],
        ),
      );
      await tester.pumpWidget(wrapList(list(session, theme: theme)));
      final background = tester.widget<ColoredBox>(
        find
            .descendant(
              of: find.byType(ChatMessageList),
              matching: find.byType(ColoredBox),
            )
            .first,
      );
      expect(background.color, const Color(0xFF010203));
      expect(
        find.byWidgetPredicate(
          (widget) => widget is SizedBox && widget.height == 20,
        ),
        findsOneWidget,
      );
      expect(
        tester.widget<ListView>(find.byType(ListView)).padding,
        const EdgeInsets.all(5),
      );
    });

    testWidgets('a theme constraint violation throws ArgumentError at build', (
      tester,
    ) async {
      final session = openSession();
      await tester.pumpWidget(
        wrapList(list(session, theme: const ChatTheme(messageSpacing: -1))),
      );
      expect(tester.takeException(), isArgumentError);
    });
  });
}
