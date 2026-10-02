import SwiftUI

/// UI レイヤー: カメラ許可プロンプトと設定ガイダンスUI。
/// design.md の "UI Components" - PermissionView を参照。

struct PermissionView: View {
    // MARK: - 環境

    @EnvironmentObject private var sessionManager: PostureSessionManager

    // カラーパレット
    private let mainBackground = Color(red: 167/255, green: 157/255, blue: 179/255)
    private let accent = Color(red: 131/255, green: 93/255, blue: 179/255)
    private let textPrimary = Color.white
    private let textSecondary = Color(red: 224/255, green: 224/255, blue: 224/255)
    private let logoBackground = Color.white

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
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(logoBackground)
                            .frame(width: 88, height: 88)
                    )

                Text("NekozeFix")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(textPrimary)

                Text("姿勢を守る、猫背フィックス")
                    .font(.subheadline)
                    .foregroundColor(textSecondary)
            }
            .padding(.top, 48)

            Spacer()

            // 許可状態に応じたコンテンツ
            switch sessionManager.snapshot.phase {
            case .permissionDenied:
                deniedContent
            case .idle:
                // 監視停止後（idle）: 権限は既にあるため再校正の入口のみ提示
                Button(action: { sessionManager.startCalibration() }) {
                    Label("キャリブレーションを開始", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(accent)
            default:
                requestingContent
            }

            Spacer()
        }
        .padding(24)
        .background(mainBackground)
    }

    // MARK: - サブビュー

    private var requestingContent: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(accent)

            Text("カメラへのアクセスを許可してください")
                .font(.headline)
                .foregroundColor(textPrimary)
                .multilineTextAlignment(.center)

            Text("フロントカメラで姿勢を検出し、猫背を検知します")
                .font(.subheadline)
                .foregroundColor(textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var deniedContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.slash.fill")
                .font(.system(size: 48))
                .foregroundColor(textPrimary)

            Text("カメラの使用が許可されていません")
                .font(.headline)
                .foregroundColor(textPrimary)
                .multilineTextAlignment(.center)

            Text("設定アプリで「カメラ」をオンにしてから、下のボタンで再試行してください")
                .font(.subheadline)
                .foregroundColor(textSecondary)
                .multilineTextAlignment(.center)

            Button(action: openSettings) {
                Label("設定を開く", systemImage: "gear")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(accent)

            Button(action: bootstrap) {
                Text("再試行")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(textPrimary)
        }
    }

    // MARK: - アクション

    private func bootstrap() {
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

#Preview("許可プロンプト") {
    PermissionView()
        .environmentObject(PostureSessionManager())
}

#Preview("拒否済み") {
    var snapshot = SessionSnapshot()
    snapshot.phase = .permissionDenied
    return PermissionView()
        .environmentObject(PostureSessionManager(snapshot: snapshot))
}