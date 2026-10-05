import XCTest
import CoreGraphics
@testable import NekozeFix

/// 監視中の表示基準線の凍結（Q1-Q4合意）。
/// monitoring中は人物ありでも `snapshot.referenceVector` を上書きせず、
/// 校正完了時点の向きに固定する。可変なのは肩点起点の耳-肩角度のみ。
@MainActor
final class ReferenceVectorFreezeTests: XCTestCase {
    var sut: PostureSessionManager!

    override func setUp() {
        super.setUp()
        sut = PostureSessionManager()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    private func seedCalibratedMonitoring() {
        sut.applyCalibrationCompletion(
            referenceNearAngleDegrees: 0.0,
            referenceDistance: 0.18,
            referenceSide: .right,
            referencePoints: []
        )
        // applyはreferenceVectorに触れないため、初期ダミー垂直(0,1)がそのまま凍結値になる。
        XCTAssertEqual(sut.snapshot.phase, .monitoring)
    }

    private func uprightFrame() -> PoseFrame {
        PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.3, y: 0.5, confidence: 0.9),
            rightEar: Keypoint(x: 0.7, y: 0.42, confidence: 0.9),
            leftShoulder: Keypoint(x: 0.3, y: 0.6, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.7, y: 0.6, confidence: 0.9)
        )
    }

    private func shiftedShoulderFrame() -> PoseFrame {
        PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.32, y: 0.52, confidence: 0.9),
            rightEar: Keypoint(x: 0.72, y: 0.40, confidence: 0.9),
            leftShoulder: Keypoint(x: 0.32, y: 0.62, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.72, y: 0.58, confidence: 0.9)
        )
    }

    /// 重力あり・monitoring中：肩位置がずれても基準線の向きは不変。
    func testMonitoring_gravityPresent_referenceVectorFrozen() {
        seedCalibratedMonitoring()
        // 凍結値は初期ダミー垂直(0,1)。ライブ重力をずらしても凍結のままであることを検証する。
        sut.motionService.latestGravityInKeypointSpace = SIMD2<Double>(0.1, 0.99)

        sut.processDetection(.pose(uprightFrame()))
        XCTAssertEqual(sut.snapshot.referenceVector.dx, 0.0, accuracy: 1e-9)
        XCTAssertEqual(sut.snapshot.referenceVector.dy, 1.0, accuracy: 1e-9)

        sut.processDetection(.pose(shiftedShoulderFrame()))
        XCTAssertEqual(sut.snapshot.referenceVector.dx, 0.0, accuracy: 1e-9)
        XCTAssertEqual(sut.snapshot.referenceVector.dy, 1.0, accuracy: 1e-9)
        // 肩ドット自体は追従する（起点の移動は許容）
        XCTAssertFalse(sut.snapshot.visualizationPoints.isEmpty)
    }

    /// calibrating中はライブ更新が継続する（再校正での解凍）。
    func testCalibrating_referenceVectorLiveUpdates() {
        sut.startCalibration()
        sut.motionService.latestGravityInKeypointSpace = SIMD2<Double>(0, 1)

        sut.processDetection(.pose(uprightFrame()))
        let first = sut.snapshot.referenceVector

        sut.motionService.latestGravityInKeypointSpace = SIMD2<Double>(0.1, 0.99)
        sut.processDetection(.pose(shiftedShoulderFrame()))
        let second = sut.snapshot.referenceVector

        XCTAssertFalse(first.dx == second.dx && first.dy == second.dy, "calibrating中はライブ更新される")
    }
}
