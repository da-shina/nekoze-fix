import XCTest
@testable import NekozeFix

/// `resolve`（重力→肩ライン直交→画像垂直）の三段解決テスト。
/// `resolve` 自体は Analyzer 内 private のため、解決ベクトルの値は
/// `analyze` が返す `referenceVector` 経由で検証する（単一解決）。
final class PostureAnalyzerResolveTests: XCTestCase {

    private var analyzer: PostureAnalyzer!

    override func setUp() {
        super.setUp()
        analyzer = PostureAnalyzer()
    }

    override func tearDown() {
        analyzer = nil
        super.tearDown()
    }

    /// 傾斜肩フレーム（左肩 (0.2, 0.5)、右肩 (0.6, 0.6)）。
    private func tiltedFrame() -> PoseFrame {
        PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.2, y: 0.7, confidence: 0.9),
            rightEar: nil,
            leftShoulder: Keypoint(x: 0.2, y: 0.5, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.6, y: 0.6, confidence: 0.9)
        )
    }

    /// 重力はそのまま（単位化済み想定）解決される。
    func testResolve_GravityReturnedAsIs() {
        let (_, _, vector) = analyzer.analyze(
            frame: tiltedFrame(),
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10,
            gravityInKeypointSpace: SIMD2<Double>(0, 1)
        )

        XCTAssertEqual(vector.x, 0.0, accuracy: 1e-9)
        XCTAssertEqual(vector.y, 1.0, accuracy: 1e-9)
    }

    /// 非単位の重力は単位化して解決される。
    func testResolve_GravityNormalized() {
        let (_, _, vector) = analyzer.analyze(
            frame: tiltedFrame(),
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10,
            gravityInKeypointSpace: SIMD2<Double>(3, 4)
        )

        XCTAssertEqual(vector.x, 0.6, accuracy: 1e-9)
        XCTAssertEqual(vector.y, 0.8, accuracy: 1e-9)
    }

    /// ゼロ重力は無効として肩ライン直交へ退行する。
    func testResolve_ZeroGravityFallsBackToShoulderLine() {
        let ux = -0.1 / sqrt(0.17)
        let uy = 0.4 / sqrt(0.17)

        let (_, _, vector) = analyzer.analyze(
            frame: tiltedFrame(),
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10,
            gravityInKeypointSpace: SIMD2<Double>(0, 0)
        )

        XCTAssertEqual(vector.x, ux, accuracy: 1e-9)
        XCTAssertEqual(vector.y, uy, accuracy: 1e-9)
    }

    /// nil重力＋両肩有効 → 肩ライン直交上向き法線。
    func testResolve_NilGravityFallsBackToShoulderLine() {
        let ux = -0.1 / sqrt(0.17)
        let uy = 0.4 / sqrt(0.17)

        let (_, _, vector) = analyzer.analyze(
            frame: tiltedFrame(),
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10,
            gravityInKeypointSpace: nil
        )

        XCTAssertEqual(vector.x, ux, accuracy: 1e-9)
        XCTAssertEqual(vector.y, uy, accuracy: 1e-9)
    }

    /// nil重力＋片肩のみ → 画像垂直 (0, 1) 終端。
    func testResolve_NilGravityOneShoulderFallsBackToImageVertical() {
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.2, y: 0.7, confidence: 0.9),
            rightEar: nil,
            leftShoulder: Keypoint(x: 0.2, y: 0.5, confidence: 0.9),
            rightShoulder: nil
        )

        let (_, _, vector) = analyzer.analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10,
            gravityInKeypointSpace: nil
        )

        XCTAssertEqual(vector.x, 0.0, accuracy: 1e-9)
        XCTAssertEqual(vector.y, 1.0, accuracy: 1e-9)
    }

    /// nil重力＋両肩同一点（距離0）→ 画像垂直 (0, 1) 終端。
    func testResolve_NilGravityCoincidentShouldersFallsBackToImageVertical() {
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.5, y: 0.3, confidence: 0.9),
            rightEar: Keypoint(x: 0.5, y: 0.3, confidence: 0.9),
            leftShoulder: Keypoint(x: 0.5, y: 0.5, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.5, y: 0.5, confidence: 0.9)
        )

        let (_, _, vector) = analyzer.analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10,
            gravityInKeypointSpace: nil
        )

        XCTAssertEqual(vector.x, 0.0, accuracy: 1e-9)
        XCTAssertEqual(vector.y, 1.0, accuracy: 1e-9)
    }

    /// 解決ベクトルは常に単位長（1±1e-9）。
    func testResolve_AlwaysUnitLength() {
        let frames: [PoseFrame] = [tiltedFrame()]
        let gravities: [SIMD2<Double>?] = [SIMD2<Double>(0, 1), SIMD2<Double>(3, 4), SIMD2<Double>(0, 0), nil]

        for frame in frames {
            for gravity in gravities {
                let (_, _, vector) = analyzer.analyze(
                    frame: frame,
                    referenceNearAngleDegrees: 0,
                    slouchDeltaThresholdDegrees: 10,
                    gravityInKeypointSpace: gravity
                )
                let length = sqrt(vector.x * vector.x + vector.y * vector.y)
                XCTAssertEqual(length, 1.0, accuracy: 1e-9)
            }
        }
    }

    /// 遠側角度も解決済みベクトルで算出される（重力下で両側とも0度）。
    func testResolve_FarAngleUsesResolvedVector() {
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.3, y: 0.5, confidence: 0.9),
            rightEar: Keypoint(x: 0.7, y: 0.45, confidence: 0.9),
            leftShoulder: Keypoint(x: 0.3, y: 0.6, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.7, y: 0.6, confidence: 0.9)
        )

        let (sample, _, _) = analyzer.analyze(
            frame: frame,
            referenceNearAngleDegrees: 0,
            slouchDeltaThresholdDegrees: 10,
            gravityInKeypointSpace: SIMD2<Double>(0, 1)
        )

        XCTAssertEqual(sample?.nearAngleDegrees ?? -1, 0.0, accuracy: 0.1)
        XCTAssertEqual(sample?.farAngleDegrees ?? -1, 0.0, accuracy: 0.1)
    }
}
