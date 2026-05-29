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
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
