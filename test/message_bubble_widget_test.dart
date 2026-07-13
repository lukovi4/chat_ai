// MessageBubble widget contract (V1_SPEC §7, docs/widgets-spec.md): one
// Message, visible parts + status markers + Copy, no outer alignment, no
// session-bound rows/actions.
import 'package:chat_ai/chat_ai.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import 'chat_session_test_utils.dart';

/// A 1×1 transparent PNG — decodable by `Image.memory` in widget tests.
final Uint8List onePixelPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, //
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00, //
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, //
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

Widget wrap(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

Finder inBubble(Finder matching) =>
    find.descendant(of: find.byType(MessageBubble), matching: matching);

void main() {
  testWidgets('owns no outer alignment: no Align and no Row of its own', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        MessageBubble(
          message: userMessage('u-1', 'hello', status: MessageStatus.failed),
          markdown: false,
        ),
      ),
    );
    expect(inBubble(find.byType(Align)), findsNothing);
    expect(inBubble(find.byType(Row)), findsNothing);
  });

  testWidgets('a standalone bubble is positioned by its parent', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 300,
            child: Align(
              alignment: Alignment.bottomRight,
              child: MessageBubble(
                message: userMessage('u-1', 'hi'),
                markdown: false,
              ),
            ),
          ),
        ),
      ),
    );
    final box = tester.getRect(find.byType(SizedBox).first);
    final bubble = tester.getRect(find.byType(MessageBubble));
    expect(bubble.bottomRight, box.bottomRight);
    expect(bubble.width, lessThan(box.width));
  });

  testWidgets('assistant markdown=true renders via GptMarkdown, '
      'markdown=false renders plain Text', (tester) async {
    final message = assistantMessage('a-1', '**bold** move');
    await tester.pumpWidget(wrap(MessageBubble(message: message)));
    expect(find.byType(GptMarkdown), findsOneWidget);
    expect(find.text('**bold** move'), findsNothing);

    await tester.pumpWidget(
      wrap(MessageBubble(message: message, markdown: false)),
    );
    expect(find.byType(GptMarkdown), findsNothing);
    expect(find.text('**bold** move'), findsOneWidget);
  });

  testWidgets('user and system text is always plain even with markdown on', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(MessageBubble(message: userMessage('u-1', '*not markup*'))),
    );
    expect(find.byType(GptMarkdown), findsNothing);
    expect(find.text('*not markup*'), findsOneWidget);

    await tester.pumpWidget(
      wrap(MessageBubble(message: systemMessage('s-1', '# plain'))),
    );
    expect(find.byType(GptMarkdown), findsNothing);
    expect(find.text('# plain'), findsOneWidget);
  });

  testWidgets('system uses the assistant visual style; user uses its own', (
    tester,
  ) async {
    const theme = ChatTheme(
      userBubbleColor: Color(0xFF112233),
      assistantBubbleColor: Color(0xFF445566),
    );
    await tester.pumpWidget(
      wrap(MessageBubble(message: systemMessage('s-1', 'rules'), theme: theme)),
    );
    expect(
      tester.widget<Material>(inBubble(find.byType(Material))).color,
      const Color(0xFF445566),
    );

    await tester.pumpWidget(
      wrap(MessageBubble(message: userMessage('u-1', 'hi'), theme: theme)),
    );
    expect(
      tester.widget<Material>(inBubble(find.byType(Material))).color,
      const Color(0xFF112233),
    );
  });

  testWidgets('partBuilder is offered text/image/tool parts first; '
      'null falls back to the default rendering', (tester) async {
    final message = assistantMessage(
      'a-1',
      '',
      parts: const [
        ContentPart.text('visible'),
        ContentPart.toolCall('call_1', 'searchNotes', {'period': 'week'}),
        ContentPart.toolResult('call_1', '3 notes', false),
      ],
    );
    final offered = <Type>[];
    await tester.pumpWidget(
      wrap(
        MessageBubble(
          message: message,
          markdown: false,
          partBuilder: (context, message, part) {
            offered.add(part.runtimeType);
            if (part is ToolCallPart) {
              return const Text('TOOL-UI');
            }
            return null; // default rendering
          },
        ),
      ),
    );
    // Every visible/tool part was offered, in order.
    expect(offered, [TextPart, ToolCallPart, ToolResultPart]);
    // The custom tool widget rendered; the null returns fell back to the
    // defaults: visible text, hidden tool result.
    expect(find.text('TOOL-UI'), findsOneWidget);
    expect(find.text('visible'), findsOneWidget);
    expect(find.textContaining('3 notes'), findsNothing);
  });

  testWidgets('an ImagePart may be replaced through partBuilder', (
    tester,
  ) async {
    final message = userMessage(
      'u-1',
      '',
      parts: [ContentPart.image(onePixelPng)],
    );
    await tester.pumpWidget(
      wrap(
        MessageBubble(
          message: message,
          partBuilder: (context, message, part) =>
              part is ImagePart ? const Text('IMG-UI') : null,
        ),
      ),
    );
    expect(find.text('IMG-UI'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('ProviderOpaquePart is never rendered and never offered', (
    tester,
  ) async {
    final message = assistantMessage(
      'a-1',
      '',
      parts: [
        const ContentPart.text('answer'),
        ContentPart.providerOpaque('openai', Uint8List.fromList([1, 2])),
      ],
    );
    final offered = <ContentPart>[];
    await tester.pumpWidget(
      wrap(
        MessageBubble(
          message: message,
          markdown: false,
          partBuilder: (context, message, part) {
            offered.add(part);
            return null;
          },
        ),
      ),
    );
    expect(offered, const [ContentPart.text('answer')]);
    expect(find.text('answer'), findsOneWidget);
  });

  testWidgets('tool parts are hidden by default', (tester) async {
    final message = assistantMessage(
      'a-1',
      '',
      parts: const [
        ContentPart.text('done'),
        ContentPart.toolCall('call_1', 'searchNotes', {'period': 'week'}),
        ContentPart.toolResult('call_1', 'internal', false),
      ],
    );
    await tester.pumpWidget(wrap(MessageBubble(message: message)));
    expect(find.textContaining('searchNotes'), findsNothing);
    expect(find.textContaining('internal'), findsNothing);
    expect(find.byType(GptMarkdown), findsOneWidget); // the text part only
  });

  testWidgets('image part: theme thumbnail size applies, tap calls '
      'onImageTap, null onImageTap is a no-op', (tester) async {
    final message = userMessage(
      'u-1',
      '',
      parts: [ContentPart.image(onePixelPng)],
    );
    const theme = ChatTheme(imageThumbnailSize: Size(48, 48));
    final taps = <Uint8List>[];
    await tester.pumpWidget(
      wrap(MessageBubble(message: message, theme: theme, onImageTap: taps.add)),
    );
    expect(tester.getSize(inBubble(find.byType(Image))), const Size(48, 48));
    await tester.tap(find.byType(Image));
    expect(taps, [onePixelPng]);

    // Without the callback the tap does nothing (and never throws).
    await tester.pumpWidget(
      wrap(MessageBubble(message: message, theme: theme)),
    );
    await tester.tap(find.byType(Image), warnIfMissed: false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Copy joins the visible TextParts with "\\n"; image/tool '
      'parts are never copied', (tester) async {
    final clipboard = <String?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add(
            (call.arguments as Map<Object?, Object?>)['text'] as String?,
          );
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final message = assistantMessage(
      'a-1',
      '',
      parts: const [
        ContentPart.text('# first'),
        ContentPart.toolCall('call_1', 'searchNotes', {'period': 'week'}),
        ContentPart.toolResult('call_1', 'hidden', false),
        ContentPart.text('second'),
      ],
    );
    await tester.pumpWidget(
      wrap(MessageBubble(message: message, markdown: false)),
    );
    await tester.longPress(find.byType(MessageBubble));
    // Source text as-is (markdown included), joined with "\n".
    expect(clipboard, ['# first\nsecond']);
  });

  testWidgets('Copy is a no-op without visible text', (tester) async {
    final clipboard = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add(call);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      wrap(
        MessageBubble(
          message: userMessage(
            'u-1',
            '',
            parts: [ContentPart.image(onePixelPng)],
          ),
        ),
      ),
    );
    await tester.longPress(find.byType(MessageBubble));
    expect(clipboard, isEmpty);
  });

  testWidgets('status markers: sending dims the bubble, failed shows the '
      'error icon, interrupted shows the stop marker — never an action', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        MessageBubble(
          message: userMessage('u-1', 'hi', status: MessageStatus.sending),
          markdown: false,
        ),
      ),
    );
    final opacity = tester.widget<Opacity>(
      inBubble(find.byType(Opacity)).first,
    );
    expect(opacity.opacity, 0.6);

    await tester.pumpWidget(
      wrap(
        MessageBubble(
          message: userMessage('u-1', 'hi', status: MessageStatus.failed),
          markdown: false,
        ),
      ),
    );
    expect(inBubble(find.byIcon(Icons.error_outline)), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsNothing);

    await tester.pumpWidget(
      wrap(
        MessageBubble(
          message: assistantMessage(
            'a-1',
            'partial',
            status: MessageStatus.interrupted,
          ),
          markdown: false,
        ),
      ),
    );
    expect(inBubble(find.byIcon(Icons.stop_circle_outlined)), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsNothing);
    expect(find.byIcon(Icons.error_outline), findsNothing);
  });

  testWidgets('an empty complete assistant Message draws no bubble at all', (
    tester,
  ) async {
    final offered = <ContentPart>[];
    await tester.pumpWidget(
      wrap(
        MessageBubble(
          message: assistantMessage('a-1', '', parts: const []),
          partBuilder: (context, message, part) {
            offered.add(part);
            return null;
          },
        ),
      ),
    );
    expect(inBubble(find.byType(Material)), findsNothing);
    expect(tester.getSize(find.byType(MessageBubble)), Size.zero);

    // Opaque-only parts are equally invisible — and still never offered.
    await tester.pumpWidget(
      wrap(
        MessageBubble(
          message: assistantMessage(
            'a-1',
            '',
            parts: [
              ContentPart.providerOpaque('openai', Uint8List.fromList([1])),
            ],
          ),
          partBuilder: (context, message, part) {
            offered.add(part);
            return null;
          },
        ),
      ),
    );
    expect(inBubble(find.byType(Material)), findsNothing);
    expect(offered, isEmpty);
  });

  testWidgets('maxBubbleWidthFactor and the bubble ShapeBorder apply', (
    tester,
  ) async {
    const shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(2)),
    );
    const theme = ChatTheme(maxBubbleWidthFactor: 0.5, userBubbleShape: shape);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 300,
            child: Align(
              alignment: Alignment.topLeft,
              child: MessageBubble(
                message: userMessage(
                  'u-1',
                  'a very long message that must wrap because it cannot fit '
                      'half of four hundred logical pixels in a single line',
                ),
                theme: theme,
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byType(MessageBubble)).width, 200);
    expect(
      tester.widget<Material>(inBubble(find.byType(Material))).shape,
      shape,
    );
  });

  testWidgets('theme constraint violations throw ArgumentError at build, '
      'before rendering', (tester) async {
    for (final theme in const [
      ChatTheme(maxBubbleWidthFactor: 0),
      ChatTheme(maxBubbleWidthFactor: 1.2),
      ChatTheme(messageSpacing: -1),
      ChatTheme(imageThumbnailSize: Size(0, 160)),
    ]) {
      await tester.pumpWidget(
        wrap(MessageBubble(message: userMessage('u-1', 'hi'), theme: theme)),
      );
      expect(tester.takeException(), isArgumentError, reason: '$theme');
    }
  });
}
