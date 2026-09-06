import XCTest
@testable import NekozeFix

final class TimedConditionGateTests: XCTestCase {

    func test_tick_while_conditionTrue_accumulatesTime() {
        // Given: a gate requiring 3.0 seconds
        var gate = TimedConditionGate(requiredDuration: 3.0)
        let startTime = CFAbsoluteTimeGetCurrent()

        // When: tick with condition true for 2.5 seconds
        for _ in 0..<25 {  // 25 frames at ~60fps = 0.417 seconds
            gate.tick(isConditionMet: true, now: CFAbsoluteTimeGetCurrent())
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            XCTAssertLessThanOrEqual(elapsed, 0.5)  // Keep test fast
        }

        // Then: should not have fired yet
        XCTAssertFalse(gate.tick(isConditionMet: true, now: CFAbsoluteTimeGetCurrent()))
    }

    func test_tick_while_conditionFalse_resetsAccumulator() {
        // Given: a gate requiring 3.0 seconds, partially accumulated
        var gate = TimedConditionGate(requiredDuration: 3.0)
        gate.accumulated = 1.5  // Simulate 1.5 seconds accumulated
        let startTime = CFAbsoluteTimeGetCurrent()

        // When: condition becomes false immediately
        gate.tick(isConditionMet: false, now: CFAbsoluteTimeGetCurrent())

        // Then: accumulator should be reset to 0
        XCTAssertEqual(gate.accumulated, 0.0)
        XCTAssertFalse(gate.isFired)
    }

    func test_tick_firesOnceWhenDurationReached() {
        // Given: a gate requiring 0.1 seconds (100ms)
        var gate = TimedConditionGate(requiredDuration: 0.1)
        let startTime = CFAbsoluteTimeGetCurrent()

        // When: tick with condition true for 0.2 seconds (200ms)
        for _ in 0..<12 {  // 12 frames at ~60fps = 0.2 seconds
            gate.tick(isConditionMet: true, now: CFAbsoluteTimeGetCurrent())
        }

        // Then: should have fired once
        XCTAssertTrue(gate.tick(isConditionMet: true, now: CFAbsoluteTimeGetCurrent()))
        XCTAssertTrue(gate.isFired)
    }

    func test_tick_falseResetsImmediately() {
        // Given: a gate requiring 5.0 seconds, accumulated time 4.0 seconds
        var gate = TimedConditionGate(requiredDuration: 5.0)
        gate.accumulated = 4.0

        // When: condition becomes false
        gate.tick(isConditionMet: false, now: CFAbsoluteTimeGetCurrent())

        // Then: accumulator should reset immediately
        XCTAssertEqual(gate.accumulated, 0.0)
        XCTAssertFalse(gate.isFired)
    }

    func test_tick_trueAfterReset_shouldStartAccumulatingAgain() {
        // Given: gate with 3.0s requirement, already reset
        var gate = TimedConditionGate(requiredDuration: 3.0)

        // When: condition true for 1.5 seconds
        for _ in 0..<25 {
            gate.tick(isConditionMet: true, now: CFAbsoluteTimeGetCurrent())
        }

        // Then: should not have fired yet (1.5s < 3.0s)
        XCTAssertFalse(gate.isFired)

        // When: condition true for another 1.5 seconds
        for _ in 0..<25 {
            gate.tick(isConditionMet: true, now: CFAbsoluteTimeGetCurrent())
        }

        // Then: should have fired once
        XCTAssertTrue(gate.tick(isConditionMet: true, now: CFAbsoluteTimeGetCurrent()))
        XCTAssertTrue(gate.isFired)
    }
}