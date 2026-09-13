import SwiftUI

/// UI レイヤー: permission/calibration/monitor フェーズを切り替えるルートビュー。
/// design.md の "UI Components" - RootView を参照。

struct RootView: View {
    // MARK: - 環境

    @EnvironmentObject private var sessionManager: PostureSessionManager
    @Environment(\.scenePhase) private var scenePhase

    // MARK: - 本文

    var body: some View {
        Group {
            switch snapshot.phase {
            case .awaitingPermission, .permissionDenied:
                PermissionView()
            case .calibrating:
                CalibrationView()
            case .monitoring:
                MonitorView()
            case .idle:
                PermissionView()
            case .rotating:
                MonitorView()
            }
        }
        .onAppear {
            Task {
                await sessionManager.bootstrap()
            }
        }
        // ライフサイクル自動停止・復帰（要求 8.1/8.2、タスク3.5）
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .background:
                sessionManager.handleDidEnterBackground()
            case .active, .inactive:
                sessionManager.handleWillEnterForeground()
            @unknown default:
                break
            }
        }
    }

    // MARK: - 計算プロパティ

    private var snapshot: SessionSnapshot {
        sessionManager.snapshot
    }
}

// MARK: - プレビュー

struct RootView_Previews: PreviewProvider {
    static var previews: some View {
        RootView()
            .environmentObject(PostureSessionManager())
    }
}
