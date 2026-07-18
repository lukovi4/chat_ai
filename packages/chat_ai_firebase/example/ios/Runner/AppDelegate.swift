import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Increment-0 voice spike: app-local native audio-writer channel. Present
    // in every launch of this harness; only lib/voice_probe_main.dart uses it.
    if let registrar = engineBridge.pluginRegistry.registrar(
      forPlugin: "VoiceProbeAudioWriterPlugin")
    {
      VoiceProbeAudioWriterPlugin.register(with: registrar)
    }
  }
}
