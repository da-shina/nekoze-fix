import SwiftUI
import AVFoundation

/// UI レイヤー: 校正ガイド、集約タイマー、人検出メッセージ。
/// design.md の "UI Components" - CalibrationView を参照。

struct CalibrationView: View {
    // MARK: - 環境

    @EnvironmentObject private var sessionManager: PostureSessionManager
    @EnvironmentObject private var settingsStore: SettingsStore

    // MARK: - 本文

    var body: some View {
        ZStack {
            // 背景にカメラプレビューを表示（4.1 実結線）。
            // プレビュー層は Session が生成した同一インスタンスを注入し（所有権は Session）、
            // preview 角は Session と同一の Service インスタンスから購読する。
            // 層出現時はペイロードなしで Session へ通知し、Session が所有層で recreate する。
            CameraPreviewView(
                session: sessionManager.cameraManager.captureSession,
                injectedPreviewLayer: sessionManager.ensureOwnedPreviewLayer(),
                rotationSource: sessionManager.rotationService,
                onPreviewLayerAppeared: {
                    Task { @MainActor in
                        sessionManager.handlePreviewLayerAppeared()
                    }
                }
            )
            .ignoresSafeArea()

            // 現在の姿勢のオーバーレイ
            PostureOverlayView(
                mode: .current,
                currentPoints: sessionManager.snapshot.visualizationPoints,
                nearSide: sessionManager.snapshot.nearSide,
                imageAspectRatio: sessionManager.snapshot.videoAspectRatio,
                referenceVector: sessionManager.snapshot.referenceVector
            )
            .ignoresSafeArea()

            VStack(spacing: 32) {
                // タイマー表示
                Text("\(Int(timerRemaining))秒")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                    .shadow(radius: 4)

                Spacer()

                // カメラ操作カード（ステータス・進捗メッセージ・カメラ切替を統合）
                VStack(spacing: 16) {
                    // ステータス表示
                    HStack {
                        Image(systemName: isPersonDetected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(isPersonDetected ? .green : .red)

                        Text(isPersonDetected ? "人を検出中" : "人を検出できません")
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
                .background(Color.black.opacity(0.25))
                .cornerRadius(16)
            }
            .padding()
        }
        .navigationBarTitle("校正", displayMode: .inline)
        .onAppear {
            if sessionManager.snapshot.phase == .calibrating {
                Task {
                    sessionManager.startCalibration()
                }
            }
        }
    }

    // MARK: - 計算プロパティ

    private var isPersonDetected: Bool {
        sessionManager.snapshot.isPersonDetected
    }

    private var progressMessage: String {
        let snapshot = sessionManager.snapshot
        let pts = snapshot.visualizationPoints
        if !snapshot.isPersonDetected {
            return "人物が検出されません"
        } else if snapshot.isShoulderMissing {
            return shoulderMissingGuidance(isLandscape: snapshot.isLandscape)
        } else if pts.count >= 4 && pts[2] == .zero && pts[3] == .zero {
            return "耳を認識できません。顔全体を画面に収めてください"
        } else {
            return ""
        }
    }

    private var timerRemaining: TimeInterval {
        switch sessionManager.snapshot.calibrationProgress {
        case .waitingForPerson:
            return CalibrationLogic.requiredStableDuration
        case .accumulating(let elapsed):
            return max(0, CalibrationLogic.requiredStableDuration - elapsed)
        case .completed:
            return 0
        }
    }
}

// MARK: - プレビュー

#Preview("校正 - 準備完了") {
    CalibrationView()
        .environmentObject(PostureSessionManager())
        .environmentObject(SettingsStore())
}
