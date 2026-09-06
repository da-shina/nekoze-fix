import XCTest
@testable import NekozeFix

final class PostureAnalyzerTests: XCTestCase {

    private var postureAnalyzer: PostureAnalyzer!

    override func setUp() {
        super.setUp()
        postureAnalyzer = PostureAnalyzer()
    }

    override func tearDown() {
        postureAnalyzer = nil
        super.tearDown()
    }

    func testNearSideSelection_LeftShoulderSmallerX() {
        // Given: left shoulder x < right shoulder x
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 100, y: 200, confidence: 0.9),
            rightEar: Keypoint(x: 300, y: 200, confidence: 0.9),
            leftShoulder: Keypoint(x: 150, y: 250, confidence: 0.9),
            rightShoulder: Keypoint(x: 250, y: 250, confidence: 0.9)
        )

        // When
        let (sample, verdict) = postureAnalyzer.analyze(frame: frame, referenceNearAngleDegrees: 0, slouchDeltaThresholdDegrees: 10)

        // Then
        XCTAssertEqual(sample?.nearSide, .left)
        XCTAssertEqual(sample?.farSideDetected, true)
        XCTAssertEqual(verdict, .good) // angle should be small
    }

    func testNearSideSelection_RightShoulderSmallerX() {
        // Given: right shoulder x < left shoulder x
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 250, y: 200, confidence: 0.9),
            rightEar: Keypoint(x: 100, y: 200, confidence: 0.9),
            leftShoulder: Keypoint(x: 250, y: 250, confidence: 0.9),
            rightShoulder: Keypoint(x: 150, y: 250, confidence: 0.9)
        )

        // When
        let (sample, verdict) = postureAnalyzer.analyze(frame: frame, referenceNearAngleDegrees: 0, slouchDeltaThresholdDegrees: 10)

        // Then
        XCTAssertEqual(sample?.nearSide, .right)
        XCTAssertEqual(sample?.farSideDetected, true)
    }

    func testAngleCalculation_Acute0to90Degrees() {
        // Given: create a frame with known angle
        // shoulder at (100, 200), ear at (100, 100) -> straight up, 0 degrees
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 100, y: 100, confidence: 0.9),
            rightEar: Keypoint(x: 300, y: 200, confidence: 0.0), // invalid
            leftShoulder: Keypoint(x: 100, y: 200, confidence: 0.9),
            rightShoulder: Keypoint(x: 300, y: 200, confidence: 0.0)  // invalid
        )

        // When
        let (sample, verdict) = postureAnalyzer.analyze(frame: frame, referenceNearAngleDegrees: 0, slouchDeltaThresholdDegrees: 10)

        // Then
        XCTAssertEqual(sample?.nearSide, .left)
        XCTAssertEqual(sample?.nearAngleDegrees, 0, accuracy: 0.1)
        XCTAssertEqual(verdict, .good)
    }

    func testSlouchDetection_WhenAngleExceedsThreshold() {
        // Given: reference angle 0 degrees, current angle 15 degrees, threshold 10 degrees
        // Create frame where ear is to the right of shoulder creating angle
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 115, y: 190, confidence: 0.9), // creates angle
            rightEar: Keypoint(x: 300, y: 200, confidence: 0.0), // invalid
            leftShoulder: Keypoint(x: 100, y: 200, confidence: 0.9),
            rightShoulder: Keypoint(x: 300, y: 200, confidence: 0.0)  // invalid
        )

        // When
        let (sample, verdict) = postureAnalyzer.analyze(frame: frame, referenceNearAngleDegrees: 0, slouchDeltaThresholdDegrees: 10)

        // Then
        XCTAssertEqual(sample?.nearSide, .left)
        XCTAssertGreaterThan(sample!.nearAngleDegrees, 10)
        XCTAssertEqual(verdict, .slouchCandidate)
    }

    func testInsufficientKeypoints_ReturnsNilSample() {
        // Given: no valid keypoints
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 100, y: 200, confidence: 0.4), // below threshold
            rightEar: Keypoint(x: 300, y: 200, confidence: 0.4),
            leftShoulder: Keypoint(x: 150, y: 250, confidence: 0.4),
            rightShoulder: Keypoint(x: 250, y: 250, confidence: 0.4)
        )

        // When
        let (sample, verdict) = postureAnalyzer.analyze(frame: frame, referenceNearAngleDegrees: 0, slouchDeltaThresholdDegrees: 10)

        // Then
        XCTAssertNil(sample)
        XCTAssertEqual(verdict, .insufficientKeypoints)
    }

    func testOneSideDetection_TreatsDetectedSideAsNear() {
        // Given: only left side valid
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 100, y: 200, confidence: 0.9),
            rightEar: Keypoint(x: 300, y: 200, confidence: 0.0), // invalid
            leftShoulder: Keypoint(x: 150, y: 250, confidence: 0.9),
            rightShoulder: Keypoint(x: 250, y: 250, confidence: 0.0)  // invalid
        )

        // When
        let (sample, verdict) = postureAnalyzer.analyze(frame: frame, referenceNearAngleDegrees: 0, slouchDeltaThresholdDegrees: 10)

        // Then
        XCTAssertEqual(sample?.nearSide, .left)
        XCTAssertEqual(sample?.farSideDetected, false) // far side not detected
    }
}