import XCTest
@testable import NekozeFix

/// 基準線ベクトルの座標系回転（kiro-debug報告の修正）。
/// 重力Kはデバイスセンサ座標系で得られるが、キーポイントは回転済みバッファ
/// 座標系に存在する。coordinatorのcapture角θはセンサ基準であり、ポートレートで
/// 90°・ランドスケープで0°/180°を取る（センサがランドスケープネイティブのため。
/// WWDC23 10106: ポートレート表示には90°回転が必要）。バッファ座標系への変換は
/// (θ−90°)回転である。代替経路（肩直交・画像垂直）は元々バッファ座標系のため回転しない。
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
    ) -> ResolvedReferenceVector {
        let (_, _, ref) = PostureAnalyzer().analyze(
            frame: uprightFrame(),
            referenceNearAngleDegrees: nil,
            slouchDeltaThresholdDegrees: 10.0,
            gravityInKeypointSpace: gravity,
            captureAngleDegrees: captureAngleDegrees
        )
        return ref
    }

    func testPortraitAngle90_deviceUpStaysBufferUp() {
        // ポートレート（capture角90°）: デバイス上(0,1)はバッファ上(0,1)。
        let ref = reference(gravity: SIMD2<Double>(0, 1), captureAngleDegrees: 90)
        XCTAssertEqual(ref.vector.x, 0, accuracy: 1e-6)
        XCTAssertEqual(ref.vector.y, 1, accuracy: 1e-6)
    }

    func testLandscape0_deviceLeftUpBecomesBufferUp() {
        // ランドスケープ（capture角0°）: 画面上＝デバイス左(−1,0)はバッファ上(0,1)。
        let ref = reference(gravity: SIMD2<Double>(-1, 0), captureAngleDegrees: 0)
        XCTAssertEqual(ref.vector.x, 0, accuracy: 1e-6)
        XCTAssertEqual(ref.vector.y, 1, accuracy: 1e-6)
    }

    func testLandscape180_deviceRightUpBecomesBufferUp() {
        // ランドスケープ（capture角180°）: 画面上＝デバイス右(1,0)はバッファ上(0,1)。
        let ref = reference(gravity: SIMD2<Double>(1, 0), captureAngleDegrees: 180)
        XCTAssertEqual(ref.vector.x, 0, accuracy: 1e-6)
        XCTAssertEqual(ref.vector.y, 1, accuracy: 1e-6)
    }

    func testNilAngle_preservesLegacyPassthrough() {
        // 角度未確定時（nil）は無回転で受け渡す。
        let ref = reference(gravity: SIMD2<Double>(-1, 0), captureAngleDegrees: nil)
        XCTAssertEqual(ref.vector.x, -1, accuracy: 1e-6)
        XCTAssertEqual(ref.vector.y, 0, accuracy: 1e-6)
    }

    func testFallbackPaths_notRotatedByAngle() {
        // 重力なし（代替経路）はcapture角の影響を受けない。
        let angled = reference(gravity: nil, captureAngleDegrees: 0)
        let unangled = reference(gravity: nil, captureAngleDegrees: nil)
        XCTAssertEqual(angled.vector.x, unangled.vector.x, accuracy: 1e-9)
        XCTAssertEqual(angled.vector.y, unangled.vector.y, accuracy: 1e-9)
    }
}
