import SwiftUI

/// UI レイヤー: permission/calibration/monitor フェーズを切り替えるルートビュー。
/// design.md の "UI Components" - RootView を参照。

struct RootView: View {
    // MARK: - 環境

    @EnvironmentObject private var sessionManager: PostureSessionManager

    // MARK: - 本文

    var body: some View {
        Group {
            switch snapshot.phase {
            case .awaitingPermission:
                PermissionView()
            case .calibrating:
                CalibrationView()
            case .monitoring:
                MonitorView()
            case .idle:
                PermissionView()
            case .rotating:
                MonitorView()
            @unknown default:
                PermissionView()
            }
        }
        .onAppear {
            Task {
                await sessionManager.bootstrap()
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
