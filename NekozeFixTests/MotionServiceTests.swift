import CoreMotion
import XCTest
@testable import NekozeFix

/// Task 12.1: MotionService の変換・単一ホールド・平置き無効の検証。
/// design.md "MotionService（新設）" 参照。
/// Requirements 4.1（重力基準・代替鎖）、9.1（電池・1/30間隔）。
///
/// 方向の契約（14.2 実機検収の知見）: キャプチャ接続が出力向きに応じてバッファを
/// 物理回転させるため、重力のデバイス座標はバッファ座標と軸一致する。
/// 天方向 K は常に `normalize(−gx, −gy)` で求まる（向き非依存）。
/// 旧来の向き別変換表は誤り（右傾きの鏡像反転）として撤去済み。
@MainActor
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

    // MARK: - 変換（向き非依存: K = normalize(−gx, −gy)）

    /// 各姿勢の重力は対応する天方向に写像される（向き引数なし）。
    func testConvert_PhysicalAttitudes_MapToSkyDirection() {
        let rows: [(CMAcceleration, SIMD2<Double>)] = [
            // 直立縦持ち: g=(0,−1,0) → K=(0,1)
            (CMAcceleration(x: 0, y: -1, z: 0), SIMD2<Double>(0, 1)),
            // 逆さ縦: g=(0,1,0) → K=(0,−1)
            (CMAcceleration(x: 0, y: 1, z: 0), SIMD2<Double>(0, -1)),
            // 右に90度回転（上端が右）: g=(1,0,0) → K=(−1,0)
            (CMAcceleration(x: 1, y: 0, z: 0), SIMD2<Double>(-1, 0)),
            // 左に90度回転（上端が左）: g=(−1,0,0) → K=(1,0)
            (CMAcceleration(x: -1, y: 0, z: 0), SIMD2<Double>(1, 0)),
        ]
        for (gravity, expected) in rows {
            let result = MotionService.convert(gravity: gravity)
            XCTAssertNotNil(result, "g=(\(gravity.x),\(gravity.y)) は有効なはず")
            XCTAssertEqual(result!.x, expected.x, accuracy: 1e-9, "x: g=(\(gravity.x),\(gravity.y))")
            XCTAssertEqual(result!.y, expected.y, accuracy: 1e-9, "y: g=(\(gravity.x),\(gravity.y))")
        }
    }

    /// 3-4-5 の重力は単位化される。u = (−0.3, 0.4)、|u| = 0.5 → (−0.6, 0.8)。
    func testConvert_ArbitraryGravity_IsNormalized() {
        let result = MotionService.convert(gravity: CMAcceleration(x: 0.3, y: -0.4, z: 0.1))
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.x, -0.6, accuracy: 1e-9)
        XCTAssertEqual(result!.y, 0.8, accuracy: 1e-9)
        let length = (result!.x * result!.x + result!.y * result!.y).squareRoot()
        XCTAssertEqual(length, 1.0, accuracy: 1e-9)
    }

    // MARK: - 実機回帰: 傾きの鏡像符号（14.2 検収で発覚）

    /// 右傾き（時計回り30度）の重力は左傾きの天方向に写像されること。
    /// gravity=(0.5,−0.866,0) → u=(−0.5,0.866) → K≈(−0.5,0.866)。x は負でなければならない。
    func testConvert_TiltedRight_MapsToLeftLeaningUp() {
        let gravity = CMAcceleration(x: 0.5, y: -0.8660254, z: 0.0)
        let result = MotionService.convert(gravity: gravity)
        XCTAssertNotNil(result, "傾きは有効なはず")
        XCTAssertLessThan(result!.x, 0, "右傾きで緑線が右に傾くのは鏡像バグ")
        XCTAssertEqual(result!.x, -0.5, accuracy: 1e-6)
        XCTAssertEqual(result!.y, 0.8660254, accuracy: 1e-6)
    }

    /// 左傾き（反時計回り30度）の重力は右傾きの天方向に写像されること。
    func testConvert_TiltedLeft_MapsToRightLeaningUp() {
        let gravity = CMAcceleration(x: -0.5, y: -0.8660254, z: 0.0)
        let result = MotionService.convert(gravity: gravity)
        XCTAssertNotNil(result, "傾きは有効なはず")
        XCTAssertGreaterThan(result!.x, 0)
        XCTAssertEqual(result!.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(result!.y, 0.8660254, accuracy: 1e-6)
    }

    // MARK: - 平置き無効（z支配）

    /// z支配の平置きは nil（代替鎖へ退行）。
    func testConvert_Flat_ZDominant_ReturnsNil() {
        let flat = CMAcceleration(x: 0.05, y: 0.05, z: -0.99)
        XCTAssertNil(MotionService.convert(gravity: flat), "平置きは無効のはず")
    }

    /// 完全な平置き（x=y=0）は正規化不能のため nil。
    func testConvert_ExactlyFlat_ReturnsNil() {
        XCTAssertNil(MotionService.convert(gravity: CMAcceleration(x: 0, y: 0, z: -1)))
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
        service.ingest(gravity: valid, now: t0)
        XCTAssertNotNil(service.latestGravityInKeypointSpace)

        let flat = CMAcceleration(x: 0.05, y: 0.05, z: -0.99)
        service.ingest(gravity: flat, now: t0.addingTimeInterval(0.2))
        XCTAssertNotNil(service.latestGravityInKeypointSpace, "平置き直後はホールド")
        service.ingest(gravity: flat, now: t0.addingTimeInterval(0.7))
        XCTAssertNil(service.latestGravityInKeypointSpace, "平置き継続は未取得扱い")
    }

    /// 未取得（nilサンプル）は無効としてホールド則に従う。
    func testIngest_MissingSample_TreatedAsInvalid() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        service.ingest(gravity: CMAcceleration(x: 0.3, y: -0.4, z: 0.1), now: t0)
        let held = service.latestGravityInKeypointSpace
        XCTAssertNotNil(held)

        service.ingest(gravity: nil, now: t0.addingTimeInterval(0.1))
        XCTAssertEqual(service.latestGravityInKeypointSpace, held, "未取得はホールド")
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
