import SwiftUI

/// UI レイヤー: 監視表示、デイムモード、閾値調整。
/// design.md の "UI Components" - MonitorView を参照。

struct MonitorView: View {
    // MARK: - 環境

    @EnvironmentObject private var sessionManager: PostureSessionManager
    @EnvironmentObject private var settingsStore: SettingsStore

    // MARK: - スライダー操作状態（閾値ガイド表示用）
    // Slider の onEditingChanged で直接追跡する。Timer による
    // 終了推測は不要（タップ・同値 set を含め編集状態が正確に取れる）。
    @State private var isDraggingAngleSlider: Bool = false
    @State private var isDraggingDistanceSlider: Bool = false

    // MARK: - ガイド付きオーバーレイの共通ビルダ（参照・現在の二重呼び出しを一本化）

    private func guideOverlay(mode: PostureOverlayView.Mode, points: [CGPoint], referencePointsForGuide: [CGPoint]) -> some View {
        PostureOverlayView(
            mode: mode,
            currentPoints: points,
            nearSide: sessionManager.snapshot.nearSide,
            imageAspectRatio: sessionManager.snapshot.videoAspectRatio,
            referenceVector: sessionManager.snapshot.referenceVector,
            showAngleGuide: isDraggingAngleSlider,
            angleThresholdDegrees: settingsStore.slouchThresholdDegrees,
            showDistanceGuide: isDraggingDistanceSlider,
            referenceDistance: sessionManager.snapshot.referenceDistance ?? 0,
            slouchDistanceThresholdPercent: settingsStore.slouchDistanceThresholdPercent,
            earShoulderVector: sessionManager.snapshot.earShoulderVector,
            referencePointsForGuide: referencePointsForGuide
        )
        .ignoresSafeArea()
    }

    // MARK: - 本文

    var body: some View {
        ZStack {
            // 校正で確定した姿勢を薄いグレーで固定表示（背面）
            if let refPoints = sessionManager.snapshot.referencePoints {
                guideOverlay(mode: .reference, points: refPoints, referencePointsForGuide: refPoints)
            }

            // 現在の姿勢をカラーで表示（背面）
            guideOverlay(
                mode: .current,
                points: sessionManager.snapshot.visualizationPoints,
                referencePointsForGuide: sessionManager.snapshot.referencePoints ?? []
            )

            // メインコンテンツ（最前面）
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

            // デイムモードオーバーレイ（最前面）
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

                    Text(String(format: "±%.1f°", settingsStore.slouchThresholdDegrees))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Slider(
                    value: $settingsStore.slouchThresholdDegrees,
                    in: SettingsStore.thresholdMinDegrees...SettingsStore.thresholdMaxDegrees,
                    step: 0.5,
                    onEditingChanged: { editing in isDraggingAngleSlider = editing }
                )
            }

            // 距離閾値スライダー（前出し検出の第2指標・FQ3/FQ4）
            VStack(spacing: 8) {
                HStack {
                    Text("距離閾値")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Spacer()

                    Text(String(format: "±%.1f%%", settingsStore.slouchDistanceThresholdPercent))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Slider(
                    value: $settingsStore.slouchDistanceThresholdPercent,
                    in: SettingsStore.distanceThresholdMinPercent...SettingsStore.distanceThresholdMaxPercent,
                    step: 0.5,
                    onEditingChanged: { editing in isDraggingDistanceSlider = editing }
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

            // カメラ切り替え設定（監視中は非表示）
            if sessionManager.snapshot.phase != .monitoring {
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
                }
                .padding(.horizontal)
            }
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

    // MARK: - 表示対応表(純粋関数。MonitorViewStyleTests が全分岐を固定)

    /// フェーズ→(アイコン,文言)。色は statusColor が担当する。
    static func statusContent(for phase: SessionPhase) -> (icon: String, text: String) {
        switch phase {
        case .monitoring:
            return ("antenna.radiowaves.left.and.right", "監視中")
        default:
            return ("stop.circle", "停止中")
        }
    }

    /// 姿勢→(アイコン,文言)。色は postureColor が担当する。
    static func postureContent(for posture: DisplayedPosture) -> (icon: String, text: String) {
        switch posture {
        case .good:
            return ("checkmark.circle.fill", "良好")
        case .slouch:
            return ("exclamationmark.triangle.fill", "猫背を検出")
        case .personMissing:
            return ("person.slash.fill", "人を検出できません")
        }
    }

    // MARK: - 計算プロパティ

    private var statusIcon: String {
        Self.statusContent(for: sessionManager.snapshot.phase).icon
    }

    private var statusColor: Color {
        sessionManager.snapshot.phase == .monitoring ? .green : .orange
    }

    private var statusText: String {
        Self.statusContent(for: sessionManager.snapshot.phase).text
    }

    private var postureIcon: String {
        Self.postureContent(for: sessionManager.snapshot.displayedPosture).icon
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
        Self.postureContent(for: sessionManager.snapshot.displayedPosture).text
    }

}

// MARK: - プレビュー

#Preview("モニター - 良好") {
    MonitorView()
        .environmentObject(PostureSessionManager())
        .environmentObject(SettingsStore())
}

#Preview("モニター - 猫背検出") {
    var snapshot = SessionSnapshot()
    snapshot.displayedPosture = .slouch
    return MonitorView()
        .environmentObject(PostureSessionManager(snapshot: snapshot))
        .environmentObject(SettingsStore())
}