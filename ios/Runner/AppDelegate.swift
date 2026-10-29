import Flutter
import GoogleMaps
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
    // The map pin: Dart hands over GOOGLE_MAPS_KEY before the first map (lib/ui/maps/maps_setup_io.dart)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "OneLocalMaps") {
      FlutterMethodChannel(name: "onelocal/maps", binaryMessenger: registrar.messenger()).setMethodCallHandler { call, result in
        if call.method == "provideKey", let key = call.arguments as? String, !key.isEmpty {
          GMSServices.provideAPIKey(key)
          result(nil)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }
}
