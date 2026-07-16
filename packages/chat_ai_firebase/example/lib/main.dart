import 'dart:async';
import 'dart:typed_data';

import 'package:chat_ai/chat_ai.dart';
import 'package:chat_ai_firebase/chat_ai_firebase.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

// Config-free reusable harness: everything is injected via compile-time defines,
// so no google-services.json / GoogleService-Info.plist is bundled. Provide them
// with `--dart-define-from-file=firebase.<platform>.local.json` (see README).
// The OpenAI key never touches the device — it lives only in the server's Secret
// Manager. FIREBASE_API_KEY is a Firebase *client* config value, not a provider
// secret, but is still kept only in local, gitignored files.
const String kEndpoint = String.fromEnvironment('CHAT_ENDPOINT');
const String kBotId = String.fromEnvironment('CHAT_BOT_ID');
const String kFirebaseApiKey = String.fromEnvironment('FIREBASE_API_KEY');
const String kFirebaseAppId = String.fromEnvironment('FIREBASE_APP_ID');
const String kFirebaseMessagingSenderId = String.fromEnvironment(
  'FIREBASE_MESSAGING_SENDER_ID',
);
const String kFirebaseProjectId = String.fromEnvironment('FIREBASE_PROJECT_ID');

/// The six mandatory defines, in a fixed order. Values are intentionally not
/// surfaced anywhere — only names are ever shown.
const Map<String, String> _requiredDefines = {
  'CHAT_ENDPOINT': kEndpoint,
  'CHAT_BOT_ID': kBotId,
  'FIREBASE_API_KEY': kFirebaseApiKey,
  'FIREBASE_APP_ID': kFirebaseAppId,
  'FIREBASE_MESSAGING_SENDER_ID': kFirebaseMessagingSenderId,
  'FIREBASE_PROJECT_ID': kFirebaseProjectId,
};

/// Names (never values) of the missing required defines.
List<String> missingDefines() => _requiredDefines.entries
    .where((entry) => entry.value.isEmpty)
    .map((entry) => entry.key)
    .toList(growable: false);

/// Pure helper (not a package API, not exported) mapping the four Firebase
/// client-config defines into [FirebaseOptions]; rejects any empty value.
FirebaseOptions buildSmokeFirebaseOptions({
  required String apiKey,
  required String appId,
  required String messagingSenderId,
  required String projectId,
}) {
  final missing = <String>[
    if (apiKey.isEmpty) 'FIREBASE_API_KEY',
    if (appId.isEmpty) 'FIREBASE_APP_ID',
    if (messagingSenderId.isEmpty) 'FIREBASE_MESSAGING_SENDER_ID',
    if (projectId.isEmpty) 'FIREBASE_PROJECT_ID',
  ];
  if (missing.isNotEmpty) {
    throw ArgumentError(
      'Missing Firebase config define(s): ${missing.join(', ')}',
    );
  }
  return FirebaseOptions(
    apiKey: apiKey,
    appId: appId,
    messagingSenderId: messagingSenderId,
    projectId: projectId,
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final missing = missingDefines();
  if (missing.isNotEmpty) {
    runApp(_SetupApp(missing: missing));
    return;
  }

  try {
    // Explicit options from the defines — no native config files required.
    await Firebase.initializeApp(
      options: buildSmokeFirebaseOptions(
        apiKey: kFirebaseApiKey,
        appId: kFirebaseAppId,
        messagingSenderId: kFirebaseMessagingSenderId,
        projectId: kFirebaseProjectId,
      ),
    );
    // Debug attestation — fine for a smoke, never production. Register the
    // printed debug token in the Firebase console (see README).
    await FirebaseAppCheck.instance.activate(
      providerAndroid: AndroidDebugProvider(),
      providerApple: AppleDebugProvider(),
    );
    if (FirebaseAuth.instance.currentUser == null) {
      await FirebaseAuth.instance.signInAnonymously();
    }
  } on Object catch (error) {
    runApp(_SetupApp(missing: const [], error: 'Firebase init failed: $error'));
    return;
  }

  runApp(const SmokeApp());
}

/// The single read-only smoke Tool: no arguments, strict Chat AI Tool Schema v1.
Tool deviceTimeTool() => const Tool(
  name: 'get_device_time',
  description: 'Returns the current device time as an ISO-8601 UTC timestamp.',
  parameters: {
    'type': 'object',
    'properties': <String, dynamic>{},
    'required': <String>[],
    'additionalProperties': false,
  },
);

/// Real tool-loop resolver: known tool → the ISO-8601 timestamp; anything else
/// → a safe `is_error` result (never throws, no dedupe store — read-only).
Future<ToolResult> resolveTool(ToolCall call) async {
  if (call.name == 'get_device_time') {
    return ToolResult(
      content: DateTime.now().toUtc().toIso8601String(),
      isError: false,
    );
  }
  return const ToolResult(content: 'Unknown tool.', isError: true);
}

/// Maps a machine failure cause to a short user string — never the developer
/// detail (the widget is given this instead of raw text).
String failureText(FailureCause cause) => switch (cause) {
  FailureCause.auth => 'Sign-in problem. Try again.',
  FailureCause.entitlement => 'This bot is not available.',
  FailureCause.quota => 'Daily limit reached.',
  FailureCause.rate => 'Too many requests — slow down a moment.',
  FailureCause.overloaded => 'The service is busy. Try again.',
  FailureCause.contentFilter => 'That request was filtered.',
  FailureCause.contextTooLong => 'This conversation is too long.',
  FailureCause.network => 'Network problem. Check your connection.',
  FailureCause.upstream => 'Something went wrong. Try again.',
  FailureCause.toolLoopLimit => 'The bot got stuck in a tool loop.',
};

class SmokeApp extends StatelessWidget {
  const SmokeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'chat_ai smoke',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const SmokeHome(),
    );
  }
}

class SmokeHome extends StatefulWidget {
  const SmokeHome({super.key});

  @override
  State<SmokeHome> createState() => _SmokeHomeState();
}

class _SmokeHomeState extends State<SmokeHome> {
  late final FirebaseChatBackend _backend = FirebaseChatBackend(kEndpoint);
  late final ChatSession _session = ChatSession(
    backend: _backend,
    botProfile: BotProfile(
      id: kBotId,
      systemPrompt:
          'You are a concise smoke-test assistant. When asked for the time, '
          'call get_device_time and report it.',
      tools: [deviceTimeTool()],
    ),
    onToolCall: resolveTool,
  );
  final ImagePicker _picker = ImagePicker();

  ConversationState _state = const ConversationState.idle();
  StreamSubscription<ConversationState>? _sub;

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '(no user)';

  @override
  void initState() {
    super.initState();
    _state = _session.state;
    _sub = _session.states.listen((s) => setState(() => _state = s));
  }

  @override
  void dispose() {
    _sub?.cancel();
    _session.dispose();
    super.dispose();
  }

  /// The Input Bar's OnAttach: raw picker bytes (the Core resizes). `[]` on
  /// cancel.
  Future<List<Uint8List>> _onAttach() async {
    final files = await _picker.pickMultiImage();
    final out = <Uint8List>[];
    for (final file in files) {
      out.add(await file.readAsBytes());
    }
    return out;
  }

  String _describeState(ConversationState s) => switch (s) {
    Idle() => 'idle',
    Sending() => 'sending',
    AwaitingTool(:final call) => 'awaitingTool(${call.name})',
    Streaming() => 'streaming',
    Done() => 'done',
    Failed(:final cause) => 'failed(${cause.name})',
    Cancelled() => 'cancelled',
  };

  String? _usageLine(ConversationState s) {
    if (s is Done && s.usage != null) {
      final u = s.usage!;
      return 'usage: in ${u.inputTokens} / out ${u.outputTokens}';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final usage = _usageLine(_state);
    return Scaffold(
      appBar: AppBar(title: Text('chat_ai smoke — ${_describeState(_state)}')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'uid: $_uid   bot: $kBotId',
                    style: Theme.of(context).textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (usage != null)
                  Text(usage, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          Expanded(
            child: ChatMessageList(
              session: _session,
              failureText: failureText,
              onImageTap: (_) {},
            ),
          ),
          SafeArea(
            top: false,
            child: ChatInputBar(
              session: _session,
              hint: 'Message… (try "what time is it?")',
              onAttach: _onAttach,
            ),
          ),
        ],
      ),
    );
  }
}

/// Shown when required defines are missing (or Firebase init failed): no live
/// session is created.
class _SetupApp extends StatelessWidget {
  const _SetupApp({required this.missing, this.error});

  final List<String> missing;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'chat_ai smoke — setup',
      home: SetupScreen(missing: missing, error: error),
    );
  }
}

/// The setup screen (no Firebase, no live session) — public so the smoke widget
/// test can pump it without network. Lists the NAMES of missing defines; never
/// their values.
class SetupScreen extends StatelessWidget {
  const SetupScreen({super.key, this.missing = const [], this.error});

  final List<String> missing;
  final String? error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('chat_ai smoke — setup')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'Not configured. Provide the smoke defines via a local file:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            const SelectableText(
              'flutter run --dart-define-from-file=firebase.android.local.json\n'
              'flutter run --dart-define-from-file=firebase.ios.local.json',
            ),
            const SizedBox(height: 16),
            if (missing.isNotEmpty) ...[
              const Text(
                'Missing defines:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              for (final name in missing) Text('• $name'),
            ],
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            const Text(
              'See example/README.md and the server DEPLOY_SMOKE.md. The OpenAI '
              'key is never on the device.',
            ),
          ],
        ),
      ),
    );
  }
}
