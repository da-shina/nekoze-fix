import XCTest
@testable import NekozeFix

/// 基準線ベクトルの座標系回転（kiro-debug報告の修正）。
/// 重力Kはデバイスセンサ座標系で得られるが、キーポイントは回転済みバッファ
/// 座標系に存在する。capture角θで配信バッファが回転している場合、重力由来の
/// 基準値はバッファ座標系へ−θ回転させなければならない（ポートレートθ=0では恒等）。
/// 代替経路（肩直交・画像垂直）は元々バッファ座標系のため回転しない。
final class ReferenceVectorRotationTests: XCTestCase {
    private func uprightFrame() -> PoseFrame {
        PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.3, y: 0.4, confidence: 0.9),
            rightEar: Keypoint(x: 0.7, y: 0.4, confidence: 0.9),
            leftShoulder: Keypoint(x: 0.3, y: 0.6, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.7, y: 0.6, confidence: 0.9)
        )
    }

    private func reference(
        gravity: SIMD2<Double>?,
        captureAngleDegrees: Double?
    ) -> ReferenceVector {
        let (_, _, ref) = PostureAnalyzer().analyze(
            frame: uprightFrame(),
            referenceNearAngleDegrees: nil,
            slouchDeltaThresholdDegrees: 10.0,
            gravityInKeypointSpace: gravity,
            captureAngleDegrees: captureAngleDegrees
        )
        return ref
    }

    func testPortraitAngleZero_deviceUpStaysBufferUp() {
        let ref = reference(gravity: SIMD2<Double>(0, 1), captureAngleDegrees: 0)
        XCTAssertEqual(ref.x, 0, accuracy: 1e-6)
        XCTAssertEqual(ref.y, 1, accuracy: 1e-6)
    }

    func testLandscape90_deviceLeftUpBecomesBufferUp() {
        // 画面上がデバイス左向き（capture角90°）のとき、デバイス(−1,0)はバッファ(0,1)。
        let ref = reference(gravity: SIMD2<Double>(-1, 0), captureAngleDegrees: 90)
        XCTAssertEqual(ref.x, 0, accuracy: 1e-6)
        XCTAssertEqual(ref.y, 1, accuracy: 1e-6)
    }

    func testLandscape270_deviceRightUpBecomesBufferUp() {
        // 画面上がデバイス右向き（capture角270°）のとき、デバイス(1,0)はバッファ(0,1)。
        let ref = reference(gravity: SIMD2<Double>(1, 0), captureAngleDegrees: 270)
        XCTAssertEqual(ref.x, 0, accuracy: 1e-6)
        XCTAssertEqual(ref.y, 1, accuracy: 1e-6)
    }

    func testNilAngle_preservesLegacyPassthrough() {
        // 角度不明時（nil）は従来通り無回転で受け渡す。
        let ref = reference(gravity: SIMD2<Double>(-1, 0), captureAngleDegrees: nil)
        XCTAssertEqual(ref.x, -1, accuracy: 1e-6)
        XCTAssertEqual(ref.y, 0, accuracy: 1e-6)
    }

    func testFallbackPaths_notRotatedByAngle() {
        // 重力なし（代替経路）はcapture角の影響を受けない。
        let angled = reference(gravity: nil, captureAngleDegrees: 90)
        let unangled = reference(gravity: nil, captureAngleDegrees: nil)
        XCTAssertEqual(angled.x, unangled.x, accuracy: 1e-9)
        XCTAssertEqual(angled.y, unangled.y, accuracy: 1e-9)
    }
}
