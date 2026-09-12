import SwiftUI
import UIKit

/// UI レイヤー: 監視表示、デイムモード、感度調整。
/// design.md の "UI Components" - MonitorView を参照。

struct MonitorView: View {
    // MARK: - 環境

    @EnvironmentObject private var sessionManager: PostureSessionManager
    @EnvironmentObject private var settingsStore: SettingsStore

    // MARK: - 状態

    @State private var originalBrightness: CGFloat = UIScreen.main.brightness

    // MARK: - 本文

    var body: some View {
        ZStack {
            // 背景にカメラプレビューを表示
            CameraPreviewView(session: sessionManager.cameraManager.captureSession)
                .ignoresSafeArea()

            // 姿勢ポイントの可視化
            PostureOverlayView(
                referenceAngle: sessionManager.snapshot.referenceAngle ?? 0.0,
                currentPoints: sessionManager.snapshot.visualizationPoints,
                threshold: sessionManager.snapshot.currentThreshold,
                nearSide: sessionManager.snapshot.nearSide
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

                // 感度スライダー
                sensitivitySlider

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

    private var sensitivitySlider: some View {
        VStack(spacing: 8) {
            HStack {
                Text("感度")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                Text("\(Int(settingsStore.sensitivity * 100))%")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Slider(
                value: $settingsStore.sensitivity,
                in: 0...1,
                step: 0.01
            ) { _ in
                sessionManager.updateSensitivity(settingsStore.sensitivity)
            }
        }
        .padding(.horizontal)
    }

    private var controlButtons: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                // 監視停止ボタン
                Button(action: stopMonitoring) {
                    Label("停止", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .buttonStyle(.borderless)

                // デイムモードボタン
                Button(action: toggleDimMode) {
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
            }
            .padding(.horizontal)
        }
    }

    private var dimModeOverlay: some View {
        Color.black
            .ignoresSafeArea()
            .onTapGesture {
                exitDimMode()
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

    // MARK: - アクション

    private func stopMonitoring() {
        sessionManager.stopMonitoring()
    }

    private func toggleDimMode() {
        if sessionManager.snapshot.isDimmed {
            exitDimMode()
        } else {
            enterDimMode()
        }
    }

    private func enterDimMode() {
        originalBrightness = UIScreen.main.brightness
        UIScreen.main.brightness = 0.0
        UIApplication.shared.isIdleTimerDisabled = true
        sessionManager.enterDimMode()
    }

    private func exitDimMode() {
        UIScreen.main.brightness = originalBrightness
        UIApplication.shared.isIdleTimerDisabled = false
        sessionManager.exitDimMode()
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
                    let manager = PostureSessionManager()
                    manager.updatePosture(.slouch)
                    return manager
                }())
                .environmentObject(SettingsStore())
                .previewDisplayName("モニター - 猫背検出")
        }
    }
}