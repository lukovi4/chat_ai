// Runtime HTTP/wire validation (SERVER-CONTRACT §5/§6, V1_SPEC §5/§6, task §4).
// Narrows an UNKNOWN parsed JSON body into the exact, closed `ChatRequest`
// shape, RECONSTRUCTING a clean typed value so unknown fields can never enter
// hashing or provider mapping. Tool declarations are re-checked through the
// existing `assertValidToolset`.
//
// The public result is a stable verdict with a sanitized reason — it never
// echoes the body, a value or user content (task §4 leakage rule).

import type {
  ChatRequest,
  WireContentPart,
  WireMessage,
  WireMessageRole,
  WireTool,
} from '../core/wire';
import { assertValidToolset, ToolSchemaValidationError } from '../core/tool-schema';

/** Canonical UUID v4 (the `Idempotency-Key`, ADR 0004). */
const UUID_V4_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/** Whether a header value is a canonical UUID v4. */
export function isUuidV4(value: unknown): value is string {
  return typeof value === 'string' && UUID_V4_RE.test(value);
}

/** A stable, sanitized failure reason (maps to a pre-stream status/detail). */
export type WireValidationReason =
  | 'unsupported-wire-version'
  | 'invalid-request'
  | 'invalid-tool-schema';

export type WireValidationResult =
  | { ok: true; request: ChatRequest }
  | { ok: false; reason: WireValidationReason };

const fail = (reason: WireValidationReason): WireValidationResult => ({ ok: false, reason });

type JsonObject = Record<string, unknown>;

function isObject(value: unknown): value is JsonObject {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

const ROLES: ReadonlySet<string> = new Set(['user', 'assistant', 'system']);

/** Reconstructs one closed content part, or `null` if it is malformed. */
function parsePart(raw: unknown): WireContentPart | null {
  if (!isObject(raw)) return null;
  switch (raw.type) {
    case 'text':
      return typeof raw.text === 'string' ? { type: 'text', text: raw.text } : null;
    case 'image':
      return raw.mimeType === 'image/jpeg' && typeof raw.data === 'string'
        ? { type: 'image', mimeType: 'image/jpeg', data: raw.data }
        : null;
    case 'toolCall':
      return typeof raw.toolCallId === 'string' &&
        typeof raw.name === 'string' &&
        isObject(raw.args)
        ? { type: 'toolCall', toolCallId: raw.toolCallId, name: raw.name, args: raw.args }
        : null;
    case 'toolResult':
      return typeof raw.toolCallId === 'string' &&
        typeof raw.content === 'string' &&
        typeof raw.isError === 'boolean'
        ? {
            type: 'toolResult',
            toolCallId: raw.toolCallId,
            content: raw.content,
            isError: raw.isError,
          }
        : null;
    case 'providerOpaque':
      return (raw.provider === 'openai' || raw.provider === 'anthropic') &&
        typeof raw.data === 'string'
        ? { type: 'providerOpaque', provider: raw.provider, data: raw.data }
        : null;
    default:
      return null;
  }
}

/** Reconstructs one closed Message, or `null` if it is malformed. */
function parseMessage(raw: unknown): WireMessage | null {
  if (!isObject(raw)) return null;
  if (typeof raw.id !== 'string') return null;
  if (typeof raw.role !== 'string' || !ROLES.has(raw.role)) return null;
  if (typeof raw.status !== 'string') return null;
  if (typeof raw.createdAt !== 'string') return null;
  if (raw.attemptKey !== undefined && typeof raw.attemptKey !== 'string') return null;
  if (!Array.isArray(raw.parts)) return null;

  const parts: WireContentPart[] = [];
  for (const rawPart of raw.parts) {
    const part = parsePart(rawPart);
    if (part === null) return null;
    parts.push(part);
  }

  const message: WireMessage = {
    id: raw.id,
    role: raw.role as WireMessageRole,
    parts,
    status: raw.status,
    createdAt: raw.createdAt,
  };
  if (typeof raw.attemptKey === 'string') {
    message.attemptKey = raw.attemptKey;
  }
  return message;
}

/** Reconstructs one closed Tool declaration, or `null` if it is malformed. */
function parseTool(raw: unknown): WireTool | null {
  if (!isObject(raw)) return null;
  if (typeof raw.name !== 'string') return null;
  if (typeof raw.description !== 'string') return null;
  if (!isObject(raw.parameters)) return null;
  return { name: raw.name, description: raw.description, parameters: raw.parameters };
}

/**
 * Validates an unknown parsed body into the exact `ChatRequest`. `wireVersion`
 * is checked first so an unsupported/missing version is a distinct verdict; the
 * toolset is re-validated through {@link assertValidToolset}.
 */
export function validateChatRequest(parsed: unknown): WireValidationResult {
  if (!isObject(parsed)) return fail('invalid-request');
  if (parsed.wireVersion !== 1) return fail('unsupported-wire-version');
  if (typeof parsed.botId !== 'string') return fail('invalid-request');
  if (typeof parsed.system !== 'string') return fail('invalid-request');
  if (!Array.isArray(parsed.messages)) return fail('invalid-request');

  const messages: WireMessage[] = [];
  for (const rawMessage of parsed.messages) {
    const message = parseMessage(rawMessage);
    if (message === null) return fail('invalid-request');
    messages.push(message);
  }

  const request: ChatRequest = {
    wireVersion: 1,
    botId: parsed.botId,
    system: parsed.system,
    messages,
  };

  if (parsed.tools !== undefined) {
    if (!Array.isArray(parsed.tools)) return fail('invalid-request');
    const tools: WireTool[] = [];
    for (const rawTool of parsed.tools) {
      const tool = parseTool(rawTool);
      if (tool === null) return fail('invalid-request');
      tools.push(tool);
    }
    try {
      assertValidToolset(tools);
    } catch (error) {
      if (error instanceof ToolSchemaValidationError) return fail('invalid-tool-schema');
      throw error;
    }
    request.tools = tools;
  }

  return { ok: true, request };
}
