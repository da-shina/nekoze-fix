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

    func test_setLimit_lowerFPS_appliesNewIntervalFromPreservedLastTime() {
        // 前提: 15FPS（上限間隔約0.0667秒）、時刻0で推論済み
        var throttle = FrameThrottle(maxFPS: 15.0)
        XCTAssertTrue(throttle.shouldInfer(at: 0.0))

        // 手順: 判定中に上限を10FPS（上限間隔0.1秒）へ切替え
        throttle.setLimit(10.0)

        // 検証: 前回推論時刻を維持し、次回判定から新間隔で評価する
        // 旧間隔なら対象（0.08 >= 0.0667）だが新間隔では対象外
        XCTAssertEqual(throttle.maxFPS, 10.0)
        XCTAssertEqual(throttle.minInterval, 0.1, accuracy: 1e-9)
        XCTAssertFalse(throttle.shouldInfer(at: 0.08))
        XCTAssertTrue(throttle.shouldInfer(at: 0.1))
    }

    func test_setLimit_higherFPS_allowsEarlierNextInfer() {
        // 前提: 10FPS（上限間隔0.1秒）、時刻0で推論済み
        var throttle = FrameThrottle(maxFPS: 10.0)
        XCTAssertTrue(throttle.shouldInfer(at: 0.0))

        // 手順: 判定中に上限を15FPS（上限間隔約0.0667秒）へ切替え
        throttle.setLimit(15.0)

        // 検証: 新間隔では0.08が推論対象になる（旧間隔なら対象外）
        XCTAssertEqual(throttle.maxFPS, 15.0)
        XCTAssertTrue(throttle.shouldInfer(at: 0.08))
    }

    func test_setLimit_doesNotResetCounters() {
        // 前提: 10FPS、計数が進んだ状態（到達2・推論1・破棄1）
        var throttle = FrameThrottle(maxFPS: 10.0)
        XCTAssertTrue(throttle.shouldInfer(at: 0.0))
        XCTAssertFalse(throttle.shouldInfer(at: 0.05))

        // 手順: 上限のみ切替え
        throttle.setLimit(15.0)

        // 検証: 計数は維持される
        let snapshot = throttle.snapshot()
        XCTAssertEqual(snapshot.arrivals, 2)
        XCTAssertEqual(snapshot.inferences, 1)
        XCTAssertEqual(snapshot.drops, 1)
    }

    func test_setLimit_invalidFPS_fallsBackToDefault() {
        // 前提: 10FPS、時刻0で推論済み
        var throttle = FrameThrottle(maxFPS: 10.0)
        XCTAssertTrue(throttle.shouldInfer(at: 0.0))

        // 手順: 不正値へ切替え（initと同一の防御則で既定値に倒す）
        throttle.setLimit(0.0)

        // 検証: 既定15.0FPSに倒し、前回推論時刻は維持される
        XCTAssertEqual(throttle.maxFPS, FrameThrottle.defaultMaxFPS)
        XCTAssertEqual(throttle.minInterval, 1.0 / FrameThrottle.defaultMaxFPS, accuracy: 1e-9)
        XCTAssertFalse(throttle.shouldInfer(at: 0.05))
        XCTAssertTrue(throttle.shouldInfer(at: 1.0 / FrameThrottle.defaultMaxFPS))

        // 検証: 不正値の別種（NaN・負・無限大）も既定値に倒す
        throttle.setLimit(.nan)
        XCTAssertEqual(throttle.maxFPS, FrameThrottle.defaultMaxFPS)
        throttle.setLimit(-5.0)
        XCTAssertEqual(throttle.maxFPS, FrameThrottle.defaultMaxFPS)
        throttle.setLimit(.infinity)
        XCTAssertEqual(throttle.maxFPS, FrameThrottle.defaultMaxFPS)
    }

    func test_init_invalidFPS_fallsBackToDefault() {
        // 前提: 不正な上限値での生成（initとsetLimitは同一の防御則）
        // 検証: いずれも既定15.0FPSに倒し、上限間隔も既定から導出される
        for invalid in [0.0, -5.0, Double.nan, Double.infinity, -Double.infinity] {
            let throttle = FrameThrottle(maxFPS: invalid)
            XCTAssertEqual(throttle.maxFPS, FrameThrottle.defaultMaxFPS, "init(\(invalid))")
            XCTAssertEqual(throttle.minInterval, 1.0 / FrameThrottle.defaultMaxFPS, accuracy: 1e-9)
        }
    }

    func test_recordInference_invalidDuration_ignored() {
        // 前提: 推論所要時間を記録済みの判定器
        var throttle = FrameThrottle(maxFPS: 10.0)
        throttle.recordInference(duration: 0.02)

        // 手順: 無効値（NaN・負・無限大）を記録
        throttle.recordInference(duration: .nan)
        throttle.recordInference(duration: -0.01)
        throttle.recordInference(duration: .infinity)
        throttle.recordInference(duration: -.infinity)

        // 検証: 推論累積時間は有効値の記録のみを反映し、無効値は無視される
        XCTAssertEqual(throttle.snapshot().totalInferenceTime, 0.02, accuracy: 1e-9)
    }

    func test_shouldInfer_intervalAboveLimit_returnsTrue() {
        // 前提: 10FPS（上限間隔0.1秒）、時刻100.0で推論済み
        var throttle = FrameThrottle(maxFPS: 10.0)
        XCTAssertTrue(throttle.shouldInfer(at: 100.0))

        // 手順: 上限間隔を超える時刻を提示
        let result = throttle.shouldInfer(at: 100.15)

        // 検証: 推論対象
        XCTAssertTrue(result)
    }

    func test_shouldInfer_intervalWithinEpsilon_returnsTrue() {
        // 前提: 10FPS（上限間隔0.1秒）、時刻100.0で推論済み
        // 境界比較には -1e-9 のイプシロンを用いる（Double誤差対策）
        var throttle = FrameThrottle(maxFPS: 10.0)
        XCTAssertTrue(throttle.shouldInfer(at: 100.0))

        // 検証: 上限間隔まで1e-9未満の不足は推論対象（含む）
        var withinThrottle = throttle
        XCTAssertTrue(withinThrottle.shouldInfer(at: 100.0 + 0.1 - 5e-10))

        // 検証: 上限間隔まで1e-9を超える不足は推論対象外
        var outsideThrottle = throttle
        XCTAssertFalse(outsideThrottle.shouldInfer(at: 100.0 + 0.1 - 2e-9))
    }
}
