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
            switch sessionManager.snapshot.phase {
            case .awaitingPermission, .permissionDenied:
                PermissionView()
            case .calibrating:
                CalibrationView()
            case .monitoring:
                MonitorView()
            case .idle:
                // 初回起動・監視停止後の開始画面。タップで許可要求→校正へ。
                SplashView(onStartCalibration: {
                    Task {
                        await sessionManager.bootstrap()
                    }
                })
            }
        }
        // ライフサイクル自動停止・復帰（要求 8.1/8.2、タスク3.5）
        // .inactive（通知シェード/コントロールセンター開等）では呼ばない —
        // 復帰時と違い暗転解除・監視再開の対象外（PR #5 レビュー指摘2）
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .background:
                sessionManager.handleDidEnterBackground()
            case .active:
                sessionManager.handleWillEnterForeground()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }

}

// MARK: - プレビュー

#Preview {
    RootView()
        .environmentObject(PostureSessionManager())
}
