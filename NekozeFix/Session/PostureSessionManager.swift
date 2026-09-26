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
    let settingsStore: SettingsStore
    private let orientationMonitor = DeviceOrientationMonitor()
    private let gravityProvider = GravityVectorProvider()


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

    // MARK: - 初期化

    /// personMissing 確定までの猶予時間（秒）。この未満の連続欠測はノイズ扱い。
    static let personMissingGracePeriod: TimeInterval = 0.5
    /// 最後に人物を検出した時刻（nil は未検出継続中）
    private var lastPersonSeenTime: TimeInterval?

    /// 肩キーポイント欠測確定までの猶予時間（秒）。personMissingGracePeriod と同パターン。
    static let shoulderMissingGracePeriod: TimeInterval = 0.5
    /// 最後に肩キーポイントを検出した時刻（nil は肩未検出継続中）
    private var lastShoulderSeenTime: TimeInterval?

    /// 可視化ポイントの EMA スムージング係数（新値の重み）。
    /// 小さいほど滑らかだが追従遅延が増す。.zero はスムージング対象外。
    private let smoothingFactor: CGFloat = 0.3
    /// 前回のスムージング済み可視化ポイント（EMA の状態）
    private var smoothedPoints: [CGPoint] = []

    init(settingsStore: SettingsStore = SettingsStore()) {
        self.settingsStore = settingsStore
        self.snapshot = SessionSnapshot()
        super.init()
        setupSettingsObservation()
        setupOrientationObservation()
    }

    /// Preview・テスト用: 任意の snapshot で初期化する。
    init(settingsStore: SettingsStore = SettingsStore(), snapshot: SessionSnapshot) {
        self.settingsStore = settingsStore
        self.snapshot = snapshot
        super.init()
        setupSettingsObservation()
        setupOrientationObservation()
    }

    /// テスト用: 表示用 dwell gate の requiredDuration を変更する。
    /// テストではフレーム間の実時間がほぼ0のため、デフォルト0.5秒では
    /// gate が発火せず displayedPosture が .slouch にならない。
    func setPostureDisplayGateDuration(_ duration: TimeInterval) {
        snapshot.postureDisplayGate = TimedConditionGate(requiredDuration: duration)
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
                // オーバーレイの座標変換用。Session が唯一の書き込み点。
                self?.snapshot.videoOrientation = orientation
            }
            .store(in: &cancellables)

        orientationMonitor.$isRotating
            .sink { [weak self] isRotating in
                guard let self = self else { return }
                if isRotating {
                    setPhase(.rotating)
                } else if self.snapshot.phase == .rotating {
                    // 回転完了後、監視有効かつ校正済みなら監視へ復帰。それ以外は idle。
                    if self.settingsStore.isMonitoringEnabled, self.snapshot.referenceAngle != nil {
                        self.startMonitoring()
                    } else {
                        setPhase(.idle)
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - 公開メソッド

    /// セッションの初期化を行う
    func bootstrap() async {
        let auth = await cameraManager.requestAuthorization()
        switch auth {
        case .authorized:
            setPhase(.calibrating)
            await startCameraPipeline()
        case .denied:
            setPhase(.permissionDenied)
        case .notDetermined:
            setPhase(.awaitingPermission)
        }
    }

    /// キャリブレーションフェーズに遷移する
    func startCalibration() {
        setPhase(.calibrating)
        calibrationLogic.start()
        smoothedPoints = []
        lastShoulderSeenTime = nil
        Task {
            await startCameraPipeline()
        }
    }

    /// 姿勢監視を開始する
    func startMonitoring() {
        setPhase(.monitoring)
        exitDimMode()
        snapshot.isMonitoringEnabled = true
        settingsStore.isMonitoringEnabled = true // 復帰判定の単一ソース（要求 8.2）
        // 監視開始の初期化（ゲート・表示状態）。再校正完了時も同じ初期化を使う
        resetMonitoringState()
        Task {
            await startCameraPipeline()
        }
    }

    /// 姿勢監視を停止する（ユーザーの明示操作）
    func stopMonitoring() {
        setPhase(.idle)
        exitDimMode()
        snapshot.isMonitoringEnabled = false
        settingsStore.isMonitoringEnabled = false
        cameraManager.stop()
        // 監視停止時は通知音も即停止（design.md Q20）
        alertPlayer?.stop()
    }

    // MARK: - ライフサイクル（要求 8.1/8.2、タスク3.5）

    /// バックグラウンド移行: 監視中/校正中なら idle へ退避しカメラ・音声を停止する。
    /// 監視フラグ（SettingsStore）は維持 — ユーザーストップではないため復帰時に再開する。
    /// 輝度はこの時点では復元しない（復帰時に handleWillEnterForeground で解除。Q24 改訂）。
    func handleDidEnterBackground() {
        alertPlayer?.stop()
        cameraManager.stop()
        if snapshot.phase == .monitoring || snapshot.phase == .calibrating || snapshot.phase == .rotating {
            setPhase(.idle)
        }
        snapshot.isMonitoringEnabled = settingsStore.isMonitoringEnabled
    }

    /// フォアグラウンド復帰: 監視フラグ true かつ校正済みなら監視を再開する（要求 8.2）。
    /// 明示停止（フラグ false）・未校正・権限なしは停止状態を維持する。
    func handleWillEnterForeground() {
        // 復帰後は暗転解除（輝度復元）。監視再開の有無に関わらず行う
        exitDimMode()
        guard settingsStore.isMonitoringEnabled, snapshot.referenceAngle != nil else {
            snapshot.isMonitoringEnabled = settingsStore.isMonitoringEnabled
            return // 非監視のまま。不変条件は背面遷移時の setPhase(.idle) で OFF 済み
        }
        guard snapshot.phase == .idle else { return } // 校正中等进行中フェーズは触らない
        startMonitoring()
    }

    // MARK: - 暗転モード（design.md Q2/Q24、ADR 0013）

    /// 暗転前に保存した元の輝度値（プロセス内メモリのみ、永続化しない。Q24）
    private var savedBrightness: CGFloat?

    /// ディムモードに入る（ブラックスクリーン。wake lock はライフサイクル側で扱うため触らない。ADR 0015）
    func enterDimMode() {
        guard !snapshot.isDimmed else { return }
        savedBrightness = UIScreen.main.brightness
        UIScreen.main.brightness = 0.0
        snapshot.isDimmed = true
    }

    /// ディムモードを終了する（輝度復元のみ。暗転解除後も自動スリープは復活しない — 要求 8.4）
    func exitDimMode() {
        guard snapshot.isDimmed else { return }
        if let brightness = savedBrightness {
            UIScreen.main.brightness = brightness
        }
        savedBrightness = nil
        snapshot.isDimmed = false
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
            setPhase(.permissionDenied)
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
            self.processDetection(detection)
        }
    }

    /// 検出結果を姿勢解析しセッション状態へ反映する（メインアクタ）。
    /// captureOutput の Task 本体。テストは合成フレームの Detection を直接投入できる。
    func processDetection(_ detection: PoseDetector.Detection) {
        guard snapshot.phase != .rotating else { return }

        // 人物なし（Body Pose 観測空 かつ 顔なし）
        if case .absent = detection {
            snapshot.isShoulderMissing = false
            updateState(presence: .personMissing, sample: nil)
            return
        }

        // 顔のみ検出（.personOnly）: 人物はいるが肩キーポイントなし。
        // 肩欠測デバウンス: 猶予期間内は前回の可視化ポイントを維持し
        // 「肩が映っていません」案内のチラつきを防ぐ（Q21 拡張パターン）。
        guard case .pose(let frame) = detection else {
            let now = CACurrentMediaTime()
            if let lastSeen = lastShoulderSeenTime, now - lastSeen < Self.shoulderMissingGracePeriod {
                snapshot.isShoulderMissing = false
                updateState(presence: .personDetected, sample: nil, points: snapshot.visualizationPoints)
            } else {
                snapshot.isShoulderMissing = true
                lastShoulderSeenTime = nil
                updateState(presence: .personDetected, sample: nil)
            }
            return
        }

        // .pose: 肩キーポイント検出あり
        lastShoulderSeenTime = CACurrentMediaTime()
        snapshot.isShoulderMissing = false

        // 2. 姿勢分析
        let refAngle = snapshot.referenceAngle
        let threshold = self.settingsStore.slouchThresholdDegrees

        // 校正ロック側の距離指標（FQ1）。referenceSide/referenceDistance は校正完了時のみ設定される。
        let distanceMetric: DistanceMetric?
        if let side = snapshot.referenceSide, let ref = snapshot.referenceDistances[side] {
            let farSide: Side = (side == .left) ? .right : .left
            let fallback = snapshot.referenceDistances[farSide]
            distanceMetric = DistanceMetric(side: side, referenceDistance: ref, fallbackReferenceDistance: fallback)
        } else {
            distanceMetric = nil
        }

        let (sample, verdict) = self.postureAnalyzer.analyze(
            frame: frame,
            verticalVector: gravityProvider.verticalVector(for: snapshot.videoOrientation),
            slouchThresholdDegrees: threshold,
            distanceMetric: distanceMetric,
            slouchDistanceThresholdPercent: self.settingsStore.slouchDistanceThresholdPercent,
            previousNearSide: snapshot.nearSide
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
        let activeNearSide = sample?.nearSide ?? snapshot.nearSide

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
            snapshot.nearSide = side
        }

        // 可視化ポイントの EMA スムージング（位置ジッタ軽減）。
        // .zero はスムージング対象外（初出/消失は即座）。
        points = points.enumerated().map { i, new in
            guard i < smoothedPoints.count,
                  smoothedPoints[i] != .zero,
                  new != .zero else { return new }
            return CGPoint(
                x: smoothedPoints[i].x + smoothingFactor * (new.x - smoothedPoints[i].x),
                y: smoothedPoints[i].y + smoothingFactor * (new.y - smoothedPoints[i].y)
            )
        }
        smoothedPoints = points

        // 3. 状態更新
        updateState(presence: .personDetected, sample: sample, verdict: verdict, points: points)
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

        if self.snapshot.phase == .calibrating {
            // キャリブレーションロジックに投入 (可視化ポイントも渡す)
            let progress = self.calibrationLogic.ingest(
                sample: sample,
                presence: presence,
                now: CACurrentMediaTime(),
                points: points
            )
            self.snapshot.calibrationProgress = progress

            if case .completed(let average, let averageDistance, let refSide, let refPoints, let refFarAngle, let refFarDistance) = progress {
                self.applyCalibrationCompletion(
                    referenceNearAngleDegrees: average,
                    referenceDistance: averageDistance,
                    referenceSide: refSide,
                    referencePoints: refPoints,
                    referenceFarAngleDegrees: refFarAngle,
                    referenceFarDistance: refFarDistance
                )
            }
        } else if self.snapshot.phase == .monitoring {
            // モニタリング中の判定
            // deltaTime を1回だけ計算し、postureDisplayGate と slouchGate で共有する
            let now = CACurrentMediaTime()
            let deltaTime = now - (self.lastGateTickTime ?? now)
            self.lastGateTickTime = now

            if presence == .personMissing {
                self.snapshot.displayedPosture = .personMissing
                self.snapshot.postureDisplayGate.reset()
                self.snapshot.slouchGate.reset()
            } else if sample != nil {
                if verdict == .slouchCandidate {
                    // slouch 方向: dwell ゲートを通して0.5秒連続でのみ .slouch 表示
                    let displayConfirmed = self.snapshot.postureDisplayGate.tick(isConditionMet: true, deltaTime: deltaTime)
                    if displayConfirmed {
                        self.snapshot.displayedPosture = .slouch
                    }
                    // ゲート未発火時は前回の表示を維持（猶予期間中と同様）
                } else {
                    // good 方向: 即時反映。ゲート蓄積もリセット
                    self.snapshot.postureDisplayGate.tick(isConditionMet: false, deltaTime: deltaTime)
                    self.snapshot.displayedPosture = .good
                }
            } else {
                // 姿勢判定不能フレーム（presence は personDetected だが sample なし）:
                // 表示は維持し、dwell 蓄積だけ解除する（欠測を挟んだ非連続フレームでの .slouch 確定を防ぐ）
                self.snapshot.postureDisplayGate.reset()
            }

            // 確定猫背ゲート: 3秒連続で .slouch が続いた時点で通知音（design.md Q17/Q18/Q20）
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

    /// 監視開始時のゲート・表示状態の初期化（監視開始の唯一の初期化点）。
    /// 再校正完了時にも呼ぶ — 校正中の経過を deltaTime に持ち込ませない（PR #9 レビュー指摘）。
    private func resetMonitoringState() {
        snapshot.slouchGate.reset()
        snapshot.postureDisplayGate.reset()
        lastGateTickTime = nil
        // 前セッションの .slouch を持ち越さない（startMonitoring と同じ初期状態にする）
        snapshot.displayedPosture = .good
    }

    /// 校正完了時に基準値をスナップショットへ反映し監視フェーズへ遷移する。
    /// テストは直接呼んで校正済み状態をシードできる。
    func applyCalibrationCompletion(
        referenceNearAngleDegrees: Double,
        referenceDistance: Double,
        referenceSide: Side,
        referencePoints: [CGPoint],
        referenceFarAngleDegrees: Double? = nil,
        referenceFarDistance: Double? = nil
    ) {
        setPhase(.monitoring)
        snapshot.isMonitoringEnabled = true
        settingsStore.isMonitoringEnabled = true // 校正完了＝監視開始。復帰判定の単一ソース
        snapshot.referenceAngle = referenceNearAngleDegrees
        snapshot.referenceDistances = [referenceSide: referenceDistance]
        if let farDist = referenceFarDistance {
            let farSide: Side = (referenceSide == .left) ? .right : .left
            snapshot.referenceDistances[farSide] = farDist
        }
        snapshot.referenceSide = referenceSide
        snapshot.referencePoints = referencePoints
        // 再校正完了時も監視開始と同じ初期状態にする（ゲート・時刻・表示をリセット）
        resetMonitoringState()
    }

    /// セッションのフェーズの唯一の書き込み経路。
    /// wake lock 不変条件 `isIdleTimerDisabled == (phase == .monitoring)` を全遷移で強制する（要求 8.3/8.4、ADR 0016）。
    private func setPhase(_ phase: SessionPhase) {
        snapshot.phase = phase
        UIApplication.shared.isIdleTimerDisabled = (phase == .monitoring)
    }

}
