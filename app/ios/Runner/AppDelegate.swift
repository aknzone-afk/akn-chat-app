import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Held for the lifetime of the app: a channel whose only strong reference is
  /// a local goes away, and the handler silently stops being called.
  private var badgeChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // The app-icon badge.
    //
    // functions/lib/push.js puts `aps.badge = totalUnread` on every push, so the
    // number only ever goes UP: it changes when a new message arrives, and at
    // that moment the count is by definition greater than zero. Nothing ever put
    // it back down, so twelve messages that arrived overnight and were read over
    // morning chai left a "12" on the icon for the rest of the day.
    //
    // Only the app knows when the count has actually come down, and neither
    // firebase_messaging nor flutter_local_notifications exposes the iOS badge
    // to Dart — hence this channel rather than a new dependency. The caller is
    // app/lib/features/push/app_badge.dart.
    badgeChannel = FlutterMethodChannel(
      name: "akn/badge",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    badgeChannel?.setMethodCallHandler { call, result in
      guard call.method == "set", let count = call.arguments as? Int else {
        result(FlutterMethodNotImplemented)
        return
      }
      if #available(iOS 16.0, *) {
        UNUserNotificationCenter.current().setBadgeCount(max(0, count)) { _ in }
      } else {
        UIApplication.shared.applicationIconBadgeNumber = max(0, count)
      }
      result(nil)
    }
  }
}
