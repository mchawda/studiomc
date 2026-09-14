import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = self.registrar(forPlugin: "MobileInferenceHost") {
      MobileInferenceHost.register(messenger: registrar.messenger())
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

/// llama.cpp host. `probe` is live; generation waits for the native lib.
enum MobileInferenceHost {
  static let methodChannel = "studiomc.mobile_inference"
  static let tokenChannel = "studiomc.mobile_inference/tokens"
  static let notLinked = "llama_cpp_not_linked"

  static func register(messenger: FlutterBinaryMessenger) {
    let events = FlutterEventChannel(name: tokenChannel, binaryMessenger: messenger)
    events.setStreamHandler(MobileInferenceTokenStream())

    let channel = FlutterMethodChannel(name: methodChannel, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "probe":
        result(probe())
      case "load", "unload", "complete", "streamStart", "streamCancel", "embed":
        result(FlutterError(
          code: notLinked,
          message: "llama.cpp is not linked yet. Place a GGUF at Application Support/models/<id>/ and implement \(call.method) in MobileInferenceHost.",
          details: call.method
        ))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  static func probe() -> [String: Any] {
    let ram = ProcessInfo.processInfo.physicalMemory
    let deviceClass = UIDevice.current.userInterfaceIdiom == .pad ? "tablet" : "phone"
    return [
      "ramBytes": ram,
      "deviceClass": deviceClass,
      "accelerators": ["neuralEngine", "metal", "cpu"],
      "chipName": machineIdentifier(),
    ]
  }

  static func machineIdentifier() -> String {
    var info = utsname()
    uname(&info)
    return withUnsafePointer(to: &info.machine) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: 1) { chars in
        String(validatingUTF8: chars) ?? "Apple"
      }
    }
  }
}

final class MobileInferenceTokenStream: NSObject, FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    return nil
  }
}
