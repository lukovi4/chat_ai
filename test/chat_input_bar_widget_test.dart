// ChatInputBar widget contract (V1_SPEC §7, docs/widgets-spec.md): the bar
// owns draft + previews, sends through the package-internal disposition
// bridge, flips send→stop in the active phases, and follows the §7
// attach/mic/cap rules exactly.
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

/// A 1×1 transparent PNG — decodable by `Image.memory` in widget tests.
final Uint8List onePixelPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, //
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, //
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

Widget wrapBar(ChatInputBar bar) => MaterialApp(home: Scaffold(body: bar));

TextEditingController controllerOf(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!;

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
    ImageSendOptions imageOptions = const ImageSendOptions(),
    ConversationCheckpoint? checkpoint,
    BotProfile botProfile = plainProfile,
    OnToolCall? onToolCall,
  }) => session = makeSession(
    backend: fake,
    botProfile: botProfile,
    onToolCall: onToolCall,
    imageOptions: imageOptions,
    checkpoint: checkpoint,
    processImage: fakeImageProcessor(),
  );

  group('layout and hint', () {
    testWidgets('hint null = empty placeholder; a given hint is shown', (
      tester,
    ) async {
      final session = openSession();
      await tester.pumpWidget(wrapBar(ChatInputBar(session: session)));
      expect(
        tester.widget<TextField>(find.byType(TextField)).decoration!.hintText,
        '',
      );

      await tester.pumpWidget(
        wrapBar(ChatInputBar(session: session, hint: 'Ask anything')),
      );
      expect(find.text('Ask anything'), findsOneWidget);
    });

    testWidgets('attach and mic buttons exist only with their callbacks', (
      tester,
    ) async {
      final session = openSession();
      await tester.pumpWidget(wrapBar(ChatInputBar(session: session)));
      expect(find.byIcon(Icons.attach_file), findsNothing);
      expect(find.byIcon(Icons.mic), findsNothing);
      expect(find.byIcon(Icons.send), findsOneWidget);

      await tester.pumpWidget(
        wrapBar(
          ChatInputBar(
            session: session,
            onAttach: () async => [onePixelPng],
            onMic: () async => null,
          ),
        ),
      );
      expect(find.byIcon(Icons.attach_file), findsOneWidget);
      expect(find.byIcon(Icons.mic), findsOneWidget);
    });

    testWidgets('invalid maxAttachments throws ArgumentError at build', (
      tester,
    ) async {
      final session = openSession();
      await tester.pumpWidget(
        wrapBar(ChatInputBar(session: session, maxAttachments: 0)),
      );
      expect(tester.takeException(), isArgumentError);
    });

    testWidgets('theme applies: bar padding, input fill, preview size', (
      tester,
    ) async {
      const theme = ChatTheme(
        inputBarPadding: EdgeInsets.all(3),
        inputFillColor: Color(0xFF0A0B0C),
        imageThumbnailSize: Size(32, 32),
      );
      final session = openSession();
      await tester.pumpWidget(
        wrapBar(
          ChatInputBar(
            session: session,
            theme: theme,
            onAttach: () async => [onePixelPng],
          ),
        ),
      );
      expect(
        tester
            .widget<Padding>(
              find
                  .descendant(
                    of: find.byType(ChatInputBar),
                    matching: find.byType(Padding),
                  )
                  .first,
            )
            .padding,
        const EdgeInsets.all(3),
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).decoration!.fillColor,
        const Color(0xFF0A0B0C),
      );

      await tester.tap(find.byIcon(Icons.attach_file));
      await tester.pump();
      expect(tester.getSize(find.byType(Image)), const Size(32, 32));
      expect(find.byIcon(Icons.close), findsOneWidget);
    });
  });

  group('send', () {
    testWidgets('a text send dispatches and the accepted disposition clears '
        'the draft', (tester) async {
      fake.reply('sure');
      final session = openSession();
      await tester.pumpWidget(wrapBar(ChatInputBar(session: session)));
      await tester.enterText(find.byType(TextField), 'hello there');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      final request = capturedRequestsOf(fake).single;
      expect(visibleText(request.messages.last), 'hello there');
      expect(controllerOf(tester).text, isEmpty);
      expect(session.state, isA<Done>());
    });

    testWidgets('an image-only send is allowed and clears the previews', (
      tester,
    ) async {
      fake.reply('nice photo');
      final session = openSession();
      await tester.pumpWidget(
        wrapBar(
          ChatInputBar(session: session, onAttach: () async => [onePixelPng]),
        ),
      );
      await tester.tap(find.byIcon(Icons.attach_file));
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);

      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      final sent = capturedRequestsOf(fake).single.messages.last;
      expect(sent.parts.single, isA<ImagePart>());
      expect(find.byType(Image), findsNothing);
      expect(session.state, isA<Done>());
    });

    testWidgets('an empty draft send is a no-op: nothing dispatched, '
        'nothing changes', (tester) async {
      final session = openSession();
      await tester.pumpWidget(wrapBar(ChatInputBar(session: session)));
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      expect(capturedRequestsOf(fake), isEmpty);
      expect(session.state, isA<Idle>());
    });

    testWidgets('a rejected send (checkpoint failure) keeps the draft and '
        'previews', (tester) async {
      final session = openSession(
        checkpoint: (snapshot) async => throw StateError('disk full'),
      );
      await tester.pumpWidget(
        wrapBar(
          ChatInputBar(session: session, onAttach: () async => [onePixelPng]),
        ),
      );
      await tester.tap(find.byIcon(Icons.attach_file));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'keep me');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      expect(session.state, isA<Failed>());
      expect(controllerOf(tester).text, 'keep me');
      expect(find.byType(Image), findsOneWidget);
    });
  });

  group('send→stop toggle', () {
    testWidgets('Sending: the send icon becomes stop and stop cancels', (
      tester,
    ) async {
      fake.reply('late', tokenDelay: const Duration(seconds: 50));
      final session = openSession();
      await tester.pumpWidget(wrapBar(ChatInputBar(session: session)));
      await tester.enterText(find.byType(TextField), 'hi');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      expect(session.state, isA<Sending>());
      expect(find.byIcon(Icons.stop), findsOneWidget);
      expect(find.byIcon(Icons.send), findsNothing);

      await tester.tap(find.byIcon(Icons.stop));
      await tester.pump();
      expect(session.state, isA<Cancelled>());
      expect(find.byIcon(Icons.send), findsOneWidget);
      expect(find.byIcon(Icons.stop), findsNothing);
    });

    testWidgets('Streaming: stop cancels and keeps the partial', (
      tester,
    ) async {
      fake.reply('one two three', tokenDelay: const Duration(milliseconds: 50));
      final session = openSession();
      await tester.pumpWidget(wrapBar(ChatInputBar(session: session)));
      await tester.enterText(find.byType(TextField), 'hi');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(session.state, isA<Streaming>());
      expect(find.byIcon(Icons.stop), findsOneWidget);

      await tester.tap(find.byIcon(Icons.stop));
      await tester.pump();
      expect(session.state, isA<Cancelled>());
      expect(visibleText(session.snapshot.messages.last), 'one ');
    });

    testWidgets('AwaitingTool: stop cancels', (tester) async {
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
      await tester.pumpWidget(wrapBar(ChatInputBar(session: session)));
      await tester.enterText(find.byType(TextField), 'find it');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump(const Duration(milliseconds: 20));
      expect(session.state, isA<AwaitingTool>());
      expect(find.byIcon(Icons.stop), findsOneWidget);

      await tester.tap(find.byIcon(Icons.stop));
      await tester.pump();
      expect(session.state, isA<Cancelled>());
      expect(find.byIcon(Icons.send), findsOneWidget);
    });
  });

  group('attachment cap', () {
    testWidgets('null maxAttachments uses the SESSION limit — a session '
        'capped at 2 accepts 2, not the default 4', (tester) async {
      final session = openSession(
        imageOptions: const ImageSendOptions(maxImagesPerMessage: 2),
      );
      await tester.pumpWidget(
        wrapBar(
          ChatInputBar(
            session: session,
            onAttach: () async => [
              onePixelPng,
              onePixelPng,
              onePixelPng,
              onePixelPng,
            ],
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.attach_file));
      await tester.pump();
      expect(find.byType(Image), findsNWidgets(2));
    });

    testWidgets('maxAttachments may only LOWER the session limit', (
      tester,
    ) async {
      final session = openSession(
        imageOptions: const ImageSendOptions(maxImagesPerMessage: 2),
      );
      // Lower than the session limit: min(1, 2) = 1.
      await tester.pumpWidget(
        wrapBar(
          ChatInputBar(
            session: session,
            maxAttachments: 1,
            onAttach: () async => [onePixelPng, onePixelPng],
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.attach_file));
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);

      // Higher than the session limit: min(5, 2) = 2.
      await tester.pumpWidget(
        wrapBar(
          ChatInputBar(
            session: session,
            maxAttachments: 5,
            onAttach: () async => [onePixelPng, onePixelPng, onePixelPng],
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.attach_file));
      await tester.pump();
      expect(find.byType(Image), findsNWidgets(2));
    });

    testWidgets('repeated attaches add up to the cap (first-N in source '
        'order) and removing a preview frees a slot', (tester) async {
      var batch = <Uint8List>[];
      final session = openSession(
        imageOptions: const ImageSendOptions(maxImagesPerMessage: 2),
      );
      await tester.pumpWidget(
        wrapBar(ChatInputBar(session: session, onAttach: () async => batch)),
      );

      batch = [onePixelPng];
      await tester.tap(find.byIcon(Icons.attach_file));
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);

      // Three more offered, one slot left: the first is kept.
      batch = [onePixelPng, onePixelPng, onePixelPng];
      await tester.tap(find.byIcon(Icons.attach_file));
      await tester.pump();
      expect(find.byType(Image), findsNWidgets(2));

      // At the cap another attach changes nothing.
      await tester.tap(find.byIcon(Icons.attach_file));
      await tester.pump();
      expect(find.byType(Image), findsNWidgets(2));

      // Removing one preview frees one slot.
      await tester.tap(find.byIcon(Icons.close).first);
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      batch = [onePixelPng];
      await tester.tap(find.byIcon(Icons.attach_file));
      await tester.pump();
      expect(find.byType(Image), findsNWidgets(2));
    });

    testWidgets('an empty attach result (cancelled picker) changes nothing', (
      tester,
    ) async {
      final session = openSession();
      await tester.pumpWidget(
        wrapBar(ChatInputBar(session: session, onAttach: () async => [])),
      );
      await tester.tap(find.byIcon(Icons.attach_file));
      await tester.pump();
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('an onAttach exception is reported through FlutterError and '
        'keeps the draft and previews', (tester) async {
      var shouldThrow = false;
      final session = openSession();
      await tester.pumpWidget(
        wrapBar(
          ChatInputBar(
            session: session,
            onAttach: () async {
              if (shouldThrow) {
                throw StateError('picker exploded');
              }
              return [onePixelPng];
            },
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.attach_file));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'draft');

      shouldThrow = true;
      final reported = <FlutterErrorDetails>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = reported.add;
      await tester.tap(find.byIcon(Icons.attach_file));
      await tester.pump();
      FlutterError.onError = previousOnError;

      expect(reported.single.exception, isA<StateError>());
      expect(reported.single.library, 'chat_ai');
      expect(controllerOf(tester).text, 'draft');
      expect(find.byType(Image), findsOneWidget);
      expect(capturedRequestsOf(fake), isEmpty);
    });
  });

  group('session swap during an in-flight async op', () {
    testWidgets('a late accepted send of the swapped-out session never '
        "clears the new session's draft", (tester) async {
      fake.reply('a-reply');
      final gate = Completer<void>();
      final sessionA = makeSession(
        backend: fake,
        checkpoint: (snapshot) =>
            gate.future, // stalls A's send until we let go
        processImage: fakeImageProcessor(),
      );
      final sessionB = session = makeSession(
        backend: FakeChatBackend(),
        processImage: fakeImageProcessor(),
      );
      addTearDown(() => unawaited(sessionA.dispose()));

      await tester.pumpWidget(wrapBar(ChatInputBar(session: sessionA)));
      await tester.enterText(find.byType(TextField), 'A-draft');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      expect(sessionA.state, isA<Sending>());

      // Swap the widget to session B; the user types B's draft.
      await tester.pumpWidget(wrapBar(ChatInputBar(session: sessionB)));
      await tester.enterText(find.byType(TextField), 'B-draft');

      // A's send finally resolves accepted — the identity guard must keep it
      // from clearing B's draft.
      gate.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(controllerOf(tester).text, 'B-draft');
    });

    testWidgets('a late onAttach result of the swapped-out session never '
        "lands in the new session's previews", (tester) async {
      final gate = Completer<List<Uint8List>>();
      final sessionA = makeSession(
        backend: fake,
        processImage: fakeImageProcessor(),
      );
      final sessionB = session = makeSession(
        backend: FakeChatBackend(),
        processImage: fakeImageProcessor(),
      );
      addTearDown(() => unawaited(sessionA.dispose()));

      await tester.pumpWidget(
        wrapBar(ChatInputBar(session: sessionA, onAttach: () => gate.future)),
      );
      await tester.tap(find.byIcon(Icons.attach_file));
      await tester.pump();

      await tester.pumpWidget(
        wrapBar(ChatInputBar(session: sessionB, onAttach: () async => [])),
      );
      gate.complete([onePixelPng]); // A's late picker result
      await tester.pump();
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('a late onMic result of the swapped-out session never edits '
        "the new session's draft", (tester) async {
      final gate = Completer<String?>();
      final sessionA = makeSession(
        backend: fake,
        processImage: fakeImageProcessor(),
      );
      final sessionB = session = makeSession(
        backend: FakeChatBackend(),
        processImage: fakeImageProcessor(),
      );
      addTearDown(() => unawaited(sessionA.dispose()));

      await tester.pumpWidget(
        wrapBar(ChatInputBar(session: sessionA, onMic: () => gate.future)),
      );
      await tester.tap(find.byIcon(Icons.mic));
      await tester.pump();

      await tester.pumpWidget(
        wrapBar(ChatInputBar(session: sessionB, onMic: () async => null)),
      );
      await tester.enterText(find.byType(TextField), 'B-draft');
      gate.complete('DICTATED'); // A's late dictation
      await tester.pump();
      expect(controllerOf(tester).text, 'B-draft');
    });
  });

  group('mic', () {
    testWidgets('a non-empty result is inserted at the selection (replacing '
        'it), cursor after the insert — and is never sent', (tester) async {
      final session = openSession();
      await tester.pumpWidget(
        wrapBar(ChatInputBar(session: session, onMic: () async => 'HI')),
      );
      await tester.enterText(find.byType(TextField), 'hello world');
      controllerOf(tester).selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 5,
      );

      await tester.tap(find.byIcon(Icons.mic));
      await tester.pump();
      expect(controllerOf(tester).text, 'HI world');
      expect(
        controllerOf(tester).selection,
        const TextSelection.collapsed(offset: 2),
      );
      expect(capturedRequestsOf(fake), isEmpty);
    });

    testWidgets('with no valid selection the insert appends at the end', (
      tester,
    ) async {
      final session = openSession();
      await tester.pumpWidget(
        wrapBar(ChatInputBar(session: session, onMic: () async => 'dictated')),
      );
      await tester.tap(find.byIcon(Icons.mic));
      await tester.pump();
      expect(controllerOf(tester).text, 'dictated');
      expect(
        controllerOf(tester).selection,
        const TextSelection.collapsed(offset: 8),
      );
    });

    testWidgets('null and empty mic results change nothing', (tester) async {
      String? result;
      final session = openSession();
      await tester.pumpWidget(
        wrapBar(ChatInputBar(session: session, onMic: () async => result)),
      );
      await tester.enterText(find.byType(TextField), 'draft');

      result = null;
      await tester.tap(find.byIcon(Icons.mic));
      await tester.pump();
      expect(controllerOf(tester).text, 'draft');

      result = '';
      await tester.tap(find.byIcon(Icons.mic));
      await tester.pump();
      expect(controllerOf(tester).text, 'draft');
      expect(capturedRequestsOf(fake), isEmpty);
    });

    testWidgets('an onMic exception is reported through FlutterError and '
        'keeps the draft', (tester) async {
      final session = openSession();
      await tester.pumpWidget(
        wrapBar(
          ChatInputBar(
            session: session,
            onMic: () async => throw StateError('mic exploded'),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'draft');

      final reported = <FlutterErrorDetails>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = reported.add;
      await tester.tap(find.byIcon(Icons.mic));
      await tester.pump();
      FlutterError.onError = previousOnError;

      expect(reported.single.exception, isA<StateError>());
      expect(controllerOf(tester).text, 'draft');
      expect(capturedRequestsOf(fake), isEmpty);
    });
  });
}
