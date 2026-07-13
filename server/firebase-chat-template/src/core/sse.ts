// Normalised SSE frame encoder (SERVER-CONTRACT §2, V1_SPEC §6). One
// `NormalizedEvent` in, one framed SSE string out — nothing else. This is pure
// event encoding: no HTTP streaming, no keepalive, no connection lifecycle
// (those belong to the future HTTP handler, out of scope this increment).
//
// The output is byte-compatible with the Dart `decodeSseFrame`
// (lib/src/backend/sse_event_decoder.dart):
//   - the event name is one of `delta | provider_state | tool_call | done |
//     error`;
//   - `data:` carries COMPACT JSON (no insignificant whitespace) with exactly
//     the pinned fields;
//   - a blank line terminates the frame.
//
// No user payload ever reaches an exception here: the encoder does not throw on
// content. The single defensive throw (an out-of-catalogue cause) carries only
// a fixed string, never the offending value.

import {
  NormalizedEvent,
  NormalizedUsage,
  WIRE_CAUSES,
  WireCause,
} from './wire';

/** Base64 of a complete provider continuity item (SERVER-CONTRACT §2). */
function base64(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString('base64');
}

/**
 * Serialises `Usage` in the pinned key order `{inputTokens, outputTokens,
 * usageRaw?}` (V1_SPEC §6). `usageRaw` is omitted when absent; the Dart decoder
 * reads by key name, so order is cosmetic there but fixed here for byte-exact
 * goldens.
 */
function usageJson(usage: NormalizedUsage): Record<string, unknown> {
  const out: Record<string, unknown> = {
    inputTokens: usage.inputTokens,
    outputTokens: usage.outputTokens,
  };
  if (usage.usageRaw !== undefined) {
    out.usageRaw = usage.usageRaw;
  }
  return out;
}

function isWireCause(cause: string): cause is WireCause {
  return (WIRE_CAUSES as readonly string[]).includes(cause);
}

/** The `event:` name and the JSON object for one normalised event. */
function frameOf(event: NormalizedEvent): {
  name: string;
  data: Record<string, unknown>;
} {
  switch (event.kind) {
    case 'delta':
      return { name: 'delta', data: { text: event.text } };
    case 'provider_state':
      return {
        name: 'provider_state',
        data: { provider: event.provider, data: base64(event.data) },
      };
    case 'tool_call': {
      const data: Record<string, unknown> = {
        id: event.id,
        name: event.name,
        args: event.args,
      };
      if (event.usage !== undefined) {
        data.usage = usageJson(event.usage);
      }
      return { name: 'tool_call', data };
    }
    case 'done': {
      const data: Record<string, unknown> = {};
      if (event.usage !== undefined) {
        data.usage = usageJson(event.usage);
      }
      return { name: 'done', data };
    }
    case 'error': {
      // Defensive: the type already excludes `tool-loop-limit` and every other
      // non-catalogue value; this guard fails closed if an `as` cast smuggles
      // one in. The rejected value is never echoed (no payload leakage).
      if (!isWireCause(event.cause)) {
        throw new Error('SSE error event: cause is not a server wire cause');
      }
      const data: Record<string, unknown> = { cause: event.cause };
      if (event.detail !== undefined) {
        data.detail = event.detail;
      }
      if (event.usage !== undefined) {
        data.usage = usageJson(event.usage);
      }
      if (event.retryAfterMs !== undefined) {
        data.retryAfterMs = event.retryAfterMs;
      }
      return { name: 'error', data };
    }
  }
}

/**
 * Encodes one normalised event as a framed SSE string:
 * `event: <name>\ndata: <compact json>\n\n`.
 */
export function encodeSseFrame(event: NormalizedEvent): string {
  const { name, data } = frameOf(event);
  return `event: ${name}\ndata: ${JSON.stringify(data)}\n\n`;
}
