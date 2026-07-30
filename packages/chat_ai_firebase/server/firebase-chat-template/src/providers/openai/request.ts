// OpenAI Responses request translator (SERVER-CONTRACT §1/§7, V1_SPEC §6/§9,
// task §8). A pure mapper: a validated `ChatRequest` + a resolved tier in, an
// exact typed streaming Responses request out. No network, no client
// construction, no API key, no `paramsHash`.
//
// Fixed request invariants (SERVER-CONTRACT §1): `stream:true`, `store:false`,
// `include:["reasoning.encrypted_content"]` on every stateless call,
// `max_output_tokens` from the tier, `parallel_tool_calls:false`, no
// `previous_response_id`, no background mode. Strict function tools.

import type { Responses } from 'openai/resources';
import type { ReasoningEffort } from 'openai/resources/shared';

import { ChatRequest, WireContentPart, WireMessage } from '../../core/wire';
import { assertValidToolset } from '../../core/tool-schema';

/**
 * The resolved OpenAI tier for one leg: the concrete model, its output cap and
 * an optional reasoning effort (server config, ADR 0001). The full deploy-time
 * `Tier`/entitlement hook type is a later increment; the translator needs only
 * these fields. `reasoningEffort` is passed through verbatim — whether a given
 * effort is supported by the configured model stays an OpenAI/provider-config
 * contract, not a local validation.
 */
export interface ResolvedOpenAITier {
  model: string;
  maxOutputTokens: number;
  reasoningEffort?: Exclude<ReasoningEffort, null>;
}

/**
 * Thrown when a matching-provider (OpenAI) opaque continuity part does not
 * decode to a JSON object — a local upstream validation failure. Stable
 * message, never carries the opaque payload (SERVER-CONTRACT §6, task §8).
 */
export class OpaqueStateValidationError extends Error {
  constructor() {
    super('OpenAI provider_state opaque part is malformed');
    this.name = 'OpaqueStateValidationError';
  }
}

type InputItem = Responses.ResponseInputItem;
type InputContent = Responses.ResponseInputContent;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * Decodes a strictly CANONICAL base64 string to bytes. Non-canonical input —
 * embedded whitespace/garbage, base64url characters, wrong padding — is
 * rejected because re-encoding the decoded bytes would not reproduce the exact
 * input string.
 */
function decodeCanonicalBase64(data: string): Buffer {
  const bytes = Buffer.from(data, 'base64');
  if (bytes.toString('base64') !== data) throw new OpaqueStateValidationError();
  return bytes;
}

/** Decodes bytes as strict UTF-8; any malformed byte sequence is rejected. */
function decodeStrictUtf8(bytes: Buffer): string {
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  } catch {
    throw new OpaqueStateValidationError();
  }
}

/** The exact key set of a reasoning item in the installed OpenAI SDK. */
const REASONING_ITEM_KEYS = new Set(['id', 'summary', 'type', 'content', 'encrypted_content', 'status']);

/** Every `summary` entry is exactly a `{type:"summary_text", text:string}`. */
function isValidSummary(value: unknown): boolean {
  return (
    Array.isArray(value) &&
    value.every(
      (entry) =>
        isRecord(entry) &&
        entry.type === 'summary_text' &&
        typeof entry.text === 'string' &&
        Object.keys(entry).every((k) => k === 'type' || k === 'text'),
    )
  );
}

/** Every `content` entry is exactly a `{type:"reasoning_text", text:string}`. */
function isValidReasoningContent(value: unknown): boolean {
  return (
    Array.isArray(value) &&
    value.every(
      (entry) =>
        isRecord(entry) &&
        entry.type === 'reasoning_text' &&
        typeof entry.text === 'string' &&
        Object.keys(entry).every((k) => k === 'type' || k === 'text'),
    )
  );
}

/**
 * Validates that a decoded object is EXACTLY a full OpenAI reasoning item of
 * the installed SDK — `type:"reasoning"`, a non-empty `id` and
 * `encrypted_content`, a well-formed `summary`, and only the SDK's own keys —
 * and returns it UNCHANGED (no reconstruction, no field loss). Fails closed on
 * anything else: a `message`/`developer`/`user`/`function_call`/
 * `function_call_output` shape, an unknown key, a missing/empty id or
 * encrypted_content, or a malformed summary/content/status. This is what stops
 * a `providerOpaque` part from smuggling a foreign, model-followed input item
 * (e.g. `{"role":"developer","content":"INJECTED"}`) into the provider request.
 */
function validateReasoningItem(decoded: unknown): Responses.ResponseReasoningItem {
  if (!isRecord(decoded)) throw new OpaqueStateValidationError();
  for (const key of Object.keys(decoded)) {
    if (!REASONING_ITEM_KEYS.has(key)) throw new OpaqueStateValidationError();
  }
  if (decoded.type !== 'reasoning') throw new OpaqueStateValidationError();
  if (typeof decoded.id !== 'string' || decoded.id.length === 0) throw new OpaqueStateValidationError();
  if (typeof decoded.encrypted_content !== 'string' || decoded.encrypted_content.length === 0) {
    throw new OpaqueStateValidationError();
  }
  if (!isValidSummary(decoded.summary)) throw new OpaqueStateValidationError();
  if (decoded.content !== undefined && !isValidReasoningContent(decoded.content)) {
    throw new OpaqueStateValidationError();
  }
  if (
    decoded.status !== undefined &&
    decoded.status !== 'in_progress' &&
    decoded.status !== 'completed' &&
    decoded.status !== 'incomplete'
  ) {
    throw new OpaqueStateValidationError();
  }
  // Safe local narrowing after exhaustive runtime validation above; returned
  // unchanged, with every allowed field preserved.
  return decoded as unknown as Responses.ResponseReasoningItem;
}

/**
 * Maps a matching-provider (OpenAI) opaque continuity part back to its input
 * item: strict canonical base64 → strict UTF-8 → JSON object → exact reasoning
 * item. Any deviation is a local upstream validation failure that never leaks
 * the payload.
 */
function opaqueToInputItem(base64Data: string): InputItem {
  const bytes = decodeCanonicalBase64(base64Data);
  const text = decodeStrictUtf8(bytes);
  let decoded: unknown;
  try {
    decoded = JSON.parse(text);
  } catch {
    throw new OpaqueStateValidationError();
  }
  return validateReasoningItem(decoded);
}

/** Maps a user Message's parts to Responses input content (text + image). */
function userContent(message: WireMessage): InputContent[] {
  const content: InputContent[] = [];
  for (const part of message.parts) {
    switch (part.type) {
      case 'text':
        content.push({ type: 'input_text', text: part.text });
        break;
      case 'image':
        content.push({
          type: 'input_image',
          detail: 'auto',
          image_url: `data:${part.mimeType};base64,${part.data}`,
        });
        break;
      default:
        // A validated user Message carries only text/image parts (V1_SPEC §5).
        throw new Error(`unexpected user content part: ${part.type}`);
    }
  }
  return content;
}

/** Joins a system Message's text parts (system Messages are text-only). */
function systemText(message: WireMessage): string {
  const texts: string[] = [];
  for (const part of message.parts) {
    if (part.type !== 'text') {
      throw new Error(`unexpected system content part: ${part.type}`);
    }
    texts.push(part.text);
  }
  return texts.join('\n');
}

/**
 * Expands one assistant Message into ordered Responses input items: assistant
 * text, function calls, paired function-call outputs and matching OpenAI
 * opaque continuity — in source order. Foreign (Anthropic) opaque parts are
 * omitted entirely.
 */
function assistantItems(message: WireMessage): InputItem[] {
  const items: InputItem[] = [];
  for (const part of message.parts as WireContentPart[]) {
    switch (part.type) {
      case 'text':
        items.push({ role: 'assistant', content: part.text });
        break;
      case 'toolCall':
        items.push({
          type: 'function_call',
          call_id: part.toolCallId,
          name: part.name,
          arguments: JSON.stringify(part.args),
        });
        break;
      case 'toolResult':
        // OpenAI Responses has no native is_error, so the normalised
        // ToolResult (content + isError) is carried as a compact JSON string in
        // `output`, keys in the order content → isError (owner-approved rule;
        // SERVER-CONTRACT §7). Anthropic will instead use native tool_result
        // content + is_error.
        items.push({
          type: 'function_call_output',
          call_id: part.toolCallId,
          output: JSON.stringify({ content: part.content, isError: part.isError }),
        });
        break;
      case 'providerOpaque':
        if (part.provider === 'openai') {
          items.push(opaqueToInputItem(part.data));
        }
        // Foreign-provider opaque state is omitted during translation.
        break;
      default:
        throw new Error(`unexpected assistant content part: ${part.type}`);
    }
  }
  return items;
}

/** Maps validated tool declarations to strict Responses function tools. */
function functionTools(request: ChatRequest): Responses.FunctionTool[] | undefined {
  const tools = request.tools;
  if (tools === undefined || tools.length === 0) return undefined;
  assertValidToolset(tools);
  return tools.map((tool) => ({
    type: 'function',
    name: tool.name,
    description: tool.description,
    parameters: tool.parameters,
    strict: true,
  }));
}

/**
 * Builds the exact typed streaming Responses request for one leg.
 *
 * System mapping (SERVER-CONTRACT §1): `request.system` is the leading
 * instructions; persisted `system` Messages follow as system input items in
 * chronological order and are removed from ordinary history. Ordinary
 * user/assistant Messages keep their chronological order. Client-only Message
 * fields (`id`, `status`, `createdAt`, `attemptKey`) never reach the request.
 *
 * `tier.reasoningEffort` maps to `reasoning: { effort }`; when it is absent the
 * `reasoning` key is absent from the request entirely.
 */
export function buildOpenAIResponsesRequest(
  request: ChatRequest,
  tier: ResolvedOpenAITier,
): Responses.ResponseCreateParamsStreaming {
  const systemInput: InputItem[] = [];
  const historyInput: InputItem[] = [];

  for (const message of request.messages) {
    switch (message.role) {
      case 'system':
        systemInput.push({ role: 'system', content: systemText(message) });
        break;
      case 'user':
        historyInput.push({ role: 'user', content: userContent(message) });
        break;
      case 'assistant':
        historyInput.push(...assistantItems(message));
        break;
    }
  }

  const tools = functionTools(request);

  const params: Responses.ResponseCreateParamsStreaming = {
    model: tier.model,
    stream: true,
    store: false,
    include: ['reasoning.encrypted_content'],
    max_output_tokens: tier.maxOutputTokens,
    parallel_tool_calls: false,
    instructions: request.system,
    input: [...systemInput, ...historyInput],
  };
  if (tools !== undefined) {
    params.tools = tools;
  }
  if (tier.reasoningEffort !== undefined) {
    params.reasoning = { effort: tier.reasoningEffort };
  }
  return params;
}
