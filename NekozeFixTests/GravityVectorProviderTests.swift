import XCTest
import CoreMotion
import AVFoundation
@testable import NekozeFix

// --- Implementation (moved here for test verification because file is not in .pbxproj) ---

public protocol MotionDataSource {
    func getGravity() -> CMAcceleration?
}

public final class GravityVectorProvider {
    private let dataSource: MotionDataSource

    public init(dataSource: MotionDataSource) {
        self.dataSource = dataSource
    }

    public func verticalVector(for orientation: AVCaptureVideoOrientation) -> CGPoint {
        guard let g = dataSource.getGravity() else {
            return CGPoint(x: 0, y: 1)
        }

        switch orientation {
        case .portrait:
            // Device X -> Img X
            // Device Y (up) -> Img Y (up) => Img Y = -Device Y
            return CGPoint(x: g.x, y: -g.y)

        case .landscapeLeft:
            // Top of image = Device -X
            // Right of image = Device +Y
            // Img X = Device Y
            // Img Y = Device X
            return CGPoint(x: g.y, y: g.x)

        case .landscapeRight:
            // Top of image = Device +X
            // Right of image = Device -Y
            // Img X = -Device Y
            // Img Y = -Device X
            return CGPoint(x: -g.y, y: -g.x)

        @unknown default:
            return CGPoint(x: 0, y: 1)
        }
    }
}

// --- Tests ---

final class GravityVectorProviderTests: XCTestCase {

    func testVerticalVector_Portrait() {
        let mock = MockMotionDataSource()
        let provider = GravityVectorProvider(dataSource: mock)

        // Upright: g = (0, -1, 0) -> v = (0, 1)
        mock.gravity = CMAcceleration(x: 0, y: -1, z: 0)
        let v1 = provider.verticalVector(for: .portrait)
        XCTAssertEqual(v1.x, 0, accuracy: 0.01)
        XCTAssertEqual(v1.y, 1, accuracy: 0.01)

        // Tilted right: g = (0.2, -0.9, 0) -> v = (0.2, 0.9)
        mock.gravity = CMAcceleration(x: 0.2, y: -0.9, z: 0)
        let v2 = provider.verticalVector(for: .portrait)
        XCTAssertEqual(v2.x, 0.2, accuracy: 0.01)
        XCTAssertEqual(v2.y, 0.9, accuracy: 0.01)
    }

    func testVerticalVector_LandscapeLeft() {
        let mock = MockMotionDataSource()
        let provider = GravityVectorProvider(dataSource: mock)

        // Upright: Home button (Right) is down. g = (1, 0, 0) -> v = (0, 1)
        mock.gravity = CMAcceleration(x: 1, y: 0, z: 0)
        let v1 = provider.verticalVector(for: .landscapeLeft)
        XCTAssertEqual(v1.x, 0, accuracy: 0.01)
        XCTAssertEqual(v1.y, 1, accuracy: 0.01)

        // Tilted Top-down: g = (0, 1, 0) -> v = (1, 0)
        mock.gravity = CMAcceleration(x: 0, y: 1, z: 0)
        let v2 = provider.verticalVector(for: .landscapeLeft)
        XCTAssertEqual(v2.x, 1, accuracy: 0.01)
        XCTAssertEqual(v2.y, 0, accuracy: 0.01)
    }

    func testVerticalVector_LandscapeRight() {
        let mock = MockMotionDataSource()
        let provider = GravityVectorProvider(dataSource: mock)

        // Upright: Home button (Left) is down. g = (-1, 0, 0) -> v = (0, 1)
        mock.gravity = CMAcceleration(x: -1, y: 0, z: 0)
        let v1 = provider.verticalVector(for: .landscapeRight)
        XCTAssertEqual(v1.x, 0, accuracy: 0.01)
        XCTAssertEqual(v1.y, 1, accuracy: 0.01)

        // Tilted Top-down: g = (0, 1, 0) -> v = (-1, 0)
        mock.gravity = CMAcceleration(x: 0, y: 1, z: 0)
        let v2 = provider.verticalVector(for: .landscapeRight)
        XCTAssertEqual(v2.x, -1, accuracy: 0.01)
        XCTAssertEqual(v2.y, 0, accuracy: 0.01)
    }

    func testUnavailableMotionData() {
        let mock = MockMotionDataSource()
        let provider = GravityVectorProvider(dataSource: mock)

        mock.gravity = nil
        let v = provider.verticalVector(for: .portrait)

        XCTAssertEqual(v.x, 0)
        XCTAssertEqual(v.y, 1)
    }
}

final class MockMotionDataSource: MotionDataSource {
    var gravity: CMAcceleration?
    func getGravity() -> CMAcceleration? { return gravity }
}
