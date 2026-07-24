// Minimal iOS smoke entrypoint for the PRODUCTION optional-final-transcript
// voice session — the public `OpenAIRealtimeVoiceSession` of
// `chat_ai_openai_realtime_voice`, with `transcriptsEnabled: true` and the
// default `inputTranscriptionModel` (gpt-4o-mini-transcribe).
//
// It is NOT a production app. It reuses the harness Firebase init and
// `SmokeClientSecretProvider`; the OpenAI key is never on the device. It does
// NOT copy voice production code, does NOT touch the voice package's `src/**`,
// does NOT use the old `VoiceProbeSession` feasibility spike, does NOT use
// `record_transcribe`, writes NO audio file and adds NO native code.
//
// Run (physical iPhone), exactly one mode per launch, no default and no runtime
// switch:
//   flutter run \
//     -t lib/voice_transcript_smoke_main.dart \
//     --dart-define-from-file=smoke.realtime.ios.local.json \
//     --dart-define=VOICE_SMOKE_MODE=singleTurn
//   flutter run \
//     -t lib/voice_transcript_smoke_main.dart \
//     --dart-define-from-file=smoke.realtime.ios.local.json \
//     --dart-define=VOICE_SMOKE_MODE=conversation
//
// The transcript lists ARE the deliberate content channel of this smoke UI.
// Nothing else — secret, tokens, endpoint, SDP, raw events, provider error,
// item/response/event ids, usage, track ids — is ever shown or logged, and the
// transcript text is never passed to print/debugPrint/a logger.
import 'dart:async';

import 'package:chat_ai/chat_ai.dart' show BotProfile;
import 'package:chat_ai_openai_realtime_voice/chat_ai_openai_realtime_voice.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'main.dart' as harness;
import 'smoke_client_secret_provider.dart';

/// The one mandatory extra define for this entrypoint. There is NO default mode
/// and NO runtime switch — an unknown/empty value shows the setup screen and
/// never creates a session.
const String kVoiceSmokeModeRaw = String.fromEnvironment('VOICE_SMOKE_MODE');

/// Parses `VOICE_SMOKE_MODE`. Anything but the two exact names — empty
/// included — is null: the setup screen, never a session.
OpenAIRealtimeVoiceMode? parseVoiceSmokeMode(String raw) => switch (raw) {
  'singleTurn' => OpenAIRealtimeVoiceMode.singleTurn,
  'conversation' => OpenAIRealtimeVoiceMode.conversation,
  _ => null,
};

/// NAMES (never values) of the missing/invalid defines for this launch: the
/// mode itself plus the mint endpoint, bot id and the four Firebase config
/// values reused from the harness.
List<String> voiceTranscriptMissingDefines() {
  return <String>[
    if (parseVoiceSmokeMode(kVoiceSmokeModeRaw) == null) 'VOICE_SMOKE_MODE',
    if (harness.kRealtimeClientSecretEndpoint.isEmpty)
      'REALTIME_CLIENT_SECRET_ENDPOINT',
    if (harness.kBotId.isEmpty) 'CHAT_BOT_ID',
    if (harness.kFirebaseApiKey.isEmpty) 'FIREBASE_API_KEY',
    if (harness.kFirebaseAppId.isEmpty) 'FIREBASE_APP_ID',
    if (harness.kFirebaseMessagingSenderId.isEmpty)
      'FIREBASE_MESSAGING_SENDER_ID',
    if (harness.kFirebaseProjectId.isEmpty) 'FIREBASE_PROJECT_ID',
  ];
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final missing = voiceTranscriptMissingDefines();
  if (missing.isNotEmpty) {
    runApp(
      MaterialApp(
        title: 'voice transcript smoke — setup',
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
    // Never surface the raw Firebase exception: it can carry config values or
    // token-like data. A stable, safe message only.
    runApp(
      const MaterialApp(
        title: 'voice transcript smoke — setup',
        home: harness.SetupScreen(
          missing: <String>[],
          error: 'Initialization failed. Check the smoke configuration.',
        ),
      ),
    );
    return;
  }

  // Guarded above: the mode is one of the two exact names here.
  runApp(
    VoiceTranscriptSmokeApp(mode: parseVoiceSmokeMode(kVoiceSmokeModeRaw)!),
  );
}

class VoiceTranscriptSmokeApp extends StatelessWidget {
  const VoiceTranscriptSmokeApp({required this.mode, super.key});

  final OpenAIRealtimeVoiceMode mode;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'voice transcript smoke',
      theme: ThemeData(colorSchemeSeed: Colors.deepPurple, useMaterial3: true),
      home: VoiceTranscriptSmokeHome(mode: mode),
    );
  }
}

class VoiceTranscriptSmokeHome extends StatefulWidget {
  const VoiceTranscriptSmokeHome({required this.mode, super.key});

  final OpenAIRealtimeVoiceMode mode;

  @override
  State<VoiceTranscriptSmokeHome> createState() =>
      _VoiceTranscriptSmokeHomeState();
}

class _VoiceTranscriptSmokeHomeState extends State<VoiceTranscriptSmokeHome> {
  // The PRODUCTION public session — no overrides beyond the two opt-in
  // transcript settings and the mode from VOICE_SMOKE_MODE.
  late final OpenAIRealtimeVoiceSession _session = OpenAIRealtimeVoiceSession(
    clientSecretProvider: SmokeClientSecretProvider(
      endpoint: Uri.parse(harness.kRealtimeClientSecretEndpoint),
    ),
    botProfile: BotProfile(
      id: harness.kBotId,
      systemPrompt: 'Answer briefly in the user\'s language.',
      tools: const <Never>[],
    ),
    mode: widget.mode,
    transcriptsEnabled: true,
  );

  OpenAIRealtimeVoiceState _state = const OpenAIRealtimeVoiceState.idle();
  final List<String> _userTranscripts = <String>[];
  final List<String> _assistantTranscripts = <String>[];

  StreamSubscription<OpenAIRealtimeVoiceState>? _statesSub;
  StreamSubscription<OpenAIRealtimeVoiceTranscript>? _transcriptsSub;

  // One session, one Start per launch.
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _state = _session.state;
    // Both subscriptions are created BEFORE start() so no early event is lost.
    _statesSub = _session.states.listen((s) {
      if (mounted) {
        setState(() => _state = s);
      }
    });
    _transcriptsSub = _session.transcripts.listen((t) {
      if (!mounted) {
        return;
      }
      // Shown verbatim (no trim); never printed/logged.
      setState(() {
        switch (t.role) {
          case OpenAIRealtimeVoiceTranscriptRole.user:
            _userTranscripts.add(t.text);
          case OpenAIRealtimeVoiceTranscriptRole.assistant:
            _assistantTranscripts.add(t.text);
        }
      });
    });
  }

  @override
  void dispose() {
    // Cancel both subscriptions, then dispose the session exactly once.
    unawaited(_statesSub?.cancel());
    unawaited(_transcriptsSub?.cancel());
    unawaited(_session.dispose());
    super.dispose();
  }

  void _onStart() {
    if (_started) {
      return;
    }
    setState(() => _started = true);
    // start() is allowed exactly once per instance.
    unawaited(_session.start());
  }

  void _onStop() => unawaited(_session.stop());

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

  String get _modeLabel => switch (widget.mode) {
    OpenAIRealtimeVoiceMode.singleTurn => 'singleTurn',
    OpenAIRealtimeVoiceMode.conversation => 'conversation',
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
      appBar: AppBar(title: Text('voice transcript smoke [$_modeLabel]')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
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
              const SizedBox(height: 16),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _TranscriptPanel(
                        title: 'User transcripts',
                        items: _userTranscripts,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _TranscriptPanel(
                        title: 'Assistant transcripts',
                        items: _assistantTranscripts,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One labelled, scrollable list of final transcripts. Each item is rendered
/// verbatim (no trim) — the deliberate content channel of this smoke UI.
class _TranscriptPanel extends StatelessWidget {
  const _TranscriptPanel({required this.title, required this.items});

  final String title;
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('$title (${items.length})', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: theme.dividerColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: items.isEmpty
                ? const Center(child: Text('—'))
                : ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: items.length,
                    itemBuilder: (context, index) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: SelectableText(
                        items[index],
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}
