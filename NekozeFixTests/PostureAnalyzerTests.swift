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

    // MARK: - Near Side Selection

    func testNearSideSelection_BothSides_LeftSmallerX() {
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.2, y: 0.3, confidence: 0.9),
            rightEar: Keypoint(x: 0.8, y: 0.3, confidence: 0.9),
            leftShoulder: Keypoint(x: 0.2, y: 0.5, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.7, y: 0.5, confidence: 0.9)
        )
        let (sample, _) = postureAnalyzer.analyze(
            frame: frame,
            verticalVector: CGPoint(x: 0, y: -1),
            slouchThresholdDegrees: 5.0,
            distanceMetric: nil,
            slouchDistanceThresholdPercent: 8.0,
            previousNearSide: nil
        )
        XCTAssertEqual(sample?.nearSide, .left)
        XCTAssertEqual(sample?.farSideDetected, true)
    }

    func testNearSideSelection_BothSides_RightSmallerX() {
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.8, y: 0.3, confidence: 0.9),
            rightEar: Keypoint(x: 0.2, y: 0.3, confidence: 0.9),
            leftShoulder: Keypoint(x: 0.7, y: 0.5, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.2, y: 0.5, confidence: 0.9)
        )
        let (sample, _) = postureAnalyzer.analyze(
            frame: frame,
            verticalVector: CGPoint(x: 0, y: -1),
            slouchThresholdDegrees: 5.0,
            distanceMetric: nil,
            slouchDistanceThresholdPercent: 8.0,
            previousNearSide: nil
        )
        XCTAssertEqual(sample?.nearSide, .right)
    }

    func testNearSideSelection_OnlyLeftValid() {
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.2, y: 0.3, confidence: 0.9),
            rightEar: Keypoint(x: 0.8, y: 0.3, confidence: 0.1),
            leftShoulder: Keypoint(x: 0.2, y: 0.5, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.7, y: 0.5, confidence: 0.1)
        )
        let (sample, _) = postureAnalyzer.analyze(
            frame: frame,
            verticalVector: CGPoint(x: 0, y: -1),
            slouchThresholdDegrees: 5.0,
            distanceMetric: nil,
            slouchDistanceThresholdPercent: 8.0,
            previousNearSide: nil
        )
        XCTAssertEqual(sample?.nearSide, .left)
        XCTAssertEqual(sample?.farSideDetected, false)
    }

    func testNearSideSelection_OnlyRightValid() {
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.8, y: 0.3, confidence: 0.1),
            rightEar: Keypoint(x: 0.2, y: 0.3, confidence: 0.9),
            leftShoulder: Keypoint(x: 0.7, y: 0.5, confidence: 0.1),
            rightShoulder: Keypoint(x: 0.2, y: 0.5, confidence: 0.9)
        )
        let (sample, _) = postureAnalyzer.analyze(
            frame: frame,
            verticalVector: CGPoint(x: 0, y: -1),
            slouchThresholdDegrees: 5.0,
            distanceMetric: nil,
            slouchDistanceThresholdPercent: 8.0,
            previousNearSide: nil
        )
        XCTAssertEqual(sample?.nearSide, .right)
        XCTAssertEqual(sample?.farSideDetected, false)
    }

    // MARK: - Angle Calculation

    func testAngleCalculation_PerfectlyVertical() {
        // Ear is exactly above shoulder, verticalVector is (0, -1)
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.2, y: 0.3, confidence: 0.9),
            rightEar: nil,
            leftShoulder: Keypoint(x: 0.2, y: 0.5, confidence: 0.9),
            rightShoulder: nil
        )
        let (sample, _) = postureAnalyzer.analyze(
            frame: frame,
            verticalVector: CGPoint(x: 0, y: -1),
            slouchThresholdDegrees: 5.0,
            distanceMetric: nil,
            slouchDistanceThresholdPercent: 8.0,
            previousNearSide: nil
        )
        XCTAssertEqual(sample?.nearAngleDegrees ?? 0, 0.0, accuracy: 0.1)
    }

    func testAngleCalculation_45Degrees() {
        // Shoulder (0.2, 0.5), Ear (0.3, 0.4) -> Vector (0.1, -0.1)
        // Vertical (0, -1)
        // cos(theta) = (0.1*0 + -0.1*-1) / (sqrt(0.02)*1) = 0.1 / 0.1414 ≈ 0.707
        // theta = 45 degrees
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.3, y: 0.4, confidence: 0.9),
            rightEar: nil,
            leftShoulder: Keypoint(x: 0.2, y: 0.5, confidence: 0.9),
            rightShoulder: nil
        )
        let (sample, _) = postureAnalyzer.analyze(
            frame: frame,
            verticalVector: CGPoint(x: 0, y: -1),
            slouchThresholdDegrees: 5.0,
            distanceMetric: nil,
            slouchDistanceThresholdPercent: 8.0,
            previousNearSide: nil
        )
        XCTAssertEqual(sample?.nearAngleDegrees ?? 0, 45.0, accuracy: 0.1)
    }

    func testAngleCalculation_AcuteRange() {
        // Ear is actually below shoulder (vector (0, 0.1)), vertical is (0, -1)
        // Dot product = -0.1 / (0.1 * 1) = -1 -> 180 degrees
        // Spec says acute angle 0-90. 180 - 180 = 0.
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.2, y: 0.6, confidence: 0.9),
            rightEar: nil,
            leftShoulder: Keypoint(x: 0.2, y: 0.5, confidence: 0.9),
            rightShoulder: nil
        )
        let (sample, _) = postureAnalyzer.analyze(
            frame: frame,
            verticalVector: CGPoint(x: 0, y: -1),
            slouchThresholdDegrees: 5.0,
            distanceMetric: nil,
            slouchDistanceThresholdPercent: 8.0,
            previousNearSide: nil
        )
        XCTAssertEqual(sample?.nearAngleDegrees ?? 0, 0.0, accuracy: 0.1)
    }

    // MARK: - Verdict OR Logic

    func testVerdict_AngleOver_DistanceUnder_SlouchCandidate() {
        // Angle 15 deg > 5 deg, Distance 100% (no change) < 108%
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.25, y: 0.4, confidence: 0.9), // angle approx 26 deg
            rightEar: nil,
            leftShoulder: Keypoint(x: 0.2, y: 0.5, confidence: 0.9),
            rightShoulder: nil
        )
        let metric = DistanceMetric(side: .left, referenceDistance: 0.1) // dist is 0.111...

        let (_, verdict) = postureAnalyzer.analyze(
            frame: frame,
            verticalVector: CGPoint(x: 0, y: -1),
            slouchThresholdDegrees: 5.0,
            distanceMetric: metric,
            slouchDistanceThresholdPercent: 15.0,
            previousNearSide: nil
        )
        XCTAssertEqual(verdict, .slouchCandidate)
    }

    func testVerdict_AngleUnder_DistanceOver_SlouchCandidate() {
        // Angle 0 deg < 5 deg, Distance 120% > 108%
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.2, y: 0.3, confidence: 0.9), // dist 0.2, angle 0
            rightEar: nil,
            leftShoulder: Keypoint(x: 0.2, y: 0.5, confidence: 0.9),
            rightShoulder: nil
        )
        let metric = DistanceMetric(side: .left, referenceDistance: 0.1) // ratio (0.2/0.1 - 1)*100 = 100%

        let (_, verdict) = postureAnalyzer.analyze(
            frame: frame,
            verticalVector: CGPoint(x: 0, y: -1),
            slouchThresholdDegrees: 5.0,
            distanceMetric: metric,
            slouchDistanceThresholdPercent: 8.0,
            previousNearSide: nil
        )
        XCTAssertEqual(verdict, .slouchCandidate)
    }

    func testVerdict_BothUnder_Good() {
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.2, y: 0.4, confidence: 0.9), // dist 0.1, angle 0
            rightEar: nil,
            leftShoulder: Keypoint(x: 0.2, y: 0.5, confidence: 0.9),
            rightShoulder: nil
        )
        let metric = DistanceMetric(side: .left, referenceDistance: 0.09) // ratio (0.1/0.09 - 1)*100 = 11.1%

        let (_, verdict) = postureAnalyzer.analyze(
            frame: frame,
            verticalVector: CGPoint(x: 0, y: -1),
            slouchThresholdDegrees: 5.0,
            distanceMetric: metric,
            slouchDistanceThresholdPercent: 15.0,
            previousNearSide: nil
        )
        XCTAssertEqual(verdict, .good)
    }

    // MARK: - Distance side lock (FQ1)

    func testDistanceSideLock_UsesLockedSide() {
        // Near side for angle is Left, but locked side for distance is Right.
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.2, y: 0.3, confidence: 0.9),   // Near side
            rightEar: Keypoint(x: 0.8, y: 0.2, confidence: 0.9), // Locked side
            leftShoulder: Keypoint(x: 0.2, y: 0.5, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.8, y: 0.5, confidence: 0.9)
        )
        // Right dist = 0.3, Left dist = 0.2
        let metric = DistanceMetric(side: .right, referenceDistance: 0.1) // Ratio = (0.3/0.1 - 1)*100 = 200%

        let (sample, verdict) = postureAnalyzer.analyze(
            frame: frame,
            verticalVector: CGPoint(x: 0, y: -1),
            slouchThresholdDegrees: 5.0,
            distanceMetric: metric,
            slouchDistanceThresholdPercent: 8.0,
            previousNearSide: nil
        )
        XCTAssertEqual(sample?.nearSide, .left)
        XCTAssertEqual(sample?.nearDistance ?? 0, 0.3, accuracy: 0.001) // Must be Right side dist
        XCTAssertEqual(verdict, .slouchCandidate)
    }

    func testDistanceSkip_WhenLockedSideMissing() {
        // Near side for angle is Left, locked side is Right, but Right is missing.
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.2, y: 0.3, confidence: 0.9),
            rightEar: Keypoint(x: 0.8, y: 0.2, confidence: 0.1), // Missing
            leftShoulder: Keypoint(x: 0.2, y: 0.5, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.8, y: 0.5, confidence: 0.1) // Missing
        )
        let metric = DistanceMetric(side: .right, referenceDistance: 0.1)

        let (sample, verdict) = postureAnalyzer.analyze(
            frame: frame,
            verticalVector: CGPoint(x: 0, y: -1),
            slouchThresholdDegrees: 5.0,
            distanceMetric: metric,
            slouchDistanceThresholdPercent: 8.0,
            previousNearSide: nil
        )
        XCTAssertEqual(sample?.nearSide, .left)
        XCTAssertEqual(sample?.nearDistance ?? 0, 0.2, accuracy: 0.001) // Fallback to near side dist in sample
        XCTAssertEqual(verdict, .good) // Dist skipped, angle 0 < 5
    }

    // MARK: - Confidence & Insufficient Keypoints

    func testInsufficientKeypoints_AllLowConfidence() {
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.2, y: 0.3, confidence: 0.2),
            rightEar: Keypoint(x: 0.8, y: 0.3, confidence: 0.2),
            leftShoulder: Keypoint(x: 0.2, y: 0.5, confidence: 0.2),
            rightShoulder: Keypoint(x: 0.8, y: 0.5, confidence: 0.2)
        )
        let (sample, verdict) = postureAnalyzer.analyze(
            frame: frame,
            verticalVector: CGPoint(x: 0, y: -1),
            slouchThresholdDegrees: 5.0,
            distanceMetric: nil,
            slouchDistanceThresholdPercent: 8.0,
            previousNearSide: nil
        )
        XCTAssertNil(sample)
        XCTAssertEqual(verdict, .insufficientKeypoints)
    }

    func testInsufficientKeypoints_MissingEar() {
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: nil,
            rightEar: nil,
            leftShoulder: Keypoint(x: 0.2, y: 0.5, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.8, y: 0.5, confidence: 0.9)
        )
        let (sample, verdict) = postureAnalyzer.analyze(
            frame: frame,
            verticalVector: CGPoint(x: 0, y: -1),
            slouchThresholdDegrees: 5.0,
            distanceMetric: nil,
            slouchDistanceThresholdPercent: 8.0,
            previousNearSide: nil
        )
        XCTAssertNil(sample)
        XCTAssertEqual(verdict, .insufficientKeypoints)
    }
}
