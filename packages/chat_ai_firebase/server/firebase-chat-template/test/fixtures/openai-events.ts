// Local, deterministic builders for typed OpenAI Responses streaming events and
// Response objects. They construct REAL SDK discriminated-union values (no
// `any`, no snapshots of huge live objects) so the stream translator is tested
// against the exact types it consumes in production. No network, no API key.

import type { Responses } from 'openai/resources';

let seq = 0;
const next = (): number => ++seq;

/** A full `ResponseUsage` with the required token-detail breakdowns. */
export function makeUsage(inputTokens: number, outputTokens: number): Responses.ResponseUsage {
  return {
    input_tokens: inputTokens,
    input_tokens_details: { cache_write_tokens: 0, cached_tokens: 0 },
    output_tokens: outputTokens,
    output_tokens_details: { reasoning_tokens: 0 },
    total_tokens: inputTokens + outputTokens,
  };
}

/** A `Response` with every required field defaulted; override what a test needs. */
export function makeResponse(overrides: Partial<Responses.Response> = {}): Responses.Response {
  return {
    id: 'resp_test',
    created_at: 0,
    output_text: '',
    error: null,
    incomplete_details: null,
    instructions: null,
    metadata: null,
    model: 'gpt-test',
    object: 'response',
    output: [],
    parallel_tool_calls: false,
    temperature: null,
    tool_choice: 'auto',
    tools: [],
    top_p: null,
    ...overrides,
  };
}

export function textDelta(
  delta: string,
  opts: { outputIndex?: number; itemId?: string } = {},
): Responses.ResponseTextDeltaEvent {
  return {
    type: 'response.output_text.delta',
    content_index: 0,
    delta,
    item_id: opts.itemId ?? 'item_text',
    logprobs: [],
    output_index: opts.outputIndex ?? 0,
    sequence_number: next(),
  };
}

export function functionCallAdded(opts: {
  outputIndex: number;
  callId: string;
  name: string;
}): Responses.ResponseOutputItemAddedEvent {
  return {
    type: 'response.output_item.added',
    item: {
      type: 'function_call',
      call_id: opts.callId,
      name: opts.name,
      arguments: '',
    },
    output_index: opts.outputIndex,
    sequence_number: next(),
  };
}

export function functionArgsDelta(opts: {
  outputIndex: number;
  delta: string;
  itemId?: string;
}): Responses.ResponseFunctionCallArgumentsDeltaEvent {
  return {
    type: 'response.function_call_arguments.delta',
    delta: opts.delta,
    item_id: opts.itemId ?? 'item_call',
    output_index: opts.outputIndex,
    sequence_number: next(),
  };
}

export function functionArgsDone(opts: {
  outputIndex: number;
  arguments: string;
  name: string;
  itemId?: string;
}): Responses.ResponseFunctionCallArgumentsDoneEvent {
  return {
    type: 'response.function_call_arguments.done',
    arguments: opts.arguments,
    item_id: opts.itemId ?? 'item_call',
    name: opts.name,
    output_index: opts.outputIndex,
    sequence_number: next(),
  };
}

export function functionCallDone(opts: {
  outputIndex: number;
  callId: string;
  name: string;
  arguments: string;
}): Responses.ResponseOutputItemDoneEvent {
  return {
    type: 'response.output_item.done',
    item: {
      type: 'function_call',
      call_id: opts.callId,
      name: opts.name,
      arguments: opts.arguments,
    },
    output_index: opts.outputIndex,
    sequence_number: next(),
  };
}

/** A complete reasoning output item (the OpenAI provider-continuity item). */
export function makeReasoningItem(overrides: Partial<Responses.ResponseReasoningItem> = {}): Responses.ResponseReasoningItem {
  return {
    id: 'rs_test',
    summary: [],
    type: 'reasoning',
    encrypted_content: 'ENCRYPTED',
    ...overrides,
  };
}

export function reasoningItemDone(
  item: Responses.ResponseReasoningItem,
  outputIndex = 0,
): Responses.ResponseOutputItemDoneEvent {
  return {
    type: 'response.output_item.done',
    item,
    output_index: outputIndex,
    sequence_number: next(),
  };
}

export function refusalDone(refusal = 'I cannot help with that.'): Responses.ResponseRefusalDoneEvent {
  return {
    type: 'response.refusal.done',
    content_index: 0,
    item_id: 'item_refusal',
    output_index: 0,
    refusal,
    sequence_number: next(),
  };
}

export function responseCompleted(response: Responses.Response): Responses.ResponseCompletedEvent {
  return { type: 'response.completed', response, sequence_number: next() };
}

export function responseFailed(response: Responses.Response): Responses.ResponseFailedEvent {
  return { type: 'response.failed', response, sequence_number: next() };
}

export function responseIncomplete(response: Responses.Response): Responses.ResponseIncompleteEvent {
  return { type: 'response.incomplete', response, sequence_number: next() };
}

export function errorEvent(): Responses.ResponseErrorEvent {
  return {
    type: 'error',
    code: 'server_error',
    message: 'internal',
    param: null,
    sequence_number: next(),
  };
}

/** Wraps a static event list as the `AsyncIterable` the translator consumes. */
export async function* asStream(
  events: Responses.ResponseStreamEvent[],
): AsyncGenerator<Responses.ResponseStreamEvent> {
  for (const event of events) {
    yield event;
  }
}
