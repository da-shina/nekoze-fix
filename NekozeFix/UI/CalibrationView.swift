import SwiftUI
import Combine
import AVFoundation

/// UI レイヤー: 校正ガイド、集約タイマー、人検出メッセージ。
/// design.md の "UI Components" - CalibrationView を参照。

struct CalibrationView: View {
    // MARK: - 環境

    @EnvironmentObject private var sessionManager: PostureSessionManager
    @EnvironmentObject private var settingsStore: SettingsStore

    // MARK: - 状態

    @State private var timerRemaining = CalibrationLogic.requiredStableDuration
    @State private var isPersonDetected = false
    @State private var isShoulderMissing = false
    @State private var showingPersonMissing = false
    @State private var progressMessage = "5秒間姿勢を保持してください"
    @State private var cancellables = Set<AnyCancellable>()

    // MARK: - 本文

    var body: some View {
        ZStack {
            // 背景にカメラプレビューを表示
            CameraPreviewView(session: sessionManager.cameraManager.captureSession)
                .ignoresSafeArea()

            // 基準線とポイントの可視化
            PostureOverlayView(
                mode: .current,
                referenceAngle: sessionManager.snapshot.referenceAngle ?? 0.0,
                currentPoints: sessionManager.snapshot.visualizationPoints,
                threshold: settingsStore.slouchThresholdDegrees,
                nearSide: sessionManager.snapshot.nearSide,
                imageAspectRatio: sessionManager.snapshot.videoAspectRatio
            )
            .ignoresSafeArea()

            VStack(spacing: 32) {
                // タイマー表示
                Text("\(Int(timerRemaining))秒")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                    .shadow(radius: 4)

                // DEBUG 距離計測（前出し検出の閾値設計用。未校正時は基準比なし）
                if let t = sessionManager.snapshot.debugDistanceText {
                    Text(t)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.yellow)
                        .shadow(radius: 2)
                }

                Spacer()

                // 肩が映っていない場合の運用ガイド（顔のみ検出状態）
                if isPersonDetected && isShoulderMissing {
                    Label("肩が認識できません。端末を少し離して肩まで画面に収めてください", systemImage: "camera.metering.center.weighted")
                        .font(.subheadline)
                        .foregroundColor(.orange)
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                }

                // カメラ操作カード（ステータス・進捗メッセージ・カメラ切替を統合）
                VStack(spacing: 16) {
                    // ステータス表示
                    HStack {
                        Image(systemName: isPersonDetected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(isPersonDetected ? .green : .red)

                        Text(isPersonDetected ? "検出中" : "人を検出できません")
                            .font(.headline)
                            .foregroundColor(isPersonDetected ? .green : .red)

                        Spacer()

                        Text(progressMessage)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.trailing)
                    }

                    Divider()

                    // カメラ切り替え
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
                }
                .padding()
                .background(.ultraThinMaterial)
                .cornerRadius(16)
            }
            .padding()
        }
        .navigationBarTitle("校正", displayMode: .inline)
        .onAppear {
            setupObservers()
            if sessionManager.snapshot.phase == .calibrating {
                Task {
                    sessionManager.startCalibration()
                }
            }
        }
        .onDisappear {
            // Timer removed
        }
    }

    // MARK: - プライベートメソッド

    private func setupObservers() {
        // snapshot 全体を監視して、人物検出と進捗を更新
        sessionManager.$snapshot
            .sink { [self] snapshot in
                // 1. 人物検出状態の更新
                let detected = snapshot.isPersonDetected
                self.isPersonDetected = detected
                self.isShoulderMissing = snapshot.isShoulderMissing
                self.showingPersonMissing = !detected
                self.progressMessage = detected ? "姿勢を保持中..." : "姿勢を保持してください"

                // 2. キャリブレーション進捗の更新
                switch snapshot.calibrationProgress {
                case .waitingForPerson:
                    self.timerRemaining = CalibrationLogic.requiredStableDuration
                case .accumulating(let elapsed):
                    // 必要安定時間から経過時間を引いた残時間を表示
                    self.timerRemaining = max(0, CalibrationLogic.requiredStableDuration - elapsed)
                case .completed:
                    self.timerRemaining = 0
                }
            }
            .store(in: &cancellables)
    }
}

// MARK: - プレビュー

struct CalibrationView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            CalibrationView()
                .environmentObject(PostureSessionManager())
                .environmentObject(SettingsStore())
                .previewDisplayName("校正 - 準備完了")
        }
    }
}
