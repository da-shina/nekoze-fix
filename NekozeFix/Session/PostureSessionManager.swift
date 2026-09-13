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

    // 通知音（design.md "AlertPlayer" Q17/Q23: 確定猫背で即再生 + 30秒間隔で繰り返し）
    private lazy var alertPlayer: AlertPlayer? = {
        guard let url = Bundle.main.url(forResource: "usagi-to-kame", withExtension: "caf") else {
            print("AlertPlayer: usagi-to-kame.caf が見つかりません")
            return nil
        }
        let player = AlertPlayer(soundURL: url)
        do {
            try player.configureSession()
        } catch {
            print("AlertPlayer: セッション構成に失敗 \(error)")
            return nil
        }
        return player
    }()
    // slouchGate の deltaTime 算出用（メインアクタからのみアクセス）
    private var lastGateTickTime: TimeInterval?
    /// DEBUG 距離計測: 直近の (時刻, 基準比%) サンプル窓。1秒中央値算出用。閾値設計後の削除対象。
    private var distanceRatioWindow: [(time: TimeInterval, pct: Double)] = []

    // MARK: - 初期化

    private var guidelineTimer: Timer?

    /// personMissing 確定までの猶予時間（秒）。この未満の連続欠測はノイズ扱い。
    static let personMissingGracePeriod: TimeInterval = 0.5
    /// 最後に人物を検出した時刻（nil は未検出継続中）
    private var lastPersonSeenTime: TimeInterval?

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
        lastGateTickTime = nil
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
        // 監視停止時は通知音も即停止（design.md Q20）
        alertPlayer?.stop()
    }

    /// ディムモードに入る（ブラックスクリーン＋ウェイクロック）
    func enterDimMode() {
        snapshot.isDimmed = true
    }

    /// ディムモードを終了する
    func exitDimMode() {
        snapshot.isDimmed = false
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
        // バッファ実寸から画像アスペクト比を算出（可視化のクロップ補正に使用）
        let imageAR: CGFloat
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            imageAR = CGFloat(CVPixelBufferGetWidth(pb)) / CGFloat(CVPixelBufferGetHeight(pb))
        } else {
            imageAR = 4.0 / 3.0
        }

        // iPadOS 18 以降、videoDataOutput のバッファはインターフェース向きに
        // 自動回転して配信される（connection.videoOrientation は参考値にすぎない）。
        // したがって Vision には常に .up を渡す。
        //
        // ポーズ検出はキャプチャキュー（sessionQueue）上で同期的に実行する。
        // メインスレッドで呼ぶと Vision 完了までの間 UI が固まり、
        // タップ応答の遅延・取りこぼしを引き起こす。
        // 検出中のフレームは alwaysDiscardsLateVideoFrames が自動で間引く。
        let detection = poseDetector.detect(sampleBuffer: sampleBuffer, orientation: .up)

        Task { @MainActor in
            self.snapshot.videoAspectRatio = imageAR

            // 人物なし（Body Pose 観測空 かつ 顔なし）
            if case .absent = detection {
                self.snapshot.isShoulderMissing = false
                self.updateState(presence: .personMissing, sample: nil)
                return
            }

            // 顔のみの検出: 人物はいるが角度は計算できない。
            // 「肩が映っていません」案内を灯す（復帰は pose 検出フレームで消える）。
            guard case .pose(let frame) = detection else {
                self.snapshot.isShoulderMissing = true
                self.updateState(presence: .personDetected, sample: nil)
                return
            }
            self.snapshot.isShoulderMissing = false

            // 2. 姿勢分析
            let refAngle = self.getReferenceAngle()
            let threshold = self.settingsStore.slouchThresholdDegrees

            let (sample, verdict) = self.postureAnalyzer.analyze(
                frame: frame,
                referenceNearAngleDegrees: refAngle,
                slouchDeltaThresholdDegrees: threshold,
                previousNearSide: self.snapshot.nearSide
            )

            // 可視化用ポイントの抽出 (固定インデックス: 0:左肩, 1:右肩, 2:左耳, 3:右耳, 4:近傍耳, 5:近傍肩)
            var points = [CGPoint](repeating: .zero, count: 6)

            // 1. 肩の描画 (側ごとに信頼度 0.3 以上で表示。片側欠測でももう片側は出す)
            if let ls = frame.leftShoulder {
                points[0] = CGPoint(x: ls.x, y: ls.y)
            }
            if let rs = frame.rightShoulder {
                points[1] = CGPoint(x: rs.x, y: rs.y)
            }

            // 2. 耳の描画 (側ごとに信頼度 0.3 以上で表示)
            if let le = frame.leftEar {
                points[2] = CGPoint(x: le.x, y: le.y)
            }
            if let re = frame.rightEar {
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

    private func updateState(presence rawPresence: DetectionPresence, sample: AngleSample?, verdict: PostureVerdict? = nil, points rawPoints: [CGPoint] = []) {
        // メインスレッドで動作することが保証されている

        // personMissing デバウンス: 欠測が gracePeriod 未満の連続なら
        // ノイズとして「検出中」を維持する（表示・蓄積とも）。
        // 復帰（検出）は即時。確定した人物なしのみリセット要因になる。
        let now = CACurrentMediaTime()
        var presence = rawPresence
        var points = rawPoints
        if rawPresence == .personDetected {
            lastPersonSeenTime = now
        } else if let seen = lastPersonSeenTime, now - seen < Self.personMissingGracePeriod {
            presence = .personDetected
            points = self.snapshot.visualizationPoints
        }

        self.snapshot.isPersonDetected = (presence == .personDetected)
        self.snapshot.visualizationPoints = points
        updateDebugDistance(sample: sample, now: now)

        if self.snapshot.phase == .calibrating {
            // キャリブレーションロジックに投入 (可視化ポイントも渡す)
            let progress = self.calibrationLogic.ingest(
                sample: sample,
                presence: presence,
                now: CACurrentMediaTime(),
                points: points
            )
            self.snapshot.calibrationProgress = progress

            if case .completed(let average, let averageDistance, let refSide, let refPoints) = progress {
                self.snapshot.phase = .monitoring
                self.snapshot.referenceAngle = average
                self.snapshot.referenceDistance = averageDistance
                self.snapshot.referenceSide = refSide
                self.snapshot.referencePoints = refPoints
            }
        } else if self.snapshot.phase == .monitoring {
            // モニタリング中の判定
            if presence == .personMissing {
                self.snapshot.displayedPosture = .personMissing
            } else if sample != nil {
                self.snapshot.displayedPosture = (verdict == .slouchCandidate) ? .slouch : .good
            }
            // 猶予期間中のサンプル欠如は表示を維持（前回の姿勢のまま）

            // 確定猫背ゲート: 3秒連続で .slouch が続いた時点で通知音（design.md Q17/Q18/Q20）
            let now = CACurrentMediaTime()
            let deltaTime = now - (self.lastGateTickTime ?? now)
            self.lastGateTickTime = now
            let isSlouch = self.snapshot.displayedPosture == .slouch
            let fired = self.snapshot.slouchGate.tick(isConditionMet: isSlouch, deltaTime: deltaTime)
            if fired {
                self.alertPlayer?.startRepeating()
            } else if !isSlouch {
                // 改善時は即停止（design.md Q20）
                self.alertPlayer?.stop()
            }
        }
    }

    private func getReferenceAngle() -> Double? {
        snapshot.referenceAngle
    }

    /// DEBUG 距離計測: 校正済み基準距離に対する耳-肩距離の比（%）を表示文字列化する。
    /// 素値（今回のフレーム）と直近1秒の中央値を併記し、前出し時の伸び率とノイズ幅を実測するためだけの足場。
    private func updateDebugDistance(sample: AngleSample?, now: TimeInterval) {
        guard let sample = sample, let ref = snapshot.referenceDistance, ref > 0 else {
            snapshot.debugDistanceText = nil
            return
        }
        let pct = sample.nearDistance / ref * 100.0
        distanceRatioWindow.append((now, pct))
        distanceRatioWindow.removeAll { now - $0.time > 1.0 }
        let values = distanceRatioWindow.map(\.pct).sorted()
        let median = values[values.count / 2]
        snapshot.debugDistanceText = String(format: "dist %.2f%% (1s-median %.2f%%)", pct, median)
    }

    private func verdictFor(sample: AngleSample) -> PostureVerdict {
        // ここで改めて判定ロジックを呼ぶか、analyzeの結果をそのまま使う
        // 実際には updateState 内で analyze した結果を使うように修正
        return .good
    }
}
