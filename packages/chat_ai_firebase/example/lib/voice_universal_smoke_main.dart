// Minimal iOS-only smoke entrypoint for the THREE new universal voice contracts
// of the production `OpenAIRealtimeVoiceSession` (chat_ai_openai_realtime_voice):
// initial HISTORY, universal TOOLS and the output GUARDRAIL — each with unified
// local `turnId`s. One compile-time scenario per launch; there is NO runtime
// scenario switch and NO default.
//
// It is a TEST HARNESS, not a production app. It uses ONLY the public production
// session API, and REUSES the harness Firebase init + `SmokeClientSecretProvider`
// (the OpenAI key is never on the device) without copying any server/mint logic.
// It does NOT touch the voice package `src/**`, adds NO native code, NO second
// microphone, NO extra signaling / upload / audio request, and NO new dependency.
//
// Common to all three scenarios: `transcriptsEnabled: true`, `recordingEnabled:
// true`, an app-writable directory inside `Directory.systemTemp`, and the
// production defaults for model / voice / maxOutputTokens / idle timeout (never
// overridden).
//
// Privacy: the UI shows the scenario, a coarse phase/failure, small coarse
// counters (finals, recordings, tool calls, guardrail events) and a plain
// chronological list of the events it received — deltas, final transcripts (with
// TEXT, a deliberate LOCAL diagnostic channel like the transcript smoke),
// recordings, recording failures, guardrail events and tool calls. There is NO
// automatic PASS/FAIL logic: correlation is judged by a human against the README
// checklist. It NEVER prints/logs anything (no print/debugPrint/logger) and
// NEVER shows the endpoint, a secret, a Firebase token, the bot id, provider
// ids, item/response/event ids, SDP, track ids or a full file path. Each event
// shows only a SHORT prefix (first 8 chars) of the local turnId — never the full
// turnId.
//
// Run (physical iPhone), exactly one scenario per launch, no default:
//   flutter run -t lib/voice_universal_smoke_main.dart \
//     --dart-define-from-file=smoke.realtime.ios.local.json \
//     --dart-define=SMOKE_SCENARIO=history      # or tools | guardrail
import 'dart:async';
import 'dart:io';

import 'package:chat_ai/chat_ai.dart'
    show
        BotProfile,
        ContentPart,
        Conversation,
        Message,
        MessageRole,
        MessageStatus,
        Tool,
        ToolCall,
        ToolResult;
import 'package:chat_ai_openai_realtime_voice/chat_ai_openai_realtime_voice.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'main.dart' as harness;
import 'smoke_client_secret_provider.dart';

/// The one new mandatory define for this entrypoint. There is NO default and NO
/// runtime switch — an unknown/empty value shows the setup screen and never
/// creates a session.
const String kVoiceSmokeScenarioRaw = String.fromEnvironment('SMOKE_SCENARIO');

/// The fixed recording sub-folder inside the app-writable tmp directory.
const String kUniversalRecordingSubdir = 'voice_universal_smoke';

/// The three universal smoke scenarios. Each is a distinct compile-time launch.
enum SmokeScenario { history, tools, guardrail }

/// Parses `SMOKE_SCENARIO`. Anything but the three exact names — empty included
/// — is null: the setup screen, never a session.
SmokeScenario? parseSmokeScenario(String raw) => switch (raw) {
  'history' => SmokeScenario.history,
  'tools' => SmokeScenario.tools,
  'guardrail' => SmokeScenario.guardrail,
  _ => null,
};

/// The fixed scenario → session mode mapping: `history` runs one turn; `tools`
/// and `guardrail` run a conversation.
OpenAIRealtimeVoiceMode scenarioMode(SmokeScenario scenario) =>
    switch (scenario) {
      SmokeScenario.history => OpenAIRealtimeVoiceMode.singleTurn,
      SmokeScenario.tools => OpenAIRealtimeVoiceMode.conversation,
      SmokeScenario.guardrail => OpenAIRealtimeVoiceMode.conversation,
    };

/// The NAMES (never values) of the missing/invalid defines for this launch. Pure
/// (takes the raw values) so it is unit-testable and can never carry a value
/// into the setup UI.
List<String> voiceUniversalMissingDefines({
  required String scenarioRaw,
  required String realtimeEndpoint,
  required String botId,
  required String firebaseApiKey,
  required String firebaseAppId,
  required String firebaseMessagingSenderId,
  required String firebaseProjectId,
}) => <String>[
  if (parseSmokeScenario(scenarioRaw) == null) 'SMOKE_SCENARIO',
  if (realtimeEndpoint.isEmpty) 'REALTIME_CLIENT_SECRET_ENDPOINT',
  if (botId.isEmpty) 'CHAT_BOT_ID',
  if (firebaseApiKey.isEmpty) 'FIREBASE_API_KEY',
  if (firebaseAppId.isEmpty) 'FIREBASE_APP_ID',
  if (firebaseMessagingSenderId.isEmpty) 'FIREBASE_MESSAGING_SENDER_ID',
  if (firebaseProjectId.isEmpty) 'FIREBASE_PROJECT_ID',
];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final missing = voiceUniversalMissingDefines(
    scenarioRaw: kVoiceSmokeScenarioRaw,
    realtimeEndpoint: harness.kRealtimeClientSecretEndpoint,
    botId: harness.kBotId,
    firebaseApiKey: harness.kFirebaseApiKey,
    firebaseAppId: harness.kFirebaseAppId,
    firebaseMessagingSenderId: harness.kFirebaseMessagingSenderId,
    firebaseProjectId: harness.kFirebaseProjectId,
  );
  if (missing.isNotEmpty) {
    runApp(
      MaterialApp(
        title: 'voice universal smoke — setup',
        home: harness.SetupScreen(missing: missing),
      ),
    );
    return;
  }

  try {
    await Firebase.initializeApp(
      options: harness.buildSmokeFirebaseOptions(
        apiKey: harness.kFirebaseApiKey,
        appId: harness.kFirebaseAppId,
        messagingSenderId: harness.kFirebaseMessagingSenderId,
        projectId: harness.kFirebaseProjectId,
      ),
    );
    await FirebaseAppCheck.instance.activate(
      providerAndroid: AndroidDebugProvider(),
      providerApple: AppleDebugProvider(),
    );
    if (FirebaseAuth.instance.currentUser == null) {
      await FirebaseAuth.instance.signInAnonymously();
    }
  } on Object {
    // Never surface the raw Firebase exception (it can carry config/token data).
    runApp(
      const MaterialApp(
        title: 'voice universal smoke — setup',
        home: harness.SetupScreen(
          missing: <String>[],
          error: 'Initialization failed. Check the smoke configuration.',
        ),
      ),
    );
    return;
  }

  final directoryPath =
      '${Directory.systemTemp.path}/$kUniversalRecordingSubdir';
  Directory(directoryPath).createSync(recursive: true);

  // Guarded above: the scenario is one of the three exact names here.
  runApp(
    VoiceUniversalSmokeApp(
      scenario: parseSmokeScenario(kVoiceSmokeScenarioRaw)!,
      directoryPath: directoryPath,
    ),
  );
}

class VoiceUniversalSmokeApp extends StatelessWidget {
  const VoiceUniversalSmokeApp({
    required this.scenario,
    required this.directoryPath,
    super.key,
  });

  final SmokeScenario scenario;
  final String directoryPath;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'voice universal smoke',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: VoiceUniversalSmokeHome(
        scenario: scenario,
        directoryPath: directoryPath,
      ),
    );
  }
}

class VoiceUniversalSmokeHome extends StatefulWidget {
  const VoiceUniversalSmokeHome({
    required this.scenario,
    required this.directoryPath,
    super.key,
  });

  final SmokeScenario scenario;
  final String directoryPath;

  @override
  State<VoiceUniversalSmokeHome> createState() =>
      _VoiceUniversalSmokeHomeState();
}

class _VoiceUniversalSmokeHomeState extends State<VoiceUniversalSmokeHome> {
  late final OpenAIRealtimeVoiceSession _session = _buildSession();

  OpenAIRealtimeVoiceState _state = const OpenAIRealtimeVoiceState.idle();

  // A plain chronological log of received events (newest appended last). Each
  // line carries only a SHORT turnId prefix — never a full turnId, id or path.
  final List<String> _events = <String>[];
  // First-delta-per-reply guard so each reply logs exactly one `delta` line.
  final Set<String> _seenDeltaTurnIds = <String>{};

  // Small coarse counters (no verdicts, no auto PASS/FAIL).
  int _finalCount = 0;
  int _recordingCount = 0;
  int _recFailureCount = 0;
  int _guardrailCount = 0;
  int _toolCalls = 0;

  StreamSubscription<OpenAIRealtimeVoiceState>? _statesSub;
  StreamSubscription<OpenAIRealtimeVoiceTranscript>? _transcriptsSub;
  StreamSubscription<OpenAIRealtimeVoiceTranscriptDelta>? _deltasSub;
  StreamSubscription<OpenAIRealtimeVoiceRecording>? _recordingsSub;
  StreamSubscription<OpenAIRealtimeVoiceRecordingFailure>? _failuresSub;
  StreamSubscription<OpenAIRealtimeVoiceGuardrailEvent>? _guardrailSub;

  bool _started = false;

  OpenAIRealtimeVoiceSession _buildSession() {
    final provider = SmokeClientSecretProvider(
      endpoint: Uri.parse(harness.kRealtimeClientSecretEndpoint),
    );
    final mode = scenarioMode(widget.scenario);
    switch (widget.scenario) {
      case SmokeScenario.history:
        return OpenAIRealtimeVoiceSession(
          clientSecretProvider: provider,
          botProfile: BotProfile(
            id: harness.kBotId,
            systemPrompt:
                'Answer briefly, using the earlier conversation when relevant.',
            tools: const <Tool>[],
          ),
          mode: mode,
          transcriptsEnabled: true,
          recordingEnabled: true,
          recordingDirectoryPath: widget.directoryPath,
          initialConversation: _historyConversation(),
        );
      case SmokeScenario.tools:
        return OpenAIRealtimeVoiceSession(
          clientSecretProvider: provider,
          botProfile: BotProfile(
            id: harness.kBotId,
            systemPrompt:
                'You are a voice smoke-test assistant. When the user asks for '
                'the smoke value, you MUST call the get_smoke_value tool and '
                'then tell the user the value it returns. Keep replies short.',
            tools: <Tool>[_smokeTool()],
          ),
          mode: mode,
          transcriptsEnabled: true,
          recordingEnabled: true,
          recordingDirectoryPath: widget.directoryPath,
          onToolCall: _onToolCall,
        );
      case SmokeScenario.guardrail:
        return OpenAIRealtimeVoiceSession(
          clientSecretProvider: provider,
          botProfile: BotProfile(
            id: harness.kBotId,
            systemPrompt:
                'You are a voice smoke-test assistant. When the user asks you '
                'to run the guardrail test, your spoken reply MUST begin with '
                'the exact word BLOCKME. Keep replies short.',
            tools: const <Tool>[],
          ),
          mode: mode,
          transcriptsEnabled: true,
          recordingEnabled: true,
          recordingDirectoryPath: widget.directoryPath,
          outputGuardrail: _guardrail,
          safeReplacementInstructions: 'Reply with only the single word: SAFE.',
        );
    }
  }

  /// A small, SAFE, text-only initial conversation for the history scenario.
  Conversation _historyConversation() {
    final at = DateTime.now().toUtc();
    return Conversation(
      messages: <Message>[
        Message(
          id: 'smoke-h-1',
          role: MessageRole.user,
          parts: <ContentPart>[
            ContentPart.text('My favourite colour is teal.'),
          ],
          status: MessageStatus.sent,
          createdAt: at,
        ),
        Message(
          id: 'smoke-h-2',
          role: MessageRole.assistant,
          parts: <ContentPart>[
            ContentPart.text('Understood — your favourite colour is teal.'),
          ],
          status: MessageStatus.complete,
          createdAt: at,
        ),
      ],
    );
  }

  Tool _smokeTool() => const Tool(
    name: 'get_smoke_value',
    description: 'Returns the smoke-test value when the user asks for it.',
    parameters: <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
      'required': <String>[],
      'additionalProperties': false,
    },
  );

  /// The test-only resolver: counts invocations, NEVER logs the call or args,
  /// contains no Firebase/business logic, and returns a fixed sentinel.
  Future<ToolResult> _onToolCall(ToolCall call) async {
    if (mounted) {
      setState(() {
        _toolCalls++;
        _events.add('tool call · #$_toolCalls');
      });
    } else {
      _toolCalls++;
    }
    return const ToolResult(content: 'TOOL_OK', isError: false);
  }

  /// The test-only guardrail: NEVER logs or stores the text; blocks any
  /// accumulated text containing `BLOCKME` (case-insensitive) and allows the
  /// rest.
  Future<OpenAIRealtimeVoiceGuardrailDecision> _guardrail({
    required String turnId,
    required String accumulatedText,
  }) async {
    return accumulatedText.toUpperCase().contains('BLOCKME')
        ? OpenAIRealtimeVoiceGuardrailDecision.block
        : OpenAIRealtimeVoiceGuardrailDecision.allow;
  }

  @override
  void initState() {
    super.initState();
    _state = _session.state;
    // All subscriptions created BEFORE start() so no early event is lost.
    _statesSub = _session.states.listen((s) {
      if (mounted) {
        setState(() => _state = s);
      }
    });
    _transcriptsSub = _session.transcripts.listen((t) {
      if (!mounted) {
        return;
      }
      final role = t.role == OpenAIRealtimeVoiceTranscriptRole.user
          ? 'user'
          : 'assistant';
      setState(() {
        _finalCount++;
        _events.add(
          'final · $role · ${_short(t.turnId)}'
          '${t.interrupted ? ' · interrupted' : ''} · ${t.text}',
        );
      });
    });
    _deltasSub = _session.assistantTranscriptDeltas.listen((d) {
      if (!mounted || _seenDeltaTurnIds.contains(d.turnId)) {
        return;
      }
      setState(() {
        _seenDeltaTurnIds.add(d.turnId);
        _events.add('delta · ${_short(d.turnId)}');
      });
    });
    _recordingsSub = _session.recordings.listen((r) {
      if (!mounted) {
        return;
      }
      final role = r.role == OpenAIRealtimeVoiceRecordingRole.user
          ? 'user'
          : 'assistant';
      setState(() {
        _recordingCount++;
        _events.add(
          'recording · $role · ${_short(r.turnId)} · '
          '${r.interrupted ? 'interrupted' : 'complete'} · '
          '${r.transcript != null ? 'hasTranscript' : 'noTranscript'}',
        );
      });
    });
    _failuresSub = _session.recordingFailures.listen((f) {
      if (!mounted) {
        return;
      }
      final role = f.role == OpenAIRealtimeVoiceRecordingRole.user
          ? 'user'
          : 'assistant';
      setState(() {
        _recFailureCount++;
        _events.add('recFailure · $role · ${_short(f.turnId)}');
      });
    });
    _guardrailSub = _session.guardrailEvents.listen((e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _guardrailCount++;
        _events.add('guardrail · ${_short(e.turnId)}');
      });
    });
  }

  @override
  void dispose() {
    unawaited(_statesSub?.cancel());
    unawaited(_transcriptsSub?.cancel());
    unawaited(_deltasSub?.cancel());
    unawaited(_recordingsSub?.cancel());
    unawaited(_failuresSub?.cancel());
    unawaited(_guardrailSub?.cancel());
    unawaited(_session.dispose());
    super.dispose();
  }

  void _onStart() {
    if (_started) {
      return;
    }
    setState(() => _started = true);
    unawaited(_session.start());
  }

  void _onStop() => unawaited(_session.stop());

  // ---- Labels -------------------------------------------------------------

  /// A SHORT prefix (first 8 chars) of a local turnId — never the full turnId.
  String _short(String turnId) =>
      turnId.length <= 8 ? turnId : turnId.substring(0, 8);

  String _phaseLabel(OpenAIRealtimeVoicePhase phase) => switch (phase) {
    OpenAIRealtimeVoicePhase.idle => 'idle',
    OpenAIRealtimeVoicePhase.minting => 'minting',
    OpenAIRealtimeVoicePhase.connecting => 'connecting',
    OpenAIRealtimeVoicePhase.listening => 'listening',
    OpenAIRealtimeVoicePhase.userSpeaking => 'userSpeaking',
    OpenAIRealtimeVoicePhase.assistantSpeaking => 'assistantSpeaking',
    OpenAIRealtimeVoicePhase.stopping => 'stopping',
    OpenAIRealtimeVoicePhase.ended => 'ended',
    OpenAIRealtimeVoicePhase.failed => 'failed',
  };

  String _failureLabel(OpenAIRealtimeVoiceFailure failure) => switch (failure) {
    OpenAIRealtimeVoiceFailure.mint => 'mint',
    OpenAIRealtimeVoiceFailure.microphone => 'microphone',
    OpenAIRealtimeVoiceFailure.connect => 'connect',
    OpenAIRealtimeVoiceFailure.session => 'session',
    OpenAIRealtimeVoiceFailure.transport => 'transport',
    OpenAIRealtimeVoiceFailure.responseTimeout => 'responseTimeout',
    OpenAIRealtimeVoiceFailure.toolLoopLimit => 'toolLoopLimit',
    OpenAIRealtimeVoiceFailure.guardrail => 'guardrail',
  };

  String get _scenarioLabel => switch (widget.scenario) {
    SmokeScenario.history => 'history (singleTurn)',
    SmokeScenario.tools => 'tools (conversation)',
    SmokeScenario.guardrail => 'guardrail (conversation)',
  };

  String get _hint => switch (widget.scenario) {
    SmokeScenario.history =>
      'Say: "What is my favourite colour?" — the reply should use the seeded '
          'history (teal). One turn, then it ends.',
    SmokeScenario.tools =>
      'Say: "What is the smoke value?" — the assistant should call the tool and '
          'say TOOL_OK. Then press Stop.',
    SmokeScenario.guardrail =>
      'Say: "Run the guardrail test." — the reply starts, is cut off, and a '
          'safe replacement says SAFE. Then press Stop.',
  };

  @override
  Widget build(BuildContext context) {
    final s = _state;
    final theme = Theme.of(context);
    final canStop =
        _started &&
        s.phase != OpenAIRealtimeVoicePhase.ended &&
        s.phase != OpenAIRealtimeVoicePhase.failed;
    return Scaffold(
      appBar: AppBar(title: const Text('voice universal smoke')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'scenario: $_scenarioLabel',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'phase: ${_phaseLabel(s.phase)}',
                style: theme.textTheme.titleMedium,
              ),
              if (s.failure != null) ...[
                const SizedBox(height: 4),
                Text(
                  'failure: ${_failureLabel(s.failure!)}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Text(_hint, style: theme.textTheme.bodySmall),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed:
                          (!_started &&
                              s.phase == OpenAIRealtimeVoicePhase.idle)
                          ? _onStart
                          : null,
                      child: const Text('Start'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: canStop ? _onStop : null,
                      child: const Text('Stop'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _countersRow(theme),
              const SizedBox(height: 12),
              Expanded(child: _eventsPanel(theme)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _countersRow(ThemeData theme) {
    final parts = <String>[
      'delta replies: ${_seenDeltaTurnIds.length}',
      'finals: $_finalCount',
      'recordings: $_recordingCount',
      if (_recFailureCount > 0) 'recFailures: $_recFailureCount',
      if (widget.scenario == SmokeScenario.tools) 'toolCalls: $_toolCalls',
      if (widget.scenario == SmokeScenario.guardrail)
        'guardrailEvents: $_guardrailCount',
    ];
    return Text(parts.join('   ·   '), style: theme.textTheme.bodySmall);
  }

  Widget _eventsPanel(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Events (${_events.length}) — in order of receipt',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 6),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: theme.dividerColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: _events.isEmpty
                ? const Center(child: Text('— (no events yet)'))
                : ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: _events.length,
                    itemBuilder: (context, index) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: SelectableText(
                        _events[index],
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}
