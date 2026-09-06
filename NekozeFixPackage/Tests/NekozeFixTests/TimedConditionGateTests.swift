import XCTest
@testable import NekozeFix

final class TimedConditionGateTests: XCTestCase {

    // MARK: - 4.2: 5秒間の継続的検出が必要

    func test_5SecondsContinuous_triggersTrue() {
        // 前提: 5.0秒を要するゲート
        var gate = TimedConditionGate(requiredDuration: 5.0)
        let startTime = CFAbsoluteTimeGetCurrent()

        // 実行: 条件がtrueの状態で5秒以上tickする
        var currentTime = startTime
        for _ in 0..<300 {  // 約60fpsで300フレーム = 5秒
            let result = gate.tick(isConditionMet: true, now: currentTime)
            if result {
                // 検証: 正確に1回だけトリガーする
                XCTAssertTrue(gate.isFired)
                return
            }
            currentTime += 1.0 / 60.0
        }

        // 検証: トリガーされているはず
        XCTFail("継続的に条件がtrueの状態で5秒後、ゲートが発火するはず")
    }

    func test_lessThan5Seconds_doesNotTrigger() {
        // 前提: 5.0秒を要するゲート
        var gate = TimedConditionGate(requiredDuration: 5.0)
        let startTime = CFAbsoluteTimeGetCurrent()

        // 実行: 条件がtrueの状態で4.9秒だけtickする
        var currentTime = startTime
        for _ in 0..<293 {  // 約60fpsで293フレーム = 4.883秒
            _ = gate.tick(isConditionMet: true, now: currentTime)
            currentTime += 1.0 / 60.0
        }

        // 検証: まだ発火していないはず
        XCTAssertFalse(gate.isFired, "5秒前は発火しないはず")
        let result = gate.tick(isConditionMet: true, now: currentTime)
        XCTAssertFalse(result, "5秒になる前はtickがfalseを返す")
    }

    // MARK: - 4.3: 改善時は即座リセット

    func test_conditionFalse_immediatelyResetsAccumulator() {
        // 前提: 5.0秒を要するゲート、部分的に蓄積済み
        var gate = TimedConditionGate(requiredDuration: 5.0)
        let startTime = CFAbsoluteTimeGetCurrent()

        // 3秒間蓄積
        var currentTime = startTime
        for _ in 0..<180 {  // 約60fpsで180フレーム = 3秒
            _ = gate.tick(isConditionMet: true, now: currentTime)
            currentTime += 1.0 / 60.0
        }
        XCTAssertFalse(gate.isFired)

        // 実行: 条件がfalseになる（人不在 / 姿勢改善）
        let result = gate.tick(isConditionMet: false, now: currentTime)

        // 検証: アキュムレータは即座にリセットされる
        XCTAssertEqual(gate.accumulated, 0.0, accuracy: 0.001)
        XCTAssertFalse(gate.isFired)
        XCTAssertFalse(result)
    }

    // MARK: - Q6: 人不在時は即座リセット

    func test_personMissing_resetsImmediately() {
        // 前提: 5.0秒を要するゲート、2秒蓄積済み
        var gate = TimedConditionGate(requiredDuration: 5.0)
        let startTime = CFAbsoluteTimeGetCurrent()
        var currentTime = startTime

        // 2秒間蓄積
        for _ in 0..<120 {  // 約60fpsで120フレーム = 2秒
            _ = gate.tick(isConditionMet: true, now: currentTime)
            currentTime += 1.0 / 60.0
        }

        // 実行: 人不在（isConditionMet == false）
        let result = gate.tick(isConditionMet: false, now: currentTime)

        // 検証: ゲートは即座にリセットされる
        XCTAssertEqual(gate.accumulated, 0.0, accuracy: 0.001)
        XCTAssertFalse(gate.isFired)
        XCTAssertFalse(result)
    }

    // MARK: - キャリブレーション: 3.0秒

    func test_3SecondsContinuous_triggersTrue() {
        // 前提: 3.0秒を要するゲート（キャリブレーション用）
        var gate = TimedConditionGate(requiredDuration: 3.0)
        let startTime = CFAbsoluteTimeGetCurrent()

        // 実行: 条件がtrueの状態で3秒以上tickする
        var currentTime = startTime
        for _ in 0..<180 {  // 約60fpsで180フレーム = 3秒
            let result = gate.tick(isConditionMet: true, now: currentTime)
            if result {
                // 検証: 正確に1回だけトリガーする
                XCTAssertTrue(gate.isFired)
                return
            }
            currentTime += 1.0 / 60.0
        }

        // 検証: トリガーされているはず
        XCTFail("継続的に条件がtrueの状態で3秒後、ゲートが発火するはず")
    }

    // MARK: - 2.4: 姿勢が不安定になったら蓄積をリセット

    func test_postureUnstable_resetsAccumulation() {
        // 前提: 3.0秒を要するゲート、2秒蓄積済み
        var gate = TimedConditionGate(requiredDuration: 3.0)
        let startTime = CFAbsoluteTimeGetCurrent()
        var currentTime = startTime

        // 2秒間蓄積
        for _ in 0..<120 {  // 約60fpsで120フレーム = 2秒
            _ = gate.tick(isConditionMet: true, now: currentTime)
            currentTime += 1.0 / 60.0
        }

        // 実行: 条件がfalseになる（姿勢不安定）
        _ = gate.tick(isConditionMet: false, now: currentTime)

        // 検証: アキュムレータがリセットされる
        XCTAssertEqual(gate.accumulated, 0.0, accuracy: 0.001)
        XCTAssertFalse(gate.isFired)
    }

    // MARK: - reset()

    func test_reset_clearsState() {
        // 前提: いくらかの時間を蓄積したゲート
        var gate = TimedConditionGate(requiredDuration: 3.0)
        let startTime = CFAbsoluteTimeGetCurrent()
        var currentTime = startTime

        // 1.5秒間蓄積
        for _ in 0..<90 {
            _ = gate.tick(isConditionMet: true, now: currentTime)
            currentTime += 1.0 / 60.0
        }

        // 実行: reset() が呼び出される
        gate.reset()

        // 検証: 状態がクリアされる
        XCTAssertEqual(gate.accumulated, 0.0, accuracy: 0.001)
        XCTAssertFalse(gate.isFired)
    }

    // MARK: - Q5: ローテーション中はゲート保持（tick呼び出しなし）

    func test_gateHeldDuringRotation_whenTickResumes() {
        // 前提: 3.0秒を要するゲート、2秒蓄積済み
        var gate = TimedConditionGate(requiredDuration: 3.0)
        let startTime = CFAbsoluteTimeGetCurrent()
        var currentTime = startTime

        // 2秒間蓄積
        for _ in 0..<120 {  // 約60fpsで120フレーム = 2秒
            _ = gate.tick(isConditionMet: true, now: currentTime)
            currentTime += 1.0 / 60.0
        }

        // 実行: ローテーションによりtick呼び出しが2秒間停止した後再開
        currentTime += 2.0  // ローテーション中の2秒間のtickなしをシミュレート
        let result = gate.tick(isConditionMet: true, now: currentTime)

        // 検証: 発火する（蓄積済み2秒 + 間隔2秒 = 4秒 > 必要3秒）
        // 注: falseでtickが呼ばれなかったため、間隔ではリセットされない
        // ローテーション中、ゲートは蓄積時間を保持する
        XCTAssertTrue(result, "ローテーション完了後にゲートが発火するはず")
    }
}