import AVFoundation
import CoreMotion
import XCTest
@testable import NekozeFix

/// Task 12.1: MotionService の変換・単一ホールド・平置き無効の検証。
/// design.md "MotionService（新設）"＋「変換表（全組み合わせ固定）」参照。
/// Requirements 4.1（重力基準・代替鎖）、7.1（向き追従）、9.1（電池・1/30間隔）。
final class MotionServiceTests: XCTestCase {

    private var service: MotionService!

    override func setUp() {
        super.setUp()
        service = MotionService()
    }

    override func tearDown() {
        service.stop()
        service = nil
        super.tearDown()
    }

    // MARK: - 変換表（全組み合わせ固定、grill Q2決定）

    /// 直立端末はいずれの向きでも K=(0,1) に写像される（不変条件）。
    func testConvert_UprightDevice_MapsToUpInAllOrientations() {
        let rows: [(AVCaptureVideoOrientation, CMAcceleration)] = [
            (.portrait, CMAcceleration(x: 0, y: -1, z: 0)),
            (.portraitUpsideDown, CMAcceleration(x: 0, y: 1, z: 0)),
            (.landscapeRight, CMAcceleration(x: -1, y: 0, z: 0)),
            (.landscapeLeft, CMAcceleration(x: 1, y: 0, z: 0)),
        ]
        for (orientation, gravity) in rows {
            let result = MotionService.convert(gravity: gravity, videoOrientation: orientation)
            XCTAssertNotNil(result, "\(orientation) は有効なはず")
            XCTAssertEqual(result!.x, 0, accuracy: 1e-9, "x: \(orientation)")
            XCTAssertEqual(result!.y, 1, accuracy: 1e-9, "y: \(orientation)")
        }
    }

    /// 変換表の全4行を 3-4-5 の重力で表駆動ロックする。
    /// u = (−gx, −gy) = (−0.3, 0.4)、|u| = 0.5。
    func testConvert_AllFourRows_TableDriven() {
        let gravity = CMAcceleration(x: 0.3, y: -0.4, z: 0.1)
        let rows: [(AVCaptureVideoOrientation, SIMD2<Double>)] = [
            // portrait → (−ux, uy) = (0.3, 0.4) → (0.6, 0.8)
            (.portrait, SIMD2<Double>(0.6, 0.8)),
            // portraitUpsideDown → (ux, −uy) = (−0.3, −0.4) → (−0.6, −0.8)
            (.portraitUpsideDown, SIMD2<Double>(-0.6, -0.8)),
            // landscapeRight → (uy, ux) = (0.4, −0.3) → (0.8, −0.6)
            (.landscapeRight, SIMD2<Double>(0.8, -0.6)),
            // landscapeLeft → (−uy, −ux) = (−0.4, 0.3) → (−0.8, 0.6)
            (.landscapeLeft, SIMD2<Double>(-0.8, 0.6)),
        ]
        for (orientation, expected) in rows {
            let result = MotionService.convert(gravity: gravity, videoOrientation: orientation)
            XCTAssertNotNil(result, "\(orientation) は有効なはず")
            XCTAssertEqual(result!.x, expected.x, accuracy: 1e-9, "x: \(orientation)")
            XCTAssertEqual(result!.y, expected.y, accuracy: 1e-9, "y: \(orientation)")
        }
    }

    /// 返値は単位化済みであること。
    func testConvert_OutputIsNormalized() {
        let result = MotionService.convert(
            gravity: CMAcceleration(x: 0.3, y: -0.4, z: 0.1),
            videoOrientation: .portrait
        )
        let length = (result!.x * result!.x + result!.y * result!.y).squareRoot()
        XCTAssertEqual(length, 1.0, accuracy: 1e-9)
    }

    // MARK: - 平置き無効（z支配）

    /// z支配の平置きはいずれの向きでも nil（代替鎖へ退行）。
    func testConvert_Flat_ZDominant_ReturnsNilForAllOrientations() {
        let flat = CMAcceleration(x: 0.05, y: 0.05, z: -0.99)
        let orientations: [AVCaptureVideoOrientation] = [
            .portrait, .portraitUpsideDown, .landscapeRight, .landscapeLeft,
        ]
        for orientation in orientations {
            XCTAssertNil(
                MotionService.convert(gravity: flat, videoOrientation: orientation),
                "平置きは無効のはず: \(orientation)"
            )
        }
    }

    /// 完全な平置き（x=y=0）は正規化不能のため nil。
    func testConvert_ExactlyFlat_ReturnsNil() {
        XCTAssertNil(
            MotionService.convert(
                gravity: CMAcceleration(x: 0, y: 0, z: -1),
                videoOrientation: .portrait
            )
        )
    }

    // MARK: - 単一ホールド（0.5秒、設計値・実装内に閉じる）

    func testHold_InvalidWithinHold_KeepsLastValid() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let valid = SIMD2<Double>(0.6, 0.8)
        service.ingest(converted: valid, now: t0)
        XCTAssertEqual(service.latestGravityInKeypointSpace, valid)

        service.ingest(converted: nil, now: t0.addingTimeInterval(0.3))
        XCTAssertEqual(
            service.latestGravityInKeypointSpace, valid,
            "0.5秒以内の無効は直前有効値を保持する"
        )
    }

    func testHold_InvalidBeyondHold_BecomesNil() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        service.ingest(converted: SIMD2<Double>(0.6, 0.8), now: t0)

        service.ingest(converted: nil, now: t0.addingTimeInterval(0.51))
        XCTAssertNil(
            service.latestGravityInKeypointSpace,
            "0.5秒超過の無効は未取得扱い（nil）"
        )
    }

    /// 単一タイマは最終有効時刻に固定（スライドしない）。
    func testHold_TimerAnchoredAtLastValid_NotSliding() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let valid = SIMD2<Double>(0.6, 0.8)
        service.ingest(converted: valid, now: t0)
        // 0.3秒時点の無効でホールド継続…
        service.ingest(converted: nil, now: t0.addingTimeInterval(0.3))
        XCTAssertEqual(service.latestGravityInKeypointSpace, valid)
        // …しても期限は t0+0.5 のまま。t0+0.6 では nil。
        service.ingest(converted: nil, now: t0.addingTimeInterval(0.6))
        XCTAssertNil(service.latestGravityInKeypointSpace, "単一タイマはスライドしない")
    }

    /// 回復時は即時復帰（通知なし）。
    func testHold_RecoveryIsImmediate() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        service.ingest(converted: SIMD2<Double>(0.6, 0.8), now: t0)
        service.ingest(converted: nil, now: t0.addingTimeInterval(10))
        XCTAssertNil(service.latestGravityInKeypointSpace)

        let recovered = SIMD2<Double>(-0.6, -0.8)
        service.ingest(converted: recovered, now: t0.addingTimeInterval(11))
        XCTAssertEqual(
            service.latestGravityInKeypointSpace, recovered,
            "有効値の回復は即時反映"
        )
    }

    /// 平置きの生サンプルはホールド則で吸収される（保持→超過でnil）。
    func testIngest_FlatGravitySample_HeldThenNil() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let valid = CMAcceleration(x: 0.3, y: -0.4, z: 0.1)
        service.ingest(gravity: valid, videoOrientation: .portrait, now: t0)
        XCTAssertNotNil(service.latestGravityInKeypointSpace)

        let flat = CMAcceleration(x: 0.05, y: 0.05, z: -0.99)
        service.ingest(gravity: flat, videoOrientation: .portrait, now: t0.addingTimeInterval(0.2))
        XCTAssertNotNil(service.latestGravityInKeypointSpace, "平置き直後はホールド")
        service.ingest(gravity: flat, videoOrientation: .portrait, now: t0.addingTimeInterval(0.7))
        XCTAssertNil(service.latestGravityInKeypointSpace, "平置き継続は未取得扱い")
    }

    /// 未取得（nilサンプル）・向き不明も無効としてホールド則に従う。
    func testIngest_MissingSampleOrOrientation_TreatedAsInvalid() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        service.ingest(
            gravity: CMAcceleration(x: 0.3, y: -0.4, z: 0.1),
            videoOrientation: .portrait,
            now: t0
        )
        let held = service.latestGravityInKeypointSpace
        XCTAssertNotNil(held)

        service.ingest(gravity: nil, videoOrientation: .portrait, now: t0.addingTimeInterval(0.1))
        XCTAssertEqual(service.latestGravityInKeypointSpace, held, "未取得はホールド")
        service.ingest(
            gravity: CMAcceleration(x: 0.3, y: -0.4, z: 0.1),
            videoOrientation: nil,
            now: t0.addingTimeInterval(0.2)
        )
        XCTAssertEqual(service.latestGravityInKeypointSpace, held, "向き不明はホールド")
    }

    /// テスト容易性: latestGravityInKeypointSpace は @testable で直接代入できる。
    func testLatestGravity_IsDirectlyAssignable() {
        service.latestGravityInKeypointSpace = SIMD2<Double>(0, 1)
        XCTAssertEqual(service.latestGravityInKeypointSpace, SIMD2<Double>(0, 1))
    }

    // MARK: - 起停

    /// シミュレータ等（DeviceMotion不可）では start 後も持続 nil。
    func testStart_WithoutDeviceMotionAvailability_StaysNil() {
        guard !CMMotionManager().isDeviceMotionAvailable else { return }
        service.start()
        XCTAssertNil(
            service.latestGravityInKeypointSpace,
            "利用不可環境では持続的に nil を返す"
        )
    }

    /// stop は保持値を破棄し nil に戻す（停止中は nil 扱い）。
    func testStop_ClearsHeldValue() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        service.ingest(converted: SIMD2<Double>(0.6, 0.8), now: t0)
        XCTAssertNotNil(service.latestGravityInKeypointSpace)

        service.stop()
        XCTAssertNil(service.latestGravityInKeypointSpace, "停止後は nil 扱い")
    }
}
