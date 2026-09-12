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
                Image("AppIconImage")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                Text("NekozeFix")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("姿勢を守る、猫背フィックス")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 48)

            Spacer()

            // 許可状態に応じたコンテンツ
            switch sessionManager.snapshot.phase {
            case .permissionDenied:
                deniedContent
            case .idle:
                // 監視停止後（idle）: 権限は既にあるため再校正の入口のみ提示
                Button(action: startCalibration) {
                    Label("キャリブレーションを開始", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            default:
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

    private func startCalibration() {
        // bootstrap() が認証確認 → .calibrating 遷移とカメラ起動を行う
        Task {
            await sessionManager.bootstrap()
        }
    }

    private func requestAuthorization() {
        // bootstrap() が CameraSessionManager 経由で認証を再リクエストし、
        // 設定で許可された場合もそのまま校正へ遷移する
        Task {
            await sessionManager.bootstrap()
        }
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