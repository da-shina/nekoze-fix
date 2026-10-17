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
    /// 時刻基準の推論間引き判定器 (vision-fps-throttle)。
    /// 全アクセスを `throttleLock` で直列化する（レビュー指摘 4241621567 対応）。
    /// captureOutput 先頭で判定し、対象外フレームを検出前に破棄する。
    /// 停止・再開時の初期化配送は `resetDetectionPipeline()` が担う（タスク 2.2）。
    /// 検出キューからの参照のため nonisolated とする（`var` のため冗長警告の対象外）。
    /// テストは @testable で直接操作する（単体テストが構造体を直接検証する）。
    nonisolated(unsafe) var frameThrottle = FrameThrottle()
    /// 判定器アクセスの単一の同期境界。検出・初期化・計測読出しの全経路で取得する。
    private let throttleLock = NSLock()
    /// Main受け渡し前段の三条件ゲートと単一スロットの錠付き保持器 (mainactor-throttle 3.1)。
    /// 申請（検出キュー）・初期化（`throttleResetQueue`）・フェーズ反映（Main の `setPhase`）・
    /// 計測読出し（Main）の全アクセスを単一の錠で直列化する（`throttleLock` と同一則）。
    /// 配送判定則自体は値型 `MainHopGate` に寄せ、本保持器は結線（軽量 view への変換・
    /// 単一スロットの最新保持・排出）に専念する。`PoseDetector` と同一則で
    /// `@unchecked Sendable` とする。参照自体は不変であり、
    /// nonisolated からの参照を許可する。
    nonisolated(unsafe) private(set) var hopGate = LockedMainHopGate()
    /// 判定パイプライン初期化の配送先 (vision-fps-throttle 2.2, requirements 6.1)。
    /// CameraSessionManager の検出キュー（sampleBuffer delegate queue）は同クラス内で
    /// private のため Session 側から直接配送できない。CameraSessionManager に手を入れず
    /// MainActor を block しないよう、Session 側で専用の直列キューを所有し async 配送する。
    /// 検出キュー・本キュー・計測読出し（Main）の三者間の競合は `throttleLock`
    /// で直列化するため、配送先キューが検出キューと別でも安全である。
    /// 将来 CameraSessionManager が検出キューを公開すれば本キューを置き換え、
    /// 飛行中判定との同一キュー直列化に格上げする。
    let throttleResetQueue = DispatchQueue(label: "com.nekozefix.session.throttleReset")
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
            startMetricsLogging()
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
        resetDetectionPipeline() // 再開直後の過剰破棄を防ぐ（2.2, requirements 6.1）
        smoothedPoints = []
        lastShoulderSeenTime = nil
        lastHeldKeypoints = [nil, nil, nil, nil]
        lastJointSeenTime = [nil, nil, nil, nil]
        Task {
            await startCameraPipeline()
            startMetricsLogging()
        }
    }

    /// 姿勢監視を開始する
    func startMonitoring() {
        setPhase(.monitoring)
        exitDimMode()
        restoreDimPowerToNormalIfNeeded() // 監視開始経路での通常戻し（3.2。非暗転時の段階乖離も正す）
        settingsStore.isMonitoringEnabled = true // 復帰判定の単一ソース（要求 8.2）
        // 監視開始時にゲートをリセットする
        snapshot.slouchGate.reset()
        resetDetectionPipeline() // 再開直後の過剰破棄を防ぐ（2.2, requirements 6.1）
        lastGateTickTime = nil
        setMotionRotationRunning(true)
        Task {
            await startCameraPipeline()
            startMetricsLogging()
        }
    }

    /// 姿勢監視を停止する（ユーザーの明示操作）
    func stopMonitoring() {
        setPhase(.idle)
        exitDimMode()
        restoreDimPowerToNormalIfNeeded() // 監視停止経路での通常戻し（3.2。非暗転時の段階乖離も正す）
        settingsStore.isMonitoringEnabled = false
        cameraManager.stop()
        resetDetectionPipeline() // 停止時の判定状態を初期化する（2.2, requirements 6.1）
        setMotionRotationRunning(false)
        stopMetricsLogging()
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
        resetDetectionPipeline() // 停止時の判定状態を初期化する（2.2, requirements 6.1）
        setMotionRotationRunning(false)
        stopMetricsLogging()
        if snapshot.phase == .monitoring || snapshot.phase == .calibrating {
            setPhase(.idle)
        }
    }

    /// フォアグラウンド復帰: 監視フラグ true かつ校正済みなら監視を再開する（要求 8.2）。
    /// 明示停止（フラグ false）・未校正・権限なしは停止状態を維持する。
    func handleWillEnterForeground() {
        // 復帰後は暗転解除（輝度復元）。監視再開の有無に関わらず行う
        exitDimMode()
        restoreDimPowerToNormalIfNeeded() // 復帰経路での通常戻し（3.2。再開しない場合も戻す）
        guard settingsStore.isMonitoringEnabled, snapshot.referenceAngle != nil else {
            return // 非監視のまま。不変条件は背面遷移時の setPhase(.idle) で OFF 済み
        }
        guard snapshot.phase == .idle else { return } // 校正中等进行中フェーズは触らない
        startMonitoring()
        // startMonitoring 内で startMetricsLogging が呼ばれる
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
        // 暗転段階へ進め、不在計測を起点からやり直した上で低下指示を適用する。
        applyDimPowerStage(dimPowerPolicy.dimmed())
        stopMetricsLogging()
    }

    /// ディムモードを終了する（輝度復元のみ。暗転解除後も自動スリープは復活しない — 要求 8.4）
    func exitDimMode() {
        guard snapshot.isDimmed else { return }
        if let brightness = savedBrightness {
            UIScreen.main.brightness = brightness
        }
        savedBrightness = nil
        snapshot.isDimmed = false
        // 復帰順序は輝度復元→通常段階→上限・頻度戻し（ADR-0024）。起停には触れない。
        // 全経路の一本化は restoreDimPowerToNormalIfNeeded に寄せる（3.2）。
        restoreDimPowerToNormalIfNeeded()
        // 監視中ならログ再開（idle 時は startMonitoring で再開される）
        if snapshot.phase == .monitoring || snapshot.phase == .calibrating {
            startMetricsLogging()
        }
    }

    // MARK: - 暗転省電力の段階連動（dim-mode-saving 3.1）

    /// 省電力段階方針。段階遷移則の所有は本値型に寄せ、
    /// 推論上限・取得頻度の具体値マッピングは Session 側定数が持つ（ADR-0024）。
    /// テストは @testable で段階の読取り・しきい値の注入を行う。
    var dimPowerPolicy = DimPowerPolicy()

    /// 段階別の推論上限マッピング（Session 所有・ADR-0024）。
    /// 長時間不在は上限据置きで更なる低下は実効実行数に委ねるため暗転と同値。
    private static func dimStageFPSLimit(for stage: DimPowerStage) -> Double {
        switch stage {
        case .normal: return 15.0
        case .dimmed, .dimmedAbsent: return 10.0
        }
    }

    /// 段階別の重力取得頻度マッピング（Session 所有・ADR-0024）。
    private static func dimStageMotionFrequency(for stage: DimPowerStage) -> MotionUpdateFrequency {
        switch stage {
        case .normal: return .thirtyHz
        case .dimmed: return .fifteenHz
        case .dimmedAbsent: return .tenHz
        }
    }

    /// 推論上限の同期適用コア。呼ぶのは検出キュー相当（`throttleResetQueue`）上のみ。
    /// 全アクセスは錠で直列化する（`resetDetectionPipelineState` と同一則）。
    private nonisolated func applyFPSLimitState(_ fps: Double) {
        throttleLock.withLock { frameThrottle.setLimit(fps) }
    }

    /// 段階に応じた上限・頻度の切替え指示。
    /// 推論上限は検出キュー相当へ async 配送し錠下で適用する（判定中の変更を起こさない）。
    /// 取得頻度は Main から直接指示し、停止中は次回開始時から反映する既存則に従う。
    /// 起停・開始停止状態には触れない。
    private func applyDimPowerStage(_ stage: DimPowerStage) {
        let fps = Self.dimStageFPSLimit(for: stage)
        throttleResetQueue.async { [weak self] in
            self?.applyFPSLimitState(fps)
        }
        motionService.setUpdateFrequency(Self.dimStageMotionFrequency(for: stage))
    }

    /// 復帰時戻しの一本化（dim-mode-saving 3.2）。
    /// 暗転解除・監視開始・監視停止・フォアグラウンド復帰の各経路から呼び、
    /// 段階が通常でなければ通常へ戻して上限・頻度を通常水準へ戻す。
    /// 輝度・暗転フラグ・センサー起停・フェーズには触れない（輝度復元は exitDimMode が先行して行う）。
    /// 既に通常なら何もしない（通常経路での Motion 再開などの副作用を起こさない）。
    private func restoreDimPowerToNormalIfNeeded() {
        guard dimPowerPolicy.stage != .normal else { return }
        _ = dimPowerPolicy.restored()
        applyDimPowerStage(.normal)
    }

    // MARK: - プライベートメソッド

    private func restartCameraPipeline() async {
        cameraManager.stop()
        resetDetectionPipeline() // 切替え時の古い判定状態を初期化する（2.2, requirements 6.1）
        snapshot.visualizationPoints = []
        smoothedPoints = []
        await startCameraPipeline()
        stopMetricsLogging()
        startMetricsLogging() // 計数初期化と対になる区間再開（4241621573 対応）
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

    /// 判定パイプラインの同期初期化コア (vision-fps-throttle 2.2, requirements 6.1)。
    /// 呼ぶのは初期化キュー上またはテストのみ。全アクセスは錠で直列化する。
    /// 順序の正本は「FrameThrottle.reset() → MainHopGate.reset()」であり、
    /// 本シーケンスの第二段でゲートの判定状態・スロット・計数を初期化する。
    nonisolated func resetDetectionPipelineState() {
        throttleLock.withLock { frameThrottle.reset() }
        hopGate.reset()
    }

    /// 判定パイプライン初期化の非同期配送ラッパ (vision-fps-throttle 2.2)。
    /// 停止・再開経路から呼び、`throttleResetQueue` へ async 配送して直列実行する。
    /// MainActor を block しないよう sync 配送は行わない。ラッパ自体は最小限に保ち、
    /// 振る舞いの検証点は `resetDetectionPipelineState()` に寄せる。
    func resetDetectionPipeline() {
        throttleResetQueue.async { [weak self] in
            self?.resetDetectionPipelineState()
        }
    }

    // MARK: - 計測用定期ログ (vision-fps-throttle 3.3)

    /// 計測用の定期ログタイマー。5秒ごとに FrameThrottle のスナップショットと導出 FPS を出力する。
    /// 本番ビルドでも有効（負荷は struct 複写と整数除算のみ）。プロセス内メモリのみ・永続化・外部送出なし。
    private var metricsLogTimer: Timer?

    /// 計測開始時刻（単調時計）。ログ開始時に記録し、経過秒の基準とする。
    private var metricsStartTime: TimeInterval = 0

    /// 判定分布の窓内計数（motion-frequency 5.1・判定一致検証用）。
    /// processDetection の確定分岐でのみ加算する（Main系列のみ・錠不要）。
    /// good/slouchCandidate/insufficientKeypoints＝analyze結果、absent/personOnly＝早期復帰。
    private var windowJudgeGood = 0
    private var windowJudgeSlouch = 0
    private var windowJudgeInsufficient = 0
    private var windowJudgeAbsent = 0
    private var windowJudgePersonOnly = 0

    /// 定期ログを開始する。監視開始・校正開始・暗転解除等の再開点から呼ぶ。
    /// Timer 稼働中は何もしない（区間の二重開始を防ぐ）。
    /// 開始時刻と計数を同一区間にそろえる（レビュー指摘 4241621573 対応）。
    func startMetricsLogging() {
        guard metricsLogTimer == nil else { return }
        metricsStartTime = CACurrentMediaTime()
        throttleLock.withLock { frameThrottle.resetCounts() }
        windowJudgeGood = 0
        windowJudgeSlouch = 0
        windowJudgeInsufficient = 0
        windowJudgeAbsent = 0
        windowJudgePersonOnly = 0
        motionService.startMeasuring(note: "freq=\(motionService.updateFrequency.shortLabel)")
        metricsLogTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.logMetricsSnapshot()
            }
        }
        RunLoop.current.add(metricsLogTimer!, forMode: .common)
    }

    /// 定期ログを停止する。監視停止・背景移行・暗転突入等の停止点から呼ぶ。
    func stopMetricsLogging() {
        metricsLogTimer?.invalidate()
        metricsLogTimer = nil
    }

    /// 現在の FrameThrottle スナップショットと導出 FPS を os_log へ出力する。
    /// 計測項目: 入力FPS(到達数/経過秒), 推論FPS(推論数/経過秒), 平均推論時間(累積/推論数), ドロップ率(破棄/到達), 残余時間(推論間隔-推論時間).
    /// 受け渡し計測（申請・配送・集約破棄・排出待ち）も同時に出力する。停止・再開で計数が
    /// 初期化されるため、長期記録（Req 7.1 の実測シナリオ用）は本定期ログの系列で追う。
    private func logMetricsSnapshot() {
        let (metrics, limit) = throttleLock.withLock { (frameThrottle.snapshot(), frameThrottle.maxFPS) }
        let hop = hopGate.snapshot()
        let elapsed = CACurrentMediaTime() - metricsStartTime
        let inputFPS = elapsed > 0 ? Double(metrics.arrivals) / elapsed : 0
        let inferFPS = elapsed > 0 ? Double(metrics.inferences) / elapsed : 0
        let avgInferenceTime = metrics.inferences > 0 ? metrics.totalInferenceTime / Double(metrics.inferences) : 0
        let dropRate = metrics.arrivals > 0 ? Double(metrics.drops) / Double(metrics.arrivals) : 0
        let frameInterval = inferFPS > 0 ? 1.0 / inferFPS : 0
        // 推論間の残余時間。キュー待ち時間ではない（待機列を持たない破棄設計のため
        // 真の待ち時間は計測不可。レビュー指摘 4241621575 対応で `estWait` から改名）。
        let inferenceResidual = max(0, frameInterval - avgInferenceTime)
        // motion-frequency区間計測（ADR-0023）: 本5秒窓の受信・公開値更新・読取りを同梱し、
        // 次窓の計測を直ちに再開する（計測は取得・判定に影響しない）。
        let motion = motionService.stopMeasuring()
        motionService.startMeasuring(note: "freq=\(motionService.updateFrequency.shortLabel)")
        // 判定分布の窓内計数を読取り・初期化する（motion-frequency 5.1・判定一致検証用）。
        let judge = "g\(windowJudgeGood)/s\(windowJudgeSlouch)/i\(windowJudgeInsufficient)/a\(windowJudgeAbsent)/p\(windowJudgePersonOnly)"
        windowJudgeGood = 0
        windowJudgeSlouch = 0
        windowJudgeInsufficient = 0
        windowJudgeAbsent = 0
        windowJudgePersonOnly = 0

        print("[NekozeFix Metrics] arrivals=\(metrics.arrivals) inferences=\(metrics.inferences) drops=\(metrics.drops) totalInferenceTime=\(String(format: "%.4f", metrics.totalInferenceTime))s inputFPS=\(String(format: "%.2f", inputFPS)) inferFPS=\(String(format: "%.2f", inferFPS)) avgInferTime=\(String(format: "%.4f", avgInferenceTime))s dropRate=\(String(format: "%.2f%%", dropRate * 100)) residual=\(String(format: "%.4f", inferenceResidual))s limitFPS=\(limit) hopSubmits=\(hop.submits) hopDelivers=\(hop.delivers) hopCoalesced=\(hop.coalesced) hopLastWait=\(String(format: "%.4f", hop.lastDrainWait))s motionFreq=\(motion.frequency.shortLabel) motionSecs=\(String(format: "%.1f", motion.duration))s motionSamples=\(motion.sampleCount) motionVisible=\(motion.visibleUpdateCount) motionReads=\(motion.readCount) motionInvalid=\(motion.invalidReadCount) motionNote=\(motion.conditionNote) judge=\(judge)")
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // 間引きゲート (vision-fps-throttle 2.1): 提示時刻の間隔基準で判定し、
        // 対象外フレームは検出実行前に破棄する。通過分のみ顔条件付き実行へ渡す
        // （順序「間引き→条件化」）。破棄時は snapshot 書込み・UI 更新を行わない。
        // 新規キュー・バッファ・蓄積は作らず、遅延破棄運用は AVFoundation 側のまま。
        let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let passed = throttleLock.withLock { frameThrottle.shouldInfer(at: timestamp) }
        guard passed else { return }

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
        // 推論所要時間を単調時計で実測し FrameThrottle へ記録する（判定器は時計を持たない）。
        let inferenceStart = CACurrentMediaTime()
        let detection = poseDetector.detect(sampleBuffer: sampleBuffer, orientation: .up)
        throttleLock.withLock {
            frameThrottle.recordInference(duration: CACurrentMediaTime() - inferenceStart)
        }

        // Main受け渡し前段の三条件ゲート (mainactor-throttle 3.1)。
        // 配送分のみ Main へ渡し、集約分は新規 Task を生成せず単一スロットに最新のみ保持する。
        // 排出時はスロットの最新（＝今回の検出結果）で判定継続と表示反映を一括で行い、
        // 古い中間結果の遅延反映を起こさない。事象駆動の受け渡し（回転角・カメラ確定・
        // 設定変更）は本ゲートを通さず現行のまま保つ。
        guard let pending = hopGate.submit(
            detection: detection,
            aspectRatio: imageAR,
            now: CACurrentMediaTime()
        ) else { return }

        Task { @MainActor in
            self.applyDeliveredAspectRatio(pending.aspectRatio)
            self.processDetection(pending.detection)
        }
    }

    /// 排出時の画面比率の反映 (mainactor-throttle 3.2)。
    /// 前回表示値から変化した場合のみ書き込み、不変時は省略して再描画 churn を抑える。
    /// 判定が参照する値（基準角・距離・近側・ゲート）には触れない。
    func applyDeliveredAspectRatio(_ newValue: CGFloat) {
        if shouldUpdateAspectRatio(newValue) {
            snapshot.videoAspectRatio = newValue
        }
    }

    /// 表示専用値の不変書込み省略の判定 (mainactor-throttle 3.2)。
    /// 許容誤差の定義と比較は受け渡し集約器と単一化する（`MainHopGate.aspectChanged`）。
    func shouldUpdateAspectRatio(_ newValue: CGFloat) -> Bool {
        MainHopGate.aspectChanged(snapshot.videoAspectRatio, newValue)
    }

    /// 検出結果を姿勢解析しセッション状態へ反映する（メインアクタ）。
    /// captureOutput の Task 本体。テストは合成フレームの Detection を直接投入できる。
    func processDetection(_ detection: PoseDetector.Detection) {
        // DEBUG 表示用の信頼度記録は毎フレーム取り直す（.pose 側で上書き）。
        snapshot.keypointConfidences = []
        // 人物なし（Body Pose 観測空 かつ 顔なし）
        if case .absent = detection {
            snapshot.isShoulderMissing = false
            windowJudgeAbsent += 1
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
            windowJudgePersonOnly += 1
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
        // 復元時も現向きの閾値を適用する（校正中の向き変更ではホールドが
        // リセットされないため、ランドスケープ保持の低信頼度点がポートレートに
        // 混入するのを防ぐ）。
        frame = holdingMissingKeypoints(
            frame,
            now: CACurrentMediaTime(),
            minimumConfidence: keypointConfidenceThreshold(isLandscape: snapshot.isLandscape)
        )

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

        // 最新公開値の読取りに参照記録を付随させる（motion-frequency Task 3・ADR-0023）。
        // 読取り則は不変（その時点の最新値を使用）。通知漏れがあっても判定には影響しない。
        let gravityForAnalysis = self.motionService.latestGravityInKeypointSpace
        self.motionService.noteConsumption(hasValue: gravityForAnalysis != nil)
        let (sample, verdict, resolvedReference) = self.postureAnalyzer.analyze(
            frame: frame,
            referenceNearAngleDegrees: refAngle,
            slouchDeltaThresholdDegrees: threshold,
            distanceMetric: distanceMetric,
            slouchDistanceThresholdPercent: self.settingsStore.slouchDistanceThresholdPercent,
            previousNearSide: snapshot.nearSide,
            gravityInKeypointSpace: gravityForAnalysis,
            // 重力はデバイス座標系・キーポイントは回転済みバッファ座標系のため、
            // 直近capture角で重力由来の基準値のみバッファ座標系へ回転させる（未確定時は無回転）。
            captureAngleDegrees: lastKnownCaptureAngle.map { Double($0) },
            // Analyzer 側のゲートにも向き別閾値を注入する（Session 事前フィルタと同値。
            // 注入なしでは Analyzer 内の 0.3 既定がランドスケープ緩和を無効化する）。
            minimumConfidence: keypointConfidenceThreshold(isLandscape: snapshot.isLandscape)
        )
        // 判定分布の窓内計数（motion-frequency 5.1）。
        switch verdict {
        case .good:
            windowJudgeGood += 1
        case .slouchCandidate:
            windowJudgeSlouch += 1
        case .insufficientKeypoints:
            windowJudgeInsufficient += 1
        }
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

        // dim-mode-saving 3.1: 不在駆動はデバウンス確定後の人物検出状態のみを入力する
        // （生検出は使わない）。監視フェーズ以外では不在計測を進めない
        // （policy 自体はフェーズ非依存）。段階遷移時のみ切替えを指示する。
        if self.snapshot.phase == .monitoring {
            let previousStage = dimPowerPolicy.stage
            let newStage = dimPowerPolicy.tick(isPersonDetected: self.snapshot.isPersonDetected, now: now)
            if newStage != previousStage {
                applyDimPowerStage(newStage)
            }
        }

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
        startFreqCycleIfEnabled() // MEASURE-TEMP2: 同一run内周波数サイクル（計測後に撤去）
    }

    /// 同一run内周波数サイクル（motion-frequency 5.1再検証用・TEMP）。
    /// `-measureFreqCycle` 付き起動でのみ動作する。校正完了を起点に
    /// 30→15→10→15→30Hzへ70秒ごとに切替え、各切替えをログに刻む。
    /// 同一校正基準・同一姿勢を3周波数で共有し、周波数効果を分離する。
    /// 計測後に本体ごと撤去する（呼出し側1行を含む）。
    private var freqCycleStarted = false
    private func startFreqCycleIfEnabled() {
        guard !freqCycleStarted else { return }
        guard ProcessInfo.processInfo.arguments.contains(where: { $0.contains("measureFreqCycle") }) else { return }
        freqCycleStarted = true
        print("[NekozeFix FreqCycle] step=0 freq=30Hz")
        let steps: [(TimeInterval, MotionUpdateFrequency)] = [(70, .fifteenHz), (70, .tenHz), (70, .fifteenHz), (70, .thirtyHz)]
        var delay: TimeInterval = 70
        for (index, step) in steps.enumerated() {
            Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.motionService.setUpdateFrequency(step.1)
                    print("[NekozeFix FreqCycle] step=\(index + 1) freq=\(step.1.shortLabel)")
                }
            }
            delay += step.0
        }
        Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            print("[NekozeFix FreqCycle] done")
        }
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
    /// 復元する保持点にも現向きの閾値を適用する（向き変更で混入した低信頼度点を排除）。
    private func holdingMissingKeypoints(_ frame: PoseFrame, now: TimeInterval, minimumConfidence: Double) -> PoseFrame {
        var frame = frame
        for (index, path) in Self.jointKeyPaths.enumerated() {
            if let current = frame[keyPath: path] {
                lastHeldKeypoints[index] = current
                lastJointSeenTime[index] = now
            } else if let held = lastHeldKeypoints[index],
                      held.confidence >= minimumConfidence,
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
    /// 受け渡しゲート用の軽量フェーズの鏡像もここで反映する（検出キューは snapshot に触れず鏡像のみ読む）。
    private func setPhase(_ phase: SessionPhase) {
        snapshot.phase = phase
        hopGate.setGatePhase(LockedMainHopGate.phase(of: phase))
        UIApplication.shared.isIdleTimerDisabled = (phase == .monitoring)
    }

}

/// Main受け渡し前段の三条件ゲートと単一スロットの錠付き保持器 (mainactor-throttle 3.1)。
///
/// `PostureSessionManager` が所有し、検出キュー（申請）・`throttleResetQueue`（初期化）・
/// Main（フェーズ反映・計測読出し）の全アクセスを単一の錠で直列化する
/// （`throttleLock` と同一則）。配送判定則自体は値型 `MainHopGate` に寄せる。
/// 構造体側は同期型のまま（単体テストは構造体を直接検証する）。
/// 錠で全状態を保護するため `@unchecked Sendable` とする
/// （`PoseDetector`・`CameraSessionManager` と同一則）。
final class LockedMainHopGate: @unchecked Sendable {
    /// 排出単位。配送時にスロットから取り出す最新の検出結果と画面比率。
    struct Pending {
        let detection: PoseDetector.Detection
        let aspectRatio: CGFloat
    }

    private let lock = NSLock()
    private var gate = MainHopGate()
    /// `setPhase` 経路が反映する軽量フェーズの鏡像。検出キューは snapshot に触れず本値を読む。
    /// 初期値は fail-open の `.calibrating`（初回反映前の判定機会を保つ）。
    private var gatePhase: GatePhase = .calibrating
    /// 単一スロット。集約分は最新のみ保持し、待機蓄積を作らない。
    private var slot: Pending?

    /// 検出結果をゲート用の軽量種別へ写像する（`PoseFrame` の中身は捨て、種別遷移の検出のみに用いる）。
    /// 判定継続に必要な検出内容自体はスロット側でそのまま保持する。
    static func kind(of detection: PoseDetector.Detection) -> DetectionKind {
        switch detection {
        case .pose: return .pose
        case .personOnly: return .personOnly
        case .absent: return .absent
        }
    }

    /// snapshot フェーズをゲート用の軽量フェーズへ写像する（校正中のみ全量配送対象）。
    static func phase(of phase: SessionPhase) -> GatePhase {
        phase == .calibrating ? .calibrating : .monitoring
    }

    /// 配送可否を判定する。申請は常にスロットへ最新として保持した上で判定し、
    /// 配送時はスロットの最新（＝今回申請）を排出して返す。集約時は nil を返す。
    func submit(detection: PoseDetector.Detection, aspectRatio: CGFloat, now: TimeInterval) -> Pending? {
        lock.withLock {
            slot = Pending(detection: detection, aspectRatio: aspectRatio)
            let decision = gate.submit(
                kind: Self.kind(of: detection),
                phase: gatePhase,
                aspectRatio: aspectRatio,
                at: now
            )
            guard decision == .deliver else { return nil }
            let pending = slot
            slot = nil
            return pending
        }
    }

    /// Main の `setPhase` 経路から軽量フェーズを反映する。
    func setGatePhase(_ phase: GatePhase) {
        lock.withLock { gatePhase = phase }
    }

    /// ゲートの判定状態・スロット・計数を初期化する（停止・再開経路から配送される）。
    func reset() {
        lock.withLock {
            gate.reset()
            slot = nil
        }
    }

    /// 計測値を値複写で読み出す。検出結果には影響しない。
    func snapshot() -> MainHopGate.Metrics {
        lock.withLock { gate.snapshot() }
    }

    /// スロットの占有数（0/1）。待機蓄積を作らないことの検証点。
    var pendingCount: Int {
        lock.withLock { slot == nil ? 0 : 1 }
    }
}
