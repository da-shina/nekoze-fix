import SwiftUI
import Combine
import AVFoundation

/// セッション層: 姿勢監視セッションの状態マシン。
/// design.md "PostureSessionManager" セクション参照。

/// 回転サービスの Session 側シーム。`DeviceRotationService` が適合し、
/// テストでは `FakeDeviceRotationService` が適合する（test target の extension）。
/// 起停は Motion 起停と完全同一箇所で駆動する。実結線は task 4.1。
/// design.md PostureSessionManager（改修）：購読とトリガ・再生成指示は Session。
protocol SessionRotationService: AnyObject {
    /// 監視・校正開始時に呼ぶ（Motion 起停と同一則）。
    func start()
    /// 監視停止・背景移行時に呼ぶ（Motion 起停と同一則）。
    func stop()
    /// カメラ確定時・プレビュー層出現時に Session が呼ぶ再生成。
    func recreate(for device: AVCaptureDevice, previewLayer: AVCaptureVideoPreviewLayer?)
}

extension DeviceRotationService: SessionRotationService {}

/// 回転角購読シーム（4.1 実結線用）。Session が同一 Service インスタンスの
/// 両角配信を購読するための受口。`DeviceRotationService` が適合し、
/// テストでは `FakeDeviceRotationService` が適合する（RotationWiringOrderTests 内の extension）。
/// `SessionRotationService`（起停・再生成の指示口）とは別口のままにし、
/// 既存適合（SessionRotationTriggerTests 内）を壊さない。
protocol SessionRotationAngleSource: AnyObject {
    var rotationAnglesPublisher: AnyPublisher<(preview: CGFloat, capture: CGFloat), Never> { get }
}

extension DeviceRotationService: SessionRotationAngleSource {
    var rotationAnglesPublisher: AnyPublisher<(preview: CGFloat, capture: CGFloat), Never> {
        $previewRotationAngle
            .combineLatest($captureRotationAngle)
            .map { (preview: $0, capture: $1) }
            .eraseToAnyPublisher()
    }
}

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
    var rotationService: (any SessionRotationService)? {
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
        // design.md 対応表（0°±45°・180°±45°→portrait、90°±45°・270°±45°→landscape）。
        // capture 角は Vision バッファと一致し前面鏡の影響を受けない。ヒステリシスなし。
        snapshot.isLandscape = Self.isLandscapeCaptureAngle(capture)
        defer { lastKnownCaptureAngle = capture }
        guard let previous = lastKnownCaptureAngle, previous != capture else { return }
        guard snapshot.phase == .monitoring else { return }
        snapshot.referenceAngle = nil
        snapshot.referenceDistances = [:]
        snapshot.referenceSide = nil
        snapshot.slouchGate.reset()
        lastGateTickTime = nil
        startCalibration()
    }

    /// capture用回転角（度）からのランドスケープ判定（requirements 2.1, 2.2）。
    /// design.md PostureSessionManager の対応表そのままの表現：
    /// 0°±45°・180°±45° → ポートレート、90°±45°・270°±45° → ランドスケープ。
    /// capture用回転角は Vision バッファと一致し、判定は軸方向のみを見るため
    /// 前面鏡の影響を受けない。境界ヒステリシスはなし（実測後の追加検討）。
    /// 境界はランドスケープ側に含める（45°→landscape、135°→portrait、
    /// 225°→landscape、315°→portrait）。
    private static func isLandscapeCaptureAngle(_ degrees: CGFloat) -> Bool {
        var normalized = degrees.truncatingRemainder(dividingBy: 360)
        if normalized < 0 { normalized += 360 }
        let isPortrait = (normalized < 45 || normalized >= 315)
            || (normalized >= 135 && normalized < 225)
        return !isPortrait
    }

    /// 回転サービスの結線（4.1 実結線）。購読の張り替えは didSet 経由で一本化する。
    /// テストは Fake を渡して TestDouble 駆動する。
    /// Session と View は本メソッドで結線した同一インスタンスを共有する
    /// （`rotationServiceForPreview` 経由。二重解決・隠れた共有所有を作らない）。
    func attachRotationService(_ service: (any SessionRotationService)?) {
        rotationService = service
    }

    /// View 注入用の同一 Service インスタンス（4.1 実結線）。
    /// 未結線時は nil（View は購読しない。3.2 の既定動作）。
    var rotationServiceForPreview: (any PreviewRotationAngleSource)? {
        rotationService as? any PreviewRotationAngleSource
    }

    /// View 注入用の Session 所有プレビュー層（4.1 実結線）。
    /// 初回アクセス時に生成し以後同一インスタンスを使い回す（所有権は Session）。
    var previewLayerForInjection: AVCaptureVideoPreviewLayer {
        ensureOwnedPreviewLayer()
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
            attachRotationService(service)
            if motionService.isRunning {
                service.start()
            }
        }
        requestRotationRecreate(for: device)
    }

    /// 角度購読の張り替え（4.1 実結線）。購読非対応時は解除のみ行う。
    /// 購読は CombineLatest の初期値で直ちに現行角を受け、初回確定として基準化する
    /// （同一角の重複発火除外と同一則。再校正は起こさない）。
    private func resetRotationSubscription() {
        rotationAnglesSubscription?.cancel()
        rotationAnglesSubscription = nil
        guard let source = rotationService as? any SessionRotationAngleSource else { return }
        rotationAnglesSubscription = source.rotationAnglesPublisher
            .sink { [weak self] angles in
                self?.deliverRotationAngles(preview: angles.preview, capture: angles.capture)
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
        rotationService?.recreate(for: device, previewLayer: ensureOwnedPreviewLayer())
    }

    /// 所有プレビュー層の遅延生成（初回再生成指示時）。以後同一インスタンスを使う。
    private func ensureOwnedPreviewLayer() -> AVCaptureVideoPreviewLayer {
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
            motionService.start()
            rotationService?.start() // Motion起停と同一則
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
        motionService.start()
        rotationService?.start() // Motion起停と同一則
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
        // 監視開始時にゲートをリセットする
        snapshot.slouchGate.reset()
        lastGateTickTime = nil
        motionService.start()
        rotationService?.start() // Motion起停と同一則
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
        motionService.stop()
        rotationService?.stop() // Motion起停と同一則
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
        motionService.stop()
        rotationService?.stop() // Motion起停と同一則
        if snapshot.phase == .monitoring || snapshot.phase == .calibrating {
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
        // 自動回転して配信される（connection.videoRotationAngle は参考値にすぎない）。
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
            distanceMetric = DistanceMetric(side: side, referenceDistance: ref)
        } else {
            distanceMetric = nil
        }

        let (sample, verdict, reference) = self.postureAnalyzer.analyze(
            frame: frame,
            referenceNearAngleDegrees: refAngle,
            slouchDeltaThresholdDegrees: threshold,
            distanceMetric: distanceMetric,
            slouchDistanceThresholdPercent: self.settingsStore.slouchDistanceThresholdPercent,
            previousNearSide: snapshot.nearSide,
            gravityInKeypointSpace: self.motionService.latestGravityInKeypointSpace,
            // 重力はデバイス座標系・キーポイントは回転済みバッファ座標系のため、
            // 直近capture角で重力由来の基準値のみバッファ座標系へ回転させる（未確定時は無回転）。
            captureAngleDegrees: lastKnownCaptureAngle.map { Double($0) }
        )
        // 判定が返した基準線ベクトルをそのまま表示へ受渡しする（単一解決、二重解決なし）。
        // analyze 済みでバッファ座標系（y上向き）の方向であり、変換は Overlay 側で点列と同一係数にて行う。
        snapshot.referenceVector = CGVector(dx: reference.x, dy: reference.y)

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

            if case .completed(let average, let averageDistance, let refSide, let refPoints, _, _) = progress {
                self.applyCalibrationCompletion(
                    referenceNearAngleDegrees: average,
                    referenceDistance: averageDistance,
                    referenceSide: refSide,
                    referencePoints: refPoints
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

    /// 校正完了時に基準値をスナップショットへ反映し監視フェーズへ遷移する。
    /// 遠側基準は構築しない（要件4.1: ロック側のみ。タスク13.1で削除）。
    /// テストは直接呼んで校正済み状態をシードできる。
    func applyCalibrationCompletion(
        referenceNearAngleDegrees: Double,
        referenceDistance: Double,
        referenceSide: Side,
        referencePoints: [CGPoint]
    ) {
        setPhase(.monitoring)
        motionService.start()
        rotationService?.start() // Motion起停と同一則
        snapshot.isMonitoringEnabled = true
        settingsStore.isMonitoringEnabled = true // 校正完了＝監視開始。復帰判定の単一ソース
        snapshot.referenceAngle = referenceNearAngleDegrees
        snapshot.referenceDistances = [referenceSide: referenceDistance]
        snapshot.referenceSide = referenceSide
        snapshot.referencePoints = referencePoints
    }

    /// セッションのフェーズの唯一の書き込み経路。
    /// wake lock 不変条件 `isIdleTimerDisabled == (phase == .monitoring)` を全遷移で強制する（要求 8.3/8.4、ADR 0016）。
    private func setPhase(_ phase: SessionPhase) {
        snapshot.phase = phase
        UIApplication.shared.isIdleTimerDisabled = (phase == .monitoring)
    }

}
