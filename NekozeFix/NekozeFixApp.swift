import SwiftUI

@main
struct NekozeFixApp: App {
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
