import XCTest
import Vision
@testable import NekozeFix

final class PoseDetectorTests: XCTestCase {

    // MARK: - 中央人物選択の距離基準（FR 4.7）

    func testCenterDistance_prefersFrameCenter() {
        let centered = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)   // 中心 (0.5, 0.5)
        let offCenter = CGRect(x: 0.0, y: 0.0, width: 0.2, height: 0.2)  // 中心 (0.1, 0.1)
        XCTAssertLessThan(PoseDetector.centerDistance(centered),
                          PoseDetector.centerDistance(offCenter))
    }

    func testCenterDistance_symmetricEqualDistance() {
        let left = CGRect(x: 0.1, y: 0.4, width: 0.2, height: 0.2)   // 中心 (0.2, 0.5)
        let right = CGRect(x: 0.7, y: 0.4, width: 0.2, height: 0.2)  // 中心 (0.8, 0.5)
        XCTAssertEqual(PoseDetector.centerDistance(left),
                       PoseDetector.centerDistance(right), accuracy: 1e-9)
    }

    func testClosestToCenter_empty_returnsNil() {
        XCTAssertNil([CGRect]().min(by: { PoseDetector.centerDistance($0) < PoseDetector.centerDistance($1) }))
    }

    // MARK: - 向き別の信頼度閾値（要件4.6）

    func testConfidenceThreshold_portrait_isStrict() {
        XCTAssertEqual(keypointConfidenceThreshold(isLandscape: false), 0.3, accuracy: 1e-9)
    }

    func testConfidenceThreshold_landscape_isRelaxed() {
        XCTAssertEqual(keypointConfidenceThreshold(isLandscape: true), 0.1, accuracy: 1e-9)
    }

    // MARK: - 人物選択矩形は有効点のみで算出

    func testPoseBoundingBox_ignoresLowConfidenceOutliers() {
        // 前提: 中心人物の高信頼度3点＋離れた低信頼度1点
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.45, y: 0.5, confidence: 0.9),
            rightEar: Keypoint(x: 0.55, y: 0.5, confidence: 0.9),
            leftShoulder: Keypoint(x: 0.45, y: 0.7, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.05, y: 0.1, confidence: 0.1)
        )

        // 検証: 外れ値を除いた矩形になる
        let box = PoseDetector.poseBoundingBox(frame)
        XCTAssertEqual(box.minX, 0.45, accuracy: 1e-9)
        XCTAssertEqual(box.maxX, 0.55, accuracy: 1e-9)
    }
}
