import 'dart:convert';

/// Internal SSE **framing** layer for the future `FirebaseChatBackend`
/// (V1_SPEC §8 "SSE parser contract", the framing subset of §12.16;
/// SERVER-CONTRACT §2–§3). Not exported from `package:chat_ai/chat_ai.dart`.
///
/// `Stream<List<int>> → Stream<SseFrame>` and nothing more: this layer does
/// not parse JSON, does not know the Chat AI event names and never produces a
/// `BackendEvent` — mapping frames to events (terminal policy, malformed
/// JSON, unknown events) is the backend adapter's job.
///
/// Framing rules implemented here:
/// - incremental UTF-8 decoding precedes line parsing; a *valid* UTF-8
///   scalar split between transport chunks still decodes correctly. Decoding
///   is STRICT (`allowMalformed: false`, the default): a malformed UTF-8
///   byte sequence inside the SSE bytes errors this framer's stream with a
///   [FormatException] — no frame is ever built from U+FFFD replacement
///   characters. The future `FirebaseChatBackend` adapter must catch that
///   error and turn it into exactly one `ErrorEvent(upstream)` (V1_SPEC §8);
///   the framer itself never creates a `BackendEvent` and knows no
///   `FailureCause`. An error on the *source* byte stream likewise passes
///   through untouched (dumb pipe).
/// - LF and CRLF line endings are accepted;
/// - one transport chunk may carry several events; one line (and the JSON
///   text inside it) may be split across chunks;
/// - comment lines (`:` first, e.g. the `: ping` keepalive, SERVER-CONTRACT
///   §3) are ignored;
/// - `event:` names the event; consecutive `data:` lines are joined with
///   `\n`; at most one space after the field colon is stripped;
/// - unknown fields (`id`, `retry`, v2's `streamId`/`eventId`, anything
///   else) are ignored (V1_SPEC §6 — ignored by the v1 client);
/// - an empty line dispatches the pending frame and resets the per-event
///   state; a block with no `data:` lines dispatches nothing (SSE semantics);
/// - at EOF a pending frame is flushed even without the trailing empty line —
///   whether "EOF without a terminal event" is an error is the next layer's
///   decision, not the framer's.
class SseFrame {
  const SseFrame({this.event, required this.data});

  /// The `event:` field of the block, or null when the block had none.
  final String? event;

  /// The joined `data:` payload (consecutive lines joined with `\n`).
  final String data;

  @override
  bool operator ==(Object other) =>
      other is SseFrame && other.event == event && other.data == data;

  @override
  int get hashCode => Object.hash(event, data);

  @override
  String toString() => 'SseFrame(event: $event, data: $data)';
}

/// Frames a raw SSE byte stream into [SseFrame]s. See [SseFrame] for the
/// exact framing rules. Malformed UTF-8 in [bytes] errors the returned
/// stream with a [FormatException] (strict decoding).
Stream<SseFrame> parseSseFrames(Stream<List<int>> bytes) async* {
  final framer = _SseFramer();
  final text = bytes.transform(const Utf8Decoder());
  await for (final chunk in text) {
    for (final frame in framer.addText(chunk)) {
      yield frame;
    }
  }
  for (final frame in framer.finish()) {
    yield frame;
  }
}

/// The stateful line/field accumulator behind [parseSseFrames].
class _SseFramer {
  /// The unterminated tail of the last chunk (a line still being received).
  String _tail = '';

  /// The `event:` buffer of the block in progress ('' = none seen yet).
  String _eventName = '';

  /// The joined `data:` buffer of the block in progress; each `data:` line
  /// appends its value plus `\n` (the trailing `\n` is removed on dispatch).
  final StringBuffer _data = StringBuffer();

  /// Whether the block in progress saw at least one `data:` line — a block
  /// without one dispatches nothing.
  bool _hasData = false;

  /// Consumes one decoded text chunk, returning the frames it completed.
  List<SseFrame> addText(String text) {
    final frames = <SseFrame>[];
    final combined = _tail + text;
    var start = 0;
    while (true) {
      final newline = combined.indexOf('\n', start);
      if (newline == -1) {
        break;
      }
      _processLine(
        _stripTrailingCr(combined.substring(start, newline)),
        frames,
      );
      start = newline + 1;
    }
    _tail = combined.substring(start);
    return frames;
  }

  /// EOF: treats an unterminated final line as complete, then flushes the
  /// pending frame even though no trailing empty line arrived.
  List<SseFrame> finish() {
    final frames = <SseFrame>[];
    final line = _stripTrailingCr(_tail);
    _tail = '';
    if (line.isNotEmpty) {
      _processLine(line, frames);
    }
    _dispatch(frames);
    return frames;
  }

  String _stripTrailingCr(String line) =>
      line.endsWith('\r') ? line.substring(0, line.length - 1) : line;

  void _processLine(String line, List<SseFrame> frames) {
    if (line.isEmpty) {
      _dispatch(frames);
      return;
    }
    if (line.startsWith(':')) {
      return; // comment / keepalive (`: ping`)
    }
    final colon = line.indexOf(':');
    final String field;
    String value;
    if (colon == -1) {
      field = line;
      value = '';
    } else {
      field = line.substring(0, colon);
      value = line.substring(colon + 1);
      if (value.startsWith(' ')) {
        value = value.substring(1); // at most one leading space is stripped
      }
    }
    switch (field) {
      case 'event':
        _eventName = value;
      case 'data':
        _data
          ..write(value)
          ..write('\n');
        _hasData = true;
      default:
      // Unknown field — ignored (`id`, `retry`, v2 `streamId`/`eventId`, …).
    }
  }

  void _dispatch(List<SseFrame> frames) {
    if (_hasData) {
      var data = _data.toString();
      if (data.endsWith('\n')) {
        data = data.substring(0, data.length - 1);
      }
      frames.add(
        SseFrame(event: _eventName.isEmpty ? null : _eventName, data: data),
      );
    }
    _eventName = '';
    _data.clear();
    _hasData = false;
  }
}
