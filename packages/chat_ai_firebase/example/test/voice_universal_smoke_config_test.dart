// The universal voice smoke entrypoint's launch configuration: the SMOKE_SCENARIO
// parser accepts exactly the three names, an unknown/empty value never yields a
// runnable configuration, the scenario → mode mapping is fixed, and the setup
// channel carries only define NAMES — never values. No Firebase, no network.
import 'package:chat_ai_openai_realtime_voice/chat_ai_openai_realtime_voice.dart';
import 'package:example/voice_universal_smoke_main.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fully-populated set of raw define values; individual tests blank entries.
List<String> missingWith({
  String scenario = 'history',
  String endpoint = 'https://mint.example.invalid/secret',
  String botId = 'bot',
  String apiKey = 'k',
  String appId = 'a',
  String senderId = 's',
  String projectId = 'p',
}) => voiceUniversalMissingDefines(
  scenarioRaw: scenario,
  realtimeEndpoint: endpoint,
  botId: botId,
  firebaseApiKey: apiKey,
  firebaseAppId: appId,
  firebaseMessagingSenderId: senderId,
  firebaseProjectId: projectId,
);

void main() {
  test('the parser accepts exactly history, tools and guardrail', () {
    expect(parseSmokeScenario('history'), SmokeScenario.history);
    expect(parseSmokeScenario('tools'), SmokeScenario.tools);
    expect(parseSmokeScenario('guardrail'), SmokeScenario.guardrail);
  });

  test(
    'an empty or unknown scenario never yields a runnable configuration',
    () {
      for (final raw in <String>[
        '',
        'HISTORY',
        'tool',
        ' guardrail',
        'nonsense',
      ]) {
        expect(parseSmokeScenario(raw), isNull, reason: 'raw: "$raw"');
        // main() opens a live session only when the missing list is empty; an
        // invalid scenario always keeps SMOKE_SCENARIO in it.
        expect(
          missingWith(scenario: raw),
          contains('SMOKE_SCENARIO'),
          reason: 'raw: "$raw"',
        );
      }
      // A fully-valid launch has no missing defines.
      expect(missingWith(), isEmpty);
    },
  );

  test('the scenario → mode mapping is fixed', () {
    expect(
      scenarioMode(SmokeScenario.history),
      OpenAIRealtimeVoiceMode.singleTurn,
    );
    expect(
      scenarioMode(SmokeScenario.tools),
      OpenAIRealtimeVoiceMode.conversation,
    );
    expect(
      scenarioMode(SmokeScenario.guardrail),
      OpenAIRealtimeVoiceMode.conversation,
    );
  });

  test('setup problems carry define NAMES only — never values', () {
    final problems = missingWith(
      scenario: 'nonsense',
      endpoint: '',
      botId: '',
      apiKey: '',
    );
    const knownNames = <String>{
      'SMOKE_SCENARIO',
      'REALTIME_CLIENT_SECRET_ENDPOINT',
      'CHAT_BOT_ID',
      'FIREBASE_API_KEY',
      'FIREBASE_APP_ID',
      'FIREBASE_MESSAGING_SENDER_ID',
      'FIREBASE_PROJECT_ID',
    };
    expect(problems, isNotEmpty);
    for (final problem in problems) {
      expect(knownNames, contains(problem));
    }
  });
}
