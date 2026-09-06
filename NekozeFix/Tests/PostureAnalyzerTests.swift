import XCTest
@testable import NekozeFix

final class PostureAnalyzerTests: XCTestCase {

    // MARK: - Near-side selection

    func testNearSide_LeftShoulderLeftOfRight_nearSideLeft() {
        // 前提: left shoulder x=100, right shoulder x=200（左側が一番左）
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 150, y: 200, confidence: 0.8),
            rightEar: Keypoint(x: 250, y: 200, confidence: 0.8),
            leftShoulder: Keypoint(x: 100, y: 250, confidence: 0.8),
            rightShoulder: Keypoint(x: 200, y: 250, confidence: 0.8)
        )
        // 手順
        let result = PostureAnalyzer().analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10
        )
        // 検証
        XCTAssertEqual(result.sample?.nearSide, .left)
    }

    func testNearSide_RightShoulderLeftOfLeft_nearSideRight() {
        // 前提: right shoulder x=100, left shoulder x=200（右側が一番左）
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 150, y: 200, confidence: 0.8),
            rightEar: Keypoint(x: 250, y: 200, confidence: 0.8),
            leftShoulder: Keypoint(x: 200, y: 250, confidence: 0.8),
            rightShoulder: Keypoint(x: 100, y: 250, confidence: 0.8)
        )
        // 手順
        let result = PostureAnalyzer().analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10
        )
        // 検証
        XCTAssertEqual(result.sample?.nearSide, .right)
    }

    func testNearSide_EqualShoulders_nearSideLeftDefault() {
        // 前提: 肩のx座標が等しい
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 150, y: 200, confidence: 0.8),
            rightEar: Keypoint(x: 250, y: 200, confidence: 0.8),
            leftShoulder: Keypoint(x: 150, y: 250, confidence: 0.8),
            rightShoulder: Keypoint(x: 150, y: 250, confidence: 0.8)
        )
        // 手順
        let result = PostureAnalyzer().analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10
        )
        // 検証
        XCTAssertEqual(result.sample?.nearSide, .left)
    }

    func testNearSide_OnlyLeftSideDetected_nearSideLeft() {
        // 前提: 左側のキーのみが検出（右はnil）
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 150, y: 200, confidence: 0.8),
            rightEar: nil,
            leftShoulder: Keypoint(x: 100, y: 250, confidence: 0.8),
            rightShoulder: nil
        )
        // 手順
        let result = PostureAnalyzer().analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10
        )
        // 検証
        XCTAssertEqual(result.sample?.nearSide, .left)
    }

    func testNearSide_OnlyRightSideDetected_nearSideRight() {
        // 前提: 右側のキーのみが検出（左はnil）
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: nil,
            rightEar: Keypoint(x: 250, y: 200, confidence: 0.8),
            leftShoulder: nil,
            rightShoulder: Keypoint(x: 100, y: 250, confidence: 0.8)
        )
        // 手順
        let result = PostureAnalyzer().analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10
        )
        // 検証
        XCTAssertEqual(result.sample?.nearSide, .right)
    }

    func testNearSide_LeftConfidenceTooLow_nearSideRight() {
        // 前提: 左側のキーのconfidence < 0.5、右側のキーは有効
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 150, y: 200, confidence: 0.3),
            rightEar: Keypoint(x: 250, y: 200, confidence: 0.8),
            leftShoulder: Keypoint(x: 100, y: 250, confidence: 0.3),
            rightShoulder: Keypoint(x: 200, y: 250, confidence: 0.8)
        )
        // 手順
        let result = PostureAnalyzer().analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10
        )
        // 検証
        XCTAssertEqual(result.sample?.nearSide, .right)
    }

    // MARK: - Angle calculation

    func testAngleCalculation_VerticalVector_0Degrees() {
        // 前提: 耳が肩の真上（ベクトルが真上、dy > 0）
        // 肩から耳へのベクトル: (0, 正) → 垂直からの角度 = 0
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 150, y: 300, confidence: 1.0),
            rightEar: Keypoint(x: 250, y: 300, confidence: 1.0),
            leftShoulder: Keypoint(x: 150, y: 200, confidence: 1.0),
            rightShoulder: Keypoint(x: 250, y: 200, confidence: 1.0)
        )
        // 手順
        let result = PostureAnalyzer().analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10
        )
        // 検証 — ベクトルが垂直の場合は鋭角は0
        XCTAssertEqual(result.sample?.nearAngleDegrees, 0, accuracy: 0.1)
    }

    func testAngleCalculation_HorizontalVector_90Degrees() {
        // 前提: 耳が肩の真右（ベクトルが右、dy = 0）
        // 肩から耳へのベクトル: (正, 0) → 垂直からの角度 = 90
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 250, y: 200, confidence: 1.0),
            rightEar: Keypoint(x: 350, y: 200, confidence: 1.0),
            leftShoulder: Keypoint(x: 150, y: 200, confidence: 1.0),
            rightShoulder: Keypoint(x: 250, y: 200, confidence: 1.0)
        )
        // 手順
        let result = PostureAnalyzer().analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10
        )
        // 検証 — ベクトルが水平の場合は鋭角は90
        XCTAssertEqual(result.sample?.nearAngleDegrees, 90, accuracy: 0.1)
    }

    func testAngleCalculation_AcuteAngle_45Degrees() {
        // 前提: 耳が肩の右斜め上
        // ベクトル (100, 100) → |v| = sqrt(20000), cosθ = 100/sqrt(20000) = 1/√2 → θ = 45°
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 250, y: 300, confidence: 1.0),
            rightEar: Keypoint(x: 350, y: 300, confidence: 1.0),
            leftShoulder: Keypoint(x: 150, y: 200, confidence: 1.0),
            rightShoulder: Keypoint(x: 250, y: 200, confidence: 1.0)
        )
        // 手順
        let result = PostureAnalyzer().analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10
        )
        // 検証 — 鋭角は45度
        XCTAssertEqual(result.sample?.nearAngleDegrees, 45, accuracy: 0.1)
    }

    func testAngleCalculation_ConfidenceFilteredOut() {
        // 前提: confidence < 0.5はフィルタリングされる
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 150, y: 300, confidence: 0.3),  // < 0.5
            rightEar: Keypoint(x: 250, y: 300, confidence: 0.3),  // < 0.5
            leftShoulder: Keypoint(x: 150, y: 200, confidence: 0.3),  // < 0.5
            rightShoulder: Keypoint(x: 250, y: 200, confidence: 0.3)  // < 0.5
        )
        // 手順
        let result = PostureAnalyzer().analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10
        )
        // 検証
        XCTAssertEqual(result.verdict, .insufficientKeypoints)
    }

    // MARK: - Verdict: slouch detection

    func testVerdict_SlouchCandidate_WhenAngleExceedsThreshold() {
        // 前提: 鋭角 = 20度、reference = 0、threshold = 10
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 250, y: 300, confidence: 1.0),
            rightEar: Keypoint(x: 350, y: 300, confidence: 1.0),
            leftShoulder: Keypoint(x: 150, y: 200, confidence: 1.0),
            rightShoulder: Keypoint(x: 250, y: 200, confidence: 1.0)
        )
        // 手順 — 角度 20 >= threshold 10 → slouchCandidate
        let result = PostureAnalyzer().analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10
        )
        // 検証
        XCTAssertEqual(result.verdict, .slouchCandidate)
    }

    func testVerdict_Good_WhenAngleWithinThreshold() {
        // 前提: 鋭角 = 5度、reference = 0、threshold = 10
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 225, y: 280, confidence: 1.0),  // より浅い角度
            rightEar: Keypoint(x: 325, y: 280, confidence: 1.0),
            leftShoulder: Keypoint(x: 150, y: 200, confidence: 1.0),
            rightShoulder: Keypoint(x: 250, y: 200, confidence: 1.0)
        )
        // 手順 — 角度 5 < threshold 10 → good
        let result = PostureAnalyzer().analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10
        )
        // 検証
        XCTAssertEqual(result.verdict, .good)
    }

    func testVerdict_InsufficientKeypoints() {
        // 前提: 有効なキーがない（confidenceすべて < 0.5）
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 150, y: 300, confidence: 0.1),
            rightEar: Keypoint(x: 250, y: 300, confidence: 0.1),
            leftShoulder: Keypoint(x: 150, y: 200, confidence: 0.1),
            rightShoulder: Keypoint(x: 250, y: 200, confidence: 0.1)
        )
        // 手順
        let result = PostureAnalyzer().analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10
        )
        // 検証
        XCTAssertEqual(result.verdict, .insufficientKeypoints)
        XCTAssertNil(result.sample)
    }
}
