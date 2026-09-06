import SwiftUI

/// UI layer: camera permission prompt and settings guidance UI.
/// See design.md "UI Components" - PermissionView.

struct PermissionView: View {
    // MARK: - Environment

    @EnvironmentObject private var sessionManager: PostureSessionManager

    // MARK: - Body

    var body: some View {
        VStack(spacing: 24) {
            // App icon/title area
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

            // Permission state content
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

    // MARK: - Subviews

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

    // MARK: - Actions

    private func requestAuthorization() {
        // CameraSessionManager handles actual authorization request
        // RootView will call bootstrap() again
        sessionManager.updatePhase(.awaitingPermission)
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - Preview

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
                .previewDisplayName("Denied")
        }
    }
}