import XCTest
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

    func testDefaultPhase_isAwaitingPermission() {
        XCTAssertEqual(sut.snapshot.phase, .awaitingPermission)
    }

    func testStartCalibration_changesPhaseToCalibrating() {
        sut.startCalibration()
        XCTAssertEqual(sut.snapshot.phase, .calibrating)
    }

    func testRecalibrate_changesPhaseToCalibrating() {
        sut.recalibrate()
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

    // MARK: - 姿勢更新

    func testUpdatePosture_good_updatesSnapshot() {
        sut.updatePosture(.good)
        XCTAssertEqual(sut.snapshot.displayedPosture, .good)
    }

    func testUpdatePosture_slouch_updatesSnapshot() {
        sut.updatePosture(.slouch)
        XCTAssertEqual(sut.snapshot.displayedPosture, .slouch)
    }

    func testUpdatePosture_personMissing_updatesSnapshot() {
        sut.updatePosture(.personMissing)
        XCTAssertEqual(sut.snapshot.displayedPosture, .personMissing)
    }

    // MARK: - 人物検出

    func testUpdatePersonDetected_true_setsFlag() {
        sut.updatePersonDetected(true)
        XCTAssertTrue(sut.snapshot.isPersonDetected)
    }

    func testUpdatePersonDetected_false_setsFlag() {
        sut.updatePersonDetected(false)
        XCTAssertFalse(sut.snapshot.isPersonDetected)
    }

    // MARK: - 監視有効化

    func testUpdateMonitoringEnabled_true() {
        sut.updateMonitoringEnabled(true)
        XCTAssertTrue(sut.snapshot.isMonitoringEnabled)
    }

    func testUpdateMonitoringEnabled_false() {
        sut.updateMonitoringEnabled(false)
        XCTAssertFalse(sut.snapshot.isMonitoringEnabled)
    }

    // MARK: - フェーズ更新

    func testUpdatePhase_rotating() {
        sut.updatePhase(.rotating)
        XCTAssertEqual(sut.snapshot.phase, .rotating)
    }

    func testUpdatePhase_permissionDenied() {
        sut.updatePhase(.permissionDenied)
        XCTAssertEqual(sut.snapshot.phase, .permissionDenied)
    }

    // MARK: - ライフサイクル自動停止・復帰（要求 8.1/8.2、タスク3.5）

    /// 背面移行: 監視中なら idle に退避し、監視フラグ（復帰判定用）は維持する
    func testDidEnterBackground_duringMonitoring_movesToIdleKeepingFlag() {
        sut.applyCalibrationCompletion(
            referenceNearAngleDegrees: 45.0, referenceDistance: 0.2, referenceSide: .left, referencePoints: []
        )
        XCTAssertTrue(sut.settingsStore.isMonitoringEnabled, "校正完了で監視遷移時はフラグ true")

        sut.handleDidEnterBackground()
        XCTAssertEqual(sut.snapshot.phase, .idle)
        XCTAssertTrue(sut.settingsStore.isMonitoringEnabled, "自動停止はユーザーストップではないのでフラグ維持")
    }

    /// 復帰: 監視フラグ true かつ校正済みなら監視を再開
    func testWillEnterForeground_resumesMonitoringWhenCalibrated() {
        sut.applyCalibrationCompletion(
            referenceNearAngleDegrees: 45.0, referenceDistance: 0.2, referenceSide: .left, referencePoints: []
        )
        sut.handleDidEnterBackground()
        XCTAssertEqual(sut.snapshot.phase, .idle)

        sut.handleWillEnterForeground()
        XCTAssertEqual(sut.snapshot.phase, .monitoring)
    }

    /// 復帰: ユーザーが明示停止（フラグ false）した場合は停止状態を維持（要求 8.2）
    func testWillEnterForeground_keepsIdleAfterExplicitStop() {
        sut.applyCalibrationCompletion(
            referenceNearAngleDegrees: 45.0, referenceDistance: 0.2, referenceSide: .left, referencePoints: []
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
            referenceNearAngleDegrees: 45.0, referenceDistance: 0.2, referenceSide: .left, referencePoints: []
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
}
