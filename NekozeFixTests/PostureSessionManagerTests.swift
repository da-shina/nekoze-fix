import XCTest
@testable import NekozeFix

@MainActor
final class PostureSessionManagerTests: XCTestCase {
    var sut: PostureSessionManager!

    override func setUp() {
        super.setUp()
        sut = PostureSessionManager()
    }

    override func tearDown() {
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

    // MARK: - 感度

    func testUpdateSensitivity_clampsToRange() {
        sut.updateSensitivity(-0.5)
        XCTAssertEqual(sut.snapshot.sensitivity, 0.0)

        sut.updateSensitivity(1.5)
        XCTAssertEqual(sut.snapshot.sensitivity, 1.0)

        sut.updateSensitivity(0.5)
        XCTAssertEqual(sut.snapshot.sensitivity, 0.5)
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
}
