// Shared deterministic harness for the ChatSession Core tests. Not a _test
// file — contains no test cases.
import 'dart:async';
import 'dart:typed_data';

import 'package:chat_ai/chat_ai.dart';
// The internal seams under test: the deterministic session factory, the
// command-disposition bridge and the fake's request-capture seam. All three
// are deliberately NOT on the public barrels.
import 'package:chat_ai/src/core/chat_session.dart';

export 'package:chat_ai/src/core/chat_session.dart'
    show ChatCommandDisposition, chatSessionForTesting, sendWithDisposition;
export 'package:chat_ai/src/testing/fake_chat_backend.dart'
    show FakeChatBackend, capturedRequestsOf, scriptFailureResponse;

/// A deterministic wall clock + backoff-delay recorder: waits complete in
/// zero real time but advance the fake clock, so deadline mechanics are
/// exact and tests never sleep real seconds.
class FakeTime {
  DateTime current = DateTime.utc(2026, 7, 12, 12);
  final List<Duration> delays = [];

  DateTime now() => current;

  Future<void> delay(Duration duration) async {
    delays.add(duration);
    current = current.add(duration);
    await Future<void>.delayed(Duration.zero);
  }
}

/// Deterministic UUID source: `uuid-1`, `uuid-2`, …
class SequentialUuid {
  int _next = 0;
  final List<String> minted = [];

  String call() {
    final id = 'uuid-${++_next}';
    minted.add(id);
    return id;
  }
}

/// Wraps a backend to log every dispatch into a shared event [log] —
/// used to pin checkpoint-before-dispatch ordering.
class LoggingBackend implements ChatBackend {
  LoggingBackend(this.inner, this.log);

  final ChatBackend inner;
  final List<String> log;

  @override
  Stream<BackendEvent> send(ChatRequest request) {
    log.add('dispatch:${request.idempotencyKey}');
    return inner.send(request);
  }
}

/// A fully manual backend: the test pushes each event by hand, so races
/// (cancel vs delta, Done vs cancel, hanging streams) are exact.
class ManualBackend implements ChatBackend {
  ManualBackend({this.onCancelAsync});

  /// Optional asynchronous wire-cancel teardown — completes the
  /// subscription cancellation only when its Future does (models a
  /// transport whose onCancel is async).
  final Future<void> Function()? onCancelAsync;

  final List<ChatRequest> requests = [];
  final List<StreamController<BackendEvent>> _controllers = [];
  int cancelledSubscriptions = 0;

  @override
  Stream<BackendEvent> send(ChatRequest request) {
    requests.add(request);
    late final StreamController<BackendEvent> controller;
    controller = StreamController<BackendEvent>(
      onCancel: () async {
        cancelledSubscriptions++;
        await onCancelAsync?.call();
      },
    );
    _controllers.add(controller);
    return controller.stream;
  }

  StreamController<BackendEvent> get current => _controllers.last;

  void emit(BackendEvent event) => current.add(event);

  Future<void> closeCurrent() => current.close();
}

/// An in-test image processor that never touches an isolate.
Future<Uint8List> Function(Uint8List, ImageSendOptions) fakeImageProcessor({
  List<Uint8List>? processedLog,
  Uint8List Function(Uint8List raw)? transform,
}) => (raw, options) async {
  final out = transform == null ? raw : transform(raw);
  processedLog?.add(out);
  return out;
};

Message userMessage(
  String id,
  String text, {
  MessageStatus status = MessageStatus.sent,
  String? attemptKey,
  List<ContentPart>? parts,
}) => Message(
  id: id,
  role: MessageRole.user,
  parts: parts ?? [ContentPart.text(text)],
  status: status,
  attemptKey: attemptKey ?? 'key-$id',
  createdAt: DateTime.utc(2026, 7, 10, 9),
);

Message assistantMessage(
  String id,
  String text, {
  MessageStatus status = MessageStatus.complete,
  String? attemptKey,
  List<ContentPart>? parts,
}) => Message(
  id: id,
  role: MessageRole.assistant,
  parts: parts ?? [ContentPart.text(text)],
  status: status,
  attemptKey: attemptKey ?? 'key-$id',
  createdAt: DateTime.utc(2026, 7, 10, 9, 1),
);

Message systemMessage(String id, String text) => Message(
  id: id,
  role: MessageRole.system,
  parts: [ContentPart.text(text)],
  status: MessageStatus.complete,
  createdAt: DateTime.utc(2026, 7, 10, 8),
);

const BotProfile plainProfile = BotProfile(
  id: 'premium',
  systemPrompt: 'be kind',
  tools: [],
);

/// One place to build a deterministic session over any backend.
ChatSession makeSession({
  required ChatBackend backend,
  BotProfile botProfile = plainProfile,
  OnToolCall? onToolCall,
  Conversation? history,
  int? trimBudget,
  int maxToolTurns = 5,
  Duration retryDeadline = const Duration(seconds: 30),
  ImageSendOptions imageOptions = const ImageSendOptions(),
  ConversationCheckpoint? checkpoint,
  FakeTime? time,
  SequentialUuid? uuid,
  double Function()? random,
  Future<Uint8List> Function(Uint8List, ImageSendOptions)? processImage,
}) => chatSessionForTesting(
  backend: backend,
  botProfile: botProfile,
  onToolCall: onToolCall,
  history: history,
  trimBudget: trimBudget,
  maxToolTurns: maxToolTurns,
  retryDeadline: retryDeadline,
  imageOptions: imageOptions,
  checkpoint: checkpoint,
  now: time?.now,
  newUuid: uuid?.call,
  delay: time?.delay,
  random: random ?? () => 1.0,
  processImage: processImage,
);

/// The provider-effective projection of a request (SERVER-CONTRACT §6):
/// what the proxy hashes — `wireVersion` and the client-only Message fields
/// (`id`, `status`, `createdAt`, `attemptKey`) stripped. Lets tests compare
/// the FULL request shape, not only the idempotency key.
Map<String, Object?> providerEffective(ChatRequest request) => {
  'botId': request.botId,
  'system': request.system,
  'messages': [
    for (final message in request.messages)
      {
        'role': message.role.name,
        'parts': [for (final part in message.parts) part.toJson()],
      },
  ],
  'tools': [
    for (final tool in request.tools)
      {
        'name': tool.name,
        'description': tool.description,
        'parameters': tool.parameters,
      },
  ],
};

/// The visible text of a Message (its text parts, concatenated).
String visibleText(Message message) => [
  for (final part in message.parts)
    if (part is TextPart) part.text,
].join();

/// Waits until the CURRENT state matches — immune to a terminal that was
/// emitted before the caller could subscribe to [ChatSession.states].
Future<ConversationState> waitForState(
  ChatSession session,
  bool Function(ConversationState state) test,
) async {
  while (!test(session.state)) {
    await Future<void>.delayed(Duration.zero);
  }
  return session.state;
}
