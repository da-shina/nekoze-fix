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
        // 前提: 左肩のx座標 < 右肩のx座標
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 155, y: 350, confidence: 0.9),  // 肩から少し右にずらして小さな角度を作る
            rightEar: Keypoint(x: 300, y: 200, confidence: 0.9),
            leftShoulder: Keypoint(x: 150, y: 250, confidence: 0.9),
            rightShoulder: Keypoint(x: 250, y: 250, confidence: 0.9)
        )

        // 手順
        let (sample, verdict) = postureAnalyzer.analyze(frame: frame, referenceNearAngleDegrees: 0, slouchDeltaThresholdDegrees: 10)

        // 検証
        XCTAssertEqual(sample?.nearSide, .left)
        XCTAssertEqual(sample?.farSideDetected, true)
        XCTAssertEqual(verdict, .good) // 角度は小さい（約2.86度）のため良好判定
    }

    func testNearSideSelection_RightShoulderSmallerX() {
        // 前提: 右肩のx座標 < 左肩のx座標
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 250, y: 200, confidence: 0.9),
            rightEar: Keypoint(x: 100, y: 200, confidence: 0.9),
            leftShoulder: Keypoint(x: 250, y: 250, confidence: 0.9),
            rightShoulder: Keypoint(x: 150, y: 250, confidence: 0.9)
        )

        // 手順
        let (sample, _) = postureAnalyzer.analyze(frame: frame, referenceNearAngleDegrees: 0, slouchDeltaThresholdDegrees: 10)

        // 検証
        XCTAssertEqual(sample?.nearSide, .right)
        XCTAssertEqual(sample?.farSideDetected, true)
    }

    func testAngleCalculation_Acute0to90Degrees() {
        // 前提: 角度が既知のフレームを作成
        // shoulder at (100, 200), ear at (100, 100) -> 真上、0度
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 100, y: 100, confidence: 0.9),
            rightEar: Keypoint(x: 300, y: 200, confidence: 0.0), // 無効
            leftShoulder: Keypoint(x: 100, y: 200, confidence: 0.9),
            rightShoulder: Keypoint(x: 300, y: 200, confidence: 0.0)  // 無効
        )

        // 手順
        let (sample, verdict) = postureAnalyzer.analyze(frame: frame, referenceNearAngleDegrees: 0, slouchDeltaThresholdDegrees: 10)

        // 検証
        XCTAssertEqual(sample?.nearSide, .left)
        XCTAssertEqual(sample?.nearAngleDegrees ?? 0, 0.0, accuracy: 0.1)
        XCTAssertEqual(verdict, .good)
    }

    func testSlouchDetection_WhenAngleExceedsThreshold() {
        // 前提: リファレンス角度0度、現在の角度15度、しきい値10度
        // 耳が肩より右にあるフレームを作成して角度を作る
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 115, y: 190, confidence: 0.9), // 角度を作る
            rightEar: Keypoint(x: 300, y: 200, confidence: 0.0), // 無効
            leftShoulder: Keypoint(x: 100, y: 200, confidence: 0.9),
            rightShoulder: Keypoint(x: 300, y: 200, confidence: 0.0)  // 無効
        )

        // 手順
        let (sample, verdict) = postureAnalyzer.analyze(frame: frame, referenceNearAngleDegrees: 0, slouchDeltaThresholdDegrees: 10)

        // 検証
        XCTAssertEqual(sample?.nearSide, .left)
        XCTAssertGreaterThan(sample!.nearAngleDegrees, 10.0)
        XCTAssertEqual(verdict, .slouchCandidate)
    }

    func testInsufficientKeypoints_ReturnsNilSample() {
        // 前提: 有効なキーがない
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 100, y: 200, confidence: 0.4), // しきい値以下
            rightEar: Keypoint(x: 300, y: 200, confidence: 0.4),
            leftShoulder: Keypoint(x: 150, y: 250, confidence: 0.4),
            rightShoulder: Keypoint(x: 250, y: 250, confidence: 0.4)
        )

        // 手順
        let (sample, verdict) = postureAnalyzer.analyze(frame: frame, referenceNearAngleDegrees: 0, slouchDeltaThresholdDegrees: 10)

        // 検証
        XCTAssertNil(sample)
        XCTAssertEqual(verdict, .insufficientKeypoints)
    }

    func testOneSideDetection_TreatsDetectedSideAsNear() {
        // 前提: 左側のみ有効
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 100, y: 200, confidence: 0.9),
            rightEar: Keypoint(x: 300, y: 200, confidence: 0.0), // 無効
            leftShoulder: Keypoint(x: 150, y: 250, confidence: 0.9),
            rightShoulder: Keypoint(x: 250, y: 250, confidence: 0.0)  // 無効
        )

        // 手順
        let (sample, _) = postureAnalyzer.analyze(frame: frame, referenceNearAngleDegrees: 0, slouchDeltaThresholdDegrees: 10)

        // 検証
        XCTAssertEqual(sample?.nearSide, .left)
        XCTAssertEqual(sample?.farSideDetected, false) // far側未検出
    }
}
