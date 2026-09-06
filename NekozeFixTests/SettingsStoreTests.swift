import XCTest
@testable import NekozeFix

final class SettingsStoreTests: XCTestCase {
    var sut: SettingsStore!

    override func setUp() {
        super.setUp()
        sut = SettingsStore()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Sensitivity to Threshold Mapping

    /// sensitivity 0.0 → 20 degrees
    func testSensitivityZero_thresholdIs20Degrees() {
        sut.sensitivity = 0.0
        XCTAssertEqual(sut.slouchDeltaThresholdDegrees(), 20.0, accuracy: 0.001)
    }

    /// sensitivity 1.0 → 5 degrees
    func testSensitivityOne_thresholdIs5Degrees() {
        sut.sensitivity = 1.0
        XCTAssertEqual(sut.slouchDeltaThresholdDegrees(), 5.0, accuracy: 0.001)
    }

    /// sensitivity 0.5 → 12.5 degrees (midpoint)
    func testSensitivityHalf_thresholdIs12Point5Degrees() {
        sut.sensitivity = 0.5
        XCTAssertEqual(sut.slouchDeltaThresholdDegrees(), 12.5, accuracy: 0.001)
    }

    /// sensitivity 0.75 → 8.75 degrees
    func testSensitivityThreeQuarters_thresholdIs8Point75Degrees() {
        sut.sensitivity = 0.75
        XCTAssertEqual(sut.slouchDeltaThresholdDegrees(), 8.75, accuracy: 0.001)
    }

    /// sensitivity 0.25 → 16.25 degrees
    func testSensitivityOneQuarter_thresholdIs16Point25Degrees() {
        sut.sensitivity = 0.25
        XCTAssertEqual(sut.slouchDeltaThresholdDegrees(), 16.25, accuracy: 0.001)
    }

    // MARK: - isMonitoringEnabled

    func testDefaultMonitoringEnabled_isFalse() {
        // Default should be false for first launch
        XCTAssertFalse(sut.isMonitoringEnabled)
    }

    func testSetMonitoringEnabled_storesValue() {
        sut.isMonitoringEnabled = true
        XCTAssertTrue(sut.isMonitoringEnabled)

        sut.isMonitoringEnabled = false
        XCTAssertFalse(sut.isMonitoringEnabled)
    }

    // MARK: - Default Sensitivity

    func testDefaultSensitivity_isHalf() {
        // Default sensitivity should be 0.5
        XCTAssertEqual(sut.sensitivity, 0.5, accuracy: 0.001)
    }
}