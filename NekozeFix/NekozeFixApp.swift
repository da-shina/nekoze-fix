import SwiftUI

/// 監視モード中の画面回転ロック。
/// PostureSessionManager がフェーズ遷移時に lock/unlock を呼び出す。
final class OrientationLockController {
    static let shared = OrientationLockController()
    private(set) var isPortraitLocked = false
    private init() {}

    func lockToPortrait() {
        guard !isPortraitLocked else { return }
        isPortraitLocked = true
        let current = UIDevice.current.orientation
        if current != .portrait && current != .faceUp && current != .faceDown {
            UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")
        }
        UIViewController.attemptRotationToDeviceOrientation()
    }

    func unlock() {
        guard isPortraitLocked else { return }
        isPortraitLocked = false
        UIViewController.attemptRotationToDeviceOrientation()
    }
}

/// AppDelegate: 監視モード中の画面回転をポートレートに制限する。
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLockController.shared.isPortraitLocked ? .portrait : .all
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
