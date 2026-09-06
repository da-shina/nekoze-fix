import XCTest
@testable import NekozeFix

final class PostureAnalyzerTests: XCTestCase {

    // MARK: - Near-side selection

    func testNearSide_LeftShoulderLeftOfRight_nearSideLeft() {
        // Given: left shoulder x=100, right shoulder x=200 (left is leftmost)
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 150, y: 200, confidence: 0.8),
            rightEar: Keypoint(x: 250, y: 200, confidence: 0.8),
            leftShoulder: Keypoint(x: 100, y: 250, confidence: 0.8),
            rightShoulder: Keypoint(x: 200, y: 250, confidence: 0.8)
        )
        // When
        let result = PostureAnalyzer().analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10
        )
        // Then
        XCTAssertEqual(result.sample?.nearSide, .left)
    }

    func testNearSide_RightShoulderLeftOfLeft_nearSideRight() {
        // Given: right shoulder x=100, left shoulder x=200 (right is leftmost)
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 150, y: 200, confidence: 0.8),
            rightEar: Keypoint(x: 250, y: 200, confidence: 0.8),
            leftShoulder: Keypoint(x: 200, y: 250, confidence: 0.8),
            rightShoulder: Keypoint(x: 100, y: 250, confidence: 0.8)
        )
        // When
        let result = PostureAnalyzer().analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10
        )
        // Then
        XCTAssertEqual(result.sample?.nearSide, .right)
    }

    func testNearSide_EqualShoulders_nearSideLeftDefault() {
        // Given: equal shoulder x-coordinates
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 150, y: 200, confidence: 0.8),
            rightEar: Keypoint(x: 250, y: 200, confidence: 0.8),
            leftShoulder: Keypoint(x: 150, y: 250, confidence: 0.8),
            rightShoulder: Keypoint(x: 150, y: 250, confidence: 0.8)
        )
        // When
        let result = PostureAnalyzer().analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10
        )
        // Then
        XCTAssertEqual(result.sample?.nearSide, .left)
    }

    func testNearSide_OnlyLeftSideDetected_nearSideLeft() {
        // Given: only left keypoints detected (right is nil)
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 150, y: 200, confidence: 0.8),
            rightEar: nil,
            leftShoulder: Keypoint(x: 100, y: 250, confidence: 0.8),
            rightShoulder: nil
        )
        // When
        let result = PostureAnalyzer().analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10
        )
        // Then
        XCTAssertEqual(result.sample?.nearSide, .left)
    }

    func testNearSide_OnlyRightSideDetected_nearSideRight() {
        // Given: only right keypoints detected (left is nil)
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: nil,
            rightEar: Keypoint(x: 250, y: 200, confidence: 0.8),
            leftShoulder: nil,
            rightShoulder: Keypoint(x: 100, y: 250, confidence: 0.8)
        )
        // When
        let result = PostureAnalyzer().analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10
        )
        // Then
        XCTAssertEqual(result.sample?.nearSide, .right)
    }

    func testNearSide_LeftConfidenceTooLow_nearSideRight() {
        // Given: left keypoints have confidence < 0.5, right keypoints are valid
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 150, y: 200, confidence: 0.3),
            rightEar: Keypoint(x: 250, y: 200, confidence: 0.8),
            leftShoulder: Keypoint(x: 100, y: 250, confidence: 0.3),
            rightShoulder: Keypoint(x: 200, y: 250, confidence: 0.8)
        )
        // When
        let result = PostureAnalyzer().analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10
        )
        // Then
        XCTAssertEqual(result.sample?.nearSide, .right)
    }

    // MARK: - Angle calculation

    func testAngleCalculation_VerticalVector_0Degrees() {
        // Given: ear directly above shoulder (vector points straight up, dy > 0)
        // Vector from shoulder to ear: (0, positive) → angle with vertical = 0
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 150, y: 300, confidence: 1.0),
            rightEar: Keypoint(x: 250, y: 300, confidence: 1.0),
            leftShoulder: Keypoint(x: 150, y: 200, confidence: 1.0),
            rightShoulder: Keypoint(x: 250, y: 200, confidence: 1.0)
        )
        // When
        let result = PostureAnalyzer().analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10
        )
        // Then — acute angle should be 0 when vector is vertical
        XCTAssertEqual(result.sample?.nearAngleDegrees, 0, accuracy: 0.1)
    }

    func testAngleCalculation_HorizontalVector_90Degrees() {
        // Given: ear directly to the right of shoulder (vector points right, dy = 0)
        // Vector from shoulder to ear: (positive, 0) → angle with vertical = 90
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 250, y: 200, confidence: 1.0),
            rightEar: Keypoint(x: 350, y: 200, confidence: 1.0),
            leftShoulder: Keypoint(x: 150, y: 200, confidence: 1.0),
            rightShoulder: Keypoint(x: 250, y: 200, confidence: 1.0)
        )
        // When
        let result = PostureAnalyzer().analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10
        )
        // Then — acute angle should be 90 when vector is horizontal
        XCTAssertEqual(result.sample?.nearAngleDegrees, 90, accuracy: 0.1)
    }

    func testAngleCalculation_AcuteAngle_45Degrees() {
        // Given: ear is diagonally up-right from shoulder
        // Vector (100, 100) → |v| = sqrt(20000), cosθ = 100/sqrt(20000) = 1/√2 → θ = 45°
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 250, y: 300, confidence: 1.0),
            rightEar: Keypoint(x: 350, y: 300, confidence: 1.0),
            leftShoulder: Keypoint(x: 150, y: 200, confidence: 1.0),
            rightShoulder: Keypoint(x: 250, y: 200, confidence: 1.0)
        )
        // When
        let result = PostureAnalyzer().analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10
        )
        // Then — acute angle should be 45 degrees
        XCTAssertEqual(result.sample?.nearAngleDegrees, 45, accuracy: 0.1)
    }

    func testAngleCalculation_ConfidenceFilteredOut() {
        // Given: confidence < 0.5 should be filtered out
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 150, y: 300, confidence: 0.3),  // < 0.5
            rightEar: Keypoint(x: 250, y: 300, confidence: 0.3),  // < 0.5
            leftShoulder: Keypoint(x: 150, y: 200, confidence: 0.3),  // < 0.5
            rightShoulder: Keypoint(x: 250, y: 200, confidence: 0.3)  // < 0.5
        )
        // When
        let result = PostureAnalyzer().analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10
        )
        // Then
        XCTAssertEqual(result.verdict, .insufficientKeypoints)
    }

    // MARK: - Verdict: slouch detection

    func testVerdict_SlouchCandidate_WhenAngleExceedsThreshold() {
        // Given: acute angle = 20 degrees, reference = 0, threshold = 10
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 250, y: 300, confidence: 1.0),
            rightEar: Keypoint(x: 350, y: 300, confidence: 1.0),
            leftShoulder: Keypoint(x: 150, y: 200, confidence: 1.0),
            rightShoulder: Keypoint(x: 250, y: 200, confidence: 1.0)
        )
        // When — angle 20 >= threshold 10 → slouchCandidate
        let result = PostureAnalyzer().analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10
        )
        // Then
        XCTAssertEqual(result.verdict, .slouchCandidate)
    }

    func testVerdict_Good_WhenAngleWithinThreshold() {
        // Given: acute angle = 5 degrees, reference = 0, threshold = 10
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 225, y: 280, confidence: 1.0),  // shallower angle
            rightEar: Keypoint(x: 325, y: 280, confidence: 1.0),
            leftShoulder: Keypoint(x: 150, y: 200, confidence: 1.0),
            rightShoulder: Keypoint(x: 250, y: 200, confidence: 1.0)
        )
        // When — angle 5 < threshold 10 → good
        let result = PostureAnalyzer().analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10
        )
        // Then
        XCTAssertEqual(result.verdict, .good)
    }

    func testVerdict_InsufficientKeypoints() {
        // Given: no valid keypoints (confidence all < 0.5)
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 150, y: 300, confidence: 0.1),
            rightEar: Keypoint(x: 250, y: 300, confidence: 0.1),
            leftShoulder: Keypoint(x: 150, y: 200, confidence: 0.1),
            rightShoulder: Keypoint(x: 250, y: 200, confidence: 0.1)
        )
        // When
        let result = PostureAnalyzer().analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10
        )
        // Then
        XCTAssertEqual(result.verdict, .insufficientKeypoints)
        XCTAssertNil(result.sample)
    }
}
