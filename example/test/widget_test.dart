// Network-free smoke tests for the example harness: the setup screen, the
// FirebaseOptions helper, the read-only tool-loop resolver and the failure
// mapping. The live path itself is exercised on a physical device (see
// example/README.md), not here.

import 'package:chat_ai/chat_ai.dart';
import 'package:example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'the config-free setup screen lists missing define NAMES (never values)',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: SetupScreen(missing: ['FIREBASE_API_KEY', 'CHAT_ENDPOINT']),
        ),
      );
      expect(find.text('• FIREBASE_API_KEY'), findsOneWidget);
      expect(find.text('• CHAT_ENDPOINT'), findsOneWidget);
      // The run instructions use the local define file, not native config.
      expect(find.textContaining('--dart-define-from-file'), findsWidgets);
    },
  );

  test(
    'buildSmokeFirebaseOptions carries the four Firebase fields through',
    () {
      final options = buildSmokeFirebaseOptions(
        apiKey: 'API',
        appId: 'APP',
        messagingSenderId: 'SENDER',
        projectId: 'PROJECT',
      );
      expect(options.apiKey, 'API');
      expect(options.appId, 'APP');
      expect(options.messagingSenderId, 'SENDER');
      expect(options.projectId, 'PROJECT');
    },
  );

  test('buildSmokeFirebaseOptions rejects an empty required value', () {
    expect(
      () => buildSmokeFirebaseOptions(
        apiKey: '',
        appId: 'APP',
        messagingSenderId: 'SENDER',
        projectId: 'PROJECT',
      ),
      throwsArgumentError,
    );
  });

  test('get_device_time resolves to an ISO-8601 UTC timestamp', () async {
    final result = await resolveTool(
      const ToolCall(id: 'c1', name: 'get_device_time', args: {}),
    );
    expect(result.isError, isFalse);
    expect(DateTime.tryParse(result.content), isNotNull);
  });

  test('an unknown tool is a safe is_error result', () async {
    final result = await resolveTool(
      const ToolCall(id: 'c1', name: 'not_a_tool', args: {}),
    );
    expect(result.isError, isTrue);
  });

  test('deviceTimeTool is a valid no-argument v1 object schema', () {
    final parameters = deviceTimeTool().parameters;
    expect(parameters['type'], 'object');
    expect(parameters['properties'], isEmpty);
    expect(parameters['required'], isEmpty);
    expect(parameters['additionalProperties'], isFalse);
  });

  test('failureText maps every failure cause to a non-empty string', () {
    for (final cause in FailureCause.values) {
      expect(failureText(cause), isNotEmpty);
    }
  });
}
