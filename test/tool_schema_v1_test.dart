// The Chat AI Tool Schema v1 contract (SERVER-CONTRACT §7), driven by the
// shared normative corpus in test/contract_fixtures/tool_schema_v1/ — the
// same fixtures the TypeScript BFF and both provider translators must agree
// with. The Dart validator's verdicts are pinned per fixture; the fixtures
// themselves live in JSON, not in Dart code.
import 'dart:convert';
import 'dart:io';

import 'package:chat_ai/chat_ai.dart';
import 'package:chat_ai/src/core/tool_schema_v1.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _readCorpus(String file) =>
    jsonDecode(
          File(
            'test/contract_fixtures/tool_schema_v1/$file',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

List<Tool> _tools(Map<String, dynamic> declarationCase) => [
  for (final Object? raw in declarationCase['tools'] as List<Object?>)
    Tool(
      name: (raw as Map<String, dynamic>)['name'] as String,
      description: raw['description'] as String,
      parameters: (raw['parameters'] as Map<Object?, Object?>)
          .cast<String, dynamic>(),
    ),
];

void main() {
  final declarations = _readCorpus('declarations.json');
  final arguments = _readCorpus('arguments.json');

  group('declaration corpus', () {
    final accepted = declarations['accepted'] as List<Object?>;
    final rejected = declarations['rejected'] as List<Object?>;

    test('the corpus is a real two-sided contract', () {
      expect(accepted, isNotEmpty);
      expect(
        rejected.length,
        greaterThan(20),
        reason: 'every non-v1 keyword and structural violation is pinned',
      );
    });

    for (final Object? raw in accepted) {
      final declarationCase = raw as Map<String, dynamic>;
      test('accepts: ${declarationCase['case']}', () {
        expect(
          () => validateToolDeclarations(_tools(declarationCase)),
          returnsNormally,
        );
      });
    }

    for (final Object? raw in rejected) {
      final declarationCase = raw as Map<String, dynamic>;
      test('rejects: ${declarationCase['case']}', () {
        expect(
          () => validateToolDeclarations(_tools(declarationCase)),
          throwsArgumentError,
        );
      });
    }
  });

  group('argument corpus', () {
    for (final Object? raw in arguments['cases'] as List<Object?>) {
      final argumentCase = raw as Map<String, dynamic>;
      final schema = (argumentCase['parameters'] as Map<Object?, Object?>)
          .cast<String, dynamic>();

      test('schema of "${argumentCase['case']}" is itself a valid '
          'declaration', () {
        expect(
          () => validateToolDeclarations([
            Tool(name: 'fixture', description: 'd', parameters: schema),
          ]),
          returnsNormally,
        );
      });

      test('verdicts of "${argumentCase['case']}"', () {
        for (final Object? instance in argumentCase['valid'] as List<Object?>) {
          expect(
            toolArgsMatchSchema(schema, instance),
            isTrue,
            reason: 'expected valid: ${jsonEncode(instance)}',
          );
        }
        for (final Object? instance
            in argumentCase['invalid'] as List<Object?>) {
          expect(
            toolArgsMatchSchema(schema, instance),
            isFalse,
            reason: 'expected invalid: ${jsonEncode(instance)}',
          );
        }
      });
    }
  });

  test('non-finite numbers do not exist in JSON and never validate', () {
    // Only expressible from Dart code — kept outside the JSON corpus by
    // necessity.
    final schema = {
      'type': 'object',
      'properties': {
        'n': {'type': 'number'},
        'i': {'type': 'integer'},
      },
      'required': ['i', 'n'],
      'additionalProperties': false,
    };
    expect(toolArgsMatchSchema(schema, {'n': double.nan, 'i': 1}), isFalse);
    expect(
      toolArgsMatchSchema(schema, {'n': 1, 'i': double.infinity}),
      isFalse,
    );
  });
}
