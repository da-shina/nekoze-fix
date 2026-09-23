import SwiftUI

/// AppDelegate: 監視モード中の画面回転をポートレートに制限する。
class AppDelegate: NSObject, UIApplicationDelegate {
    static var isPortraitLocked = false

    static func lockToPortrait() {
        guard !isPortraitLocked else { return }
        isPortraitLocked = true
        let current = UIDevice.current.orientation
        if current != .portrait && current != .faceUp && current != .faceDown {
            UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
        }
        UIViewController.attemptRotationToDeviceOrientation()
    }

    static func unlock() {
        guard isPortraitLocked else { return }
        isPortraitLocked = false
        UIViewController.attemptRotationToDeviceOrientation()
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.isPortraitLocked ? .portrait : .all
    }
}

@main
struct NekozeFixApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var settingsStore: SettingsStore
    @StateObject private var sessionManager: PostureSessionManager

    init() {
        let store = SettingsStore()
        _settingsStore = StateObject(wrappedValue: store)
        _sessionManager = StateObject(wrappedValue: PostureSessionManager(settingsStore: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(sessionManager)
                .environmentObject(settingsStore)
        }
    }
}
