import XCTest
import AVFoundation
@testable import NekozeFix

/// Task 13.3: monitoring中の向き変化で旧基準破棄→校正へ自動遷移し、
/// 再校正完了まで監視を停止する。calibrating中・idleの向き変化は対象外。
/// トリガは既存 DeviceOrientationMonitor.currentVideoOrientation の購読のみ
/// （モニタ自体は無改修）。テストは購読先のハンドラを直接駆動する。
@MainActor
final class OrientationRecalibrationTests: XCTestCase {
    var sut: PostureSessionManager!

    override func setUp() {
        super.setUp()
        sut = PostureSessionManager()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - ヘルパー

    /// 校正済み監視状態をシードする（基準: 角度10度・距離0.18・ロック側 .right）。
    private func seedCalibratedMonitoring() {
        sut.applyCalibrationCompletion(
            referenceNearAngleDegrees: 10.0,
            referenceDistance: 0.18,
            referenceSide: .right,
            referencePoints: []
        )
        XCTAssertEqual(sut.snapshot.phase, .monitoring)
    }

    /// 初期向き (.portrait) を確定させた上で向き変化を起こす。
    /// 実機の購読は初期値で一度発火するため、テストでも同順序を再現する。
    private func changeOrientation(to orientation: AVCaptureVideoOrientation) {
        sut.handleVideoOrientationChange(.portrait)
        sut.handleVideoOrientationChange(orientation)
    }

    /// 監視中なら即 .slouch になる前出しフレーム（右距離0.21＝基準比116.7%）。
    private func slouchFrame() -> PoseFrame {
        PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.3, y: 0.5, confidence: 0.9),
            rightEar: Keypoint(x: 0.7, y: 0.6 - 0.21, confidence: 0.9),
            leftShoulder: Keypoint(x: 0.3, y: 0.6, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.7, y: 0.6, confidence: 0.9)
        )
    }

    // MARK: - monitoring中の向き変化: 破棄→校正遷移

    /// 旧基準（角度・距離・ロック側）と猫背ゲートを破棄し calibrating へ遷移する。
    func testMonitoringOrientationChange_discardsReferencesAndMovesToCalibrating() {
        seedCalibratedMonitoring()
        // ゲートを確定まで進める（破棄の検証用。実フレーム投入で実時間蓄積する）
        let deadline = Date().addingTimeInterval(10)
        while !sut.snapshot.slouchGate.isFired && Date() < deadline {
            sut.processDetection(.pose(slouchFrame()))
            usleep(20_000)
        }
        XCTAssertTrue(sut.snapshot.slouchGate.isFired, "前提: 猫背3秒連続で確定")

        changeOrientation(to: .landscapeLeft)

        XCTAssertEqual(sut.snapshot.phase, .calibrating, "monitoring中の向き変化で校正へ自動遷移")
        XCTAssertNil(sut.snapshot.referenceAngle, "旧基準角度を破棄")
        XCTAssertEqual(sut.snapshot.referenceDistances, [:], "旧基準距離を破棄")
        XCTAssertNil(sut.snapshot.referenceSide, "ロック側を破棄")
        XCTAssertEqual(sut.snapshot.slouchGate.accumulated, 0, "猫背ゲートを破棄")
        XCTAssertFalse(sut.snapshot.slouchGate.isFired)
        XCTAssertTrue(sut.motionService.isRunning, "再校正フローで Motion を継続")
    }

    // MARK: - 再校正完了まで監視を停止する

    /// 遷移後は監視判定が止まり（.slouch 表示なし）、再校正完了で監視に復帰する。
    func testMonitoringSuspendedUntilRecalibrationCompletes() {
        seedCalibratedMonitoring()
        changeOrientation(to: .landscapeLeft)
        XCTAssertEqual(sut.snapshot.phase, .calibrating)

        // 猫背フレームを投入しても監視表示は動かない（校正 ingest のみ）
        for _ in 0..<5 {
            sut.processDetection(.pose(slouchFrame()))
        }
        XCTAssertNotEqual(sut.snapshot.displayedPosture, .slouch, "再校正完了まで監視は停止")

        // 再校正完了で監視に復帰する
        sut.applyCalibrationCompletion(
            referenceNearAngleDegrees: 12.0,
            referenceDistance: 0.19,
            referenceSide: .left,
            referencePoints: []
        )
        XCTAssertEqual(sut.snapshot.phase, .monitoring, "再校正完了で監視に復帰")
        XCTAssertEqual(sut.snapshot.referenceAngle, 12.0)
        XCTAssertEqual(sut.snapshot.referenceSide, .left)
        XCTAssertEqual(sut.snapshot.referenceDistances, [.left: 0.19])
    }

    // MARK: - 対象外: calibrating中・idle・同一向き

    /// calibrating中の向き変化は対象外（校正蓄積を妨げない）。
    func testCalibratingOrientationChange_isIgnored() {
        sut.startCalibration()
        XCTAssertEqual(sut.snapshot.phase, .calibrating)

        changeOrientation(to: .landscapeLeft)

        XCTAssertEqual(sut.snapshot.phase, .calibrating, "calibrating中の向き変化は対象外")
    }

    /// idleの向き変化は対象外（旧基準を保持し遷移しない）。
    func testIdleOrientationChange_isIgnored() {
        seedCalibratedMonitoring()
        sut.stopMonitoring()
        XCTAssertEqual(sut.snapshot.phase, .idle)
        XCTAssertEqual(sut.snapshot.referenceAngle, 10.0)

        changeOrientation(to: .landscapeLeft)

        XCTAssertEqual(sut.snapshot.phase, .idle, "idleの向き変化は対象外")
        XCTAssertEqual(sut.snapshot.referenceAngle, 10.0, "旧基準を保持")
        XCTAssertEqual(sut.snapshot.referenceSide, .right)
        XCTAssertEqual(sut.snapshot.referenceDistances, [.right: 0.18])
    }

    /// 同一向きの再通知では遷移しない（初期購読・重複発火の無視）。
    func testSameOrientation_doesNotTriggerRecalibration() {
        seedCalibratedMonitoring()

        sut.handleVideoOrientationChange(.portrait)
        sut.handleVideoOrientationChange(.portrait)

        XCTAssertEqual(sut.snapshot.phase, .monitoring, "同一向きでは遷移しない")
        XCTAssertEqual(sut.snapshot.referenceAngle, 10.0)
        XCTAssertEqual(sut.snapshot.referenceSide, .right)
    }
}
