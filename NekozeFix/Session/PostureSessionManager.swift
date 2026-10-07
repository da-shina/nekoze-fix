import SwiftUI
import Combine
import AVFoundation

/// セッション層: 姿勢監視セッションの状態マシン。
/// design.md "PostureSessionManager" セクション参照。
/// 回転サービスのシームは `DeviceRotationServiceProtocol`（Types）に一本化。
/// `DeviceRotationService` が適合し、テストでは `FakeDeviceRotationService` が適合する。

@MainActor
final class PostureSessionManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    // MARK: - 公開プロパティ

    @Published private(set) var snapshot: SessionSnapshot

    // MARK: - プライベートプロパティ

    private var cancellables = Set<AnyCancellable>()
    let cameraManager = CameraSessionManager()
    private let poseDetector = PoseDetector()
    private let postureAnalyzer = PostureAnalyzer()
    /// 重力の取得・変換・保持を所有する（タスク13.1）。
    /// 起停は Session が駆動する（開始系で start、停止・背景移行で stop、暗転中は継続）。
    /// テストは @testable で latestGravityInKeypointSpace へ直接代入する。
    let motionService = MotionService()
    private var calibrationLogic = CalibrationLogic()
    let settingsStore: SettingsStore
    /// 回転角サービス（起停・再生成の指示先。4.1 で結線済み）。
    /// nil 時は指示を見送る（監視・校正フロー自体は継続）。
    /// 起停は Motion 起停と完全同一箇所で駆動する（暗転中継続・背景移行停止を含む）。
    /// 代入時は角度購読を張り替える（4.1 で結線済み）。
    var rotationService: (any DeviceRotationServiceProtocol)? {
        didSet { resetRotationSubscription() }
    }
    /// 結線中の角度購読（代入のたびに張り替える。nil 代入時は解除する）。
    private var rotationAnglesSubscription: AnyCancellable?
    /// Session 所有のプレビュー層（coordinator 初期化用・View 注入用）。
    /// 所有権は Session（View 側で生成しない）。View への注入は 4.1 で結線済み。
    /// 生成は遅延（初回再生成指示時）し、以後同一インスタンスを使い回す。
    private(set) var ownedPreviewLayer: AVCaptureVideoPreviewLayer?
    /// 直近に確定したカメラデバイス（層出現時の再生成用。確定通知の結線は 4.1）。
    private(set) weak var lastFinalizedCameraDevice: AVCaptureDevice?

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

    /// キーポイント瞬断ホールドの猶予時間（秒）。既存グレースと同一則。
    static let keypointHoldGracePeriod: TimeInterval = 0.5
    /// ホールド対象の4点 [左耳, 右耳, 左肩, 右肩]。
    private static let jointKeyPaths: [WritableKeyPath<PoseFrame, Keypoint?>] = [
        \.leftEar, \.rightEar, \.leftShoulder, \.rightShoulder,
    ]
    /// 点単位の直近値・最終検出時刻（ホールド用）。
    private var lastHeldKeypoints: [Keypoint?] = [nil, nil, nil, nil]
    private var lastJointSeenTime: [TimeInterval?] = [nil, nil, nil, nil]

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
        setupRotationWiring()
    }

    /// Preview・テスト用: 任意の snapshot で初期化する。
    init(settingsStore: SettingsStore = SettingsStore(), snapshot: SessionSnapshot) {
        self.settingsStore = settingsStore
        self.snapshot = snapshot
        super.init()
        setupSettingsObservation()
        setupRotationWiring()
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

    /// 直近の確定 capture 角（度。初回確定・同一角の重複発火を除外する）。
    private var lastKnownCaptureAngle: CGFloat?

    /// 回転角変更時の新トリガ（requirements 2.1–2.4, 3.1, 3.2, 4.1）。
    /// `DeviceRotationService` の変更配信の受口。購読結線は 4.1 で結線済み。
    /// テストは角度値を直接注入して駆動する。
    /// - Parameters:
    ///   - preview: preview用回転角（度）。View が Service を直接購読するため
    ///     Session は転送しない（受口の対称性のためのみ受け取る）。
    ///   - capture: capture用回転角（度）。data-output 接続への適用・
    ///     `isLandscape` 導出・自動再校正トリガの唯一の駆動源。
    /// 向き変化時の自動再校正遷移（要件 2.3/2.4/7.1）。
    /// monitoring中のみ旧基準（角度・距離・ロック側）と猫背ゲートを破棄して
    /// 校正へ自動遷移し、再校正完了まで監視を停止する（calibrating滞留）。
    /// Motion再始動・校正リセットは既存 startCalibration フローへ委譲し重複実装しない。
    /// calibrating中・idle・同一角の再通知は対象外。
    func handleRotationAngleChange(preview: CGFloat, capture: CGFloat) {
        cameraManager.updateCaptureRotationAngle(capture)
        // なで肩ガイダンスの向き分岐用（ADR 0014）。Session が唯一の書き込み点。
        // design.md 対応表（正規化角 [45°,135°)/[225°,315°)→portrait、それ以外→landscape）。
        // capture 角は Vision バッファと一致し前面鏡の影響を受けない。ヒステリシスなし。
        snapshot.isLandscape = Self.isLandscapeCaptureAngle(capture)

        // 背面カメラのランドスケープモードでは、センサがデバイス背面にあるため
        /// capture 角が前面と 180° 異なる。重力ベクトル回転用に補正する（Comment: 実機検収で発覚）。
        /// この補正は重力ベクトルのバッファ座標系変換（PostureAnalyzer.rotateToBufferSpace）のみに適用し、
        /// capture 接続適用・isLandscape 判定・再校正トリガには元の capture 角を使用する。
        let adjustedCapture = adjustedCaptureAngleForGravity(capture, cameraPosition: settingsStore.cameraPosition)
        defer { lastKnownCaptureAngle = adjustedCapture }
        guard let previous = lastKnownCaptureAngle, previous != adjustedCapture else { return }
        guard snapshot.phase == .monitoring else { return }
        resetCalibrationState()
        startCalibration()
    }

    /// 再校正時の基準値・ゲート・可視化の破棄を一本化する。
    /// 向き変化トリガと基準元変化トリガの重複分。フェーズ遷移・Motion起停は含まない。
    private func resetCalibrationState() {
        snapshot.referenceAngle = nil
        snapshot.referenceDistance = nil
        snapshot.referenceSide = nil
        snapshot.earShoulderVector = .zero
        snapshot.referencePoints = nil
        snapshot.calibrationReferenceSource = nil
        snapshot.slouchGate.reset()
        lastGateTickTime = nil
        snapshot.visualizationPoints = []
        smoothedPoints = []
        lastHeldKeypoints = [nil, nil, nil, nil]
        lastJointSeenTime = [nil, nil, nil, nil]
    }

    /// Motion・回転サービスの起停を一本化する（暗転中継続・背景停止は呼び出し側の則）。
    private func setMotionRotationRunning(_ running: Bool) {
        if running {
            motionService.start()
            rotationService?.start() // Motion起停と同一則
        } else {
            motionService.stop()
            rotationService?.stop() // Motion起停と同一則
        }
    }

    /// 背面カメラ・ランドスケープ時の重力ベクトル用 capture 角補正。
    /// - Parameters:
    ///   - capture: RotationCoordinator からの元の capture 角（度）
    ///   - cameraPosition: 現在のカメラ位置（前面／背面）
    /// - Returns: 重力ベクトル回転用の調整済み capture 角（度）
    ///   背面カメラかつランドスケープ（0° または 180° 付近）の場合、180° 加算する。
    private func adjustedCaptureAngleForGravity(_ capture: CGFloat, cameraPosition: CameraPosition) -> CGFloat {
        guard cameraPosition == .back else { return capture }
        // ランドスケープ判定は isLandscapeCaptureAngle に一本化（二重定義しない）
        return Self.isLandscapeCaptureAngle(capture) ? capture + 180 : capture
    }

    /// capture用回転角（度）からのランドスケープ判定（requirements 2.1, 2.2）。
    /// coordinator実機規約（センサ基準：ポートレート90°・ランドスケープ0°/180°）の対応表：
    /// 正規化角 [45°,135°)・[225°,315°) → ポートレート、それ以外 → ランドスケープ。
    /// capture用回転角は Vision バッファと一致し、判定は軸方向のみを見るため
    /// 前面鏡の影響を受けない。境界ヒステリシスはなし（実測後の追加検討）。
    /// 45°・225°はポートレート、135°・315°はランドスケープ。
    private static func isLandscapeCaptureAngle(_ degrees: CGFloat) -> Bool {
        var normalized = degrees.truncatingRemainder(dividingBy: 360)
        if normalized < 0 { normalized += 360 }
        let isPortrait = (normalized >= 45 && normalized < 135)
            || (normalized >= 225 && normalized < 315)
        return !isPortrait
    }

    /// カメラ確定デバイスの受口（4.1 実結線。`CameraSessionManager.deviceFinalizedHandler` の接続先）。
    /// 初回は本番 Service を生成して購読結線し、以後は所有層で recreate する。
    /// 生成直後の start は Motion 稼働 parity（稼働中のみ開始。暗転中継続・背景停止は既存則）。
    ///
    /// 順序・キュー保証（初回・切替・層再出現の3ケース）：
    /// 本受口は sessionQueue 上の構成ブロック由来で Main に直列化され、
    /// recreate→publish（同期・最新値上書き）→capture角転送（sessionQueue FIFO）の順に確定する。
    /// 初回・切替では構成（直前角の再適用）の後に新角が適用され、
    /// 層再出現（`handlePreviewLayerAppeared`）では適用のみ行われる。
    /// いずれも最終値は最新角であり、古い角による上書きは起きない。
    /// KVO 配送はメイン、読取りはメイン、最新値の上書きのみ。
    private func handleCameraDeviceFinalized(_ device: AVCaptureDevice) {
        lastFinalizedCameraDevice = device
        if rotationService == nil {
            let service = DeviceRotationService(device: device, previewLayer: ensureOwnedPreviewLayer())
            rotationService = service
            if motionService.isRunning {
                service.start()
            }
        }
        requestRotationRecreate(for: device)
    }

    /// 角度購読の張り替え（4.1 実結線）。購読非対応時は解除のみ行う。
    /// capture 角のみ購読する（Session は preview 角を使わない）。
    /// 購読は初期値で直ちに現行角を受け、初回確定として基準化する
    /// （同一角の重複発火除外と同一則。再校正は起こさない）。
    private func resetRotationSubscription() {
        rotationAnglesSubscription?.cancel()
        rotationAnglesSubscription = nil
        guard let source = rotationService else { return }
        rotationAnglesSubscription = source.captureRotationAnglePublisher
            .sink { [weak self] capture in
                guard let self, let source = self.rotationService else { return }
                self.deliverRotationAngles(preview: source.previewRotationAngle, capture: capture)
            }
    }

    /// 結線された角度配信の受口。KVO 由来の本番配信はメイン配送が保証されるため
    /// メインでは同期受渡しし、それ以外では MainActor へ hop する
    /// （`DeviceRotationService.publish` と同一則。最新値の上書きのみ）。
    private func deliverRotationAngles(preview: CGFloat, capture: CGFloat) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.handleRotationAngleChange(preview: preview, capture: capture)
            }
        } else {
            Task { @MainActor [weak self] in
                self?.handleRotationAngleChange(preview: preview, capture: capture)
            }
        }
    }

    /// 4.1 実結線：確定デバイス通知の受口登録。
    /// ハンドラは sessionQueue 上で呼ばれるため Main へ hop して受口へ渡す。
    private func setupRotationWiring() {
        cameraManager.deviceFinalizedHandler = { [weak self] device in
            Task { @MainActor [weak self] in
                self?.handleCameraDeviceFinalized(device)
            }
        }
    }

    /// カメラ確定時（カメラ構成時）に coordinator 再生成を指示する。
    /// 確定デバイスの通知結線・順序保証は 4.1 で結線済み。本メソッドは転送口を持つ。
    func requestRotationRecreate(for device: AVCaptureDevice) {
        lastFinalizedCameraDevice = device
        rotationService?.recreate(for: device, previewLayer: ensureOwnedPreviewLayer())
    }

    /// プレビュー層出現時（View からのペイロードなし通知の受口。4.1 で結線済み）の
    /// coordinator 再生成指示。Session が所有層・確定デバイスで recreate する。
    /// 未確定時は見送る（直前有効角の維持）。
    func handlePreviewLayerAppeared() {
        guard let device = lastFinalizedCameraDevice else { return }
        requestRotationRecreate(for: device)
    }

    /// 所有プレビュー層の遅延生成（初回再生成指示時）。以後同一インスタンスを使う。
    /// View 注入用（所有権は Session。View 側で生成しない）。
    func ensureOwnedPreviewLayer() -> AVCaptureVideoPreviewLayer {
        if let ownedPreviewLayer { return ownedPreviewLayer }
        let layer = AVCaptureVideoPreviewLayer(session: cameraManager.captureSession)
        self.ownedPreviewLayer = layer
        return layer
    }

    // MARK: - 公開メソッド

    /// セッションの初期化を行う
    func bootstrap() async {
        let auth = await cameraManager.requestAuthorization()
        switch auth {
        case .authorized:
            setPhase(.calibrating)
            setMotionRotationRunning(true)
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
        setMotionRotationRunning(true)
        calibrationLogic.start()
        smoothedPoints = []
        lastShoulderSeenTime = nil
        lastHeldKeypoints = [nil, nil, nil, nil]
        lastJointSeenTime = [nil, nil, nil, nil]
        Task {
            await startCameraPipeline()
        }
    }

    /// 姿勢監視を開始する
    func startMonitoring() {
        setPhase(.monitoring)
        exitDimMode()
        settingsStore.isMonitoringEnabled = true // 復帰判定の単一ソース（要求 8.2）
        // 監視開始時にゲートをリセットする
        snapshot.slouchGate.reset()
        lastGateTickTime = nil
        setMotionRotationRunning(true)
        Task {
            await startCameraPipeline()
        }
    }

    /// 姿勢監視を停止する（ユーザーの明示操作）
    func stopMonitoring() {
        setPhase(.idle)
        exitDimMode()
        settingsStore.isMonitoringEnabled = false
        cameraManager.stop()
        setMotionRotationRunning(false)
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
        setMotionRotationRunning(false)
        if snapshot.phase == .monitoring || snapshot.phase == .calibrating {
            setPhase(.idle)
        }
    }

    /// フォアグラウンド復帰: 監視フラグ true かつ校正済みなら監視を再開する（要求 8.2）。
    /// 明示停止（フラグ false）・未校正・権限なしは停止状態を維持する。
    func handleWillEnterForeground() {
        // 復帰後は暗転解除（輝度復元）。監視再開の有無に関わらず行う
        exitDimMode()
        guard settingsStore.isMonitoringEnabled, snapshot.referenceAngle != nil else {
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
        snapshot.visualizationPoints = []
        smoothedPoints = []
        await startCameraPipeline()
    }

    private func startCameraPipeline() async {
        do {
            // デリゲートは start() より先に設定する。
            // 両メソッドは同一の sessionQueue に async 投入されるため、
            // configureSession が必ず非 nil のデリゲートを参照する順序が保証される。
            cameraManager.setSampleBufferDelegate(self)
            try await cameraManager.start(position: settingsStore.cameraPosition == .front ? .front : .back)
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
        // 自動回転して配信される（connection.videoRotationAngle は参考値にすぎない）。
        // したがって Vision には常に .up を渡す。
        //
        // ポーズ検出は検出専用キュー（detectionQueue）上で同期的に実行する。
        // 制御系 sessionQueue とは分離されており、人物ありの高負荷推論中も
        // 回転角適用・カメラ再構成をブロックしない。
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
        // DEBUG 表示用の信頼度記録は毎フレーム取り直す（.pose 側で上書き）。
        snapshot.keypointConfidences = []
        // 人物なし（Body Pose 観測空 かつ 顔なし）
        if case .absent = detection {
            snapshot.isShoulderMissing = false
            // ホールドも破棄する。不在前の点を直後の .pose に補完すると、
            // 別人物の耳と肩で判定してしまう。
            lastHeldKeypoints = [nil, nil, nil, nil]
            lastJointSeenTime = [nil, nil, nil, nil]
            updateState(presence: .personMissing, sample: nil, resolvedReference: nil)
            return
        }

        // 顔のみ検出（.personOnly）: 人物はいるが肩キーポイントなし。
        // 肩欠測デバウンス: 猶予期間内は前回の可視化ポイントを維持し
        // 「肩が映っていません」案内のチラつきを防ぐ（Q21 拡張パターン）。
        guard case .pose(var frame) = detection else {
            let now = CACurrentMediaTime()
            if let lastSeen = lastShoulderSeenTime, now - lastSeen < Self.shoulderMissingGracePeriod {
                snapshot.isShoulderMissing = false
                updateState(presence: .personDetected, sample: nil, resolvedReference: nil, points: snapshot.visualizationPoints)
            } else {
                snapshot.isShoulderMissing = true
                lastShoulderSeenTime = nil
                updateState(presence: .personDetected, sample: nil, resolvedReference: nil)
            }
            return
        }

        // .pose: 肩キーポイント検出あり
        lastShoulderSeenTime = CACurrentMediaTime()
        snapshot.isShoulderMissing = false

        // DEBUG 表示用にフィルタ前の生信頼度を記録する。
        snapshot.keypointConfidences = [
            frame.leftEar?.confidence,
            frame.rightEar?.confidence,
            frame.leftShoulder?.confidence,
            frame.rightShoulder?.confidence,
        ]

        // 向き別の信頼度フィルタ（ランドスケープは緩め。要件4.6）。
        // 検出層は全点を保持してくるため、ここで snapshot.isLandscape に応じて落とす。
        // 検出キューから snapshot を読むとアクタ境界をまたぐため方針判断は MainActor 側に寄せる。
        frame = applyingKeypointThreshold(frame, isLandscape: snapshot.isLandscape)

        // キーポイントの瞬断ホールド（猶予 0.5 秒。既存グレースと同一則）。
        // 肩が切れると耳も連動して落ちる実測のため、点単位で直近値を保持し
        // 校正蓄積・可視化のチラつきを防ぐ。人物不在 (.absent) 時は保持しない。
        frame = holdingMissingKeypoints(frame, now: CACurrentMediaTime())

        // 2. 姿勢分析
        let refAngle = snapshot.referenceAngle
        let threshold = self.settingsStore.slouchThresholdDegrees

        // 校正ロック側の距離指標（FQ1）。referenceSide/referenceDistance は校正完了時のみ設定される。
        let distanceMetric: DistanceMetric?
        if let side = snapshot.referenceSide, let ref = snapshot.referenceDistance {
            distanceMetric = DistanceMetric(side: side, referenceDistance: ref)
        } else {
            distanceMetric = nil
        }

        let (sample, verdict, resolvedReference) = self.postureAnalyzer.analyze(
            frame: frame,
            referenceNearAngleDegrees: refAngle,
            slouchDeltaThresholdDegrees: threshold,
            distanceMetric: distanceMetric,
            slouchDistanceThresholdPercent: self.settingsStore.slouchDistanceThresholdPercent,
            previousNearSide: snapshot.nearSide,
            gravityInKeypointSpace: self.motionService.latestGravityInKeypointSpace,
            // 重力はデバイス座標系・キーポイントは回転済みバッファ座標系のため、
            // 直近capture角で重力由来の基準値のみバッファ座標系へ回転させる（未確定時は無回転）。
            captureAngleDegrees: lastKnownCaptureAngle.map { Double($0) },
            // Analyzer 側のゲートにも向き別閾値を注入する（Session 事前フィルタと同値。
            // 注入なしでは Analyzer 内の 0.3 既定がランドスケープ緩和を無効化する）。
            minimumConfidence: keypointConfidenceThreshold(isLandscape: snapshot.isLandscape)
        )
        // 判定が返した基準線ベクトルを表示へ受渡しする（単一解決、二重解決なし）。
        // analyze 済みでバッファ座標系（y上向き）の方向であり、変換は Overlay 側で点列と同一係数にて行う。
        // monitoring中は校正完了時点の向きに凍結し、人物ありの毎フレーム上書きによる微振動を防ぐ。
        // 可変なのは肩点起点の耳-肩角度（黄線側）のみ。calibrating中はライブ更新を継続し、
        // 向き・解決元変化の再校正では自動で解凍→完了時に再凍結される。
        if snapshot.phase != .monitoring {
            snapshot.referenceVector = CGVector(dx: resolvedReference.vector.x, dy: resolvedReference.vector.y)
        }

        // 可視化用ポイントの抽出 (固定インデックス: 0:左肩, 1:右肩, 2:左耳, 3:右耳, 4:近傍耳, 5:近傍肩)
        var points = [CGPoint](repeating: .zero, count: 6)

        // 1. 肩の描画 (側ごとに閾値以上で表示。片側欠測でももう片側は出す)
        if let ls = frame.leftShoulder {
            points[0] = CGPoint(x: ls.x, y: ls.y)
        }
        if let rs = frame.rightShoulder {
            points[1] = CGPoint(x: rs.x, y: rs.y)
        }

        // 2. 耳の描画 (側ごとに閾値以上で表示)
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
        updateState(presence: .personDetected, sample: sample, verdict: verdict, resolvedReference: resolvedReference, points: points)
    }

    private func updateState(presence rawPresence: DetectionPresence, sample: AngleSample?, verdict: PostureVerdict? = nil, resolvedReference: ResolvedReferenceVector? = nil, points rawPoints: [CGPoint] = []) {
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
                referenceSource: resolvedReference?.source,
                presence: presence,
                now: CACurrentMediaTime(),
                points: points
            )
            self.snapshot.calibrationProgress = progress

            if case .completed(let average, let averageDistance, let refSide, let refPoints, let refSource) = progress {
                self.applyCalibrationCompletion(
                    referenceNearAngleDegrees: average,
                    referenceDistance: averageDistance,
                    referenceSide: refSide,
                    referencePoints: refPoints,
                    referenceSource: refSource
                )
            }
        } else if self.snapshot.phase == .monitoring {
            // モニタリング中の判定
            if presence == .personMissing {
                self.snapshot.displayedPosture = .personMissing
            } else if sample != nil {
                self.snapshot.displayedPosture = (verdict == .slouchCandidate) ? .slouch : .good
            }
            // 猶予期間中のサンプル欠如は表示を維持（前回の姿勢のまま）

            // 基準ベクトル解決元が校正時から変わったら再校正をトリガー（Comment 1 対策: 校正値の整合性確保）。
            // 向き変化時の自動再校正（grill Q3/Q5）と同様に、基準値とゲートを破棄して calibrating へ遷移。
            // Motion は停止しない（回転トリガ経路と同一則）。停止すると再校正中の重力が恒常nilになり
            // 代替基準でしか完了できず、完了時の Motion 再開で重力が戻ると即座に再発火する往復ループになる。
            // resolvedReference が nil の場合（人物不在・ポーズ未取得）は解決元の変更とはみなさない（猶予期間を維持）。
            let sourceChanged = snapshot.calibrationReferenceSource != nil
                && resolvedReference?.source != nil
                && resolvedReference?.source != snapshot.calibrationReferenceSource
            if sourceChanged {
                self.setPhase(.calibrating)
                self.calibrationLogic.start()
                self.snapshot.calibrationProgress = .waitingForPerson
                self.resetCalibrationState()
                self.settingsStore.isMonitoringEnabled = false
                self.snapshot.slouchGate = TimedConditionGate(requiredDuration: 3.0)
                self.alertPlayer?.stop()
            } else {
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
                
                // 閾値ガイド表示用パラメータを更新（スライダー操作中のみ表示されるが、
                // パラメータは常に最新の可視化ポイントから計算しておく）
                self.updateGuideParameters()
            }
        }
    }

    /// 校正完了時に基準値をスナップショットへ反映し監視フェーズへ遷移する。
    /// 遠側基準は構築しない（要件4.1: ロック側のみ。タスク13.1で削除）。
    /// テストは直接呼んで校正済み状態をシードできる。
    func applyCalibrationCompletion(
        referenceNearAngleDegrees: Double,
        referenceDistance: Double,
        referenceSide: Side,
        referencePoints: [CGPoint],
        referenceSource: ReferenceVectorSource? = nil
    ) {
        setPhase(.monitoring)
        setMotionRotationRunning(true)
        settingsStore.isMonitoringEnabled = true // 校正完了＝監視開始。復帰判定の単一ソース
        snapshot.referenceAngle = referenceNearAngleDegrees
        snapshot.referenceDistance = referenceDistance
        snapshot.referenceSide = referenceSide
        snapshot.referencePoints = referencePoints
        snapshot.calibrationReferenceSource = referenceSource
        updateGuideParameters()
    }

    /// 向き別の信頼度でキーポイントを落とす（ランドスケープは緩め。要件4.6）。
    /// 横向きは垂直画角不足で confidence が下がりがちなため閾値を下げる。
    private func applyingKeypointThreshold(_ frame: PoseFrame, isLandscape: Bool) -> PoseFrame {
        let threshold = keypointConfidenceThreshold(isLandscape: isLandscape)
        func keep(_ keypoint: Keypoint?) -> Keypoint? {
            guard let keypoint, keypoint.confidence >= threshold else { return nil }
            return keypoint
        }
        return PoseFrame(
            timestamp: frame.timestamp,
            leftEar: keep(frame.leftEar),
            rightEar: keep(frame.rightEar),
            leftShoulder: keep(frame.leftShoulder),
            rightShoulder: keep(frame.rightShoulder)
        )
    }

    /// 欠測キーポイントの直近値ホールド（人物不在時は対象外。呼び出し側で分岐済み）。
    /// 猶予内の再検出は前回値をそのまま使い、超過後は破棄する。
    private func holdingMissingKeypoints(_ frame: PoseFrame, now: TimeInterval) -> PoseFrame {
        var frame = frame
        for (index, path) in Self.jointKeyPaths.enumerated() {
            if let current = frame[keyPath: path] {
                lastHeldKeypoints[index] = current
                lastJointSeenTime[index] = now
            } else if let held = lastHeldKeypoints[index],
                      let seen = lastJointSeenTime[index],
                      now - seen < Self.keypointHoldGracePeriod {
                frame[keyPath: path] = held
            } else {
                lastHeldKeypoints[index] = nil
                lastJointSeenTime[index] = nil
            }
        }
        return frame
    }

    /// 閾値ガイド表示用パラメータを更新する（スライダー操作中のみ使用）。
    /// 方向ベクトルは校正ロック側 (referenceSide) の耳・肩ペアから導出する。
    /// referenceDistance と監視判定がロック側基準のため、ガイドも同一側にそろえる。
    /// 未校正時は nearSide にフォールバックする。起点は Overlay 側で referencePoints (校正時肩点) を使用。
    /// 画面ピクセルへの変換はビュー層（GeometryReader）で行う。
    private func updateGuideParameters() {
        guard let guideSide = snapshot.referenceSide ?? snapshot.nearSide,
              snapshot.visualizationPoints.count >= 6 else {
            snapshot.earShoulderVector = .zero
            return
        }

        let points = snapshot.visualizationPoints
        let earIndex = guideSide == .left ? 2 : 3
        let shoulderIndex = guideSide == .left ? 0 : 1
        
        guard earIndex < points.count, shoulderIndex < points.count,
              points[earIndex] != .zero, points[shoulderIndex] != .zero else {
            snapshot.earShoulderVector = .zero
            return
        }

        let earPoint = points[earIndex]
        let shoulderPoint = points[shoulderIndex]
        
        // 正規化座標系での耳→肩ベクトル
        let vecX = shoulderPoint.x - earPoint.x
        let vecY = shoulderPoint.y - earPoint.y
        let vecLen = hypot(vecX, vecY)
        
        // Vision正規化座標系の単位ベクトル（ガイド線の方向用）
        if vecLen > 0 {
            snapshot.earShoulderVector = CGVector(dx: vecX / vecLen, dy: vecY / vecLen)
        } else {
            snapshot.earShoulderVector = .zero
        }
    }

    /// セッションのフェーズの唯一の書き込み経路。
    /// wake lock 不変条件 `isIdleTimerDisabled == (phase == .monitoring)` を全遷移で強制する（要求 8.3/8.4、ADR 0016）。
    private func setPhase(_ phase: SessionPhase) {
        snapshot.phase = phase
        UIApplication.shared.isIdleTimerDisabled = (phase == .monitoring)
    }

}
