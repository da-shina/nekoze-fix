import XCTest
import AVFoundation
import CoreMotion
@testable import NekozeFix

final class GravityVectorRobustnessTests: XCTestCase {

    // MARK: - Mocks

    class MockMotionDataSource: MotionDataSource {
        var simulatedGravity: CMAcceleration?
        func getGravity() -> CMAcceleration? {
            return simulatedGravity
        }
    }

    // MARK: - Properties

    var provider: GravityVectorProvider!
    var analyzer: PostureAnalyzer!
    var mockDataSource: MockMotionDataSource!

    override func setUp() {
        super.setUp()
        mockDataSource = MockMotionDataSource()
        provider = GravityVectorProvider(dataSource: mockDataSource)
        analyzer = PostureAnalyzer()
    }

    override func tearDown() {
        provider = nil
        analyzer = nil
        mockDataSource = nil
        super.tearDown()
    }

    // MARK: - Helper

    private func createFrame(earY: Double, shoulderY: Double, x: Double = 0.4) -> PoseFrame {
        return PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: x, y: earY, confidence: 1.0),
            rightEar: nil,
            leftShoulder: Keypoint(x: x, y: shoulderY, confidence: 1.0),
            rightShoulder: nil
        )
    }

    private func createRotatedFrame(earX: Double, earY: Double, shoulderX: Double, shoulderY: Double) -> PoseFrame {
        return PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: earX, y: earY, confidence: 1.0),
            rightEar: nil,
            leftShoulder: Keypoint(x: shoulderX, y: shoulderY, confidence: 1.0),
            rightShoulder: nil
        )
    }

    // MARK: - Test Scenarios

    /// Scenario 1: Perfect Portrait, User Upright -> GOOD
    func testPortrait_Upright_IsGood() {
        mockDataSource.simulatedGravity = CMAcceleration(x: 0, y: -1.0, z: 0)
        let verticalVector = provider.verticalVector(for: .portrait)

        let frame = createFrame(earY: 0.3, shoulderY: 0.5)
        let (_, verdict) = analyzer.analyze(frame: frame, verticalVector: verticalVector, slouchThresholdDegrees: 15.0)

        XCTAssertEqual(verdict, PostureVerdict.good)
    }

    /// Scenario 2: Perfect Portrait, User Slouched -> SLOUCH
    func testPortrait_Slouched_IsSlouch() {
        mockDataSource.simulatedGravity = CMAcceleration(x: 0, y: -1.0, z: 0)
        let verticalVector = provider.verticalVector(for: .portrait)

        // Slouched: Ear moves forward/down relative to shoulder.
        // In 2D, this manifests as an angle from the vertical.
        let frame = createFrame(earY: 0.4, shoulderY: 0.5) // Not quite slouched in 2D if X is same.
        // To get an angle in 2D, we need an X offset.
        let slouchedFrame = createRotatedFrame(earX: 0.5, earY: 0.4, shoulderX: 0.4, shoulderY: 0.5)

        let (_, verdict) = analyzer.analyze(frame: slouchedFrame, verticalVector: verticalVector, slouchThresholdDegrees: 15.0)

        XCTAssertEqual(verdict, PostureVerdict.slouchCandidate)
    }

    /// Scenario 3: Landscape Left, User Upright -> GOOD
    func testLandscapeLeft_Upright_IsGood() {
        // Device rotated 90 deg Left: Top of image is Device -X.
        // Gravity in device coords: x=0, y=-1.
        mockDataSource.simulatedGravity = CMAcceleration(x: 0, y: -1.0, z: 0)
        let verticalVector = provider.verticalVector(for: .landscapeLeft)

        // In landscapeLeft, verticalVector is (g.y, g.x) = (-1, 0) [Left in image]
        XCTAssertEqual(verticalVector.x, -1, accuracy: 0.001)
        XCTAssertEqual(verticalVector.y, 0, accuracy: 0.001)

        // User upright: ear is "above" shoulder physically.
        // In landscapeLeft, "above" is Device -X, which is Image Left.
        // Ear at (0.3, 0.4), Shoulder at (0.5, 0.4) -> Vector (-0.2, 0).
        // Parallel to verticalVector (-1, 0) -> 0 degrees.
        let frame = createRotatedFrame(earX: 0.3, earY: 0.4, shoulderX: 0.5, shoulderY: 0.4)
        let (_, verdict) = analyzer.analyze(frame: frame, verticalVector: verticalVector, slouchThresholdDegrees: 15.0)

        XCTAssertEqual(verdict, PostureVerdict.good)
    }

    /// Scenario 4: Landscape Right, User Upright -> GOOD
    func testLandscapeRight_Upright_IsGood() {
        mockDataSource.simulatedGravity = CMAcceleration(x: 0, y: -1.0, z: 0)
        let verticalVector = provider.verticalVector(for: .landscapeRight)

        // In landscapeRight, verticalVector is (-g.y, -g.x) = (1, 0) [Right in image]
        XCTAssertEqual(verticalVector.x, 1, accuracy: 0.001)
        XCTAssertEqual(verticalVector.y, 0, accuracy: 0.001)

        // User upright: "above" is Device -X, which is Image Right.
        // Ear at (0.7, 0.4), Shoulder at (0.5, 0.4) -> Vector (0.2, 0).
        let frame = createRotatedFrame(earX: 0.7, earY: 0.4, shoulderX: 0.5, shoulderY: 0.4)
        let (_, verdict) = analyzer.analyze(frame: frame, verticalVector: verticalVector, slouchThresholdDegrees: 15.0)

        XCTAssertEqual(verdict, PostureVerdict.good)
    }

    /// Scenario 5: Tilted (30 deg), User Upright -> GOOD
    func testTilted_Upright_IsGood() {
        // Tilted 30 deg clockwise around Z.
        // Gravity: x = sin(30)=0.5, y = -cos(30)=-0.866
        mockDataSource.simulatedGravity = CMAcceleration(x: 0.5, y: -0.866, z: 0)
        let verticalVector = provider.verticalVector(for: .portrait)

        // verticalVector = (g.x, -g.y) = (0.5, 0.866)

        // User upright: Shoulder -> Ear vector should be physically UP.
        // physically UP is (-g.x, g.y) = (-0.5, -0.866) in device coords.
        // In image: (-0.5, 0.866) [Wait, Img Y is -Device Y]
        // Actually, let's just make the vector parallel to the verticalVector (but opposite).
        // Shoulder (0.5, 0.5), Ear (0.5 - 0.5*0.1, 0.5 - 0.866*0.1) = (0.45, 0.4134)
        let frame = createRotatedFrame(earX: 0.45, earY: 0.4134, shoulderX: 0.5, shoulderY: 0.5)

        let (_, verdict) = analyzer.analyze(frame: frame, verticalVector: verticalVector, slouchThresholdDegrees: 15.0)

        XCTAssertEqual(verdict, PostureVerdict.good)
    }

    /// Scenario 6: Tilted (30 deg), User Slouched -> SLOUCH
    func testTilted_Slouched_IsSlouch() {
        mockDataSource.simulatedGravity = CMAcceleration(x: 0.5, y: -0.866, z: 0)
        let verticalVector = provider.verticalVector(for: .portrait)

        // Slouched: Angle offset from the physical vertical.
        // upright vector: (-0.5, -0.866). Let's rotate this by 30 degrees.
        // New vector approx: (0, -1)
        let frame = createRotatedFrame(earX: 0.5, earY: 0.4, shoulderX: 0.5, shoulderY: 0.5)

        let (_, verdict) = analyzer.analyze(frame: frame, verticalVector: verticalVector, slouchThresholdDegrees: 15.0)

        XCTAssertEqual(verdict, PostureVerdict.slouchCandidate)
    }

    /// Scenario 7: Consistency Check
    func testConsistency_AcrossOrientations() {
        let slouchThreshold = 15.0

        // Defined "Slouch" relative to physical vertical: a vector (0.2, -0.8) normalized
        let relativeVector = CGPoint(x: 0.2, y: -0.8)

        let configs: [(orientation: AVCaptureVideoOrientation, gravity: CMAcceleration)] = [
            (.portrait, CMAcceleration(x: 0, y: -1.0, z: 0)),
            (.landscapeLeft, CMAcceleration(x: 0, y: -1.0, z: 0)),
            (.landscapeRight, CMAcceleration(x: 0, y: -1.0, z: 0))
        ]

        for config in configs {
            mockDataSource.simulatedGravity = config.gravity
            let vv = provider.verticalVector(for: config.orientation)

            // Construct a frame where the ear-shoulder vector is exactly the relativeVector
            // rotated into the image coordinate system.
            // Actually, the simplest way is to ensure the angle is the same.

            // We'll just test that a known "good" relative posture is always good.
            // physical upright = -verticalVector
            let uprightVector = CGPoint(x: -vv.x, y: -vv.y)
            let frame = createRotatedFrame(
                earX: 0.5 + uprightVector.x * 0.1,
                earY: 0.5 + uprightVector.y * 0.1,
                shoulderX: 0.5,
                shoulderY: 0.5
            )

            let (_, verdict) = analyzer.analyze(frame: frame, verticalVector: vv, slouchThresholdDegrees: slouchThreshold)
            XCTAssertEqual(verdict, PostureVerdict.good, "Failed consistency for \(config.orientation)")
        }
    }
}
