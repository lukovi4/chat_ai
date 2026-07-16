/// Internal validator of the closed **Chat AI Tool Schema v1** dialect
/// (docs/TOOL-SCHEMA-V1.md) — declarations and argument instances. Not
/// exported from `package:chat_ai/chat_ai.dart`.
///
/// Deliberately NOT a general JSON Schema implementation: only the exact v1
/// dialect is accepted; everything else — `$ref`, `oneOf`, `pattern`,
/// `format`, length/range constraints, schema-valued `additionalProperties`,
/// any unknown keyword — is rejected.
///
/// Declaration validation throws [ArgumentError] (a configuration bug by
/// Flutter convention — V1_SPEC §3/§5); argument validation returns a
/// verdict (`bool`), because invalid bot-produced arguments are an
/// operational fact answered with a sanitised `is_error` ToolResult, never
/// an exception (V1_SPEC §4).
library;

import '../models/tool.dart';

/// `^[A-Za-z0-9_-]{1,64}$` (docs/TOOL-SCHEMA-V1.md).
final RegExp _toolNamePattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// The only keywords a v1 schema object may carry (docs/TOOL-SCHEMA-V1.md).
const Set<String> _allowedKeywords = {
  'type',
  'description',
  'enum',
  'properties',
  'required',
  'additionalProperties',
  'items',
};

const Set<String> _scalarTypes = {'string', 'number', 'integer', 'boolean'};
const Set<String> _allTypes = {...(_scalarTypes), 'null', 'object', 'array'};

/// Validates a whole Tool list as one frozen Bot Profile catalogue:
/// every name matches the v1 regex, names are unique, and every
/// `parameters` schema is a valid v1 **root object** schema.
///
/// Throws [ArgumentError] on the first violation.
void validateToolDeclarations(List<Tool> tools) {
  final seenNames = <String>{};
  for (final tool in tools) {
    if (!_toolNamePattern.hasMatch(tool.name)) {
      throw ArgumentError.value(
        tool.name,
        'tools',
        'Tool name must match ^[A-Za-z0-9_-]{1,64}\$ (Chat AI Tool Schema v1)',
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

/// Validates one already-declared-valid [schema] against a parsed [args]
/// instance. Returns `true` iff the instance conforms. Never throws on the
/// instance — invalid arguments are a verdict, not an exception.
bool toolArgsMatchSchema(Map<String, dynamic> schema, Object? args) =>
    _instanceMatches(schema, args);

// --- declaration side ------------------------------------------------------

/// Returns a human-readable violation (logs-only wording) or null when the
/// [schema] node is a valid v1 schema object. [isRoot] additionally pins
/// `type: object` at the root (docs/TOOL-SCHEMA-V1.md).
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

  // type — a single allowed name, or the exact nullable pair
  // [<one non-null type>, "null"].
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

  // Keyword applicability: object keywords only on objects, items only on
  // arrays, enum only on scalars (docs/TOOL-SCHEMA-V1.md).
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
    // Every object declares properties, lists EVERY property in required and
    // closes itself with additionalProperties: false.
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
    // Exactly one items schema — a Map, never a tuple-style List.
    final Object? items = schema['items'];
    if (items == null || items is List) {
      return '$path: an array schema must carry exactly one "items" schema';
    }
    return _schemaViolation(items, path: '$path.items');
  }

  // Scalar (string | number | integer | boolean | null), optionally nullable.
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
    // A nullable enum must include null (docs/TOOL-SCHEMA-V1.md).
    if (nullable && !enumValues.contains(null)) {
      return '$path: a nullable enum must include null';
    }
  }
  return null;
}

// --- instance side ---------------------------------------------------------

bool _instanceMatches(Object? schema, Object? value) {
  // The declaration is already validated; the casts below cannot fail for a
  // schema that passed _schemaViolation.
  final node = schema as Map<String, dynamic>;
  final Object? rawType = node['type'];
  final bool nullable =
      rawType is List || rawType == 'null'; // ["T","null"] or bare "null"
  final String type = rawType is List
      ? rawType.first as String
      : rawType as String;

  if (value == null) {
    return nullable;
  }
  if (type == 'null') {
    return false; // non-null value against a bare "null" type
  }

  switch (type) {
    case 'object':
      if (value is! Map<String, dynamic>) {
        return false;
      }
      final properties = node['properties'] as Map<String, dynamic>;
      // Closed object: no unknown keys, every declared key present
      // (required lists them all by construction).
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

/// The exact scalar⇄type compatibility of the dialect, aligned with JSON
/// number semantics so the Dart and TypeScript validators produce identical
/// verdicts: `integer` is any finite JSON number with a zero fractional part
/// (`5` and `5.0` both conform, `5.5` does not); `number` is any finite JSON
/// number (non-finite values do not exist in JSON and are rejected); `null`
/// stays distinct.
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
