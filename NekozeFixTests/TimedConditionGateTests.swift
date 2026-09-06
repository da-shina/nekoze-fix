import XCTest
@testable import NekozeFix

final class TimedConditionGateTests: XCTestCase {

    func test_tick_while_conditionTrue_accumulatesTime() {
        // Given: a gate requiring 3.0 seconds
        var gate = TimedConditionGate(requiredDuration: 3.0)

        // When: tick with condition true for 2.5 seconds (using actual deltaTime)
        let deltaTime: TimeInterval = 1.0 / 60.0  // ~60fps
        for _ in 0..<150 {  // 150 frames = 2.5 seconds
            gate.tick(isConditionMet: true, deltaTime: deltaTime)
        }

        // Then: should not have fired yet (2.5s < 3.0s)
        XCTAssertFalse(gate.tick(isConditionMet: true, deltaTime: deltaTime))
    }

    func test_tick_while_conditionFalse_resetsAccumulator() {
        // Given: a gate requiring 3.0 seconds, partially accumulated
        var gate = TimedConditionGate(requiredDuration: 3.0)
        gate.accumulated = 1.5  // Simulate 1.5 seconds accumulated

        // When: condition becomes false
        gate.tick(isConditionMet: false, deltaTime: 0.0)

        // Then: accumulator should be reset to 0
        XCTAssertEqual(gate.accumulated, 0.0)
        XCTAssertFalse(gate.isFired)
    }

    func test_tick_firesOnceWhenDurationReached() {
        // Given: a gate requiring 2.0 seconds
        var gate = TimedConditionGate(requiredDuration: 2.0)
        let deltaTime: TimeInterval = 1.0 / 60.0  // ~60fps

        // When: tick with condition true for 2.0 seconds
        for _ in 0..<120 {  // 120 frames = 2.0 seconds
            gate.tick(isConditionMet: true, deltaTime: deltaTime)
        }

        // Then: should have fired
        XCTAssertTrue(gate.isFired)
        // Subsequent ticks should return false (already fired)
        XCTAssertFalse(gate.tick(isConditionMet: true, deltaTime: deltaTime))
    }

    func test_tick_falseResetsImmediately() {
        // Given: a gate requiring 5.0 seconds, accumulated time 4.0 seconds
        var gate = TimedConditionGate(requiredDuration: 5.0)
        gate.accumulated = 4.0

        // When: condition becomes false
        gate.tick(isConditionMet: false, deltaTime: 0.0)

        // Then: accumulator should reset immediately
        XCTAssertEqual(gate.accumulated, 0.0)
        XCTAssertFalse(gate.isFired)
    }

    func test_tick_trueAfterReset_shouldStartAccumulatingAgain() {
        // Given: gate with 3.0s requirement
        var gate = TimedConditionGate(requiredDuration: 3.0)
        let deltaTime: TimeInterval = 1.0 / 60.0  // ~60fps

        // When: condition true for 1.5 seconds
        for _ in 0..<90 {
            gate.tick(isConditionMet: true, deltaTime: deltaTime)
        }

        // Then: should not have fired yet (1.5s < 3.0s)
        XCTAssertFalse(gate.isFired)

        // When: condition becomes false then true again
        gate.tick(isConditionMet: false, deltaTime: 0.0)
        for _ in 0..<180 {  // 180 frames = 3.0 seconds
            gate.tick(isConditionMet: true, deltaTime: deltaTime)
        }

        // Then: should have fired
        XCTAssertTrue(gate.isFired)
    }

    func test_tick_usesActualDeltaTime() {
        // Given: a gate requiring 1.0 second
        var gate = TimedConditionGate(requiredDuration: 1.0)

        // When: tick with large deltaTime (simulating slow frame rate)
        gate.tick(isConditionMet: true, deltaTime: 0.5)  // 500ms
        gate.tick(isConditionMet: true, deltaTime: 0.5)  // 500ms

        // Then: should have fired (1.0s >= 1.0s)
        XCTAssertTrue(gate.isFired)
    }
}
