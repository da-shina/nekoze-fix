import SwiftUI

/// UI レイヤー: 姿勢監視メイン画面。
/// design.md "MonitorView" セクションおよび要件 3.1-3.4, 4.4, 6.1-6.3 参照。
struct MonitorView: View {
    // MARK: - 環境
    @EnvironmentObject private var sessionManager: PostureSessionManager

    // MARK: - 本文
    var body: some View {
        ZStack {
            // 1. ベースレイヤー: カメラプレビューとステータス表示
            VStack(spacing: 20) {
                // 姿勢状態表示
                statusDisplay
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(statusColor.opacity(0.2))
                    .cornerRadius(12)
                    .padding(.horizontal)

                // カメラプレビュー（暗転時は非表示）
                if !snapshot.isDimmed {
                    CameraPreviewView(session: sessionManager.cameraManager.captureSession)
                        .cornerRadius(16)
                        .padding(.horizontal)
                        .aspectRatio(snapshot.videoAspectRatio, contentMode: .fit)
                } else {
                    // プレビュー非表示時のスペース確保
                    Color.clear
                        .aspectRatio(snapshot.videoAspectRatio, contentMode: .fit)
                        .padding(.horizontal)
                }

                // コントロールパネル
                controlsPanel
            }
            .padding(.vertical)

            // 2. オーバーレイレイヤー: 画面暗転モード
            if snapshot.isDimmed {
                Color.black
                    .ignoresSafeArea()
                    .onTapGesture {
                        sessionManager.exitDimMode()
                    }
            }
        }
    }

    // MARK: - サブビュー

    /// 現在の姿勢状態を表示するビュー
    private var statusDisplay: some View {
        Text(statusText)
            .foregroundColor(statusColor)
    }

    /// 監視開始・停止、閾値調整、暗転操作を行うパネル
    private var controlsPanel: some View {
        VStack(spacing: 24) {
            // 監視コントロール
            HStack(spacing: 20) {
                if !snapshot.isMonitoringEnabled {
                    Button(action: { sessionManager.startMonitoring() }) {
                        Label("監視開始", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button(action: { sessionManager.stopMonitoring() }) {
                        Label("監視停止", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .foregroundColor(.red)
                }
            }
            .padding(.horizontal)

            // 閾値調整スライダー (横並び)
            VStack(spacing: 16) {
                HStack {
                    thresholdSlider(
                        label: "角度閾値",
                        value: $sessionManager.settingsStore.slouchThresholdDegrees,
                        range: SettingsStore.thresholdMinDegrees...SettingsStore.thresholdMaxDegrees,
                        step: 0.5,
                        unit: "°"
                    )
                    Divider().frame(height: 40)
                    thresholdSlider(
                        label: "距離閾値",
                        value: $sessionManager.settingsStore.slouchDistanceThresholdPercent,
                        range: SettingsStore.distanceThresholdMinPercent...SettingsStore.distanceThresholdMaxPercent,
                        step: 0.5,
                        unit: "%"
                    )
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal)
            }

            // 暗転モード切り替え
            if snapshot.isMonitoringEnabled {
                Button(action: {
                    if snapshot.isDimmed {
                        sessionManager.exitDimMode()
                    } else {
                        sessionManager.enterDimMode()
                    }
                }) {
                    Label(snapshot.isDimmed ? "暗転解除" : "画面暗転", systemImage: snapshot.isDimmed ? "sun.max.fill" : "moon.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal)
            }
        }
        .padding()
    }

    /// 汎用スライダーコンポーネント
    private func thresholdSlider<V: BinaryFloatingPoint>(
        label: String,
        value: Binding<V>,
        range: ClosedRange<V>,
        step: V,
        unit: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(String(format: "%.1f", Double(truncatingIfNeeded: value.wrappedValue)))\(unit)")
                    .font(.system(.caption, design: .monospaced))
                    .bold()
            }
            Slider(value: value, in: range, step: step)
        }
    }

    // MARK: - 計算プロパティ

    private var snapshot: SessionSnapshot {
        sessionManager.snapshot
    }

    private var statusText: String {
        switch snapshot.displayedPosture {
        case .good: return "良好"
        case .slouch: return "猫背"
        case .personMissing: return "人物が検出されていません"
        }
    }

    private var statusColor: Color {
        switch snapshot.displayedPosture {
        case .good: return .green
        case .slouch: return .red
        case .personMissing: return .orange
        }
    }
}

// MARK: - プレビュー
struct MonitorView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            // 良好状態
            MonitorView()
                .environmentObject(PostureSessionManager(snapshot: SessionSnapshot(phase: .monitoring, displayedPosture: .good, isMonitoringEnabled: true)))
                .previewDisplayName("良好")

            // 猫背状態
            MonitorView()
                .environmentObject(PostureSessionManager(snapshot: SessionSnapshot(phase: .monitoring, displayedPosture: .slouch, isMonitoringEnabled: true)))
                .previewDisplayName("猫背")

            // 人物なし状態
            MonitorView()
                .environmentObject(PostureSessionManager(snapshot: SessionSnapshot(phase: .monitoring, displayedPosture: .personMissing, isMonitoringEnabled: true)))
                .previewDisplayName("人物なし")

            // 暗転状態
            MonitorView()
                .environmentObject(PostureSessionManager(snapshot: SessionSnapshot(phase: .monitoring, displayedPosture: .good, isDimmed: true, isMonitoringEnabled: true)))
                .previewDisplayName("暗転")
        }
    }
}
