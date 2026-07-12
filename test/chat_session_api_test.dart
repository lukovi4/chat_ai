// The public ChatSession surface (V1_SPEC §3), through the public barrels
// ONLY: exact command/getter signatures, the ConversationCheckpoint typedef,
// and a full send round-trip over the public FakeChatBackend.
import 'dart:typed_data';

import 'package:chat_ai/chat_ai.dart';
import 'package:chat_ai/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'the façade constructs with every documented parameter and defaults',
    () async {
      final saved = <Conversation>[];
      Future<void> checkpoint(Conversation snapshot) async =>
          saved.add(snapshot);
      final ConversationCheckpoint typed = checkpoint;

      final session = ChatSession(
        backend: FakeChatBackend()..reply('Hello!'),
        botProfile: const BotProfile(
          id: 'premium',
          systemPrompt: 's',
          tools: [],
        ),
        onToolCall: (call) async =>
            const ToolResult(content: '', isError: false),
        history: const Conversation(messages: []),
        trimBudget: null,
        maxToolTurns: 5,
        retryDeadline: const Duration(seconds: 30),
        imageOptions: const ImageSendOptions(),
        checkpoint: typed,
      );

      // Exact signatures (V1_SPEC §3) — a mismatch fails to compile.
      final Future<void> Function(String, {List<Uint8List> images}) send =
          session.send;
      final Future<void> Function() regenerate = session.regenerate;
      final Future<void> Function(String) resend = session.resend;
      final Future<void> Function(String, String) editAndResend =
          session.editAndResend;
      final void Function() cancel = session.cancel;
      final Future<void> Function() dispose = session.dispose;
      final Stream<ConversationState> states = session.states;
      final ConversationState state = session.state;
      final Stream<String> tokens = session.tokens;
      final Conversation snapshot = session.snapshot;
      final BotProfile profile = session.botProfile;
      session.botProfile = profile; // mutable get/set

      expect(state, const ConversationState.idle());
      expect(snapshot.messages, isEmpty);
      expect(tokens, isA<Stream<String>>());
      expect(states, isA<Stream<ConversationState>>());
      expect(regenerate, isNotNull);
      expect(resend, isNotNull);
      expect(editAndResend, isNotNull);
      expect(cancel, isNotNull);

      // A full public round-trip: send → Done, checkpointed before dispatch.
      await send('hi', images: const []);
      while (session.state is! Done) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(saved, hasLength(1));
      expect(session.snapshot.messages, hasLength(2));
      await dispose();
    },
  );

  test('FakeChatBackend is assignable to ChatBackend from testing.dart', () {
    final ChatBackend backend = FakeChatBackend();
    expect(backend, isA<FakeChatBackend>());
  });
}
