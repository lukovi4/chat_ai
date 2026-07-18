// Increment-0 iOS voice feasibility spike entrypoint. NOT a production app and
// NOT a public API — a device-only probe of ONE speech-to-speech WebRTC turn
// with two app-local, iOS-native audio files (user + assistant).
//
// Run (physical iPhone):
//   flutter run \
//     -t lib/voice_probe_main.dart \
//     --dart-define-from-file=smoke.realtime.ios.local.json
//
// It reuses the harness Firebase init and SmokeClientSecretProvider; the OpenAI
// key is never on the device. The UI shows only coarse state and, after a
// successful turn, Play user / Play assistant — never a path, transcript,
// secret or raw event.
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'main.dart' as harness;
import 'smoke_client_secret_provider.dart';
import 'src/voice_probe/native_audio_writer.dart';
import 'src/voice_probe/probe_state.dart';
import 'src/voice_probe/voice_probe_session.dart';
import 'src/voice_probe/voice_probe_transport.dart';

/// The defines this probe needs (no `SMOKE_BACKEND` — the probe is its own
/// mode). Returns the NAMES (never values) of the missing ones.
List<String> voiceProbeMissingDefines() {
  return <String>[
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

  final missing = voiceProbeMissingDefines();
  if (missing.isNotEmpty) {
    runApp(
      MaterialApp(
        title: 'voice probe — setup',
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
        title: 'voice probe — setup',
        home: harness.SetupScreen(
          missing: <String>[],
          error: 'Initialization failed. Check the smoke configuration.',
        ),
      ),
    );
    return;
  }

  runApp(const VoiceProbeApp());
}

class VoiceProbeApp extends StatelessWidget {
  const VoiceProbeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'voice probe',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const VoiceProbeHome(),
    );
  }
}

class VoiceProbeHome extends StatefulWidget {
  const VoiceProbeHome({super.key});

  @override
  State<VoiceProbeHome> createState() => _VoiceProbeHomeState();
}

class _VoiceProbeHomeState extends State<VoiceProbeHome> {
  late final VoiceProbeSession _session = VoiceProbeSession(
    clientSecretProvider: SmokeClientSecretProvider(
      endpoint: Uri.parse(harness.kRealtimeClientSecretEndpoint),
    ),
    botId: harness.kBotId,
    transportFactory: WebRtcVoiceProbeTransport.new,
    writerFactory: NativeAudioWriterFactory(),
  );

  VoiceProbeState _state = const VoiceProbeState.idle();

  @override
  void initState() {
    super.initState();
    _state = _session.state;
    _session.states.listen((s) {
      if (mounted) {
        setState(() => _state = s);
      }
    });
  }

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  String _phaseLabel(VoiceProbePhase phase) => switch (phase) {
    VoiceProbePhase.idle => 'idle',
    VoiceProbePhase.minting => 'minting',
    VoiceProbePhase.capturing => 'capturing',
    VoiceProbePhase.connecting => 'connecting',
    VoiceProbePhase.configuring => 'configuring',
    VoiceProbePhase.speak => 'speak now (one short phrase)',
    VoiceProbePhase.responding => 'assistant responding',
    VoiceProbePhase.finalizing => 'finalizing',
    VoiceProbePhase.ready => 'ready',
    VoiceProbePhase.failed => 'failed (${_state.errorCode?.name ?? 'unknown'})',
    VoiceProbePhase.closed => 'closed',
  };

  @override
  Widget build(BuildContext context) {
    final s = _state;
    return Scaffold(
      appBar: AppBar(title: const Text('voice probe [realtime]')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _phaseLabel(s.phase),
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              if (s.diagnostics?.responseFinished == true &&
                  s.phase == VoiceProbePhase.responding) ...[
                const SizedBox(height: 8),
                Text(
                  'Response finished — press Stop / Close',
                  style: Theme.of(context).textTheme.titleSmall,
                  textAlign: TextAlign.center,
                ),
              ],
              if (s.diagnostics != null) ...[
                const SizedBox(height: 12),
                _diagnosticsPanel(context, s.diagnostics!),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: s.canStart ? _session.start : null,
                child: const Text('Start'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: s.canStop ? _session.stop : null,
                child: const Text('Stop / Close'),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FilledButton.tonal(
                    onPressed: s.canPlay ? _session.playUser : null,
                    child: const Text('Play user'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.tonal(
                    onPressed: s.canPlay ? _session.playAssistant : null,
                    child: const Text('Play assistant'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Compact, content-free diagnostic readout shown during a turn and after
  /// Stop/failure: the four lifecycle booleans and each writer's minimal
  /// counters + stable status. Never a path, transcript, secret or audio.
  Widget _diagnosticsPanel(BuildContext context, VoiceProbeDiagnostics d) {
    final style = Theme.of(context).textTheme.bodySmall;
    String flag(bool b) => b ? '✓' : '·';
    String writer(String name, WriterDiagnostics? w) => w == null
        ? '$name: —'
        : '$name: cb=${w.callbackCount} frames=${w.writtenFrames} '
              '${w.status.name}';
    return Column(
      children: [
        Text(
          'events  created ${flag(d.responseCreated)}   '
          'audioStart ${flag(d.outputAudioStarted)}   '
          'audioStop ${flag(d.outputAudioStopped)}   '
          'done ${flag(d.responseDone)}',
          style: style,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        Text(writer('user', d.user), style: style),
        Text(writer('assistant', d.assistant), style: style),
      ],
    );
  }
}
