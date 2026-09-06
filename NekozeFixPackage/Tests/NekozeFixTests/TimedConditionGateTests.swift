import XCTest
@testable import NekozeFix

final class TimedConditionGateTests: XCTestCase {

    // MARK: - 4.2: 5-second continuous detection required

    func test_5SecondsContinuous_triggersTrue() {
        // Given: a gate requiring 5.0 seconds
        var gate = TimedConditionGate(requiredDuration: 5.0)
        let startTime = CFAbsoluteTimeGetCurrent()

        // When: tick with condition true for 5+ seconds
        var currentTime = startTime
        for _ in 0..<300 {  // 300 frames at ~60fps = 5 seconds
            let result = gate.tick(isConditionMet: true, now: currentTime)
            if result {
                // Then: should trigger exactly once
                XCTAssertTrue(gate.isFired)
                return
            }
            currentTime += 1.0 / 60.0
        }

        // Then: should have triggered
        XCTFail("Gate should have fired after 5 seconds of continuous condition")
    }

    func test_lessThan5Seconds_doesNotTrigger() {
        // Given: a gate requiring 5.0 seconds
        var gate = TimedConditionGate(requiredDuration: 5.0)
        let startTime = CFAbsoluteTimeGetCurrent()

        // When: tick with condition true for only 4.9 seconds
        var currentTime = startTime
        for _ in 0..<293 {  // 293 frames at ~60fps = 4.883 seconds
            _ = gate.tick(isConditionMet: true, now: currentTime)
            currentTime += 1.0 / 60.0
        }

        // Then: should not have fired yet
        XCTAssertFalse(gate.isFired, "Gate should NOT fire before 5 seconds")
        let result = gate.tick(isConditionMet: true, now: currentTime)
        XCTAssertFalse(result, "tick should return false before reaching 5 seconds")
    }

    // MARK: - 4.3: Improvement is immediate reset

    func test_conditionFalse_immediatelyResetsAccumulator() {
        // Given: a gate requiring 5.0 seconds, partially accumulated
        var gate = TimedConditionGate(requiredDuration: 5.0)
        let startTime = CFAbsoluteTimeGetCurrent()

        // Accumulate for 3 seconds
        var currentTime = startTime
        for _ in 0..<180 {  // 180 frames at ~60fps = 3 seconds
            _ = gate.tick(isConditionMet: true, now: currentTime)
            currentTime += 1.0 / 60.0
        }
        XCTAssertFalse(gate.isFired)

        // When: condition becomes false (person missing / posture improved)
        let result = gate.tick(isConditionMet: false, now: currentTime)

        // Then: accumulator resets immediately
        XCTAssertEqual(gate.accumulated, 0.0, accuracy: 0.001)
        XCTAssertFalse(gate.isFired)
        XCTAssertFalse(result)
    }

    // MARK: - Q6: Person missing resets immediately

    func test_personMissing_resetsImmediately() {
        // Given: a gate requiring 5.0 seconds, accumulated 2 seconds
        var gate = TimedConditionGate(requiredDuration: 5.0)
        let startTime = CFAbsoluteTimeGetCurrent()
        var currentTime = startTime

        // Accumulate for 2 seconds
        for _ in 0..<120 {  // 120 frames at ~60fps = 2 seconds
            _ = gate.tick(isConditionMet: true, now: currentTime)
            currentTime += 1.0 / 60.0
        }

        // When: person missing (isConditionMet == false)
        let result = gate.tick(isConditionMet: false, now: currentTime)

        // Then: gate resets immediately
        XCTAssertEqual(gate.accumulated, 0.0, accuracy: 0.001)
        XCTAssertFalse(gate.isFired)
        XCTAssertFalse(result)
    }

    // MARK: - Calibration: 3.0 seconds

    func test_3SecondsContinuous_triggersTrue() {
        // Given: a gate requiring 3.0 seconds (calibration)
        var gate = TimedConditionGate(requiredDuration: 3.0)
        let startTime = CFAbsoluteTimeGetCurrent()

        // When: tick with condition true for 3+ seconds
        var currentTime = startTime
        for _ in 0..<180 {  // 180 frames at ~60fps = 3 seconds
            let result = gate.tick(isConditionMet: true, now: currentTime)
            if result {
                // Then: should trigger exactly once
                XCTAssertTrue(gate.isFired)
                return
            }
            currentTime += 1.0 / 60.0
        }

        // Then: should have triggered
        XCTFail("Gate should have fired after 3 seconds of continuous condition")
    }

    // MARK: - 2.4: Posture becomes unstable resets accumulation

    func test_postureUnstable_resetsAccumulation() {
        // Given: a gate requiring 3.0 seconds, accumulated 2 seconds
        var gate = TimedConditionGate(requiredDuration: 3.0)
        let startTime = CFAbsoluteTimeGetCurrent()
        var currentTime = startTime

        // Accumulate for 2 seconds
        for _ in 0..<120 {  // 120 frames at ~60fps = 2 seconds
            _ = gate.tick(isConditionMet: true, now: currentTime)
            currentTime += 1.0 / 60.0
        }

        // When: condition becomes false (posture unstable)
        _ = gate.tick(isConditionMet: false, now: currentTime)

        // Then: accumulator resets
        XCTAssertEqual(gate.accumulated, 0.0, accuracy: 0.001)
        XCTAssertFalse(gate.isFired)
    }

    // MARK: - reset()

    func test_reset_clearsState() {
        // Given: a gate that has accumulated some time
        var gate = TimedConditionGate(requiredDuration: 3.0)
        let startTime = CFAbsoluteTimeGetCurrent()
        var currentTime = startTime

        // Accumulate for 1.5 seconds
        for _ in 0..<90 {
            _ = gate.tick(isConditionMet: true, now: currentTime)
            currentTime += 1.0 / 60.0
        }

        // When: reset() is called
        gate.reset()

        // Then: state is cleared
        XCTAssertEqual(gate.accumulated, 0.0, accuracy: 0.001)
        XCTAssertFalse(gate.isFired)
    }

    // MARK: - Q5: Gate held during rotation (tick not called)

    func test_gateHeldDuringRotation_whenTickResumes() {
        // Given: a gate requiring 3.0 seconds, accumulated 2 seconds
        var gate = TimedConditionGate(requiredDuration: 3.0)
        let startTime = CFAbsoluteTimeGetCurrent()
        var currentTime = startTime

        // Accumulate for 2 seconds
        for _ in 0..<120 {  // 120 frames at ~60fps = 2 seconds
            _ = gate.tick(isConditionMet: true, now: currentTime)
            currentTime += 1.0 / 60.0
        }

        // When: rotation stops tick calls for 2 seconds, then resumes
        currentTime += 2.0  // Simulate 2 seconds of no ticking (rotation)
        let result = gate.tick(isConditionMet: true, now: currentTime)

        // Then: should fire (2s accumulated + 2s gap = 4s > 3s required)
        // Note: the gap doesn't reset because tick wasn't called with false
        // The gate held its accumulated time during rotation
        XCTAssertTrue(result, "Gate should fire after rotation completes")
    }
}