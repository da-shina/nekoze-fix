import XCTest
@testable import NekozeFix

final class E2EIntegrationTests: XCTestCase {
    var sut: PostureSessionManager!

    override func setUp() {
        super.setUp()
        sut = PostureSessionManager()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    func testE2ECriticalPath() {
        // Phase 1: Permission check
        XCTAssertEqual(sut.snapshot.phase, .awaitingPermission)

        // Phase 2: Bootstrap (simulates auth check)
        Task { @MainActor in
            await sut.bootstrap()
        }

        // Phase 3: Calibration
        sut.startCalibration()
        XCTAssertEqual(sut.snapshot.phase, .calibrating)

        // Simulate 3 seconds of stable person detection
        sut.updatePersonDetected(true)

        // Simulate timed condition gate - 3 seconds stable
        var gate = TimedConditionGate(requiredDuration: 3.0)
        let startTime = CFAbsoluteTimeGetCurrent()

        for _ in 0..<60 {
            gate.tick(isConditionMet: true, now: CFAbsoluteTimeGetCurrent())
            if gate.isFired { break }
        }

        // Should complete after 3 seconds
        if gate.isFired {
            // Calibration completed - should move to idle or monitoring
            let finalPhase = sut.snapshot.phase
            // At this point, calibration is complete and we can start monitoring
            sut.startMonitoring()
            XCTAssertTrue(sut.snapshot.phase == .monitoring || sut.snapshot.phase == .idle)
        } else {
            XCTFail("Calibration gate should fire after 3 seconds")
        }
    }

    func testSlouchDetectionFlow() {
        // Setup: calibrated and monitoring
        sut.startMonitoring()
        sut.updatePersonDetected(true)

        // Simulate slouch detection
        var gate = TimedConditionGate(requiredDuration: 5.0)
        let startTime = CFAbsoluteTimeGetCurrent()

        // Simulate 5 seconds of slouch (angle over threshold)
        for _ in 0..<60 {
            gate.tick(isConditionMet: true, now: CFAbsoluteTimeGetCurrent())
            if gate.isFired { break }
        }

        // After 5+ seconds of slouch, notification should be triggered
        // The confirmed slouch triggers AlertPlayer.playOnce()
        XCTAssertTrue(gate.isFired, "5 seconds of slouch should trigger the gate")
    }

    func testDimModeToggle() {
        // Start with normal monitoring
        sut.startMonitoring()
        XCTAssertFalse(sut.snapshot.isDimmed)

        // Enter dim mode
        sut.enterDimMode()
        XCTAssertTrue(sut.snapshot.isDimmed)

        // Exit dim mode
        sut.exitDimMode()
        XCTAssertFalse(sut.snapshot.isDimmed)
    }

    func testSensitivityMapping() {
        let store = SettingsStore()

        // sensitivity 0.0 → 20 degrees
        store.sensitivity = 0.0
        XCTAssertEqual(store.slouchDeltaThresholdDegrees(), 20.0)

        // sensitivity 1.0 → 5 degrees
        store.sensitivity = 1.0
        XCTAssertEqual(store.slouchDeltaThresholdDegrees(), 5.0)

        // sensitivity 0.5 → 12.5 degrees
        store.sensitivity = 0.5
        XCTAssertEqual(store.slouchDeltaThresholdDegrees(), 12.5, accuracy: 0.001)
    }
}