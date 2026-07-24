// Minimal iOS smoke entrypoint for the PRODUCTION optional LOCAL RECORDING of
// the voice session — the public `OpenAIRealtimeVoiceSession` of
// `chat_ai_openai_realtime_voice`, with `recordingEnabled: true` AND
// `transcriptsEnabled: true`.
//
// It is a TEST HARNESS, not a production app. It reuses the harness Firebase
// init and `SmokeClientSecretProvider` (the OpenAI key is never on the device),
// and the PRODUCTION public session with NO overrides beyond the two opt-in
// flags, the mode from VOICE_SMOKE_MODE and an app-writable recording directory.
// It does NOT copy voice production code, does NOT touch the voice package's
// `src/**`, does NOT use the old `VoiceProbeSession`, does NOT use
// `record_transcribe`, and adds NO native code and NO second microphone.
//
// Privacy: this UI shows a recording's role / interrupted / whether a transcript
// is present / whether the file exists, the file BASENAME (never the full path)
// and its size, a recording failure's role, phase/failure, and — as a diagnostic
// content channel like the transcript smoke — the final transcript TEXT on the
// `transcripts` stream (so a tester can confirm transcripts arrive AND pair to
// recordings). It NEVER prints/logs any of this (no print/debugPrint) and never
// shows the file path, the endpoint, a token, a secret or a bot id.
//
// Playback: each file has an on-device play button (via `audioplayers`, a
// test-harness-only dependency integrated through Swift Package Manager on iOS —
// like the Firebase plugins) for a quick "is it playable" check. The exact
// FORMAT metadata (container / AAC-LC / 16 kHz / mono / ~32 kbps / non-zero
// duration) is verified OFF-DEVICE: pull the files from the app tmp container
// (Xcode → Devices & Simulators → the app → Download Container) and run
// `afinfo` / `ffprobe` on the `.m4a` files. The in-app "Directory files" panel
// (size in KiB, refreshable) is the on-device no-delete / no-overwrite check
// across two sessions.
//
// The recording directory is a fixed sub-folder of the app-writable temporary
// directory (`Directory.systemTemp`, i.e. the app sandbox's tmp) — obtained via
// `dart:io` with NO extra dependency. It is REUSED across launches on purpose:
// running the harness twice into the same folder is the no-overwrite /
// no-collision check (the "Directory files" panel then shows BOTH sessions'
// files).
//
// Run (physical iPhone), exactly one mode per launch, no default, no runtime
// switch:
//   flutter run \
//     -t lib/voice_recording_smoke_main.dart \
//     --dart-define-from-file=smoke.realtime.ios.local.json \
//     --dart-define=VOICE_SMOKE_MODE=singleTurn
//   flutter run \
//     -t lib/voice_recording_smoke_main.dart \
//     --dart-define-from-file=smoke.realtime.ios.local.json \
//     --dart-define=VOICE_SMOKE_MODE=conversation
import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
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

/// The fixed recording sub-folder inside the app-writable tmp directory.
const String kRecordingSubdir = 'voice_recording_smoke';

/// Parses `VOICE_SMOKE_MODE`. Anything but the two exact names — empty
/// included — is null: the setup screen, never a session.
OpenAIRealtimeVoiceMode? parseVoiceSmokeMode(String raw) => switch (raw) {
  'singleTurn' => OpenAIRealtimeVoiceMode.singleTurn,
  'conversation' => OpenAIRealtimeVoiceMode.conversation,
  _ => null,
};

/// NAMES (never values) of the missing/invalid defines for this launch.
List<String> voiceRecordingMissingDefines() {
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

  final missing = voiceRecordingMissingDefines();
  if (missing.isNotEmpty) {
    runApp(
      MaterialApp(
        title: 'voice recording smoke — setup',
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
        title: 'voice recording smoke — setup',
        home: harness.SetupScreen(
          missing: <String>[],
          error: 'Initialization failed. Check the smoke configuration.',
        ),
      ),
    );
    return;
  }

  // The app-writable recording directory (app sandbox tmp) — created if needed.
  final directoryPath = '${Directory.systemTemp.path}/$kRecordingSubdir';
  Directory(directoryPath).createSync(recursive: true);

  // Guarded above: the mode is one of the two exact names here.
  runApp(
    VoiceRecordingSmokeApp(
      mode: parseVoiceSmokeMode(kVoiceSmokeModeRaw)!,
      directoryPath: directoryPath,
    ),
  );
}

class VoiceRecordingSmokeApp extends StatelessWidget {
  const VoiceRecordingSmokeApp({
    required this.mode,
    required this.directoryPath,
    super.key,
  });

  final OpenAIRealtimeVoiceMode mode;
  final String directoryPath;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'voice recording smoke',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: VoiceRecordingSmokeHome(mode: mode, directoryPath: directoryPath),
    );
  }
}

/// One observed recording. It keeps the file path in memory ONLY to check
/// existence/size and to play the file on-device; the path itself is never
/// shown or logged.
class _RecordingRow {
  _RecordingRow({
    required this.role,
    required this.interrupted,
    required this.hasTranscript,
    required this.filePath,
  });

  final OpenAIRealtimeVoiceRecordingRole role;
  final bool interrupted;
  final bool hasTranscript;
  final String filePath;

  String get basename => filePath.substring(filePath.lastIndexOf('/') + 1);
  bool get exists {
    final f = File(filePath);
    return f.existsSync() && f.lengthSync() > 0;
  }
}

/// The size of a file in KiB (0 if missing), for a quick non-zero check. The
/// exact codec/rate/channels/bitrate is verified OFF-DEVICE (afinfo/ffprobe);
/// the on-device play button only confirms the file is playable.
int _fileSizeKiB(String path) {
  final f = File(path);
  return f.existsSync() ? (f.lengthSync() / 1024).ceil() : 0;
}

class VoiceRecordingSmokeHome extends StatefulWidget {
  const VoiceRecordingSmokeHome({
    required this.mode,
    required this.directoryPath,
    super.key,
  });

  final OpenAIRealtimeVoiceMode mode;
  final String directoryPath;

  @override
  State<VoiceRecordingSmokeHome> createState() =>
      _VoiceRecordingSmokeHomeState();
}

class _VoiceRecordingSmokeHomeState extends State<VoiceRecordingSmokeHome> {
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
    recordingEnabled: true,
    recordingDirectoryPath: widget.directoryPath,
  );

  final AudioPlayer _player = AudioPlayer();

  OpenAIRealtimeVoiceState _state = const OpenAIRealtimeVoiceState.idle();
  final List<_RecordingRow> _recordings = <_RecordingRow>[];
  final List<OpenAIRealtimeVoiceRecordingRole> _failures =
      <OpenAIRealtimeVoiceRecordingRole>[];
  // Diagnostic ONLY: the raw transcript side channel, so a tester can see
  // whether transcripts arrive at all and confirm they pair to recordings.
  // Shown on-device only; never printed/logged.
  final List<String> _transcripts = <String>[];
  // Assistant transcript deltas of the current response: the count of fragments
  // and the text assembled in arrival order. In-memory only; never logged.
  int _deltaCount = 0;
  String _deltaText = '';
  List<String> _dirFiles = <String>[]; // basenames currently in the directory

  StreamSubscription<OpenAIRealtimeVoiceState>? _statesSub;
  StreamSubscription<OpenAIRealtimeVoiceRecording>? _recordingsSub;
  StreamSubscription<OpenAIRealtimeVoiceRecordingFailure>? _failuresSub;
  StreamSubscription<OpenAIRealtimeVoiceTranscript>? _transcriptsSub;
  StreamSubscription<OpenAIRealtimeVoiceTranscriptDelta>? _deltasSub;

  bool _started = false;
  bool _interrupting = false; // an interruptResponse() is in flight

  @override
  void initState() {
    super.initState();
    _state = _session.state;
    _refreshDirFiles();
    // All subscriptions are created BEFORE start() so no early event is lost.
    _statesSub = _session.states.listen((s) {
      if (mounted) {
        setState(() => _state = s);
      }
    });
    _transcriptsSub = _session.transcripts.listen((t) {
      if (!mounted) {
        return;
      }
      final role = switch (t.role) {
        OpenAIRealtimeVoiceTranscriptRole.user => 'user',
        OpenAIRealtimeVoiceTranscriptRole.assistant => 'assistant',
      };
      setState(() => _transcripts.add('$role: ${t.text}'));
    });
    _deltasSub = _session.assistantTranscriptDeltas.listen((delta) {
      if (!mounted) {
        return;
      }
      // Verbatim, in order — the app assembles the displayed text itself.
      setState(() {
        _deltaCount++;
        _deltaText += delta.delta;
      });
    });
    _recordingsSub = _session.recordings.listen((r) {
      if (!mounted) {
        return;
      }
      setState(() {
        _recordings.add(
          _RecordingRow(
            role: r.role,
            interrupted: r.interrupted,
            hasTranscript: r.transcript != null,
            filePath: r.filePath,
          ),
        );
      });
      _refreshDirFiles();
    });
    _failuresSub = _session.recordingFailures.listen((f) {
      if (mounted) {
        setState(() => _failures.add(f.role));
      }
    });
  }

  @override
  void dispose() {
    unawaited(_statesSub?.cancel());
    unawaited(_recordingsSub?.cancel());
    unawaited(_failuresSub?.cancel());
    unawaited(_transcriptsSub?.cancel());
    unawaited(_deltasSub?.cancel());
    unawaited(_session.dispose());
    unawaited(_player.dispose());
    super.dispose();
  }

  void _refreshDirFiles() {
    final dir = Directory(widget.directoryPath);
    final files = <String>[];
    if (dir.existsSync()) {
      for (final entity in dir.listSync()) {
        if (entity is File && entity.path.endsWith('.m4a')) {
          files.add(entity.path.substring(entity.path.lastIndexOf('/') + 1));
        }
      }
    }
    files.sort();
    if (mounted) {
      setState(() => _dirFiles = files);
    }
  }

  void _onStart() {
    if (_started) {
      return;
    }
    setState(() => _started = true);
    unawaited(_session.start());
  }

  void _onStop() => unawaited(_session.stop());

  /// Calls ONLY the public `interruptResponse()`; no cancel/clear logic is
  /// copied here. Guarded so a second tap while one is in flight is a no-op; a
  /// local failure surfaces only as a coarse UI flag, never a raw exception.
  Future<void> _onInterrupt() async {
    if (_interrupting) {
      return;
    }
    setState(() => _interrupting = true);
    try {
      await _session.interruptResponse();
    } on Object {
      // Coarse UI status only — never a raw exception.
    } finally {
      if (mounted) {
        setState(() => _interrupting = false);
      }
    }
  }

  /// On-device "is it playable" check. Best-effort; a failure carries no detail.
  /// Format metadata is still verified off-device (afinfo/ffprobe).
  Future<void> _play(String filePath) async {
    try {
      await _player.stop();
      await _player.play(DeviceFileSource(filePath));
    } on Object {
      // Playback failure is non-fatal for the smoke and carries no detail.
    }
  }

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

  String _roleLabel(OpenAIRealtimeVoiceRecordingRole role) => switch (role) {
    OpenAIRealtimeVoiceRecordingRole.user => 'user',
    OpenAIRealtimeVoiceRecordingRole.assistant => 'assistant',
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
      appBar: AppBar(title: Text('voice recording smoke [$_modeLabel]')),
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
              const SizedBox(height: 4),
              Text(
                'dir: $kRecordingSubdir/ (app tmp)',
                style: theme.textTheme.bodySmall,
              ),
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
              const SizedBox(height: 8),
              OutlinedButton(
                // Enabled only while the assistant is speaking and no interrupt
                // is already in flight.
                onPressed:
                    (s.phase == OpenAIRealtimeVoicePhase.assistantSpeaking &&
                        !_interrupting)
                    ? _onInterrupt
                    : null,
                child: Text(
                  _interrupting ? 'Interrupting…' : 'Interrupt response',
                ),
              ),
              if (_failures.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  'recordingFailures: '
                  '${_failures.map(_roleLabel).join(', ')}',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              _deltasPanel(theme),
              const SizedBox(height: 12),
              Expanded(child: _transcriptsPanel(theme)),
              const SizedBox(height: 12),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: _recordingsPanel(theme)),
                    const SizedBox(width: 12),
                    Expanded(child: _directoryPanel(theme)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _deltasPanel(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Assistant deltas ($_deltaCount fragments)',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 96),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: theme.dividerColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(8),
              child: SelectableText(
                _deltaText.isEmpty ? '—' : _deltaText,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _transcriptsPanel(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Transcripts stream (${_transcripts.length})',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 6),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: theme.dividerColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: _transcripts.isEmpty
                ? const Center(child: Text('— (no transcripts received)'))
                : ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: _transcripts.length,
                    itemBuilder: (context, index) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: SelectableText(
                        _transcripts[index],
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _recordingsPanel(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Recordings this session (${_recordings.length})',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 6),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: theme.dividerColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: _recordings.isEmpty
                ? const Center(child: Text('—'))
                : ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: _recordings.length,
                    itemBuilder: (context, index) {
                      final r = _recordings[index];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${_roleLabel(r.role)} · '
                                    'interrupted=${r.interrupted} · '
                                    'transcript=${r.hasTranscript} · '
                                    'exists=${r.exists}',
                                    style: theme.textTheme.bodySmall,
                                  ),
                                  SelectableText(
                                    r.basename,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.play_arrow),
                              tooltip: 'play (on-device)',
                              onPressed: () => _play(r.filePath),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  Widget _directoryPanel(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Directory files (${_dirFiles.length})',
                style: theme.textTheme.titleSmall,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'refresh',
              onPressed: _refreshDirFiles,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: theme.dividerColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: _dirFiles.isEmpty
                ? const Center(child: Text('—'))
                : ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: _dirFiles.length,
                    itemBuilder: (context, index) {
                      final name = _dirFiles[index];
                      final path = '${widget.directoryPath}/$name';
                      final kib = _fileSizeKiB(path);
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '$kib KiB',
                                    style: theme.textTheme.bodySmall,
                                  ),
                                  SelectableText(
                                    name,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.play_arrow),
                              tooltip: 'play (on-device)',
                              onPressed: () => _play(path),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}
