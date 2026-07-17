// Package-internal fake transport/signaling seams + shared fixtures. No
// OpenAI, no real network, no real ephemeral secret anywhere in the tests.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:chat_ai/chat_ai.dart';
import 'package:chat_ai_openai_realtime/src/client_secret_provider.dart';
import 'package:chat_ai_openai_realtime/src/realtime_transport.dart';

class RecordingSecretProvider implements ClientSecretProvider {
  RecordingSecretProvider({this.secret = 'fake-ephemeral-secret', this.error});

  final String secret;
  final Object? error;
  final List<String> receivedBotIds = <String>[];
  int calls = 0;

  @override
  Future<String> getClientSecret({required String botId}) async {
    calls++;
    receivedBotIds.add(botId);
    final error = this.error;
    if (error != null) {
      throw error;
    }
    return secret;
  }
}

/// A secret provider whose Future never completes on its own — the test
/// completes (or fails) [completer] explicitly to model a late outcome.
class HangingSecretProvider implements ClientSecretProvider {
  final Completer<String> completer = Completer<String>();
  int calls = 0;

  @override
  Future<String> getClientSecret({required String botId}) {
    calls++;
    return completer.future;
  }
}

class FakeTransport implements RealtimeTransport {
  FakeTransport({this.connectError, FakeConnection? connection})
    : connection = connection ?? FakeConnection();

  final Object? connectError;
  final FakeConnection connection;
  int connectCalls = 0;
  final List<String> receivedSecrets = <String>[];
  RealtimeCancellation? receivedCancellation;

  /// The suspended connect was actively aborted by the cancellation signal.
  bool abortedByCancellation = false;

  /// When set, connect() suspends on the gate. By default the suspended
  /// connect honours the cancellation signal like the production transport:
  /// it aborts, releases its partial resources and throws. With
  /// [ignoreCancellation] it models a transport whose connect races the
  /// cancel and completes successfully anyway.
  Completer<void>? gate;
  bool ignoreCancellation = false;

  @override
  Future<RealtimeConnection> connect(
    String clientSecret,
    RealtimeCancellation cancellation,
  ) async {
    connectCalls++;
    receivedSecrets.add(clientSecret);
    receivedCancellation = cancellation;
    final gate = this.gate;
    if (gate != null) {
      if (ignoreCancellation) {
        await gate.future;
      } else {
        await Future.any(<Future<void>>[
          gate.future,
          cancellation.whenCancelled,
        ]);
        if (cancellation.isCancelled) {
          abortedByCancellation = true;
          await connection.close(); // partial resources released
          throw const RealtimeConnectCancelled();
        }
      }
    }
    final connectError = this.connectError;
    if (connectError != null) {
      throw connectError;
    }
    return connection;
  }
}

class FakeConnection implements RealtimeConnection {
  final StreamController<String> serverEvents = StreamController<String>();
  final List<String> sent = <String>[];

  /// When set, send() throws it (before recording anything as sent).
  Object? sendError;
  Object? closeError;
  int closeCalls = 0;

  /// When set, send() records the message but its returned Future never
  /// completes — models a `response.create` dispatch whose Future hangs
  /// forever, which the idle watchdog must still fire past.
  Completer<void>? sendGate;

  @override
  Stream<String> get events =>
      _InstantCancelStream<String>(serverEvents.stream);

  @override
  Future<void> send(String message) {
    final sendError = this.sendError;
    if (sendError != null) {
      throw sendError;
    }
    sent.add(message);
    final gate = sendGate;
    if (gate != null) {
      return gate.future;
    }
    return Future<void>.value();
  }

  @override
  Future<void> close() {
    closeCalls++;
    final closeError = this.closeError;
    // Fire-and-forget the source close like a real socket close, so a fake
    // clock never has to drive its completion; the call count is what matters.
    if (!serverEvents.isClosed) {
      unawaited(serverEvents.close());
    }
    return closeError != null
        ? Future<void>.error(closeError)
        : Future<void>.value();
  }

  List<Map<String, dynamic>> get sentJson => [
    for (final message in sent) jsonDecode(message) as Map<String, dynamic>,
  ];

  List<Map<String, dynamic>> get sentResponseCreates => [
    for (final event in sentJson)
      if (event['type'] == 'response.create') event,
  ];
}

/// A single-subscription stream wrapper whose subscription `cancel()` always
/// resolves right away (the real inner cancel is fired and forgotten). A real
/// WebSocket subscription cancel completes too; this only makes that
/// completion observable under a fake clock, where `StreamSubscription.cancel`
/// otherwise never settles.
class _InstantCancelStream<T> extends Stream<T> {
  _InstantCancelStream(this._inner);

  final Stream<T> _inner;

  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _InstantCancelSubscription<T>(
    _inner.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    ),
  );
}

class _InstantCancelSubscription<T> implements StreamSubscription<T> {
  _InstantCancelSubscription(this._inner);

  final StreamSubscription<T> _inner;

  @override
  Future<void> cancel() {
    unawaited(_inner.cancel());
    return Future<void>.value();
  }

  @override
  void onData(void Function(T data)? handleData) => _inner.onData(handleData);

  @override
  void onError(Function? handleError) => _inner.onError(handleError);

  @override
  void onDone(void Function()? handleDone) => _inner.onDone(handleDone);

  @override
  void pause([Future<void>? resumeSignal]) => _inner.pause(resumeSignal);

  @override
  void resume() => _inner.resume();

  @override
  bool get isPaused => _inner.isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) => _inner.asFuture(futureValue);
}

/// Collects one backend stream without ever letting an error pass silently.
class Collector {
  Collector(Stream<BackendEvent> stream) {
    subscription = stream.listen(
      events.add,
      onError: errors.add,
      onDone: () => done = true,
    );
  }

  final List<BackendEvent> events = <BackendEvent>[];
  final List<Object> errors = <Object>[];
  bool done = false;
  late final StreamSubscription<BackendEvent> subscription;
}

// --- fixtures -----------------------------------------------------------------

Message userTextMessage(
  String text, {
  String id = 'user-1',
  String attemptKey = 'attempt-user-1',
}) => Message(
  id: id,
  role: MessageRole.user,
  parts: [ContentPart.text(text)],
  status: MessageStatus.sent,
  attemptKey: attemptKey,
  createdAt: DateTime.utc(2026, 7, 16),
);

ChatRequest chatRequest({
  String botId = 'bot-1',
  String system = 'You are helpful.',
  List<Message>? messages,
  List<Tool> tools = const <Tool>[],
  String idempotencyKey = 'idempotency-key-1',
}) => ChatRequest(
  botId: botId,
  system: system,
  messages: messages ?? [userTextMessage('hi')],
  tools: tools,
  idempotencyKey: idempotencyKey,
);

Uint8List jpegBytes() =>
    Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0xFF, 0xD9]);

// --- server event fixtures ------------------------------------------------------

String responseCreated({String id = 'resp_1'}) => jsonEncode(<String, dynamic>{
  'type': 'response.created',
  'response': <String, dynamic>{'id': id, 'status': 'in_progress'},
});

/// A well-formed `response.output_text.delta` of Response [responseId].
String textDelta(
  String delta, {
  String responseId = 'resp_1',
  String itemId = 'item_1',
  int outputIndex = 0,
  int contentIndex = 0,
}) => jsonEncode(<String, dynamic>{
  'type': 'response.output_text.delta',
  'response_id': responseId,
  'item_id': itemId,
  'output_index': outputIndex,
  'content_index': contentIndex,
  'delta': delta,
});

/// A well-formed `response.output_text.done`.
String textDone({
  String text = 'Hello',
  String responseId = 'resp_1',
  String itemId = 'item_1',
  int outputIndex = 0,
  int contentIndex = 0,
}) => jsonEncode(<String, dynamic>{
  'type': 'response.output_text.done',
  'response_id': responseId,
  'item_id': itemId,
  'output_index': outputIndex,
  'content_index': contentIndex,
  'text': text,
});

/// A well-formed `response.content_part.added` (or `.done` when [done]).
String contentPart({
  bool done = false,
  String responseId = 'resp_1',
  String itemId = 'item_1',
  int outputIndex = 0,
  int contentIndex = 0,
}) => jsonEncode(<String, dynamic>{
  'type': done ? 'response.content_part.done' : 'response.content_part.added',
  'response_id': responseId,
  'item_id': itemId,
  'output_index': outputIndex,
  'content_index': contentIndex,
  'part': <String, dynamic>{'type': 'text', 'text': ''},
});

Map<String, dynamic> usageJson({int input = 10, int output = 5}) =>
    <String, dynamic>{
      'input_tokens': input,
      'output_tokens': output,
      'total_tokens': input + output,
    };

/// A completed `response.done`; [usage] defaults to a valid usage object.
String responseDoneCompleted({Object? usage}) => jsonEncode(<String, dynamic>{
  'type': 'response.done',
  'response': <String, dynamic>{
    'id': 'resp_1',
    'status': 'completed',
    'usage': usage ?? usageJson(),
  },
});

/// A completed `response.done` with NO usage object at all.
String responseDoneCompletedWithoutUsage() => jsonEncode(<String, dynamic>{
  'type': 'response.done',
  'response': <String, dynamic>{'id': 'resp_1', 'status': 'completed'},
});

String functionCallItemAdded({
  int outputIndex = 0,
  String callId = 'call_1',
  String name = 'get_weather',
  String responseId = 'resp_1',
  String itemId = 'item_1',
}) => jsonEncode(<String, dynamic>{
  'type': 'response.output_item.added',
  'response_id': responseId,
  'output_index': outputIndex,
  'item': <String, dynamic>{
    'id': itemId,
    'type': 'function_call',
    'call_id': callId,
    'name': name,
    'arguments': '',
  },
});

String functionCallArgsDelta(
  String delta, {
  int outputIndex = 0,
  String responseId = 'resp_1',
  String itemId = 'item_1',
  String callId = 'call_1',
}) => jsonEncode(<String, dynamic>{
  'type': 'response.function_call_arguments.delta',
  'response_id': responseId,
  'item_id': itemId,
  'call_id': callId,
  'output_index': outputIndex,
  'delta': delta,
});

String functionCallArgsDone(
  String arguments, {
  int outputIndex = 0,
  String responseId = 'resp_1',
  String itemId = 'item_1',
  String callId = 'call_1',
}) => jsonEncode(<String, dynamic>{
  'type': 'response.function_call_arguments.done',
  'response_id': responseId,
  'item_id': itemId,
  'call_id': callId,
  'output_index': outputIndex,
  'arguments': arguments,
});
