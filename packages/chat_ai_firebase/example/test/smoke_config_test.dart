// The dual-backend launch configuration: which defines each SMOKE_BACKEND
// mode requires, that an unknown/empty mode never opens a live session, and
// that the setup UI surfaces only define NAMES — never values. No Firebase,
// no network.
import 'package:example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fully-populated defines map for [mode]; tests remove entries from it.
Map<String, String> fullDefines(String mode) => {
  'SMOKE_BACKEND': mode,
  'CHAT_BOT_ID': 'bot',
  'FIREBASE_API_KEY': 'k',
  'FIREBASE_APP_ID': 'a',
  'FIREBASE_MESSAGING_SENDER_ID': 's',
  'FIREBASE_PROJECT_ID': 'p',
  'CHAT_ENDPOINT': 'https://chat.example.invalid/chat',
  'REALTIME_CLIENT_SECRET_ENDPOINT': 'https://mint.example.invalid/secret',
};

void main() {
  test('firebase requires CHAT_ENDPOINT but not the Realtime endpoint', () {
    final defines = fullDefines('firebase')
      ..remove('CHAT_ENDPOINT')
      ..remove('REALTIME_CLIENT_SECRET_ENDPOINT');
    final problems = smokeConfigProblems(defines);
    expect(problems, contains('CHAT_ENDPOINT'));
    expect(problems, isNot(contains('REALTIME_CLIENT_SECRET_ENDPOINT')));
    // With CHAT_ENDPOINT present the firebase config is complete even
    // without any Realtime endpoint.
    expect(
      smokeConfigProblems(
        fullDefines('firebase')..remove('REALTIME_CLIENT_SECRET_ENDPOINT'),
      ),
      isEmpty,
    );
  });

  test('realtime requires REALTIME_CLIENT_SECRET_ENDPOINT but not '
      'CHAT_ENDPOINT', () {
    final defines = fullDefines('realtime')
      ..remove('CHAT_ENDPOINT')
      ..remove('REALTIME_CLIENT_SECRET_ENDPOINT');
    final problems = smokeConfigProblems(defines);
    expect(problems, contains('REALTIME_CLIENT_SECRET_ENDPOINT'));
    expect(problems, isNot(contains('CHAT_ENDPOINT')));
    expect(
      smokeConfigProblems(fullDefines('realtime')..remove('CHAT_ENDPOINT')),
      isEmpty,
    );
  });

  test('an unknown or empty SMOKE_BACKEND never yields a runnable config '
      '(no live session, no default backend)', () {
    for (final raw in ['', 'FIREBASE', 'both', 'openai', ' realtime']) {
      expect(parseSmokeBackendMode(raw), isNull, reason: 'raw: "$raw"');
      final problems = smokeConfigProblems(
        fullDefines('ignored')..['SMOKE_BACKEND'] = raw,
      );
      // main() opens a live session only when problems is empty.
      expect(problems, contains('SMOKE_BACKEND'), reason: 'raw: "$raw"');
    }
    // The two exact mode names are the only accepted values.
    expect(parseSmokeBackendMode('firebase'), SmokeBackendMode.firebase);
    expect(parseSmokeBackendMode('realtime'), SmokeBackendMode.realtime);
  });

  test('config problems carry define NAMES only — never values', () {
    final defines = fullDefines('nonsense-mode')
      ..['CHAT_BOT_ID'] = ''
      ..['FIREBASE_API_KEY'] = '';
    final problems = smokeConfigProblems(defines);
    const knownNames = {
      'SMOKE_BACKEND',
      'CHAT_BOT_ID',
      'FIREBASE_API_KEY',
      'FIREBASE_APP_ID',
      'FIREBASE_MESSAGING_SENDER_ID',
      'FIREBASE_PROJECT_ID',
      'CHAT_ENDPOINT',
      'REALTIME_CLIENT_SECRET_ENDPOINT',
    };
    // Every reported problem is one of the fixed define names — the only
    // channel into the setup UI can never carry a value.
    expect(problems, isNotEmpty);
    for (final problem in problems) {
      expect(knownNames, contains(problem));
    }
  });

  testWidgets('the setup screen lists define NAMES and never any value', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SetupScreen(
          missing: ['SMOKE_BACKEND', 'REALTIME_CLIENT_SECRET_ENDPOINT'],
        ),
      ),
    );
    expect(find.text('• SMOKE_BACKEND'), findsOneWidget);
    expect(find.text('• REALTIME_CLIENT_SECRET_ENDPOINT'), findsOneWidget);
    // No define VALUE exists anywhere in the tree: the screen receives only
    // names, and nothing resembling an endpoint/secret is rendered.
    expect(find.textContaining('https://'), findsNothing);
    expect(find.textContaining('ek_'), findsNothing);
  });
}
