// Package-private tool support for the voice session: the synchronous
// declaration validator (a self-contained re-implementation of the closed
// **Chat AI Tool Schema v1** dialect, docs/TOOL-SCHEMA-V1.md) plus the small
// wire helpers for a Realtime function-calling turn.
//
// This deliberately does NOT open the core's internal validator (it is not
// exported) and does NOT add a new package — it lives inside this voice package
// exactly as the task requires. It is NOT a general JSON Schema implementation:
// only the exact v1 dialect is accepted; everything else is rejected with an
// [ArgumentError], BEFORE any mint/network I/O.
library;

import 'dart:convert';

import 'package:chat_ai/chat_ai.dart' show Tool, ToolResult;

/// `^[A-Za-z0-9_-]{1,64}$` (docs/TOOL-SCHEMA-V1.md).
final RegExp _toolNamePattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// The only keywords a v1 schema object may carry (docs/TOOL-SCHEMA-V1.md).
const Set<String> _allowedKeywords = <String>{
  'type',
  'description',
  'enum',
  'properties',
  'required',
  'additionalProperties',
  'items',
};

const Set<String> _scalarTypes = <String>{
  'string',
  'number',
  'integer',
  'boolean',
};
const Set<String> _allTypes = <String>{
  ..._scalarTypes,
  'null',
  'object',
  'array',
};

/// Validates a whole Tool list as one frozen Bot Profile catalogue: every name
/// matches the v1 regex, names are unique, and every `parameters` schema is a
/// valid v1 **root object** schema. Throws [ArgumentError] on the first
/// violation. Mirrors the core's internal `validateToolDeclarations` verdicts.
void validateVoiceToolDeclarations(List<Tool> tools) {
  final seenNames = <String>{};
  for (final tool in tools) {
    if (!_toolNamePattern.hasMatch(tool.name)) {
      throw ArgumentError.value(
        tool.name,
        'tools',
        r'Tool name must match ^[A-Za-z0-9_-]{1,64}$ (Chat AI Tool Schema v1)',
      );
    }
    if (!seenNames.add(tool.name)) {
      throw ArgumentError.value(
        tool.name,
        'tools',
        'duplicate Tool name inside one Bot Profile',
      );
    }
    final String? violation = _schemaViolation(
      tool.parameters,
      path: 'parameters',
      isRoot: true,
    );
    if (violation != null) {
      throw ArgumentError.value(
        tool.name,
        'tools',
        'invalid Chat AI Tool Schema v1: $violation',
      );
    }
  }
}

/// Validates an already-declared-valid [schema] against a parsed [args]
/// instance, in the closed **Chat AI Tool Schema v1** dialect. Returns `true`
/// iff the instance conforms. NEVER throws on the instance — invalid bot-produced
/// arguments are an operational verdict answered with a sanitised error
/// [ToolResult], not an exception. This is the instance-side counterpart of
/// [validateVoiceToolDeclarations] (self-contained; it does not open the core's
/// internal validator and adds no JSON Schema engine / dependency).
bool toolArgsMatchSchema(Map<String, dynamic> schema, Object? args) =>
    _instanceMatches(schema, args);

/// Parses a Realtime `function_call.arguments` string. Returns the decoded map
/// when (and only when) it is a JSON **object**; returns null for an empty
/// string, a non-object JSON value or a decode error. Never throws — an invalid
/// argument payload is an operational fact answered with a sanitised error
/// [ToolResult], not an exception.
Map<String, dynamic>? parseToolArguments(String raw) {
  if (raw.trim().isEmpty) {
    return null;
  }
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return null;
  }
  if (decoded is Map<String, dynamic>) {
    return decoded;
  }
  if (decoded is Map) {
    return decoded.cast<String, dynamic>();
  }
  return null;
}

/// The canonical `function_call_output.output` string: the normalised
/// ToolResult as a compact JSON object with keys in the order content → isError
/// — byte-compatible with the base package's server translator (the
/// chat_ai_firebase SERVER-CONTRACT §7 and the Realtime request translator).
String encodeToolResultOutput(ToolResult result) => jsonEncode(
  <String, Object?>{'content': result.content, 'isError': result.isError},
);

// --- declaration side (v1 dialect) -----------------------------------------

String? _schemaViolation(
  Object? schema, {
  required String path,
  bool isRoot = false,
}) {
  if (schema is! Map<String, dynamic>) {
    return '$path: a schema must be a JSON object';
  }
  for (final keyword in schema.keys) {
    if (!_allowedKeywords.contains(keyword)) {
      return '$path: keyword "$keyword" is not in the v1 dialect';
    }
  }

  final Object? description = schema['description'];
  if (description != null && description is! String) {
    return '$path: "description" must be a string';
  }

  final Object? rawType = schema['type'];
  final String nonNullType;
  final bool nullable;
  switch (rawType) {
    case final String single when _allTypes.contains(single):
      nonNullType = single;
      nullable = single == 'null';
    case [final String first, 'null']
        when _allTypes.contains(first) && first != 'null':
      nonNullType = first;
      nullable = true;
    case null:
      return '$path: "type" is required';
    default:
      return '$path: "type" must be one scalar/object/array name or '
          '[<one non-null type>, "null"]';
  }
  if (isRoot && (nonNullType != 'object' || rawType is! String)) {
    return '$path: the root must be exactly {"type": "object", ...}';
  }

  final bool isObject = nonNullType == 'object';
  final bool isArray = nonNullType == 'array';

  if (!isObject &&
      (schema.containsKey('properties') ||
          schema.containsKey('required') ||
          schema.containsKey('additionalProperties'))) {
    return '$path: "properties"/"required"/"additionalProperties" are only '
        'valid on an object schema';
  }
  if (!isArray && schema.containsKey('items')) {
    return '$path: "items" is only valid on an array schema';
  }
  if ((isObject || isArray) && schema.containsKey('enum')) {
    return '$path: "enum" is only valid on a scalar schema';
  }

  if (isObject) {
    final Object? properties = schema['properties'];
    if (properties is! Map<String, dynamic>) {
      return '$path: an object schema must declare "properties"';
    }
    final Object? required = schema['required'];
    if (required is! List) {
      return '$path: an object schema must declare "required"';
    }
    final requiredNames = <String>{};
    for (final Object? name in required) {
      if (name is! String || !requiredNames.add(name)) {
        return '$path: "required" must list unique property names';
      }
    }
    if (requiredNames.length != properties.length ||
        !requiredNames.containsAll(properties.keys)) {
      return '$path: "required" must list every declared property '
          '(optionality is expressed as a nullable type pair)';
    }
    if (schema['additionalProperties'] != false) {
      return '$path: an object schema must set "additionalProperties": false';
    }
    for (final MapEntry<String, dynamic> entry in properties.entries) {
      final String? nested = _schemaViolation(
        entry.value,
        path: '$path.properties.${entry.key}',
      );
      if (nested != null) {
        return nested;
      }
    }
    return null;
  }

  if (isArray) {
    final Object? items = schema['items'];
    if (items == null || items is List) {
      return '$path: an array schema must carry exactly one "items" schema';
    }
    return _schemaViolation(items, path: '$path.items');
  }

  final Object? enumValues = schema['enum'];
  if (enumValues != null) {
    if (enumValues is! List || enumValues.isEmpty) {
      return '$path: "enum" must be a non-empty list of scalar values';
    }
    for (final Object? value in enumValues) {
      if (value == null) {
        if (!nullable) {
          return '$path: a null enum value requires a nullable type';
        }
        continue;
      }
      if (!_scalarMatchesType(nonNullType, value)) {
        return '$path: enum value "$value" is not compatible with the '
            'declared type "$nonNullType"';
      }
    }
    if (nullable && !enumValues.contains(null)) {
      return '$path: a nullable enum must include null';
    }
  }
  return null;
}

bool _scalarMatchesType(String type, Object value) => switch (type) {
  'string' => value is String,
  'boolean' => value is bool,
  'integer' =>
    value is int ||
        (value is double &&
            value.isFinite &&
            value == value.truncateToDouble()),
  'number' => value is num && (value is int || value.isFinite),
  _ => false,
};

// --- instance side (v1 dialect) --------------------------------------------

bool _instanceMatches(Object? schema, Object? value) {
  // The declaration is already validated; the casts below cannot fail for a
  // schema that passed the declaration validator.
  final node = schema as Map<String, dynamic>;
  final Object? rawType = node['type'];
  final bool nullable = rawType is List || rawType == 'null';
  final String type = rawType is List
      ? rawType.first as String
      : rawType as String;

  if (value == null) {
    return nullable;
  }
  if (type == 'null') {
    return false; // a non-null value against a bare "null" type
  }

  switch (type) {
    case 'object':
      if (value is! Map<String, dynamic>) {
        return false;
      }
      final properties = node['properties'] as Map<String, dynamic>;
      // Closed object: no unknown keys, every declared key present (required
      // lists them all by construction of the v1 dialect).
      for (final key in value.keys) {
        if (!properties.containsKey(key)) {
          return false;
        }
      }
      for (final MapEntry<String, dynamic> entry in properties.entries) {
        if (!value.containsKey(entry.key)) {
          return false;
        }
        if (!_instanceMatches(entry.value, value[entry.key])) {
          return false;
        }
      }
      return true;
    case 'array':
      if (value is! List) {
        return false;
      }
      final Object? items = node['items'];
      for (final Object? element in value) {
        if (!_instanceMatches(items, element)) {
          return false;
        }
      }
      return true;
    default:
      if (!_scalarMatchesType(type, value)) {
        return false;
      }
      final Object? enumValues = node['enum'];
      if (enumValues is List && !enumValues.contains(value)) {
        return false;
      }
      return true;
  }
}
