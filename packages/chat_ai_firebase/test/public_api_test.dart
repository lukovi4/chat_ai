// Public-API compile test of the adapter: it imports ONLY public entry
// points — no `src/` imports — and pins the export boundary of the barrel:
// exactly `FirebaseChatBackend`, never the internal test seam, and no
// re-export of `chat_ai`.
import 'dart:io';

import 'package:chat_ai/chat_ai.dart';
import 'package:chat_ai_firebase/chat_ai_firebase.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('FirebaseChatBackend is public and assignable to the ChatBackend '
      'interface', () {
    // Constructing it touches no Firebase/network — tokens are pulled per
    // send, which this test never calls — and the URL constructor is the
    // whole public configuration surface (V1_SPEC §8).
    final ChatBackend backend = FirebaseChatBackend(
      'https://example.invalid/chat',
    );
    expect(backend, isA<FirebaseChatBackend>());
  });

  test('the barrel exports exactly FirebaseChatBackend', () {
    final barrel = File('lib/chat_ai_firebase.dart').readAsStringSync();
    // The transport file is exported selectively: the class only — the
    // internal test seam never reaches the public surface.
    expect(barrel.contains('show FirebaseChatBackend'), isTrue);
    expect(barrel.contains('firebaseChatBackendForTesting'), isFalse);
    // The core package and its testing helpers are never re-exported.
    expect(barrel.contains("export 'package:chat_ai"), isFalse);
    expect(barrel.contains('testing.dart'), isFalse);
    expect(barrel.contains('FakeChatBackend'), isFalse);
    // The transport export is the only export directive of the barrel.
    final exports = RegExp("export '[^']*'").allMatches(barrel);
    expect(exports, hasLength(1));
  });
}
