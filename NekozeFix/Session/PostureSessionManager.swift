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
    let cameraManager = CameraSessionManager()
    private let poseDetector = PoseDetector()
    private let postureAnalyzer = PostureAnalyzer()
    private var calibrationLogic = CalibrationLogic()
    private let settingsStore: SettingsStore
    private let orientationMonitor = DeviceOrientationMonitor()

    // MARK: - 初期化

    private var guidelineTimer: Timer?

    init(settingsStore: SettingsStore = SettingsStore()) {
        self.settingsStore = settingsStore
        self.snapshot = SessionSnapshot()
        super.init()
        setupSettingsObservation()
        setupOrientationObservation()
    }

    private func setupSettingsObservation() {
        settingsStore.$cameraPosition
            .dropFirst() // 初期値での再起動を防ぐ
            .sink { [weak self] _ in
                guard let self = self else { return }
                if self.snapshot.phase == .monitoring || self.snapshot.phase == .calibrating {
                    Task {
                        await self.restartCameraPipeline()
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func setupOrientationObservation() {
        orientationMonitor.$currentVideoOrientation
            .sink { [weak self] orientation in
                print("PostureSessionManager: Updating orientation to \(orientation)")
                self?.cameraManager.updateVideoOrientation(orientation)
            }
            .store(in: &cancellables)
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

    private func restartCameraPipeline() async {
        cameraManager.stop()
        await startCameraPipeline()
    }

    private func startCameraPipeline() async {
        do {
            // デリゲートは start() より先に設定する。
            // 両メソッドは同一の sessionQueue に async 投入されるため、
            // configureSession が必ず非 nil のデリゲートを参照する順序が保証される。
            cameraManager.setSampleBufferDelegate(self)
            try await cameraManager.start(position: settingsStore.cameraPosition.avPosition)
        } catch {
            print("Camera pipeline start failed: \(error)")
            snapshot.phase = .permissionDenied
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // 1. カメラ位置に基づいた正確な画像向きの決定
        let videoOrientation = connection.videoOrientation

        Task { @MainActor in
            let isFrontCamera = self.settingsStore.cameraPosition == .front
            let orientation: CGImagePropertyOrientation

            // Visionの CGImagePropertyOrientation はセンサーの物理的な向きに基づいた指定が必要
            // 前面カメラと背面カメラでマッピングが異なる
            switch videoOrientation {
            case .portrait:
                orientation = isFrontCamera ? .left : .right
            case .portraitUpsideDown:
                orientation = isFrontCamera ? .right : .left
            case .landscapeLeft:
                orientation = isFrontCamera ? .up : .down
            case .landscapeRight:
                orientation = isFrontCamera ? .down : .up
            @unknown default:
                orientation = isFrontCamera ? .left : .right
            }

            // 2. ポーズ検出
            guard let frame = self.poseDetector.detect(sampleBuffer: sampleBuffer, orientation: orientation) else {
                self.updateState(presence: .personMissing, sample: nil)
                return
            }

            // 2. 姿勢分析
            let refAngle = self.getReferenceAngle()
            let threshold = self.getThreshold()

            let (sample, verdict) = self.postureAnalyzer.analyze(
                frame: frame,
                referenceNearAngleDegrees: refAngle,
                slouchDeltaThresholdDegrees: threshold,
                previousNearSide: self.snapshot.nearSide
            )

            // 可視化用ポイントの抽出 (固定インデックス: 0:左肩, 1:右肩, 2:左耳, 3:右耳, 4:近傍耳, 5:近傍肩)
            var points = [CGPoint](repeating: .zero, count: 6)

            // 1. 両肩の描画 (信頼度 0.3 以上で表示)
            if let ls = frame.leftShoulder, let rs = frame.rightShoulder {
                points[0] = CGPoint(x: ls.x, y: ls.y)
                points[1] = CGPoint(x: rs.x, y: rs.y)
            }

            // 2. 両耳の描画 (信頼度 0.3 以上で表示)
            if let le = frame.leftEar, let re = frame.rightEar {
                points[2] = CGPoint(x: le.x, y: le.y)
                points[3] = CGPoint(x: re.x, y: re.y)
            }

            // 3. 判定用ラインの描画 (近傍側を決定して描画)
            // まず、今回のフレームで判定された近傍側を優先し、なければ前回の状態を継承する
            let activeNearSide = sample?.nearSide ?? self.snapshot.nearSide

            if let side = activeNearSide {
                let ear = (side == .left) ? frame.leftEar : frame.rightEar
                let shoulder = (side == .left) ? frame.leftShoulder : frame.rightShoulder
                if let e = ear, let s = shoulder {
                    points[4] = CGPoint(x: e.x, y: e.y)
                    points[5] = CGPoint(x: s.x, y: s.y)
                }
            }

            // snapshot の nearSide を更新 (判定が成功したときのみ更新して安定させる)
            if let side = sample?.nearSide {
                self.snapshot.nearSide = side
            }

            // 3. 状態更新
            self.updateState(presence: .personDetected, sample: sample, verdict: verdict, points: points)
        }
    }

    private func updateState(presence: DetectionPresence, sample: AngleSample?, verdict: PostureVerdict? = nil, points: [CGPoint] = []) {
        // メインスレッドで動作することが保証されている
        self.snapshot.isPersonDetected = (presence == .personDetected)
        self.snapshot.visualizationPoints = points

        if self.snapshot.phase == .calibrating {
            // キャリブレーションロジックに投入 (可視化ポイントも渡す)
            let progress = self.calibrationLogic.ingest(
                sample: sample,
                presence: presence,
                now: CACurrentMediaTime(),
                points: points
            )
            self.snapshot.calibrationProgress = progress

            if case .completed(let average, let refPoints) = progress {
                self.snapshot.phase = .monitoring
                self.snapshot.referenceAngle = average
                self.snapshot.referencePoints = refPoints
            }
        } else if self.snapshot.phase == .monitoring {
            // モニタリング中の判定
            if sample != nil {
                self.snapshot.displayedPosture = (verdict == .slouchCandidate) ? .slouch : .good
            } else {
                self.snapshot.displayedPosture = .personMissing
            }
        }
    }

    private func getReferenceAngle() -> Double? {
        snapshot.referenceAngle
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
