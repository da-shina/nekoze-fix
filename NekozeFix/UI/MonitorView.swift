import SwiftUI

/// UI レイヤー: 監視表示、デイムモード、閾値調整。
/// design.md の "UI Components" - MonitorView を参照。

struct MonitorView: View {
    // MARK: - 環境

    @EnvironmentObject private var sessionManager: PostureSessionManager
    @EnvironmentObject private var settingsStore: SettingsStore

    // MARK: - スライダー操作状態（閾値ガイド表示用）

    @State private var isDraggingAngleSlider: Bool = false
    @State private var isDraggingDistanceSlider: Bool = false

    // MARK: - スライダー値変更検知用のカスタムバインディング

    private var angleThresholdBinding: Binding<Double> {
        Binding(
            get: { settingsStore.slouchThresholdDegrees },
            set: { newValue in
                isDraggingAngleSlider = true
                settingsStore.slouchThresholdDegrees = newValue
            }
        )
    }

    private var distanceThresholdBinding: Binding<Double> {
        Binding(
            get: { settingsStore.slouchDistanceThresholdPercent },
            set: { newValue in
                isDraggingDistanceSlider = true
                settingsStore.slouchDistanceThresholdPercent = newValue
            }
        )
    }

    // ドラッグ終了検知用（値変更が一定時間止まったら終了とみなす）
    @State private var angleDragTimer: Timer?
    @State private var distanceDragTimer: Timer?

    private func onAngleValueChange(_ newValue: Double) {
        angleDragTimer?.invalidate()
        angleDragTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { _ in
            DispatchQueue.main.async {
                self.isDraggingAngleSlider = false
            }
        }
    }

    private func onDistanceValueChange(_ newValue: Double) {
        distanceDragTimer?.invalidate()
        distanceDragTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { _ in
            DispatchQueue.main.async {
                self.isDraggingDistanceSlider = false
            }
        }
    }

    // MARK: - ガイド表示パラメータ（両オーバーレイ共通）

    private var guideParams: (showAngleGuide: Bool, angleThresholdDegrees: Double, showDistanceGuide: Bool, referenceDistance: Double, slouchDistanceThresholdPercent: Double, earShoulderVector: CGVector) {
        (isDraggingAngleSlider,
         settingsStore.slouchThresholdDegrees,
         isDraggingDistanceSlider,
         sessionManager.snapshot.referenceDistance ?? 0,
         settingsStore.slouchDistanceThresholdPercent,
         sessionManager.snapshot.earShoulderVector)
    }

    // MARK: - 本文

    var body: some View {
        ZStack {
            // 校正で確定した姿勢を薄いグレーで固定表示（背面）
            if let refPoints = sessionManager.snapshot.referencePoints {
                PostureOverlayView(
                    mode: .reference,
                    currentPoints: refPoints,
                    nearSide: sessionManager.snapshot.nearSide,
                    imageAspectRatio: sessionManager.snapshot.videoAspectRatio,
                    referenceVector: sessionManager.snapshot.referenceVector,
                    showAngleGuide: guideParams.showAngleGuide,
                    angleThresholdDegrees: guideParams.angleThresholdDegrees,
                    showDistanceGuide: guideParams.showDistanceGuide,
                    referenceDistance: guideParams.referenceDistance,
                    slouchDistanceThresholdPercent: guideParams.slouchDistanceThresholdPercent,
                    earShoulderVector: guideParams.earShoulderVector,
                    referencePointsForGuide: refPoints
                )
                .ignoresSafeArea()
            }

            // 現在の姿勢をカラーで表示（背面）
            PostureOverlayView(
                mode: .current,
                currentPoints: sessionManager.snapshot.visualizationPoints,
                nearSide: sessionManager.snapshot.nearSide,
                imageAspectRatio: sessionManager.snapshot.videoAspectRatio,
                referenceVector: sessionManager.snapshot.referenceVector,
                showAngleGuide: guideParams.showAngleGuide,
                angleThresholdDegrees: guideParams.angleThresholdDegrees,
                showDistanceGuide: guideParams.showDistanceGuide,
                referenceDistance: guideParams.referenceDistance,
                slouchDistanceThresholdPercent: guideParams.slouchDistanceThresholdPercent,
                earShoulderVector: guideParams.earShoulderVector,
                referencePointsForGuide: sessionManager.snapshot.referencePoints ?? []
            )
            .ignoresSafeArea()

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
                    value: angleThresholdBinding,
                    in: SettingsStore.thresholdMinDegrees...SettingsStore.thresholdMaxDegrees,
                    step: 0.5
                )
                .onChange(of: settingsStore.slouchThresholdDegrees) { _, newValue in
                    onAngleValueChange(newValue)
                }
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
                    value: distanceThresholdBinding,
                    in: SettingsStore.distanceThresholdMinPercent...SettingsStore.distanceThresholdMaxPercent,
                    step: 0.5
                )
                .onChange(of: settingsStore.slouchDistanceThresholdPercent) { _, newValue in
                    onDistanceValueChange(newValue)
                }
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

    // MARK: - 計算プロパティ

    private var statusIcon: String {
        switch sessionManager.snapshot.phase {
        case .monitoring:
            return "antenna.radiowaves.left.and.right"
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