import XCTest
@testable import NekozeFix

final class CalibrationLogicTests: XCTestCase {

    func test_Calibration_CompletesAfter5sStable() {
        var logic = CalibrationLogic()
        logic.start()

        let sample = AngleSample(nearSide: .left, nearAngleDegrees: 10.0, farSideDetected: false, nearDistance: 0.1)
        let points: [CGPoint] = [CGPoint(x: 0, y: 0)]

        // First sample: start accumulation
        _ = logic.ingest(sample: sample, presence: .personDetected, now: 0, points: points)

        // Stable for 5 seconds
        let result = logic.ingest(sample: sample, presence: .personDetected, now: 5.0, points: points)

        if case .completed(let angle, let dist, let side, let refPoints, _, _) = result {
            XCTAssertEqual(angle, 10.0, accuracy: 0.001)
            XCTAssertEqual(dist, 0.1, accuracy: 0.001)
            XCTAssertEqual(side, .left)
            XCTAssertEqual(refPoints, points)
        } else {
            XCTFail("Expected .completed, got \(result)")
        }
    }

    func test_Calibration_ResetsOnAngleChange() {
        var logic = CalibrationLogic()
        logic.start()

        let sample1 = AngleSample(nearSide: .left, nearAngleDegrees: 10.0, farSideDetected: false, nearDistance: 0.1)
        _ = logic.ingest(sample: sample1, presence: .personDetected, now: 0, points: [])

        // 2 seconds later, angle jumps by 6 degrees
        let sample2 = AngleSample(nearSide: .left, nearAngleDegrees: 16.1, farSideDetected: false, nearDistance: 0.1)
        let result = logic.ingest(sample: sample2, presence: .personDetected, now: 2.0, points: [])

        if case .accumulating(let elapsed) = result {
            XCTAssertEqual(elapsed, 0, "Should have reset accumulation")
        } else {
            XCTFail("Expected .accumulating(0), got \(result)")
        }
    }

    func test_Calibration_ResetsOnSideFlip() {
        var logic = CalibrationLogic()
        logic.start()

        let sample1 = AngleSample(nearSide: .left, nearAngleDegrees: 10.0, farSideDetected: false, nearDistance: 0.1)
        _ = logic.ingest(sample: sample1, presence: .personDetected, now: 0, points: [])

        // Side flips to right
        let sample2 = AngleSample(nearSide: .right, nearAngleDegrees: 10.0, farSideDetected: false, nearDistance: 0.1)
        let result = logic.ingest(sample: sample2, presence: .personDetected, now: 1.0, points: [])

        if case .accumulating(let elapsed) = result {
            XCTAssertEqual(elapsed, 0, "Should have reset accumulation on side flip")
        } else {
            XCTFail("Expected .accumulating(0), got \(result)")
        }
    }

    func test_Calibration_FreezesOnShortDropout() {
        var logic = CalibrationLogic()
        logic.start()

        let sample = AngleSample(nearSide: .left, nearAngleDegrees: 10.0, farSideDetected: false, nearDistance: 0.1)
        _ = logic.ingest(sample: sample, presence: .personDetected, now: 0, points: [])

        // 1 second of stable accumulation
        _ = logic.ingest(sample: sample, presence: .personDetected, now: 1.0, points: [])

        // Person missing for 0.5s (should freeze)
        let result = logic.ingest(sample: nil, presence: .personMissing, now: 1.5, points: [])

        if case .accumulating(let elapsed) = result {
            XCTAssertEqual(elapsed, 1.0, accuracy: 0.001, "Elapsed time should be frozen at 1.0s")
        } else {
            XCTFail("Expected .accumulating(1.0), got \(result)")
        }
    }

    func test_Calibration_ResetsOnLongDropout() {
        var logic = CalibrationLogic()
        logic.start()

        let sample = AngleSample(nearSide: .left, nearAngleDegrees: 10.0, farSideDetected: false, nearDistance: 0.1)
        _ = logic.ingest(sample: sample, presence: .personDetected, now: 0, points: [])
        _ = logic.ingest(sample: sample, presence: .personDetected, now: 1.0, points: [])

        // Person missing for 1.1s (should reset)
        let result = logic.ingest(sample: nil, presence: .personMissing, now: 2.1, points: [])

        XCTAssertEqual(result, .waitingForPerson, "Should have reset to waitingForPerson after long dropout")
    }

    func test_Calibration_CalculatesAverage() {
        var logic = CalibrationLogic()
        logic.start()

        // Sequence of samples with varying angles/distances
        let samples = [
            (0.0, 10.0, 0.1),
            (1.0, 11.0, 0.11),
            (2.0, 9.0, 0.09),
            (3.0, 10.0, 0.1),
            (4.0, 10.0, 0.1),
            (5.0, 10.0, 0.1)
        ]

        var lastResult: CalibrationProgress = .waitingForPerson
        for (time, angle, dist) in samples {
            let sample = AngleSample(nearSide: .left, nearAngleDegrees: angle, farSideDetected: false, nearDistance: dist)
            lastResult = logic.ingest(sample: sample, presence: .personDetected, now: time, points: [])
        }

        if case .completed(let avgAngle, let avgDist, _, _, _, _) = lastResult {
            // Average of [10, 11, 9, 10, 10, 10] = 60/6 = 10.0
            XCTAssertEqual(avgAngle, 10.0, accuracy: 0.001)
            // Average of [0.1, 0.11, 0.09, 0.1, 0.1, 0.1] = 0.6/6 = 0.1
            XCTAssertEqual(avgDist, 0.1, accuracy: 0.001)
        } else {
            XCTFail("Expected .completed, got \(lastResult)")
        }
    }
}
