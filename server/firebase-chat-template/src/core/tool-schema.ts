// Chat AI Tool Schema v1 — the exact closed validator (SERVER-CONTRACT §7).
// A small, hand-written dialect checker mirroring the Dart Core, NOT a general
// JSON Schema engine. The one shared normative corpus lives at
// test/contract_fixtures/tool_schema_v1/ and Dart, this validator and both
// provider translators MUST agree on every verdict.
//
// The public contract is boolean/result only: errors are stable and never echo
// the schema or argument payload (SERVER-CONTRACT §7). Two entry points:
//   - `validateToolset` — declarations: names, uniqueness, each parameters
//     schema;
//   - `validateArgumentInstance` — a decoded argument object against a schema
//     already known to be valid.

// ---------------------------------------------------------------------------
// small JSON helpers
// ---------------------------------------------------------------------------

type JsonObject = Record<string, unknown>;

function isObject(value: unknown): value is JsonObject {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * JSON "integer": any finite whole-valued number (`2` and `2.0` both count;
 * `2.5` does not). Booleans are not numbers. Mirrors the corpus cases
 * "integer enum may use whole-valued JSON numbers" / "fractional number in an
 * integer enum".
 */
function isWholeNumber(value: unknown): boolean {
  return typeof value === 'number' && Number.isFinite(value) && Number.isInteger(value);
}

// ---------------------------------------------------------------------------
// dialect constants (SERVER-CONTRACT §7)
// ---------------------------------------------------------------------------

const TOOL_NAME_RE = /^[A-Za-z0-9_-]{1,64}$/;

const ALLOWED_KEYWORDS = new Set([
  'type',
  'description',
  'enum',
  'properties',
  'required',
  'additionalProperties',
  'items',
]);

const SCALAR_TYPES = new Set(['string', 'number', 'integer', 'boolean', 'null']);
const COMPOUND_TYPES = new Set(['object', 'array']);

/** The resolved type of one schema node: a base type plus a nullable flag. */
interface ResolvedType {
  base: string; // one scalar or compound type name (never "null" via the pair)
  nullable: boolean; // true only via the `[T, "null"]` pair
}

// ---------------------------------------------------------------------------
// declaration validation
// ---------------------------------------------------------------------------

/**
 * Resolves the `type` keyword to a `ResolvedType`, or `null` when it is missing
 * or malformed. Accepts a single scalar/compound string, or the exact nullable
 * pair `[<one non-null type>, "null"]` — nothing else: wrong order, two
 * non-null types, three entries, an empty list and unknown names all fail
 * (matching the corpus).
 */
function resolveType(node: JsonObject): ResolvedType | null {
  const type = node.type;
  if (typeof type === 'string') {
    if (SCALAR_TYPES.has(type) || COMPOUND_TYPES.has(type)) {
      return { base: type, nullable: false };
    }
    return null;
  }
  if (Array.isArray(type)) {
    if (type.length !== 2) return null;
    const [first, second] = type;
    if (second !== 'null') return null;
    if (typeof first !== 'string' || first === 'null') return null;
    if (!SCALAR_TYPES.has(first) && !COMPOUND_TYPES.has(first)) return null;
    return { base: first, nullable: true };
  }
  return null;
}

/** Validates one `enum` array against an already-resolved scalar type. */
function isValidEnum(enumValue: unknown, resolved: ResolvedType): boolean {
  if (!Array.isArray(enumValue)) return false;
  if (enumValue.length === 0) return false;
  for (const entry of enumValue) {
    if (entry === null) {
      // A null entry is allowed on a nullable pair OR the bare `null` scalar
      // type (mirrors the Dart validator, which treats bare "null" as nullable).
      if (!resolved.nullable && resolved.base !== 'null') return false;
      continue;
    }
    switch (resolved.base) {
      case 'string':
        if (typeof entry !== 'string') return false;
        break;
      case 'number':
        if (typeof entry !== 'number' || !Number.isFinite(entry)) return false;
        break;
      case 'integer':
        if (!isWholeNumber(entry)) return false;
        break;
      case 'boolean':
        if (typeof entry !== 'boolean') return false;
        break;
      case 'null':
        return false; // a non-null enum entry on a `null` type
      default:
        return false; // enum on a compound type
    }
  }
  // A nullable scalar enum MUST include null (SERVER-CONTRACT §7).
  if (resolved.nullable && !enumValue.includes(null)) return false;
  return true;
}

/**
 * Recursively validates one schema node in the v1 dialect. `isRoot` pins the
 * `parameters` root to a non-nullable `object`.
 */
function isValidSchema(node: unknown, isRoot: boolean): boolean {
  if (!isObject(node)) return false;

  // Closed keyword set.
  for (const key of Object.keys(node)) {
    if (!ALLOWED_KEYWORDS.has(key)) return false;
  }

  const resolved = resolveType(node);
  if (resolved === null) return false;

  if (isRoot && (resolved.base !== 'object' || resolved.nullable)) return false;

  if ('description' in node && typeof node.description !== 'string') return false;

  const hasProperties = 'properties' in node;
  const hasRequired = 'required' in node;
  const hasAdditional = 'additionalProperties' in node;
  const hasItems = 'items' in node;
  const hasEnum = 'enum' in node;

  if (resolved.base === 'object') {
    // Every object declares properties + required + additionalProperties:false.
    if (!hasProperties || !hasRequired || !hasAdditional) return false;
    if (hasItems || hasEnum) return false;
    if (node.additionalProperties !== false) return false;

    const properties = node.properties;
    if (!isObject(properties)) return false;
    const required = node.required;
    if (!Array.isArray(required)) return false;
    if (!required.every((name) => typeof name === 'string')) return false;

    const propertyNames = Object.keys(properties);
    const requiredNames = required as string[];
    // Exactness: every property is required, and every required name exists.
    const requiredSet = new Set(requiredNames);
    if (requiredSet.size !== requiredNames.length) return false; // duplicates
    if (requiredSet.size !== propertyNames.length) return false;
    for (const name of propertyNames) {
      if (!requiredSet.has(name)) return false;
    }
    for (const child of Object.values(properties)) {
      if (!isValidSchema(child, false)) return false;
    }
    return true;
  }

  if (resolved.base === 'array') {
    if (!hasItems) return false;
    if (hasProperties || hasRequired || hasAdditional || hasEnum) return false;
    // Exactly one items schema — a single object, never a tuple-style list.
    return isValidSchema(node.items, false);
  }

  // Scalar (string | number | integer | boolean | null).
  if (hasProperties || hasRequired || hasAdditional || hasItems) return false;
  if (hasEnum && !isValidEnum(node.enum, resolved)) return false;
  return true;
}

/**
 * Validates one tool declaration's `parameters` schema in the v1 dialect. The
 * name is checked separately by {@link validateToolset}.
 */
export function isValidToolSchema(parameters: unknown): boolean {
  return isValidSchema(parameters, true);
}

/** Whether a tool name matches the dialect regex (SERVER-CONTRACT §7). */
export function isValidToolName(name: unknown): boolean {
  return typeof name === 'string' && TOOL_NAME_RE.test(name);
}

/**
 * Validates a whole toolset: each name matches the regex, names are unique, and
 * each `parameters` is a valid v1 schema. Returns a single boolean verdict —
 * the accepted/rejected verdict the shared corpus pins.
 */
export function validateToolset(
  tools: ReadonlyArray<{ name: unknown; description?: unknown; parameters: unknown }>,
): boolean {
  const seen = new Set<string>();
  for (const tool of tools) {
    if (!isValidToolName(tool.name)) return false;
    const name = tool.name as string;
    if (seen.has(name)) return false;
    seen.add(name);
    if ('description' in tool && typeof tool.description !== 'string') return false;
    if (!isValidToolSchema(tool.parameters)) return false;
  }
  return true;
}

/** Stable error thrown when a toolset fails v1 validation (no payload). */
export class ToolSchemaValidationError extends Error {
  constructor() {
    super('Chat AI Tool Schema v1 validation failed');
    this.name = 'ToolSchemaValidationError';
  }
}

/** Throws {@link ToolSchemaValidationError} when the toolset is invalid. */
export function assertValidToolset(
  tools: ReadonlyArray<{ name: unknown; description?: unknown; parameters: unknown }>,
): void {
  if (!validateToolset(tools)) throw new ToolSchemaValidationError();
}

// ---------------------------------------------------------------------------
// argument-instance validation
// ---------------------------------------------------------------------------

/**
 * Validates a decoded argument value against a schema that is already known to
 * be a valid v1 schema (the corpus feeds only valid `parameters`). Closed
 * objects reject unknown/missing keys; `integer` accepts any whole-valued
 * number; `null` is accepted only for a nullable type or the `null` scalar.
 */
function isValidInstance(schema: JsonObject, value: unknown): boolean {
  const resolved = resolveType(schema);
  if (resolved === null) return false; // defensive; schema is pre-validated

  if (value === null) {
    return resolved.nullable || resolved.base === 'null';
  }

  switch (resolved.base) {
    case 'string':
      if (typeof value !== 'string') return false;
      break;
    case 'number':
      if (typeof value !== 'number' || !Number.isFinite(value)) return false;
      break;
    case 'integer':
      if (!isWholeNumber(value)) return false;
      break;
    case 'boolean':
      if (typeof value !== 'boolean') return false;
      break;
    case 'null':
      return false; // a non-null value on a `null` type
    case 'object': {
      if (!isObject(value)) return false;
      const properties = schema.properties as JsonObject;
      const propertyNames = Object.keys(properties);
      const valueKeys = Object.keys(value);
      // Closed object: every property present (all are required), no extras.
      if (valueKeys.length !== propertyNames.length) return false;
      for (const name of propertyNames) {
        if (!(name in value)) return false;
        if (!isValidInstance(properties[name] as JsonObject, value[name])) return false;
      }
      return true;
    }
    case 'array': {
      if (!Array.isArray(value)) return false;
      const items = schema.items as JsonObject;
      for (const element of value) {
        if (!isValidInstance(items, element)) return false;
      }
      return true;
    }
    default:
      return false;
  }

  // Scalar enum membership (compound types never carry an enum in v1).
  if ('enum' in schema) {
    const enumValues = schema.enum as unknown[];
    if (!enumValues.some((candidate) => candidate === value)) return false;
  }
  return true;
}

/**
 * Validates a decoded argument object against a valid v1 `parameters` schema.
 * The top-level value must satisfy the root object schema.
 */
export function validateArgumentInstance(parameters: JsonObject, value: unknown): boolean {
  return isValidInstance(parameters, value);
}
