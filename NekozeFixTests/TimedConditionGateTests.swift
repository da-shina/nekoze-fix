import XCTest
@testable import NekozeFix

final class TimedConditionGateTests: XCTestCase {

    func test_tick_while_conditionTrue_accumulatesTime() {
        // 前提: 3.0秒必要なゲート
        var gate = TimedConditionGate(requiredDuration: 3.0)

        // 手順: 条件がtrueで2.5秒間tick（実際のdeltaTimeを使用）
        let deltaTime: TimeInterval = 1.0 / 60.0  // 約60fps
        for _ in 0..<150 {  // 150フレーム = 2.5秒
            gate.tick(isConditionMet: true, deltaTime: deltaTime)
        }

        // 検証: まだ発火していない（2.5秒 < 3.0秒）
        XCTAssertFalse(gate.tick(isConditionMet: true, deltaTime: deltaTime))
    }

    func test_tick_while_conditionFalse_resetsAccumulator() {
        // 前提: 3.0秒必要なゲート、部分的に蓄積済み
        var gate = TimedConditionGate(requiredDuration: 3.0)
        gate.accumulated = 1.5  // 1.5秒蓄積をシミュレート

        // 手順: 条件がfalseになる
        gate.tick(isConditionMet: false, deltaTime: 0.0)

        // 検証: アキュムレータが0にリセットされる
        XCTAssertEqual(gate.accumulated, 0.0)
        XCTAssertFalse(gate.isFired)
    }

    func test_tick_firesOnceWhenDurationReached() {
        // 前提: 2.0秒必要なゲート
        var gate = TimedConditionGate(requiredDuration: 2.0)
        let deltaTime: TimeInterval = 1.0 / 60.0  // 約60fps

        // 手順: 条件がtrueで2.0秒間tick
        for _ in 0..<120 {  // 120フレーム = 2.0秒
            gate.tick(isConditionMet: true, deltaTime: deltaTime)
        }

        // 検証: 発火しているはず
        XCTAssertTrue(gate.isFired)
        // 後続のtickはfalseを返す（すでに発火済み）
        XCTAssertFalse(gate.tick(isConditionMet: true, deltaTime: deltaTime))
    }

    func test_tick_falseResetsImmediately() {
        // 前提: 5.0秒必要なゲート、蓄積時間4.0秒
        var gate = TimedConditionGate(requiredDuration: 5.0)
        gate.accumulated = 4.0

        // 手順: 条件がfalseになる
        gate.tick(isConditionMet: false, deltaTime: 0.0)

        // 検証: アキュムレータが即座にリセット
        XCTAssertEqual(gate.accumulated, 0.0)
        XCTAssertFalse(gate.isFired)
    }

    func test_tick_trueAfterReset_shouldStartAccumulatingAgain() {
        // 前提: 3.0秒要件のゲート
        var gate = TimedConditionGate(requiredDuration: 3.0)
        let deltaTime: TimeInterval = 1.0 / 60.0  // 約60fps

        // 手順: 条件が1.5秒間true
        for _ in 0..<90 {
            gate.tick(isConditionMet: true, deltaTime: deltaTime)
        }

        // 検証: まだ発火していない（1.5秒 < 3.0秒）
        XCTAssertFalse(gate.isFired)

        // 手順: 条件がfalseになり、再びtrueになる
        gate.tick(isConditionMet: false, deltaTime: 0.0)
        for _ in 0..<180 {  // 180フレーム = 3.0秒
            gate.tick(isConditionMet: true, deltaTime: deltaTime)
        }

        // 検証: 発火しているはず
        XCTAssertTrue(gate.isFired)
    }

    func test_tick_usesActualDeltaTime() {
        // 前提: 1.0秒必要なゲート
        var gate = TimedConditionGate(requiredDuration: 1.0)

        // 手順: 大きなdeltaTimeでtick（フレームレートが遅い場合をシミュレート）
        gate.tick(isConditionMet: true, deltaTime: 0.5)  // 500ms
        gate.tick(isConditionMet: true, deltaTime: 0.5)  // 500ms

        // 検証: 発火しているはず（1.0秒 >= 1.0秒）
        XCTAssertTrue(gate.isFired)
    }
}
