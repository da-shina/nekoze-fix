import SwiftUI

/// UI レイヤー: 監視表示、デイムモード、閾値調整。
/// design.md の "UI Components" - MonitorView を参照。

struct MonitorView: View {
    // MARK: - 環境

    @EnvironmentObject private var sessionManager: PostureSessionManager
    @EnvironmentObject private var settingsStore: SettingsStore

    // MARK: - 本文

    var body: some View {
        ZStack {
            // 校正で確定した姿勢を薄いグレーで固定表示
            if let refPoints = sessionManager.snapshot.referencePoints {
                PostureOverlayView(
                    mode: .reference,
                    referenceAngle: sessionManager.snapshot.referenceAngle ?? 0.0,
                    currentPoints: refPoints,
                    nearSide: sessionManager.snapshot.nearSide,
                    imageAspectRatio: sessionManager.snapshot.videoAspectRatio,
                    videoOrientation: sessionManager.snapshot.videoOrientation
                )
                .ignoresSafeArea()
            }

            // 現在の姿勢をカラーで表示
            PostureOverlayView(
                mode: .current,
                referenceAngle: sessionManager.snapshot.referenceAngle ?? 0.0,
                currentPoints: sessionManager.snapshot.visualizationPoints,
                nearSide: sessionManager.snapshot.nearSide,
                imageAspectRatio: sessionManager.snapshot.videoAspectRatio,
                videoOrientation: sessionManager.snapshot.videoOrientation
            )
            .ignoresSafeArea()

            // メインコンテンツ
            VStack(spacing: 24) {
                // ステータス表示
                statusView

                Spacer()

                // 姿勢インジケーター
                postureIndicator

                Spacer()

                // 閾値スライダー
                thresholdSlider

                // コントロールボタン
                controlButtons
            }
            .padding()

            // デイムモードオーバーレイ
            if sessionManager.snapshot.isDimmed {
                dimModeOverlay
            }

        }
        .background(Color(.systemBackground))
    }

    // MARK: - サブビュー

    private var statusView: some View {
        HStack {
            Image(systemName: statusIcon)
                .foregroundColor(statusColor)
                .font(.title)

            Text(statusText)
                .font(.headline)
                .foregroundColor(statusColor)
        }
    }

    private var postureIndicator: some View {
        VStack(spacing: 16) {
            Image(systemName: postureIcon)
                .font(.system(size: 80))
                .foregroundColor(postureColor)
                .animation(.easeInOut, value: sessionManager.snapshot.displayedPosture)

            Text(postureText)
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(postureColor)
        }
    }

    private var thresholdSlider: some View {
        HStack(alignment: .top, spacing: 16) {
            // 角度閾値スライダー
            VStack(spacing: 8) {
                HStack {
                    Text("角度閾値")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Spacer()

                    Text(String(format: "%.1f°", settingsStore.slouchThresholdDegrees))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Slider(
                    value: $settingsStore.slouchThresholdDegrees,
                    in: SettingsStore.thresholdMinDegrees...SettingsStore.thresholdMaxDegrees,
                    step: 0.5
                )
            }

            // 距離閾値スライダー（前出し検出の第2指標・FQ3/FQ4）
            VStack(spacing: 8) {
                HStack {
                    Text("距離閾値")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Spacer()

                    Text(String(format: "%.1f%%", settingsStore.slouchDistanceThresholdPercent))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Slider(
                    value: $settingsStore.slouchDistanceThresholdPercent,
                    in: SettingsStore.distanceThresholdMinPercent...SettingsStore.distanceThresholdMaxPercent,
                    step: 0.5
                )
            }
        }
        .padding(.horizontal)
    }

    private var controlButtons: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                // 監視停止ボタン
                Button(action: { sessionManager.stopMonitoring() }) {
                    Label("停止", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .buttonStyle(.borderless)

                // デイムモードボタン
                Button(action: { sessionManager.snapshot.isDimmed ? sessionManager.exitDimMode() : sessionManager.enterDimMode() }) {
                    Label(sessionManager.snapshot.isDimmed ? "解除" : "暗転", systemImage: "moon.fill")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(sessionManager.snapshot.isDimmed ? Color.orange : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .buttonStyle(.borderless)
            }

            // カメラ切り替え設定
            HStack {
                Text("カメラ")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                Picker("カメラ位置", selection: $settingsStore.cameraPosition) {
                    Text("前面").tag(CameraPosition.front)
                    Text("背面").tag(CameraPosition.back)
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .disabled(sessionManager.snapshot.phase == .monitoring)
            }
            .padding(.horizontal)
        }
    }

    private var dimModeOverlay: some View {
        Color.black
            .ignoresSafeArea()
            .onTapGesture {
                sessionManager.exitDimMode()
            }
            .overlay(
                Text("タップして解除")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(8)
            )
            .opacity(0.8)
    }

    // MARK: - 計算プロパティ

    private var statusIcon: String {
        switch sessionManager.snapshot.phase {
        case .monitoring:
            return "antenna.radiowaves.left.and.right"
        case .rotating:
            return "arrow.triangle.2.circlepath"
        default:
            return "stop.circle"
        }
    }

    private var statusColor: Color {
        sessionManager.snapshot.phase == .monitoring ? .green : .orange
    }

    private var statusText: String {
        switch sessionManager.snapshot.phase {
        case .monitoring:
            return "監視中"
        case .rotating:
            return "回転中..."
        default:
            return "停止中"
        }
    }

    private var postureIcon: String {
        switch sessionManager.snapshot.displayedPosture {
        case .good:
            return "checkmark.circle.fill"
        case .slouch:
            return "exclamationmark.triangle.fill"
        case .personMissing:
            return "person.slash.fill"
        }
    }

    private var postureColor: Color {
        switch sessionManager.snapshot.displayedPosture {
        case .good:
            return .green
        case .slouch:
            return .orange
        case .personMissing:
            return .red
        }
    }

    private var postureText: String {
        switch sessionManager.snapshot.displayedPosture {
        case .good:
            return "良好"
        case .slouch:
            return "猫背を検出"
        case .personMissing:
            return "人を検出できません"
        }
    }

}

// MARK: - プレビュー

struct MonitorView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            MonitorView()
                .environmentObject(PostureSessionManager())
                .environmentObject(SettingsStore())
                .previewDisplayName("モニター - 良好")

            MonitorView()
                .environmentObject({
                    var snapshot = SessionSnapshot()
                    snapshot.displayedPosture = .slouch
                    return PostureSessionManager(snapshot: snapshot)
                }())
                .environmentObject(SettingsStore())
                .previewDisplayName("モニター - 猫背検出")
        }
    }
}
