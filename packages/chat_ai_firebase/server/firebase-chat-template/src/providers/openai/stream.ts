// OpenAI Responses stream translator (SERVER-CONTRACT §2/§7, task §9). A pure
// async translator over the OpenAI SDK's typed streaming events into the
// normalised event stream. No live API calls, no SDK client here.
//
// Terminal policy (task §9.7): exactly one terminal event, first-terminal-wins;
// once a terminal is yielded the generator returns, so any later provider
// events are ignored without re-decoding. No raw provider error/body/user
// payload ever reaches a client `detail`.

import type { Responses } from 'openai/resources';

import { NormalizedEvent, NormalizedUsage, WireCause } from '../../core/wire';

/** A leg token count: a non-negative safe integer (task §9.6 / usage rules). */
function isValidTokenCount(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0;
}

/**
 * Normalises a provider `ResponseUsage` into leg Usage, or `null` when it is
 * absent or malformed. `input_tokens`/`output_tokens` are accepted only as
 * non-negative safe integers — a fractional, negative, NaN/Infinity or missing
 * count yields `null` (→ `upstream`, never a faked zero; task §9.4). `usageRaw`
 * keeps the full provider usage payload (token counts only — no user content).
 */
function normalizeUsage(usage: Responses.ResponseUsage | undefined): NormalizedUsage | null {
  if (usage === undefined) return null;
  const { input_tokens: inputTokens, output_tokens: outputTokens } = usage;
  if (!isValidTokenCount(inputTokens) || !isValidTokenCount(outputTokens)) return null;
  return {
    inputTokens,
    outputTokens,
    usageRaw: usage as unknown as Record<string, unknown>,
  };
}

/** A terminal error with best-effort leg usage attached when it is available. */
function errorWithBestEffortUsage(
  cause: WireCause,
  response: Responses.Response,
): NormalizedEvent {
  const usage = normalizeUsage(response.usage);
  return usage === null ? { kind: 'error', cause } : { kind: 'error', cause, usage };
}

/** Accumulated state of the (at most one) function call on a leg. */
interface CallState {
  callId?: string;
  name?: string;
  deltaArgs: string; // buffered argument fragments
  finalArgs: string | null; // authoritative arguments once the call closes
}

/**
 * Translates a stream of typed OpenAI Responses events into normalised events.
 *
 * Rules (task §9):
 *  1. every non-empty text delta → exactly one `delta`, order preserved;
 *  2. a complete reasoning item with `encrypted_content` → one `provider_state`
 *     carrying the full item's UTF-8 JSON bytes; partial/plain reasoning is
 *     never surfaced;
 *  3. function-call argument fragments are buffered until the call closes, then
 *     parsed to a JSON object; a second call, or invalid/truncated JSON, is a
 *     terminal `upstream`; the terminal `tool_call` carries the leg's usage and
 *     is not followed by `done`;
 *  4. a normal completion with no pending call → `done` with normalised usage;
 *  5. a documented refusal/safety outcome → `content-filter`;
 *  6. failed/incomplete/unknown-terminal/malformed/EOF-without-terminal, and an
 *     input-iterator exception before a terminal → exactly one `upstream`.
 *
 * Errors are data: a throw from the underlying provider iterator is caught and
 * surfaced as one `error(upstream)` (no raw message/stack/source leaks in);
 * already-yielded `delta`/`provider_state` events are preserved; after a
 * terminal has been yielded the generator returns, so no further events (or
 * exceptions) are read, and consumer cancellation adds no extra event.
 */
export async function* translateOpenAIStream(
  events: AsyncIterable<Responses.ResponseStreamEvent>,
): AsyncGenerator<NormalizedEvent> {
  // At most one call per leg (parallel_tool_calls:false); keyed by output_index
  // so a genuinely second call is detectable and fails closed.
  const calls = new Map<number, CallState>();
  let firstCallIndex: number | null = null;

  const registerCall = (index: number, seed: Partial<CallState>): 'ok' | 'second' => {
    const existing = calls.get(index);
    if (existing) {
      Object.assign(existing, seed);
      return 'ok';
    }
    if (firstCallIndex !== null && firstCallIndex !== index) return 'second';
    firstCallIndex = index;
    calls.set(index, { deltaArgs: '', finalArgs: null, ...seed });
    return 'ok';
  };

  try {
    for await (const event of events) {
      switch (event.type) {
        case 'response.output_text.delta': {
          // Transparent passthrough: never merge, split or reorder; drop empties.
          if (event.delta.length > 0) {
            yield { kind: 'delta', text: event.delta };
          }
          break;
        }

        case 'response.output_item.added': {
          if (event.item.type === 'function_call') {
            const outcome = registerCall(event.output_index, {
              callId: event.item.call_id,
              name: event.item.name,
            });
            if (outcome === 'second') {
              yield { kind: 'error', cause: 'upstream' };
              return;
            }
          }
          break;
        }

        case 'response.function_call_arguments.delta': {
          const call = calls.get(event.output_index);
          if (call) call.deltaArgs += event.delta;
          break;
        }

        case 'response.function_call_arguments.done': {
          const call = calls.get(event.output_index);
          if (call) call.finalArgs = event.arguments;
          break;
        }

        case 'response.output_item.done': {
          const item = event.item;
          if (item.type === 'reasoning') {
            // Complete provider continuity item — emitted only with encrypted
            // content, serialised whole, never shown to the user.
            if (item.encrypted_content != null && item.encrypted_content !== '') {
              const bytes = Buffer.from(JSON.stringify(item), 'utf8');
              yield { kind: 'provider_state', provider: 'openai', data: new Uint8Array(bytes) };
            }
          } else if (item.type === 'compaction') {
            // Server-side Compact state (automatic `context_management`). Unlike
            // reasoning it is NOT optional continuity: it replaces the summarised
            // history, so an incomplete item may never be silently dropped —
            // continuing the reply without it would lose that history for good.
            if (
              typeof item.id !== 'string' ||
              item.id.length === 0 ||
              typeof item.encrypted_content !== 'string' ||
              item.encrypted_content.length === 0 ||
              (item.created_by !== undefined && typeof item.created_by !== 'string')
            ) {
              yield { kind: 'error', cause: 'upstream' };
              return;
            }
            const bytes = Buffer.from(JSON.stringify(item), 'utf8');
            yield { kind: 'provider_state', provider: 'openai', data: new Uint8Array(bytes) };
          } else if (item.type === 'function_call') {
            const outcome = registerCall(event.output_index, {
              callId: item.call_id,
              name: item.name,
              finalArgs: item.arguments,
            });
            if (outcome === 'second') {
              yield { kind: 'error', cause: 'upstream' };
              return;
            }
          }
          break;
        }

        case 'response.refusal.done': {
          // Documented refusal/safety outcome (task §9.5).
          yield { kind: 'error', cause: 'content-filter' };
          return;
        }

        case 'response.failed': {
          yield errorWithBestEffortUsage('upstream', event.response);
          return;
        }

        case 'response.incomplete': {
          const contentFiltered = event.response.incomplete_details?.reason === 'content_filter';
          yield errorWithBestEffortUsage(contentFiltered ? 'content-filter' : 'upstream', event.response);
          return;
        }

        case 'error': {
          // A stream-level provider error event; raw code/message never relayed.
          yield { kind: 'error', cause: 'upstream' };
          return;
        }

        case 'response.completed': {
          const usage = normalizeUsage(event.response.usage);

          if (calls.size > 0) {
            if (calls.size > 1) {
              yield { kind: 'error', cause: 'upstream' };
              return;
            }
            const call = calls.values().next().value as CallState;
            const argsText = call.finalArgs ?? call.deltaArgs;
            let parsed: unknown;
            try {
              parsed = JSON.parse(argsText);
            } catch {
              yield { kind: 'error', cause: 'upstream' };
              return;
            }
            if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
              yield { kind: 'error', cause: 'upstream' };
              return;
            }
            if (!call.callId || !call.name || usage === null) {
              yield { kind: 'error', cause: 'upstream' };
              return;
            }
            yield {
              kind: 'tool_call',
              id: call.callId,
              name: call.name,
              args: parsed as Record<string, unknown>,
              usage,
            };
            return;
          }

          if (usage === null) {
            yield { kind: 'error', cause: 'upstream' };
            return;
          }
          yield { kind: 'done', usage };
          return;
        }

        default:
          // Every other event is non-terminal and ignored.
          break;
      }
    }
  } catch {
    // The input iterator threw before any terminal (a terminal returns above,
    // so we cannot be here after one). Surface exactly one upstream terminal;
    // the raw exception message/stack/source never reaches the event.
    yield { kind: 'error', cause: 'upstream' };
    return;
  }

  // The stream ended without a terminal event (task §9.6).
  yield { kind: 'error', cause: 'upstream' };
}
