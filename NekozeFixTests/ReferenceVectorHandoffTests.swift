import XCTest
import CoreGraphics
@testable import NekozeFix

/// Task 13.2: 基準線ベクトルの表示受渡し（Session+UI統合）。
/// 判定が返したベクトルをそのまま snapshot 経由で表示へ受渡しする（単一解決）。
/// 代替中も判定と表示が同一ベクトルであることを結合テストで保証する。
@MainActor
final class ReferenceVectorHandoffTests: XCTestCase {
    var sut: PostureSessionManager!
    let analyzer = PostureAnalyzer()

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

    /// 肩傾斜フレーム: 重力 (0,1) と肩直交代替で解決値が異なる。
    private func tiltedShoulderFrame() -> PoseFrame {
        PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.3, y: 0.5, confidence: 0.9),
            rightEar: Keypoint(x: 0.7, y: 0.32, confidence: 0.9),
            leftShoulder: Keypoint(x: 0.3, y: 0.6, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.7, y: 0.5, confidence: 0.9)
        )
    }

    // MARK: - プレビュー/初期値: ダミー垂直ベクトル

    /// snapshot 初期値は表示専用のダミー垂直ベクトル（プレビューで基準線が表示される）。
    func testDefaultSnapshot_isVerticalDummy() {
        let snapshot = SessionSnapshot()
        XCTAssertEqual(snapshot.referenceVector.dx, 0.0, accuracy: 1e-9)
        XCTAssertEqual(snapshot.referenceVector.dy, 1.0, accuracy: 1e-9)
    }

    /// Overlay の既定入力はダミー垂直ベクトル（プレビュー用）。
    func testOverlayDefault_isVerticalDummy() {
        let overlay = PostureOverlayView(
            mode: .current,
            currentPoints: [],
            nearSide: nil
        )
        XCTAssertEqual(overlay.referenceVector.dx, 0.0, accuracy: 1e-9)
        XCTAssertEqual(overlay.referenceVector.dy, 1.0, accuracy: 1e-9)
    }

    // MARK: - 同一ベクトル受渡し（単一解決）

    /// 重力あり: snapshot のベクトルは判定が返したベクトルと同一である。
    func testHandoff_gravity_matchesAnalyzerVector() {
        seedCalibratedMonitoring()
        let frame = uprightFrame()
        let gravity = SIMD2<Double>(0, 1)
        sut.motionService.latestGravityInKeypointSpace = gravity

        sut.processDetection(.pose(frame))

        let (_, _, expected) = analyzer.analyze(
            frame: frame,
            referenceNearAngleDegrees: 0.0,
            slouchDeltaThresholdDegrees: sut.settingsStore.slouchThresholdDegrees,
            distanceMetric: DistanceMetric(side: .right, referenceDistance: 0.18),
            slouchDistanceThresholdPercent: sut.settingsStore.slouchDistanceThresholdPercent,
            previousNearSide: nil,
            gravityInKeypointSpace: gravity
        )
        XCTAssertEqual(sut.snapshot.referenceVector.dx, expected.vector.x, accuracy: 1e-9)
        XCTAssertEqual(sut.snapshot.referenceVector.dy, expected.vector.y, accuracy: 1e-9)
    }

    /// 代替中（重力なし→肩直交）も判定と表示が同一ベクトルである（無区別表示の前提）。
    func testHandoff_fallback_matchesAnalyzerVector() {
        seedCalibratedMonitoring()
        let frame = tiltedShoulderFrame()
        sut.motionService.latestGravityInKeypointSpace = nil

        sut.processDetection(.pose(frame))

        let (_, _, expected) = analyzer.analyze(
            frame: frame,
            referenceNearAngleDegrees: 0.0,
            slouchDeltaThresholdDegrees: sut.settingsStore.slouchThresholdDegrees,
            distanceMetric: DistanceMetric(side: .right, referenceDistance: 0.18),
            slouchDistanceThresholdPercent: sut.settingsStore.slouchDistanceThresholdPercent,
            previousNearSide: nil,
            gravityInKeypointSpace: nil
        )
        // 判定と表示の同一性（単一解決）
        XCTAssertEqual(sut.snapshot.referenceVector.dx, expected.vector.x, accuracy: 1e-9)
        XCTAssertEqual(sut.snapshot.referenceVector.dy, expected.vector.y, accuracy: 1e-9)
        // 代替解決であること（重力 (0,1) とは異なる肩直交値）
        XCTAssertNotEqual(sut.snapshot.referenceVector.dx, 0.0)
    }
}
