import XCTest
@testable import NekozeFix

final class FrameThrottleTests: XCTestCase {

    func test_init_maxFPS_determinesMinInterval() {
        // 前提: 10FPS指定
        let throttle = FrameThrottle(maxFPS: 10.0)

        // 検証: 上限間隔が注入値から定まる（1/10秒）
        XCTAssertEqual(throttle.minInterval, 0.1, accuracy: 1e-9)
        XCTAssertEqual(throttle.maxFPS, 10.0)
    }

    func test_init_default_matchesDocumentedProvisionalValue() {
        // 前提: 引数なしの既定生成
        let throttle = FrameThrottle()

        // 検証: 暫定既定15.0FPS（最終選定はタスク3.3の実測比較に委ねる）
        XCTAssertEqual(throttle.maxFPS, 15.0)
        XCTAssertEqual(throttle.minInterval, 1.0 / 15.0, accuracy: 1e-9)
    }

    func test_shouldInfer_firstFrame_returnsTrue() {
        // 前提: 初期状態の判定器
        var throttle = FrameThrottle(maxFPS: 10.0)

        // 手順: 最初のフレーム時刻を提示
        let result = throttle.shouldInfer(at: 100.0)

        // 検証: 初回は推論対象
        XCTAssertTrue(result)
    }

    func test_shouldInfer_intervalBelowLimit_returnsFalse() {
        // 前提: 10FPS（上限間隔0.1秒）、時刻100.0で推論済み
        var throttle = FrameThrottle(maxFPS: 10.0)
        XCTAssertTrue(throttle.shouldInfer(at: 100.0))

        // 手順: 上限間隔未満の時刻を提示
        let result = throttle.shouldInfer(at: 100.05)

        // 検証: 推論対象外
        XCTAssertFalse(result)
    }

    func test_shouldInfer_intervalAtLimit_returnsTrue() {
        // 前提: 10FPS（上限間隔0.1秒）、時刻100.0で推論済み
        var throttle = FrameThrottle(maxFPS: 10.0)
        XCTAssertTrue(throttle.shouldInfer(at: 100.0))

        // 手順: ちょうど上限間隔後の時刻を提示
        let result = throttle.shouldInfer(at: 100.1)

        // 検証: 境界は推論対象（含む）
        XCTAssertTrue(result)
    }

    func test_shouldInfer_rejectedFrame_preservesState() {
        // 前提: 10FPS、時刻100.0で推論済み
        var throttle = FrameThrottle(maxFPS: 10.0)
        XCTAssertTrue(throttle.shouldInfer(at: 100.0))

        // 手順: 対象外フレームの後に上限間隔を満たす時刻を提示
        XCTAssertFalse(throttle.shouldInfer(at: 100.05))

        // 検証: 対象外判定で前回時刻は進んでいない（100.0基準で判定）
        XCTAssertTrue(throttle.shouldInfer(at: 100.1))
    }

    func test_shouldInfer_invalidTimestamp_returnsTrue() {
        // 前提: 10FPS、時刻100.0で推論済み
        var throttle = FrameThrottle(maxFPS: 10.0)
        XCTAssertTrue(throttle.shouldInfer(at: 100.0))

        // 検証: 無効時刻は推論実行側に倒す（検出機会を保つ）
        var nanThrottle = throttle
        XCTAssertTrue(nanThrottle.shouldInfer(at: .nan))
        var negativeThrottle = throttle
        XCTAssertTrue(negativeThrottle.shouldInfer(at: -1.0))
        var infiniteThrottle = throttle
        XCTAssertTrue(infiniteThrottle.shouldInfer(at: .infinity))
        var negativeInfiniteThrottle = throttle
        XCTAssertTrue(negativeInfiniteThrottle.shouldInfer(at: -.infinity))
    }

    func test_shouldInfer_invalidTimestamp_doesNotCorruptState() {
        // 前提: 10FPS、時刻100.0で推論済み
        var throttle = FrameThrottle(maxFPS: 10.0)
        XCTAssertTrue(throttle.shouldInfer(at: 100.0))

        // 手順: 無効時刻を提示（推論対象だが前回時刻を汚さない）
        XCTAssertTrue(throttle.shouldInfer(at: .nan))

        // 検証: 直後の近接時刻は依然として対象外（基準は100.0のまま）
        XCTAssertFalse(throttle.shouldInfer(at: 100.05))
        XCTAssertTrue(throttle.shouldInfer(at: 100.1))
    }

    func test_reset_clearsLastInferenceTime() {
        // 前提: 10FPS、時刻100.0で推論済み
        var throttle = FrameThrottle(maxFPS: 10.0)
        XCTAssertTrue(throttle.shouldInfer(at: 100.0))
        XCTAssertFalse(throttle.shouldInfer(at: 100.05))

        // 手順: 状態を初期化
        throttle.reset()

        // 検証: 初期化直後は次のフレームが推論対象になる
        XCTAssertTrue(throttle.shouldInfer(at: 100.05))
    }
}
