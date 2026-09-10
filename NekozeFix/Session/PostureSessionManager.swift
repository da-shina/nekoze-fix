import SwiftUI
import Combine
import AVFoundation

/// セッション層: 姿勢監視セッションの状態マシン。
/// design.md "PostureSessionManager" セクション参照。

@MainActor
final class PostureSessionManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    // MARK: - 公開プロパティ

    @Published private(set) var snapshot: SessionSnapshot

    // MARK: - プライベートプロパティ

    private var cancellables = Set<AnyCancellable>()
    private let cameraManager = CameraSessionManager()
    private let poseDetector = PoseDetector()
    private let postureAnalyzer = PostureAnalyzer()
    private var calibrationLogic = CalibrationLogic()
    private let settingsStore = SettingsStore()

    // MARK: - 初期化

    /// デフォルトのスナップショットで初期化する
    override init() {
        self.snapshot = SessionSnapshot()
    }

    // MARK: - 公開メソッド

    /// セッションの初期化を行う
    func bootstrap() async {
        let auth = await cameraManager.requestAuthorization()
        switch auth {
        case .authorized:
            snapshot.phase = .calibrating
            await startCameraPipeline()
        case .denied:
            snapshot.phase = .permissionDenied
        case .notDetermined:
            snapshot.phase = .awaitingPermission
        }
    }

    /// キャリブレーションフェーズに遷移する
    func startCalibration() {
        snapshot.phase = .calibrating
        calibrationLogic.start()
        Task {
            await startCameraPipeline()
        }
    }

    /// アイドル状態から再キャリブレーションする
    func recalibrate() {
        snapshot.phase = .calibrating
        calibrationLogic.start()
        Task {
            await startCameraPipeline()
        }
    }

    /// 姿勢監視を開始する
    func startMonitoring() {
        snapshot.phase = .monitoring
        snapshot.isDimmed = false
        snapshot.isRotating = false
        // 監視開始時にゲートをリセットする
        snapshot.slouchGate.reset()
        Task {
            await startCameraPipeline()
        }
    }

    /// 姿勢監視を停止する
    func stopMonitoring() {
        snapshot.phase = .idle
        snapshot.isDimmed = false
        snapshot.isRotating = false
        cameraManager.stop()
    }

    /// ディムモードに入る（ブラックスクリーン＋ウェイクロック）
    func enterDimMode() {
        snapshot.isDimmed = true
    }

    /// ディムモードを終了する
    func exitDimMode() {
        snapshot.isDimmed = false
    }

    /// 感度設定を更新する
    func updateSensitivity(_ value: Double) {
        snapshot.sensitivity = max(0.0, min(1.0, value))
    }

    /// 表示される姿勢状態を更新する
    func updatePosture(_ posture: DisplayedPosture) {
        snapshot.displayedPosture = posture
    }

    /// 人検出状態を更新する
    func updatePersonDetected(_ detected: Bool) {
        snapshot.isPersonDetected = detected
    }

    /// フェーズを更新する（外部ステートマシン制御用）
    func updatePhase(_ phase: SessionPhase) {
        snapshot.phase = phase
    }

    /// 監視有効フラグを更新する
    func updateMonitoringEnabled(_ enabled: Bool) {
        snapshot.isMonitoringEnabled = enabled
    }

    // MARK: - プライベートメソッド

    private func startCameraPipeline() async {
        do {
            try await cameraManager.start()
            cameraManager.setSampleBufferDelegate(self)
        } catch {
            print("Camera pipeline start failed: \(error)")
            snapshot.phase = .permissionDenied
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // フレームの向きを取得
        let orientation = connection.videoOrientation == .portrait ? CGImagePropertyOrientation.up : CGImagePropertyOrientation.right

        // 1. ポーズ検出
        guard let frame = poseDetector.detect(sampleBuffer: sampleBuffer, orientation: orientation) else {
            Task { @MainActor in
                self.updateState(presence: .personMissing, sample: nil)
            }
            return
        }

        // 2. 姿勢分析
        // リファレンス角度と閾値はメインスレッドから取得するか、値として渡す必要がある
        Task { @MainActor in
            let refAngle = self.getReferenceAngle()
            let threshold = self.getThreshold()

            let (sample, verdict) = postureAnalyzer.analyze(
                frame: frame,
                referenceNearAngleDegrees: refAngle,
                slouchDeltaThresholdDegrees: threshold
            )

            // 3. 状態更新
            self.updateState(presence: .personDetected, sample: sample, verdict: verdict)
        }
    }

    private func updateState(presence: DetectionPresence, sample: AngleSample?, verdict: PostureVerdict? = nil) {
        // メインスレッドで動作することが保証されている
        self.snapshot.isPersonDetected = (presence == .personDetected)

        if self.snapshot.phase == .calibrating {
            // キャリブレーションロジックに投入
            let progress = self.calibrationLogic.ingest(
                sample: sample,
                presence: presence,
                now: CACurrentMediaTime()
            )
            self.snapshot.calibrationProgress = progress

            if case .completed(let refAngle) = progress {
                self.snapshot.phase = .monitoring
                // TODO: refAngle を保存する仕組みを実装
            }
        } else if self.snapshot.phase == .monitoring {
            // モニタリング中の判定
            if let sample = sample {
                self.snapshot.displayedPosture = (verdict == .slouchCandidate) ? .slouch : .good
            } else {
                self.snapshot.displayedPosture = .personMissing
            }
        }
    }

    private func getReferenceAngle() -> Double? {
        // 実際には calibrationLogic の完了後の平均値を保持して返す必要がある
        // 現在の簡易実装では 0.0 または最新の完了値を返す
        return 0.0 // TODO: キャリブレーション完了値を保持
    }

    private func getThreshold() -> Double {
        return 20.0 - (snapshot.sensitivity * 15.0)
    }

    private func verdictFor(sample: AngleSample) -> PostureVerdict {
        // ここで改めて判定ロジックを呼ぶか、analyzeの結果をそのまま使う
        // 実際には updateState 内で analyze した結果を使うように修正
        return .good
    }
}