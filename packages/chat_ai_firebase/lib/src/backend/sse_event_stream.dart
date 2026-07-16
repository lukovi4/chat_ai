import 'package:chat_ai/chat_ai.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import 'sse_event_decoder.dart';
import 'sse_parser.dart';

/// Stable logs-only detail for a stream that ends before any terminal event
/// (V1_SPEC §8 "EOF without terminal"; SERVER-CONTRACT §2: "`done` is the
/// only proof of completion of the final leg").
const String _eofWithoutTerminalDetail =
    'SSE stream ended without a terminal event';

/// Stable logs-only detail for a [FormatException] raised by the frame
/// stream itself (framing / strict UTF-8 defects from `parseSseFrames`).
/// Deliberately a constant: the original exception text and `source` may
/// embed raw wire bytes and must never be echoed.
const String _malformedFrameStreamDetail = 'Malformed SSE frame stream';

/// Internal lifecycle of the normalized SSE event stream (V1_SPEC §8 "SSE
/// parser contract", §12.16; SERVER-CONTRACT §2): `Stream<SseFrame>` →
/// `Stream<BackendEvent>`. Not exported from `package:chat_ai/chat_ai.dart`.
///
/// Before the terminal, every frame is decoded with [decodeSseFrame] and
/// emitted unchanged, in input order — [ProviderStateEvent] keeps its order
/// relative to [Delta] (SERVER-CONTRACT §2: original content order).
///
/// **First terminal wins.** [ToolCallEvent], [DoneEvent] and [ErrorEvent]
/// are the only terminals. The first one is emitted exactly once and closes
/// the logical stream: no [BackendEvent] is ever emitted after it — ignored
/// frames and late input errors are only reported to debug diagnostics via
/// [_debugMarker], classified by `frame.event` alone (a late frame is never
/// decoded). [Accepted], [ConflictEvent] and [GoneEvent] never appear
/// here: they are HTTP-layer facts (V1_SPEC §6 "Protocol signals") that
/// [decodeSseFrame] rejects on the wire.
///
/// **Parser defects never escape as stream errors** (V1_SPEC §8):
/// - [decodeSseFrame] throwing [FormatException] before the terminal becomes
///   exactly one `ErrorEvent(upstream, detail: exception.message)` — the
///   decoder's messages are sanitized by contract — and that event IS the
///   terminal; the remaining frames are ignored per first-terminal-wins;
/// - a [FormatException] raised by [frames] itself before the terminal
///   (framing / strict UTF-8 defect) becomes exactly one
///   `ErrorEvent(upstream)` with the stable [_malformedFrameStreamDetail];
/// - EOF before any terminal — a completely empty stream included — becomes
///   exactly one `ErrorEvent(upstream)` with [_eofWithoutTerminalDetail].
///
/// A non-[FormatException] error from [frames] is a transport fact this
/// layer does not classify: before the terminal it passes through untouched
/// (the future transport adapter maps it — the public "never throws"
/// guarantee of `ChatBackend.send` is completed there, V1_SPEC §8); after
/// the terminal it is swallowed with a debug marker.
///
/// No detail or diagnostic built here contains `frame.data`, unknown event
/// names, `exception.toString()`, `exception.source` or stack traces.
Stream<BackendEvent> decodeSseEventStream(Stream<SseFrame> frames) async* {
  var terminal = false;
  try {
    await for (final frame in frames) {
      if (terminal) {
        // Classified by frame.event ALONE — a late frame is never decoded:
        // no JSON/base64 parsing and no BackendEvent/ToolCall/Usage/
        // ProviderOpaquePart construction happens after the terminal. The
        // marker never carries the actual event value or frame.data.
        _debugMarker(
          () => switch (frame.event) {
            'tool_call' || 'done' || 'error' => 'duplicate terminal ignored',
            _ => 'event after terminal ignored',
          },
        );
        continue;
      }
      final BackendEvent event;
      try {
        event = decodeSseFrame(frame);
      } on FormatException catch (exception) {
        terminal = true;
        yield BackendEvent.error(
          FailureCause.upstream,
          detail: exception.message,
        );
        continue;
      }
      yield event;
      if (event is ToolCallEvent || event is DoneEvent || event is ErrorEvent) {
        terminal = true;
      }
    }
  } on FormatException {
    if (terminal) {
      _debugMarker(() => 'malformed frame stream after terminal ignored');
      return;
    }
    yield const BackendEvent.error(
      FailureCause.upstream,
      detail: _malformedFrameStreamDetail,
    );
    return;
  } catch (_) {
    if (terminal) {
      _debugMarker(() => 'transport error after terminal ignored');
      return;
    }
    rethrow;
  }
  if (!terminal) {
    yield const BackendEvent.error(
      FailureCause.upstream,
      detail: _eofWithoutTerminalDetail,
    );
  }
}

/// The single debug-only diagnostics hook of this layer (V1_SPEC §8: ignored
/// input is "reported to debug diagnostics, never emitted as a second
/// outcome"). [describe] runs only inside [assert]: in release builds
/// neither it nor [debugPrint] executes. Markers are stable strings by
/// construction — call sites never interpolate frame data, event names or
/// exception text into them.
void _debugMarker(String Function() describe) {
  assert(() {
    debugPrint('chat_ai SSE lifecycle: ${describe()}');
    return true;
  }());
}
