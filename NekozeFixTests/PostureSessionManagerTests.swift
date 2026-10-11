import XCTest
import Combine
@testable import NekozeFix

@MainActor
final class PostureSessionManagerTests: XCTestCase {
    var sut: PostureSessionManager!
    private var suite: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "PostureSessionManagerTests")!
        suite.removePersistentDomain(forName: "PostureSessionManagerTests")
        sut = PostureSessionManager(settingsStore: SettingsStore(defaults: suite))
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: "PostureSessionManagerTests")
        suite = nil
        sut = nil
        super.tearDown()
    }

    // MARK: - フェーズ遷移

    func testDefaultPhase_isIdle() {
        // 初回起動はスプラッシュ (idle) で待機し、タップで bootstrap → 校正へ進む。
        XCTAssertEqual(sut.snapshot.phase, .idle)
    }

    func testStartCalibration_changesPhaseToCalibrating() {
        sut.startCalibration()
        XCTAssertEqual(sut.snapshot.phase, .calibrating)
    }

    func testRecalibrate_changesPhaseToCalibrating() {
        sut.startCalibration()
        XCTAssertEqual(sut.snapshot.phase, .calibrating)
    }

    func testStartMonitoring_changesPhaseToMonitoring() {
        sut.startMonitoring()
        XCTAssertEqual(sut.snapshot.phase, .monitoring)
    }

    func testStopMonitoring_changesPhaseToIdle() {
        sut.startMonitoring()
        sut.stopMonitoring()
        XCTAssertEqual(sut.snapshot.phase, .idle)
    }

    func testEnterDimMode_setsIsDimmedTrue() {
        sut.enterDimMode()
        XCTAssertTrue(sut.snapshot.isDimmed)
    }

    func testExitDimMode_setsIsDimmedFalse() {
        sut.enterDimMode()
        sut.exitDimMode()
        XCTAssertFalse(sut.snapshot.isDimmed)
    }

    // MARK: - 姿勢更新（processDetection 経由で不変条件を維持）

    func testProcessDetection_absent_showsPersonMissing() {
        sut.applyCalibrationCompletion(
            referenceNearAngleDegrees: 45.0, referenceDistance: 0.2, referenceSide: .left, referencePoints: [], referenceSource: nil
        )
        sut.processDetection(.absent)
        XCTAssertEqual(sut.snapshot.displayedPosture, .personMissing)
    }

    func testProcessDetection_withPose_updatesVisualizationPoints() {
        sut.applyCalibrationCompletion(
            referenceNearAngleDegrees: 45.0, referenceDistance: 0.2, referenceSide: .left, referencePoints: [], referenceSource: nil
        )
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.3, y: 0.4, confidence: 0.9),
            rightEar: Keypoint(x: 0.7, y: 0.4, confidence: 0.9),
            leftShoulder: Keypoint(x: 0.4, y: 0.7, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.6, y: 0.7, confidence: 0.9)
        )
        sut.processDetection(.pose(frame))
        XCTAssertTrue(sut.snapshot.isPersonDetected)
        // 可視化ポイントが更新されている（.zero 以外の値が含まれる）
        let nonZero = sut.snapshot.visualizationPoints.filter { $0 != .zero }
        XCTAssertFalse(nonZero.isEmpty, "ポーズ検出で可視化ポイントが更新される")
    }

    // MARK: - 人物検出

    func testProcessDetection_personDetected_setsFlag() {
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.3, y: 0.4, confidence: 0.9),
            rightEar: nil,
            leftShoulder: Keypoint(x: 0.4, y: 0.7, confidence: 0.9),
            rightShoulder: nil
        )
        sut.startCalibration()
        sut.processDetection(.pose(frame))
        XCTAssertTrue(sut.snapshot.isPersonDetected)
    }

    func testProcessDetection_absent_clearsFlag() {
        sut.startCalibration()
        sut.processDetection(.absent)
        XCTAssertFalse(sut.snapshot.isPersonDetected)
    }

    // MARK: - 監視有効化

    func testStartMonitoring_setsFlag() {
        sut.startMonitoring()
        XCTAssertTrue(sut.settingsStore.isMonitoringEnabled)
    }

    func testStopMonitoring_clearsFlag() {
        sut.startMonitoring()
        sut.stopMonitoring()
        XCTAssertFalse(sut.settingsStore.isMonitoringEnabled)
    }

    // MARK: - フェーズ遷移（setPhase 不変条件の検証）

    // 回転中状態値は除去済み（ios17-baseline 3.5）。回転過渡の停止は
    // 自動再校正経路に一本化され、wake lock 不変条件
    // `isIdleTimerDisabled == (phase == .monitoring)` で強制される。
    // 本テストは監視停止後の退避で .idle へ戻り OFF になることを確認する。
    func testRotationTransient_unifiedAutoRecalibrationPath_restoresIdleTimerDisabled() {
        // 自動再校正への一本化により旧経由の停止は存在しないが、
        // 監視停止後の退避で .idle へ戻ることで isIdleTimerDisabled == false を確認できる
        sut.startMonitoring()
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        sut.stopMonitoring()
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled, "idle では wake lock OFF")
    }

    func testSetPhase_permissionDenied_disablesIdleTimer() {
        sut.startMonitoring()
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        // permissionDenied 遷移は bootstrap 経由のみ
        // 停止で idle に戻り wake lock が OFF になることを確認
        sut.stopMonitoring()
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
    }

    // MARK: - ライフサイクル自動停止・復帰（要求 8.1/8.2、タスク3.5）

    /// 背面移行: 監視中なら idle に退避し、監視フラグ（復帰判定用）は維持する
    func testDidEnterBackground_duringMonitoring_movesToIdleKeepingFlag() {
        sut.applyCalibrationCompletion(
            referenceNearAngleDegrees: 45.0, referenceDistance: 0.2, referenceSide: .left, referencePoints: [], referenceSource: nil
        )
        XCTAssertTrue(sut.settingsStore.isMonitoringEnabled, "校正完了で監視遷移時はフラグ true")

        sut.handleDidEnterBackground()
        XCTAssertEqual(sut.snapshot.phase, .idle)
        XCTAssertTrue(sut.settingsStore.isMonitoringEnabled, "自動停止はユーザーストップではないのでフラグ維持")
    }

    /// 復帰: 監視フラグ true かつ校正済みなら監視を再開
    func testWillEnterForeground_resumesMonitoringWhenCalibrated() {
        sut.applyCalibrationCompletion(
            referenceNearAngleDegrees: 45.0, referenceDistance: 0.2, referenceSide: .left, referencePoints: [], referenceSource: nil
        )
        sut.handleDidEnterBackground()
        XCTAssertEqual(sut.snapshot.phase, .idle)

        sut.handleWillEnterForeground()
        XCTAssertEqual(sut.snapshot.phase, .monitoring)
    }

    /// 復帰: ユーザーが明示停止（フラグ false）した場合は停止状態を維持（要求 8.2）
    func testWillEnterForeground_keepsIdleAfterExplicitStop() {
        sut.applyCalibrationCompletion(
            referenceNearAngleDegrees: 45.0, referenceDistance: 0.2, referenceSide: .left, referencePoints: [], referenceSource: nil
        )
        sut.stopMonitoring()
        XCTAssertFalse(sut.settingsStore.isMonitoringEnabled)

        sut.handleDidEnterBackground()
        sut.handleWillEnterForeground()
        XCTAssertEqual(sut.snapshot.phase, .idle, "明示停止後の復帰は停止維持")
    }

    /// 復帰: 未校正（referenceAngle なし）では監視へ戻さない
    func testWillEnterForeground_withoutCalibration_staysIdle() {
        sut.startMonitoring() // 未经校正：監視フラグは true だが referenceAngle は nil
        sut.handleDidEnterBackground()
        sut.handleWillEnterForeground()
        XCTAssertEqual(sut.snapshot.phase, .idle)
    }

    /// 復帰: 暗転中だった場合は監視再開の有無に関わらず暗転解除する（design.md Q24 改訂）
    func testWillEnterForeground_whileDimmed_clearsDim() {
        sut.applyCalibrationCompletion(
            referenceNearAngleDegrees: 45.0, referenceDistance: 0.2, referenceSide: .left, referencePoints: [], referenceSource: nil
        )
        sut.enterDimMode()
        XCTAssertTrue(sut.snapshot.isDimmed)

        sut.handleDidEnterBackground()
        XCTAssertTrue(sut.snapshot.isDimmed, "背面移行中は暗転フラグを維持")
        sut.handleWillEnterForeground()
        XCTAssertFalse(sut.snapshot.isDimmed, "復帰後に暗転解除")
    }

    /// 監視開始・停止が SettingsStore の監視フラグを反映する（復帰判定の単一ソース）
    func testStartStopMonitoring_syncsSettingsFlag() {
        sut.stopMonitoring()
        XCTAssertFalse(sut.settingsStore.isMonitoringEnabled)
        sut.startMonitoring()
        XCTAssertTrue(sut.settingsStore.isMonitoringEnabled)
    }

    // MARK: - 監視中の自動スリープ抑止（要件 8.3/8.4 改訂、タスク10.1、ADR 0016）
    // 不変条件: isIdleTimerDisabled == (phase == .monitoring)

    /// 監視開始で ON、監視停止で OFF（8.3 改訂: 抑止は監視中に限定）
    func testStartStopMonitoring_togglesIdleTimerDisabled() {
        UIApplication.shared.isIdleTimerDisabled = false
        sut.startMonitoring()
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled, "監視開始で wake lock ON")
        sut.stopMonitoring()
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled, "監視停止で OS 標準へ復元")
    }

    /// 非監視フェーズ（校正中・idle）は抑止しない（8.4 改訂）
    func testNonMonitoringPhases_doNotEnableIdleTimerDisabled() {
        UIApplication.shared.isIdleTimerDisabled = true
        sut.startCalibration()
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled, "校正中は wake lock OFF")
        UIApplication.shared.isIdleTimerDisabled = true
        sut.stopMonitoring()
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled, "idle は wake lock OFF")
    }

    /// 監視中の暗転 enter/exit は点灯を維持する（8.4: 暗転の解除操作と無関係）
    func testDimModeDuringMonitoring_keepsIdleTimerDisabled() {
        UIApplication.shared.isIdleTimerDisabled = false
        sut.startMonitoring()
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        sut.enterDimMode()
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled, "enterDimMode で抑止は継続")
        sut.exitDimMode()
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled, "exitDimMode で自動スリープは復活しない")
    }

    /// 監視中の退避で OFF、復帰して再開すれば ON（8.3）
    func testBackgroundDuringMonitoring_disablesAndForegroundResumeReenables() {
        sut.applyCalibrationCompletion(
            referenceNearAngleDegrees: 45.0, referenceDistance: 0.2, referenceSide: .left, referencePoints: [], referenceSource: nil
        )
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled, "校正完了＝監視開始で ON")
        sut.handleDidEnterBackground()
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled, "退避で OS 標準へ復元")
        sut.handleWillEnterForeground()
        XCTAssertEqual(sut.snapshot.phase, .monitoring)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled, "監視再開で ON 復帰")
    }

    /// 明示停止状態からの復帰（監視を再開しない）は OFF のまま（8.3 改訂: アクティブでも非監視は抑止しない）
    func testForegroundResumeWithoutMonitoring_keepsIdleTimerDisabledOff() {
        UIApplication.shared.isIdleTimerDisabled = false
        sut.handleWillEnterForeground() // 未校正・フラグ false → 監視再開しない
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
    }

    // MARK: - Motion所有・起停（要件 2.7/3.1/6.2/8.1/8.2、タスク13.1）

    /// 監視開始で傾き取得を開始する（要求 3.1）
    func testStartMonitoring_startsMotionService() {
        XCTAssertFalse(sut.motionService.isRunning)
        sut.startMonitoring()
        XCTAssertTrue(sut.motionService.isRunning, "監視開始で Motion 開始")
    }

    /// 監視停止で傾き取得を停止し、保持重力を破棄する（要求 3.1）
    func testStopMonitoring_stopsMotionServiceAndClearsGravity() {
        sut.startMonitoring()
        sut.motionService.latestGravityInKeypointSpace = SIMD2<Double>(0, 1)
        sut.stopMonitoring()
        XCTAssertFalse(sut.motionService.isRunning, "監視停止で Motion 停止")
        XCTAssertNil(sut.motionService.latestGravityInKeypointSpace, "停止で保持値を破棄")
    }

    /// 校正開始で傾き取得を開始する（要求 2.7: 校正は天方向基準で登録）
    func testStartCalibration_startsMotionService() {
        XCTAssertFalse(sut.motionService.isRunning)
        sut.startCalibration()
        XCTAssertTrue(sut.motionService.isRunning, "校正開始で Motion 開始")
    }

    /// 暗転中も傾き取得は継続する（要求 6.2: enter/exit ともに起停しない）
    func testDimMode_keepsMotionServiceRunning() {
        sut.startMonitoring()
        XCTAssertTrue(sut.motionService.isRunning)
        sut.enterDimMode()
        XCTAssertTrue(sut.motionService.isRunning, "暗転中も Motion 継続")
        sut.exitDimMode()
        XCTAssertTrue(sut.motionService.isRunning, "暗転解除後も Motion 継続")
    }

    /// 背景移行で傾き取得を停止する（要求 8.1）
    func testDidEnterBackground_stopsMotionService() {
        sut.applyCalibrationCompletion(
            referenceNearAngleDegrees: 45.0, referenceDistance: 0.2, referenceSide: .left, referencePoints: [], referenceSource: nil
        )
        XCTAssertTrue(sut.motionService.isRunning, "校正完了＝監視開始で Motion 開始")
        sut.motionService.latestGravityInKeypointSpace = SIMD2<Double>(0, 1)
        sut.handleDidEnterBackground()
        XCTAssertFalse(sut.motionService.isRunning, "背景移行で Motion 停止")
        XCTAssertNil(sut.motionService.latestGravityInKeypointSpace, "背景移行で保持値を破棄")
    }

    /// 復帰して監視再開すれば傾き取得も再開する（要求 8.2）
    func testWillEnterForeground_resumesMotionService() {
        sut.applyCalibrationCompletion(
            referenceNearAngleDegrees: 45.0, referenceDistance: 0.2, referenceSide: .left, referencePoints: [], referenceSource: nil
        )
        sut.handleDidEnterBackground()
        XCTAssertFalse(sut.motionService.isRunning)
        sut.handleWillEnterForeground()
        XCTAssertEqual(sut.snapshot.phase, .monitoring)
        XCTAssertTrue(sut.motionService.isRunning, "監視再開で Motion 再開")
    }

    // MARK: - 向き別の信頼度フィルタ（要件4.6）

    /// 境界値 0.12 の肩: ランドスケープ (0.1) では保持される。
    func testConfidenceThreshold_landscape_keepsLowConfidenceShoulder() {
        var snapshot = SessionSnapshot()
        snapshot.isLandscape = true
        let manager = PostureSessionManager(settingsStore: SettingsStore(defaults: suite), snapshot: snapshot)
        manager.processDetection(.pose(testFrame(shoulderConfidence: 0.12)))
        XCTAssertNotEqual(manager.snapshot.visualizationPoints[0], .zero, "landscape は 0.12 の肩を保持する")
    }

    /// 境界値 0.12 の肩: ポートレート (0.3) では落とされる。耳 (0.9) は残る。
    func testConfidenceThreshold_portrait_dropsLowConfidenceShoulder() {
        var snapshot = SessionSnapshot()
        snapshot.isLandscape = false
        let manager = PostureSessionManager(settingsStore: SettingsStore(defaults: suite), snapshot: snapshot)
        manager.processDetection(.pose(testFrame(shoulderConfidence: 0.12)))
        XCTAssertEqual(manager.snapshot.visualizationPoints[0], .zero, "portrait は 0.12 の肩を落とす")
        XCTAssertNotEqual(manager.snapshot.visualizationPoints[2], .zero, "0.9 の耳は残る")
    }

    /// DEBUG 表示用にフィルタ前の生信頼度 [左耳, 右耳, 左肩, 右肩] を記録する。
    func testProcessDetection_recordsRawKeypointConfidences() {
        sut.processDetection(.pose(testFrame(shoulderConfidence: 0.12)))
        XCTAssertEqual(sut.snapshot.keypointConfidences, [0.9, nil, 0.12, nil])
    }

    /// 人物なしでは信頼度記録を空にする。
    func testProcessDetection_absent_clearsKeypointConfidences() {
        sut.processDetection(.pose(testFrame(shoulderConfidence: 0.12)))
        sut.processDetection(.absent)
        XCTAssertEqual(sut.snapshot.keypointConfidences, [])
    }

    // MARK: - キーポイント瞬断ホールド

    /// 肩が1フレーム欠測しても直近値を保持する（チラつき対策）。
    func testKeypointHold_holdsMissingShoulder() {
        sut.processDetection(.pose(testFrame(shoulderConfidence: 0.9)))
        XCTAssertNotEqual(sut.snapshot.visualizationPoints[0], .zero)
        var dropped = testFrame(shoulderConfidence: 0.9)
        dropped.leftShoulder = nil
        sut.processDetection(.pose(dropped))
        XCTAssertNotEqual(sut.snapshot.visualizationPoints[0], .zero, "猶予内は直近の肩を保持する")
    }

    /// 校正中の向き変更ではホールドがリセットされないため、復元時も現向きの閾値を適用する。
    /// ランドスケープ保持の 0.12 の肩はポートレートに戻すと復元されない。
    func testHold_appliesCurrentOrientationThresholdAfterRotation() {
        var snapshot = SessionSnapshot()
        snapshot.isLandscape = true
        let manager = PostureSessionManager(settingsStore: SettingsStore(defaults: suite), snapshot: snapshot)
        manager.processDetection(.pose(testFrame(shoulderConfidence: 0.12)))
        XCTAssertNotEqual(manager.snapshot.visualizationPoints[0], .zero)
        // 校正中の回転（portrait 角）に切り替える。リセット対象外のためホールドは残る。
        manager.handleRotationAngleChange(preview: 90, capture: 90)
        XCTAssertFalse(manager.snapshot.isLandscape)
        var dropped = testFrame(shoulderConfidence: 0.12)
        dropped.leftShoulder = nil
        manager.processDetection(.pose(dropped))
        XCTAssertEqual(manager.snapshot.visualizationPoints[0], .zero, "ポートレートでは 0.12 の保持点を復元しない")
    }

    /// 人物不在ではホールドを破棄する（不在前の点を別人の判定に使わない）。
    func testAbsent_clearsKeypointHold() {
        sut.processDetection(.pose(testFrame(shoulderConfidence: 0.9)))
        sut.processDetection(.absent)
        var dropped = testFrame(shoulderConfidence: 0.9)
        dropped.leftShoulder = nil
        sut.processDetection(.pose(dropped))
        XCTAssertEqual(sut.snapshot.visualizationPoints[0], .zero, "不在後は保持しない")
    }

    /// 猶予（0.5秒）超過後の欠測は破棄する（古い値を使い続けない）。
    func testKeypointHold_releasesAfterGracePeriod() {
        sut.processDetection(.pose(testFrame(shoulderConfidence: 0.9)))
        Thread.sleep(forTimeInterval: 0.6)
        var dropped = testFrame(shoulderConfidence: 0.9)
        dropped.leftShoulder = nil
        sut.processDetection(.pose(dropped))
        XCTAssertEqual(sut.snapshot.visualizationPoints[0], .zero, "猶予超過は破棄する")
    }

    // MARK: - 間引きゲート結線 (vision-fps-throttle 2.1)

    /// 初回フレームは推論対象（ゲート開放）。
    func testThrottleGate_firstFrame_passes() {
        XCTAssertTrue(sut.shouldInferFrame(at: 100.0))
    }

    /// 上限間隔未満の後続フレームは破棄対象（detect に到達させない）。
    func testThrottleGate_rapidSuccessor_drops() {
        XCTAssertTrue(sut.shouldInferFrame(at: 100.0))
        XCTAssertFalse(sut.shouldInferFrame(at: 100.01))
    }

    /// 通過フレームのみが条件化へ渡る順序を保つ（破棄は前回推論時刻を進めない）。
    func testThrottleGate_droppedFrame_doesNotAdvanceBaseline() {
        let interval = 1.0 / FrameThrottle.defaultMaxFPS
        XCTAssertTrue(sut.shouldInferFrame(at: 100.0))
        XCTAssertFalse(sut.shouldInferFrame(at: 100.0 + interval / 2))
        XCTAssertTrue(sut.shouldInferFrame(at: 100.0 + interval))
    }

    /// 無効時刻は実行側に倒す（検出欠落を起こさない）。
    func testThrottleGate_invalidTimestamp_failsOpen() {
        XCTAssertTrue(sut.shouldInferFrame(at: Double.nan))
        XCTAssertTrue(sut.shouldInferFrame(at: -1.0))
    }

    /// 計数がゲート判定を反映する（到達・推論・破棄の区別）。
    func testThrottleGate_metrics_reflectGateDecisions() {
        XCTAssertTrue(sut.shouldInferFrame(at: 100.0))
        XCTAssertFalse(sut.shouldInferFrame(at: 100.01))
        let metrics = sut.frameThrottle.snapshot()
        XCTAssertEqual(metrics.arrivals, 2)
        XCTAssertEqual(metrics.inferences, 1)
        XCTAssertEqual(metrics.drops, 1)
    }

    // MARK: - 停止・再開時の判定パイプライン初期化 (vision-fps-throttle 2.2, requirements 6.1)

    /// 同期コア: 判定状態と計数をクリアし、次フレームが推論対象になる（再開直後の過剰破棄なし）。
    func testResetDetectionPipelineState_clearsGateAndCounters() {
        XCTAssertTrue(sut.shouldInferFrame(at: 100.0))
        XCTAssertFalse(sut.shouldInferFrame(at: 100.01))
        sut.resetDetectionPipelineState()
        let metrics = sut.frameThrottle.snapshot()
        XCTAssertEqual(metrics.arrivals, 0)
        XCTAssertEqual(metrics.inferences, 0)
        XCTAssertEqual(metrics.drops, 0)
        XCTAssertEqual(metrics.totalInferenceTime, 0.0, accuracy: 1e-9)
        XCTAssertTrue(sut.shouldInferFrame(at: 100.01), "初期化直後は同一時刻でも推論対象になる")
    }

    /// 同期コア: 初期化は上限設定を変えない（再開後に制限値が維持される）。
    func testResetDetectionPipelineState_preservesMaxFPS() {
        XCTAssertTrue(sut.shouldInferFrame(at: 100.0))
        let before = sut.frameThrottle.maxFPS
        sut.resetDetectionPipelineState()
        XCTAssertEqual(sut.frameThrottle.maxFPS, before)
    }

    /// 停止経路: stopMonitoring が検出キューへ初期化を配送する。
    func testStopMonitoring_dispatchesThrottleReset() {
        XCTAssertTrue(sut.shouldInferFrame(at: 100.0))
        XCTAssertFalse(sut.shouldInferFrame(at: 100.01))
        sut.stopMonitoring()
        sut.throttleResetQueue.sync {}
        XCTAssertEqual(sut.frameThrottle.snapshot().arrivals, 0)
        XCTAssertTrue(sut.shouldInferFrame(at: 100.01), "停止で初期化され再開直後の過剰破棄がない")
    }

    /// 停止経路: 背景移行が検出キューへ初期化を配送する。
    func testDidEnterBackground_dispatchesThrottleReset() {
        XCTAssertTrue(sut.shouldInferFrame(at: 100.0))
        XCTAssertFalse(sut.shouldInferFrame(at: 100.01))
        sut.handleDidEnterBackground()
        sut.throttleResetQueue.sync {}
        XCTAssertEqual(sut.frameThrottle.snapshot().arrivals, 0)
        XCTAssertTrue(sut.shouldInferFrame(at: 100.01), "背景停止で初期化され復帰直後の過剰破棄がない")
    }

    /// 再開経路: startMonitoring が検出キューへ初期化を配送する。
    func testStartMonitoring_dispatchesThrottleReset() {
        XCTAssertTrue(sut.shouldInferFrame(at: 100.0))
        XCTAssertFalse(sut.shouldInferFrame(at: 100.01))
        sut.startMonitoring()
        sut.throttleResetQueue.sync {}
        XCTAssertEqual(sut.frameThrottle.snapshot().arrivals, 0)
        XCTAssertTrue(sut.shouldInferFrame(at: 100.01), "開始で初期化され古い状態による判定の乱れがない")
    }

    /// 再開経路: startCalibration が検出キューへ初期化を配送する。
    func testStartCalibration_dispatchesThrottleReset() {
        XCTAssertTrue(sut.shouldInferFrame(at: 100.0))
        XCTAssertFalse(sut.shouldInferFrame(at: 100.01))
        sut.startCalibration()
        sut.throttleResetQueue.sync {}
        XCTAssertEqual(sut.frameThrottle.snapshot().arrivals, 0)
        XCTAssertTrue(sut.shouldInferFrame(at: 100.01), "校正開始で初期化され古い状態による判定の乱れがない")
    }

    // MARK: - 結線と判定非回帰の結合検証 (vision-fps-throttle 3.2)

    /// 条件化は間引き計数へ逆流しない（順序は間引き→条件化の一方通行。requirements 2.4）。
    func testThrottleOrder_conditioningDoesNotTouchThrottleCounters() {
        sut.applyCalibrationCompletion(
            referenceNearAngleDegrees: 45.0, referenceDistance: 0.2, referenceSide: .left, referencePoints: [], referenceSource: nil
        )
        sut.processDetection(.pose(testFrame(shoulderConfidence: 0.9)))
        sut.processDetection(.absent)
        let metrics = sut.frameThrottle.snapshot()
        XCTAssertEqual(metrics.arrivals, 0, "条件化は到達計数へ触れない")
        XCTAssertEqual(metrics.inferences, 0, "条件化は推論計数へ触れない")
        XCTAssertEqual(metrics.drops, 0, "条件化は破棄計数へ触れない")
    }

    /// ゲート判定はセッション状態を変えない（破棄フレームは snapshot 書込みなし。requirements 2.4/6.4）。
    func testThrottleOrder_gateDecisionDoesNotMutateSnapshot() {
        let before = sut.snapshot
        XCTAssertTrue(sut.shouldInferFrame(at: 100.0))
        XCTAssertFalse(sut.shouldInferFrame(at: 100.01))
        XCTAssertEqual(sut.snapshot, before, "間引き判定はセッション状態へ副作用を持たない")
    }

    /// 背面移行は非監視時も判定状態を初期化する（停止経路の無条件初期化。requirements 6.1）。
    func testDidEnterBackground_whenIdle_stillResetsThrottle() {
        XCTAssertTrue(sut.shouldInferFrame(at: 100.0))
        XCTAssertFalse(sut.shouldInferFrame(at: 100.01))
        XCTAssertEqual(sut.snapshot.phase, .idle)
        sut.handleDidEnterBackground()
        sut.throttleResetQueue.sync {}
        XCTAssertEqual(sut.frameThrottle.snapshot().arrivals, 0, "idle 時の背景移行でも初期化する")
        XCTAssertTrue(sut.shouldInferFrame(at: 100.01), "初期化直後は同一時刻でも推論対象になる")
    }

    /// 間引き下でも猫背3秒連続で確定し、回復で即改善する（時刻駆動の証明。requirements 4.1/4.2）。
    /// 10fps相当間隔（100ms）で投入し、ネイティブ60fps換算の回数基準（180）より
    /// 大幅に少ないフレーム数で確定することを数えて示す（回数基準なら確定しない）。
    func testThrottledRate_slouchStillConfirmsAfter3SecondsAndRecovers() {
        sut.applyCalibrationCompletion(
            referenceNearAngleDegrees: 0.0, referenceDistance: 0.18, referenceSide: .right, referencePoints: [], referenceSource: nil
        )
        for _ in 0..<3 {
            sut.processDetection(.pose(throttledRateFrame(rightEarDistance: 0.18)))
        }
        XCTAssertEqual(sut.snapshot.displayedPosture, .good, "基準比100%は良好")

        let deadline = Date().addingTimeInterval(15)
        var fedFrames = 0
        while !sut.snapshot.slouchGate.isFired && Date() < deadline {
            sut.processDetection(.pose(throttledRateFrame(rightEarDistance: 0.21)))
            fedFrames += 1
            usleep(100_000) // 10fps相当間隔（間引き通過レートの再現）
        }
        XCTAssertTrue(sut.snapshot.slouchGate.isFired, "間引き下でも猫背3秒連続で確定する")
        XCTAssertEqual(sut.snapshot.displayedPosture, .slouch)
        XCTAssertLessThan(fedFrames, 60, "確定は時刻駆動であり到達回数に依存しない")

        for _ in 0..<5 {
            sut.processDetection(.pose(throttledRateFrame(rightEarDistance: 0.18)))
        }
        XCTAssertEqual(sut.snapshot.displayedPosture, .good, "全指標閾値未満で即改善")
        XCTAssertFalse(sut.snapshot.slouchGate.isFired, "改善で確定ゲート解除")
    }

    /// 間引き下でも人物不在の猶予（0.5秒）が時刻基準で働く（requirements 4.3）。
    func testThrottledRate_personMissingGraceSurvivesThinning() {
        sut.applyCalibrationCompletion(
            referenceNearAngleDegrees: 0.0, referenceDistance: 0.18, referenceSide: .right, referencePoints: [], referenceSource: nil
        )
        sut.processDetection(.pose(throttledRateFrame(rightEarDistance: 0.18)))
        XCTAssertTrue(sut.snapshot.isPersonDetected)

        // 10fps相当間隔で不在を0.3秒 → 猶予内は検出維持
        for _ in 0..<3 {
            usleep(100_000)
            sut.processDetection(.absent)
        }
        XCTAssertTrue(sut.snapshot.isPersonDetected, "0.5秒猶予内は不在をノイズ扱い")

        // 計0.7秒 → 不在確定
        for _ in 0..<4 {
            usleep(100_000)
            sut.processDetection(.absent)
        }
        XCTAssertFalse(sut.snapshot.isPersonDetected, "猶予超過で不在確定")
        XCTAssertEqual(sut.snapshot.displayedPosture, .personMissing)
    }

    /// 間引き下でもキーポイントホールドの猶予（0.5秒）が時刻基準で働く（requirements 4.3）。
    func testThrottledRate_keypointHoldGraceSurvivesThinning() {
        sut.processDetection(.pose(testFrame(shoulderConfidence: 0.9)))
        XCTAssertNotEqual(sut.snapshot.visualizationPoints[0], .zero)

        // 10fps相当間隔で肩欠測を0.3秒 → 猶予内は保持
        for _ in 0..<3 {
            usleep(100_000)
            var dropped = testFrame(shoulderConfidence: 0.9)
            dropped.leftShoulder = nil
            sut.processDetection(.pose(dropped))
        }
        XCTAssertNotEqual(sut.snapshot.visualizationPoints[0], .zero, "猶予内は間引き下でも直近の肩を保持する")

        // 計0.7秒 → 破棄
        for _ in 0..<4 {
            usleep(100_000)
            var dropped = testFrame(shoulderConfidence: 0.9)
            dropped.leftShoulder = nil
            sut.processDetection(.pose(dropped))
        }
        XCTAssertEqual(sut.snapshot.visualizationPoints[0], .zero, "猶予超過は間引き下でも破棄する")
    }

    /// 条件化は解像度由来の状態へ触れない（解像度・プリセット不変。requirements 4.4）。
    /// videoAspectRatio の唯一の書き込み点は captureOutput の Task のままである。
    func testProcessDetection_doesNotTouchVideoAspectRatio() {
        let defaultAR = sut.snapshot.videoAspectRatio
        sut.applyCalibrationCompletion(
            referenceNearAngleDegrees: 45.0, referenceDistance: 0.2, referenceSide: .left, referencePoints: [], referenceSource: nil
        )
        sut.processDetection(.pose(testFrame(shoulderConfidence: 0.9)))
        sut.processDetection(.absent)
        XCTAssertEqual(sut.snapshot.videoAspectRatio, defaultAR, "条件化は解像度由来の状態を変えない")
    }

    // MARK: - Main受け渡しゲート結線 (mainactor-throttle 3.1)

    /// 監視フェーズでは定常 pose 連続が間引かれる（配送分のみ Main へ渡る）。
    func testHopGate_monitoringPhase_throttlesSteadyPose() {
        sut.startMonitoring()
        sut.throttleResetQueue.sync {}
        let frame = testFrame(shoulderConfidence: 0.9)
        XCTAssertNotNil(sut.hopGate.submit(detection: .pose(frame), aspectRatio: 4.0 / 3.0, now: 300.0))
        XCTAssertNil(
            sut.hopGate.submit(detection: .pose(frame), aspectRatio: 4.0 / 3.0, now: 300.01),
            "定常連続は表示更新間隔で間引く"
        )
    }

    /// 校正フェーズ中は全量配送する（校正蓄積の到達を欠落させない）。
    func testHopGate_calibratingPhase_deliversAll() {
        sut.startCalibration()
        sut.throttleResetQueue.sync {}
        let frame = testFrame(shoulderConfidence: 0.9)
        XCTAssertNotNil(sut.hopGate.submit(detection: .pose(frame), aspectRatio: 4.0 / 3.0, now: 300.0))
        XCTAssertNotNil(
            sut.hopGate.submit(detection: .pose(frame), aspectRatio: 4.0 / 3.0, now: 300.01),
            "校正中は間隔にかかわらず配送する"
        )
    }

    /// 集約分は単一スロットに最新のみ保持し、蓄積を作らない。
    func testHopGate_coalescedFrames_holdSingleLatestSlot() {
        sut.startMonitoring()
        sut.throttleResetQueue.sync {}
        let frame = testFrame(shoulderConfidence: 0.9)
        XCTAssertNotNil(sut.hopGate.submit(detection: .pose(frame), aspectRatio: 4.0 / 3.0, now: 300.0))
        XCTAssertNil(sut.hopGate.submit(detection: .pose(frame), aspectRatio: 4.0 / 3.0, now: 300.01))
        XCTAssertEqual(sut.hopGate.pendingCount, 1)
        XCTAssertNil(sut.hopGate.submit(detection: .pose(frame), aspectRatio: 4.0 / 3.0, now: 300.02))
        XCTAssertEqual(sut.hopGate.pendingCount, 1, "集約分は単一スロットに最新のみ保持する")
    }

    /// 排出時はスロットを空にし、最新の結果を返す。
    func testHopGate_deliver_drainsLatestAndClearsSlot() {
        sut.startMonitoring()
        sut.throttleResetQueue.sync {}
        let frame = testFrame(shoulderConfidence: 0.9)
        XCTAssertNotNil(sut.hopGate.submit(detection: .pose(frame), aspectRatio: 4.0 / 3.0, now: 300.0))
        XCTAssertNil(sut.hopGate.submit(detection: .pose(frame), aspectRatio: 4.0 / 3.0, now: 300.01))
        XCTAssertEqual(sut.hopGate.pendingCount, 1)
        let pending = sut.hopGate.submit(detection: .absent, aspectRatio: 4.0 / 3.0, now: 300.02)
        XCTAssertNotNil(pending)
        if case .absent = pending?.detection {} else {
            XCTFail("排出時は常に最新の結果を返す")
        }
        XCTAssertEqual(pending?.aspectRatio, 4.0 / 3.0)
        XCTAssertEqual(sut.hopGate.pendingCount, 0, "排出後はスロットを空にする")
    }

    /// 停止経路: stopMonitoring がゲートの判定状態・スロット・計数を初期化する。
    func testStopMonitoring_dispatchesHopReset() {
        sut.startMonitoring()
        sut.throttleResetQueue.sync {}
        let frame = testFrame(shoulderConfidence: 0.9)
        XCTAssertNotNil(sut.hopGate.submit(detection: .pose(frame), aspectRatio: 4.0 / 3.0, now: 300.0))
        XCTAssertNil(sut.hopGate.submit(detection: .pose(frame), aspectRatio: 4.0 / 3.0, now: 300.01))
        XCTAssertEqual(sut.hopGate.pendingCount, 1)
        sut.stopMonitoring()
        sut.throttleResetQueue.sync {}
        XCTAssertEqual(sut.hopGate.pendingCount, 0, "停止でスロットを破棄する")
        XCTAssertEqual(sut.hopGate.snapshot().submits, 0, "停止で計数を初期化する")
        XCTAssertNotNil(
            sut.hopGate.submit(detection: .pose(frame), aspectRatio: 4.0 / 3.0, now: 300.01),
            "初期化直後は同一時刻でも配送対象になる"
        )
    }

    /// 同期コア: 初期化がゲートの判定状態とスロットをクリアする。
    func testResetDetectionPipelineState_clearsHopGateAndSlot() {
        sut.startMonitoring()
        sut.throttleResetQueue.sync {}
        let frame = testFrame(shoulderConfidence: 0.9)
        XCTAssertNotNil(sut.hopGate.submit(detection: .pose(frame), aspectRatio: 4.0 / 3.0, now: 300.0))
        XCTAssertNil(sut.hopGate.submit(detection: .pose(frame), aspectRatio: 4.0 / 3.0, now: 300.01))
        sut.resetDetectionPipelineState()
        XCTAssertEqual(sut.hopGate.pendingCount, 0)
        XCTAssertNotNil(sut.hopGate.submit(detection: .pose(frame), aspectRatio: 4.0 / 3.0, now: 300.01))
    }

    // MARK: - 削減下の判定・体験の非回帰 (mainactor-throttle 4.2)

    /// ゲート判定はセッション状態を変えない（集約・配送の選定自体に副作用なし）。
    func testHopOrder_gateDecisionDoesNotMutateSnapshot() {
        sut.startMonitoring()
        sut.throttleResetQueue.sync {}
        let before = sut.snapshot
        let frame = testFrame(shoulderConfidence: 0.9)
        XCTAssertNotNil(sut.hopGate.submit(detection: .pose(frame), aspectRatio: 4.0 / 3.0, now: 300.0))
        XCTAssertNil(sut.hopGate.submit(detection: .pose(frame), aspectRatio: 4.0 / 3.0, now: 300.01))
        XCTAssertNotNil(sut.hopGate.submit(detection: .absent, aspectRatio: 4.0 / 3.0, now: 300.02))
        XCTAssertEqual(sut.snapshot, before, "受け渡し選定はセッション状態へ副作用を持たない")
    }

    /// 受け渡し選定は推論間引き計数へ逆流しない（上流計数の独立性）。
    func testHopOrder_gateDoesNotTouchThrottleCounters() {
        sut.startMonitoring()
        sut.throttleResetQueue.sync {}
        let frame = testFrame(shoulderConfidence: 0.9)
        XCTAssertNotNil(sut.hopGate.submit(detection: .pose(frame), aspectRatio: 4.0 / 3.0, now: 300.0))
        XCTAssertNil(sut.hopGate.submit(detection: .pose(frame), aspectRatio: 4.0 / 3.0, now: 300.01))
        let metrics = sut.frameThrottle.snapshot()
        XCTAssertEqual(metrics.arrivals, 0, "受け渡し選定は到達計数へ触れない")
        XCTAssertEqual(metrics.inferences, 0, "受け渡し選定は推論計数へ触れない")
        XCTAssertEqual(metrics.drops, 0, "受け渡し選定は破棄計数へ触れない")
    }

    /// 削減下でも猫背3秒連続で確定し、回復で即改善する（到達60fps→配送10Hzの再現）。
    /// 処理回数が毎フレーム到達より大幅に少ないことで受け渡し削減を数えて示す。
    func testHopGatedRate_slouchStillConfirmsAfter3SecondsAndRecovers() {
        sut.applyCalibrationCompletion(
            referenceNearAngleDegrees: 0.0, referenceDistance: 0.18, referenceSide: .right, referencePoints: [], referenceSource: nil
        )
        sut.startMonitoring()
        sut.throttleResetQueue.sync {}
        for _ in 0..<3 {
            if let pending = sut.hopGate.submit(
                detection: .pose(throttledRateFrame(rightEarDistance: 0.18)),
                aspectRatio: 4.0 / 3.0, now: CACurrentMediaTime()
            ) {
                sut.processDetection(pending.detection)
            }
            usleep(16_666)
        }
        XCTAssertEqual(sut.snapshot.displayedPosture, .good, "基準比100%は良好")

        let deadline = Date().addingTimeInterval(15)
        var processed = 0
        while !sut.snapshot.slouchGate.isFired && Date() < deadline {
            if let pending = sut.hopGate.submit(
                detection: .pose(throttledRateFrame(rightEarDistance: 0.21)),
                aspectRatio: 4.0 / 3.0, now: CACurrentMediaTime()
            ) {
                sut.processDetection(pending.detection)
                processed += 1
            }
            usleep(16_666) // 60fps到達の再現（ゲートが10Hzへ間引く）
        }
        XCTAssertTrue(sut.snapshot.slouchGate.isFired, "削減下でも猫背3秒連続で確定する")
        XCTAssertEqual(sut.snapshot.displayedPosture, .slouch)
        XCTAssertLessThan(processed, 60, "確定は時刻駆動であり削減後の処理回数に依存しない")

        for _ in 0..<5 {
            if let pending = sut.hopGate.submit(
                detection: .pose(throttledRateFrame(rightEarDistance: 0.18)),
                aspectRatio: 4.0 / 3.0, now: CACurrentMediaTime()
            ) {
                sut.processDetection(pending.detection)
            }
            usleep(16_666)
        }
        XCTAssertEqual(sut.snapshot.displayedPosture, .good, "全指標閾値未満で即改善")
        XCTAssertFalse(sut.snapshot.slouchGate.isFired, "改善で確定ゲート解除")
    }

    // MARK: - 表示専用値の不変書込み省略 (mainactor-throttle 3.2)

    /// 画面比率が不変の場合は書込み（publish）を省略する。
    func testAspectSkip_unchangedValue_doesNotPublish() {
        var events: [CGFloat] = []
        let cancellable = sut.$snapshot.map(\.videoAspectRatio).sink { events.append($0) }
        XCTAssertEqual(events.count, 1, "購読直後の初期値のみ")
        sut.applyDeliveredAspectRatio(sut.snapshot.videoAspectRatio)
        XCTAssertEqual(events.count, 1, "不変時は書込みを省略する")
        cancellable.cancel()
    }

    /// 画面比率の変化時は変化後の値で更新する。
    func testAspectSkip_changedValue_publishesNewValue() {
        var events: [CGFloat] = []
        let cancellable = sut.$snapshot.map(\.videoAspectRatio).sink { events.append($0) }
        sut.applyDeliveredAspectRatio(16.0 / 9.0)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(Double(events.last ?? 0), 16.0 / 9.0, accuracy: 1e-9)
        XCTAssertEqual(Double(sut.snapshot.videoAspectRatio), 16.0 / 9.0, accuracy: 1e-9)
        cancellable.cancel()
    }

    /// 微小差は不変とみなし、判定が参照する値には触れない。
    func testAspectSkip_toleranceAndJudgmentUntouched() {
        XCTAssertFalse(sut.shouldUpdateAspectRatio(sut.snapshot.videoAspectRatio))
        XCTAssertFalse(sut.shouldUpdateAspectRatio(sut.snapshot.videoAspectRatio + MainHopGate.aspectTolerance / 2))
        XCTAssertTrue(sut.shouldUpdateAspectRatio(16.0 / 9.0))
        let before = sut.snapshot.referenceAngle
        sut.applyDeliveredAspectRatio(16.0 / 9.0)
        XCTAssertEqual(sut.snapshot.referenceAngle, before, "判定が参照する値には触れない")
    }

    /// 左右とも耳が肩の真上（角度0度）で、ロック側（右）の耳-肩距離だけ dist のフレーム。
    /// DistanceMetricIntegrationTests と同一則（角度0度・距離のみで猫背候補を作る）。
    private func throttledRateFrame(rightEarDistance: Double) -> PoseFrame {
        PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.3, y: 0.6 - 0.1, confidence: 0.9),
            rightEar: Keypoint(x: 0.7, y: 0.6 - rightEarDistance, confidence: 0.9),
            leftShoulder: Keypoint(x: 0.3, y: 0.6, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.7, y: 0.6, confidence: 0.9)
        )
    }

    /// ホールド確認用の全点そろったフレーム（耳 0.9・肩は指定信頼度）。
    private func testFrame(shoulderConfidence: Double) -> PoseFrame {
        PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.3, y: 0.4, confidence: 0.9),
            rightEar: nil,
            leftShoulder: Keypoint(x: 0.4, y: 0.7, confidence: shoulderConfidence),
            rightShoulder: nil
        )
    }
}
