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

    func test_counters_arrivalInferDrop_advanceCorrectly() {
        // 前提: 10FPS（上限間隔0.1秒）の初期状態
        var throttle = FrameThrottle(maxFPS: 10.0)

        // 手順: 推論対象→対象外→推論対象の順に提示
        XCTAssertTrue(throttle.shouldInfer(at: 100.0))
        XCTAssertFalse(throttle.shouldInfer(at: 100.05))
        XCTAssertTrue(throttle.shouldInfer(at: 100.1))

        // 検証: 到達数は呼出ごとに1ずつ、推論・破棄は判定結果に従う（要件1.1, 1.2）
        let snapshot = throttle.snapshot()
        XCTAssertEqual(snapshot.arrivals, 3)
        XCTAssertEqual(snapshot.inferences, 2)
        XCTAssertEqual(snapshot.drops, 1)
    }

    func test_counters_invalidTimestamp_countsAsArrivalAndInference() {
        // 前提: 10FPS、時刻100.0で推論済み
        var throttle = FrameThrottle(maxFPS: 10.0)
        XCTAssertTrue(throttle.shouldInfer(at: 100.0))

        // 手順: 無効時刻を提示（推論対象に倒す）
        XCTAssertTrue(throttle.shouldInfer(at: .nan))

        // 検証: 到達・推論の双方が進む
        let snapshot = throttle.snapshot()
        XCTAssertEqual(snapshot.arrivals, 2)
        XCTAssertEqual(snapshot.inferences, 2)
        XCTAssertEqual(snapshot.drops, 0)
    }

    func test_recordInference_accumulatesTotalTime() {
        // 前提: 初期状態の判定器
        var throttle = FrameThrottle(maxFPS: 10.0)

        // 手順: 推論所要時間を2回記録
        throttle.recordInference(duration: 0.02)
        throttle.recordInference(duration: 0.03)

        // 検証: 推論累積時間のみが加算される
        XCTAssertEqual(throttle.snapshot().totalInferenceTime, 0.05, accuracy: 1e-9)
    }

    func test_reset_clearsCountersAndGate() {
        // 前提: 10FPS、計数と前回時刻が進んだ状態
        var throttle = FrameThrottle(maxFPS: 10.0)
        XCTAssertTrue(throttle.shouldInfer(at: 100.0))
        XCTAssertFalse(throttle.shouldInfer(at: 100.05))
        throttle.recordInference(duration: 0.02)

        // 手順: 状態を初期化（要件6.1 停止・再開時の初期化）
        throttle.reset()

        // 検証: 計数が全て零に戻る
        let snapshot = throttle.snapshot()
        XCTAssertEqual(snapshot.arrivals, 0)
        XCTAssertEqual(snapshot.inferences, 0)
        XCTAssertEqual(snapshot.drops, 0)
        XCTAssertEqual(snapshot.totalInferenceTime, 0.0, accuracy: 1e-9)

        // 検証: ゲート状態も初期化され次のフレームが推論対象になる
        XCTAssertTrue(throttle.shouldInfer(at: 100.05))
    }

    func test_snapshot_isValueCopy() {
        // 前提: 計数が進んだ状態
        var throttle = FrameThrottle(maxFPS: 10.0)
        XCTAssertTrue(throttle.shouldInfer(at: 100.0))

        // 手順: 読み出した複写を置き換える
        var copy = throttle.snapshot()
        copy = FrameThrottle.Metrics(arrivals: 999, inferences: 999, drops: 999, totalInferenceTime: 999)

        // 検証: 内部状態は変わらない（要件1.3 複写読出し）
        let reread = throttle.snapshot()
        XCTAssertEqual(reread.arrivals, 1)
        XCTAssertEqual(reread.inferences, 1)
        XCTAssertEqual(reread.drops, 0)
        XCTAssertEqual(reread.totalInferenceTime, 0.0, accuracy: 1e-9)
    }

    func test_counting_doesNotAffectDetectionOutcomes() {
        // 前提: 同一上限の判定器を2台用意し、片方だけ計測読出しと時間記録を挟む
        var measured = FrameThrottle(maxFPS: 10.0)
        var plain = FrameThrottle(maxFPS: 10.0)
        let timestamps: [TimeInterval] = [100.0, 100.05, 100.1, .nan, 100.15, 100.2]

        // 手順: 同一時刻列を両方に提示し、片方には計測操作を混ぜる
        var measuredResults: [Bool] = []
        var plainResults: [Bool] = []
        for timestamp in timestamps {
            _ = measured.snapshot()
            measuredResults.append(measured.shouldInfer(at: timestamp))
            measured.recordInference(duration: 0.01)
            _ = measured.snapshot()
            plainResults.append(plain.shouldInfer(at: timestamp))
        }

        // 検証: 計測の有無で検出結果と呼出順序（結果列）が変わらない
        XCTAssertEqual(measuredResults, plainResults)
    }
}
