import SwiftUI

/// UI レイヤー: カメラ許可プロンプトと設定ガイダンスUI。
/// design.md の "UI Components" - PermissionView を参照。

struct PermissionView: View {
    // MARK: - 環境

    @EnvironmentObject private var sessionManager: PostureSessionManager

    // MARK: - 本文

    var body: some View {
        VStack(spacing: 24) {
            // アプリアイコン/タイトルエリア
            VStack(spacing: 12) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.accentColor)

                Text("NekozeFix")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("姿勢を守る、ねこぜフィックス")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 48)

            Spacer()

            // 許可状態に応じたコンテンツ
            if sessionManager.snapshot.phase == .permissionDenied {
                deniedContent
            } else {
                requestingContent
            }

            Spacer()
        }
        .padding(24)
        .background(Color(.systemBackground))
    }

    // MARK: - サブビュー

    private var requestingContent: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)

            Text("カメラへのアクセスを許可してください")
                .font(.headline)
                .multilineTextAlignment(.center)

            Text("フロントカメラで姿勢を検出し、猫背を検知します")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var deniedContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.slash.fill")
                .font(.system(size: 48))
                .foregroundColor(.red)

            Text("カメラの使用が許可されていません")
                .font(.headline)
                .multilineTextAlignment(.center)

            Text("設定アプリで「カメラ」をオンにしてから、下のボタンで再試行してください")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button(action: openSettings) {
                Label("設定を開く", systemImage: "gear")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button(action: requestAuthorization) {
                Text("再試行")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    // MARK: - アクション

    private func requestAuthorization() {
        // CameraSessionManager が実際の認証リクエストを処理
        // RootView が再度 bootstrap() を呼び出す
        sessionManager.updatePhase(.awaitingPermission)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - プレビュー

struct PermissionView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            PermissionView()
                .environmentObject(PostureSessionManager())

            PermissionView()
                .environmentObject({
                    let manager = PostureSessionManager()
                    manager.updatePhase(.permissionDenied)
                    return manager
                }())
                .previewDisplayName("拒否済み")
        }
    }
}