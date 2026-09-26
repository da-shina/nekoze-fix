import XCTest
@testable import NekozeFix

@MainActor
final class E2EIntegrationTests: XCTestCase {
    var sut: PostureSessionManager!
    var settings: SettingsStore!

    override func setUp() {
        super.setUp()
        settings = SettingsStore()
        sut = PostureSessionManager(settingsStore: settings)
    }

    override func tearDown() {
        sut = nil
        settings = nil
        super.tearDown()
    }

    func testCriticalPath_HappyPath() async {
        // 1. Permission & Bootstrap
        // Simulate authorized state by starting calibration
        sut.startCalibration()
        XCTAssertEqual(sut.snapshot.phase, .calibrating)

        // 2. Calibration Sequence
        let stableFrame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.4, y: 0.3, confidence: 0.9),
            rightEar: Keypoint(x: 0.6, y: 0.3, confidence: 0.9),
            leftShoulder: Keypoint(x: 0.4, y: 0.6, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.6, y: 0.6, confidence: 0.9)
        )

        // In a real simulator environment, we can't easily wait 5s in a unit test.
        // We force completion to verify the subsequent monitoring flow.
        sut.applyCalibrationCompletion(
            referenceNearAngleDegrees: 10.0,
            referenceDistance: 0.3,
            referenceSide: .left,
            referencePoints: [CGPoint(x: 0.4, y: 0.3), CGPoint(x: 0.4, y: 0.6)]
        )
        XCTAssertEqual(sut.snapshot.phase, .monitoring)
        XCTAssertTrue(sut.snapshot.isMonitoringEnabled)

        // 3. Slouch Detection Sequence
        let slouchFrame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.3, y: 0.4, confidence: 0.9),
            rightEar: Keypoint(x: 0.5, y: 0.4, confidence: 0.9),
            leftShoulder: Keypoint(x: 0.4, y: 0.6, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.6, y: 0.6, confidence: 0.9)
        )

        // Remove dwell gate for instant feedback in test
        sut.setPostureDisplayGateDuration(0.0)

        sut.processDetection(.pose(slouchFrame))
        XCTAssertEqual(sut.snapshot.displayedPosture, .slouch)

        // 4. Improvement Sequence
        sut.processDetection(.pose(stableFrame))
        XCTAssertEqual(sut.snapshot.displayedPosture, .good)

        // 5. Dim Mode Sequence
        sut.enterDimMode()
        XCTAssertTrue(sut.snapshot.isDimmed)

        sut.processDetection(.pose(slouchFrame))
        XCTAssertEqual(sut.snapshot.displayedPosture, .slouch)

        sut.exitDimMode()
        XCTAssertFalse(sut.snapshot.isDimmed)

        // 6. Lifecycle Sequence
        sut.handleDidEnterBackground()
        XCTAssertEqual(sut.snapshot.phase, .idle)

        sut.handleWillEnterForeground()
        XCTAssertEqual(sut.snapshot.phase, .monitoring)
    }
}
