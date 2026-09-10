import SwiftUI

@main
struct NekozeFixApp: App {
    @StateObject private var sessionManager = PostureSessionManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(sessionManager)
        }
    }
}
