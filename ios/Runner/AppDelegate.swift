import Flutter
import UIKit

// Classic Flutter app delegate, compatible with Flutter 3.32 stable.
// The previous version of this file used FlutterImplicitEngineDelegate /
// FlutterImplicitEngineBridge (and a paired FlutterSceneDelegate), all
// of which only exist on Flutter 3.33+ after the UIScene lifecycle
// migration. Keeping the classic delegate makes the iOS build portable
// across the entire 3.10–3.32+ SDK range the CI pipeline targets.
@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      FrpBridge.register(with: controller)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

// ── Embedded frpc (gomobile) bridge ─────────────────────────────────────────
//
// Lives in AppDelegate.swift (already in the Runner target) so no project.pbxproj
// surgery is needed. Guarded by `#if canImport(Frpmobile)` so the Runner target
// compiles whether or not the XCFramework is present:
//   * bare checkout / no gomobile build → channel reports "unavailable", Dart
//     surfaces FrpUnsupported, the rest of the app is unaffected;
//   * CI that built + pod-linked Frpmobile.xcframework → real frpc.
// See docs/frp_embed.md. gomobile name mangling (target=ios):
//   Go New() → FrpmobileNew(); *Engine → FrpmobileEngine;
//   interface LogSink → FrpmobileLogSinkProtocol.
#if canImport(Frpmobile)
import Frpmobile

enum FrpBridge {
  private static var engine: FrpmobileEngine?
  private static var sink: FlutterEventSink?

  static func register(with controller: FlutterViewController) {
    let messenger = controller.binaryMessenger
    FlutterEventChannel(name: "explorejournal/frp_events", binaryMessenger: messenger)
      .setStreamHandler(FrpStreamHandler())
    FlutterMethodChannel(name: "explorejournal/frp", binaryMessenger: messenger)
      .setMethodCallHandler { call, result in
        do {
          switch call.method {
          case "start":  try ensure().start(cfg(call));  result(nil)
          case "reload": try ensure().reload(cfg(call)); result(nil)
          case "stop":   engine?.stop();                 result(nil)
          case "status": result(engine?.running() ?? false)
          default:       result(FlutterMethodNotImplemented)
          }
        } catch {
          result(FlutterError(code: "frp_error", message: error.localizedDescription, details: nil))
        }
      }
  }

  fileprivate static func emit(_ line: String) {
    DispatchQueue.main.async { sink?(line) }
  }
  fileprivate static func setSink(_ s: FlutterEventSink?) { sink = s }

  private static func cfg(_ call: FlutterMethodCall) -> String {
    (call.arguments as? [String: Any])?["config"] as? String ?? ""
  }

  private static func ensure() -> FrpmobileEngine {
    if let e = engine { return e }
    let e = FrpmobileNew()!
    e.setLogSink(FrpLogSink())
    engine = e
    return e
  }
}

private final class FrpStreamHandler: NSObject, FlutterStreamHandler {
  func onListen(withArguments args: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? {
    FrpBridge.setSink(eventSink); return nil
  }
  func onCancel(withArguments args: Any?) -> FlutterError? {
    FrpBridge.setSink(nil); return nil
  }
}

private final class FrpLogSink: NSObject, FrpmobileLogSinkProtocol {
  func log(_ line: String?) { if let line = line { FrpBridge.emit(line) } }
}

#else

// No framework bundled — report unavailable so Dart falls back cleanly
// instead of hitting MissingPluginException.
enum FrpBridge {
  static func register(with controller: FlutterViewController) {
    FlutterMethodChannel(name: "explorejournal/frp",
                         binaryMessenger: controller.binaryMessenger)
      .setMethodCallHandler { call, result in
        if call.method == "status" {
          result(false)
        } else {
          result(FlutterError(code: "frp_unavailable",
                              message: "未内置 frpc（缺少 Frpmobile.xcframework）",
                              details: nil))
        }
      }
  }
}

#endif
