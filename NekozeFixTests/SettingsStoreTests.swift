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

    // MARK: - 感度からしきい値へのマッピング

    /// sensitivity 0.0 → 20度
    func testSensitivityZero_thresholdIs20Degrees() {
        sut.sensitivity = 0.0
        XCTAssertEqual(sut.slouchDeltaThresholdDegrees(), 20.0, accuracy: 0.001)
    }

    /// sensitivity 1.0 → 5度
    func testSensitivityOne_thresholdIs5Degrees() {
        sut.sensitivity = 1.0
        XCTAssertEqual(sut.slouchDeltaThresholdDegrees(), 5.0, accuracy: 0.001)
    }

    /// sensitivity 0.5 → 12.5度（中点）
    func testSensitivityHalf_thresholdIs12Point5Degrees() {
        sut.sensitivity = 0.5
        XCTAssertEqual(sut.slouchDeltaThresholdDegrees(), 12.5, accuracy: 0.001)
    }

    /// sensitivity 0.75 → 8.75度
    func testSensitivityThreeQuarters_thresholdIs8Point75Degrees() {
        sut.sensitivity = 0.75
        XCTAssertEqual(sut.slouchDeltaThresholdDegrees(), 8.75, accuracy: 0.001)
    }

    /// sensitivity 0.25 → 16.25度
    func testSensitivityOneQuarter_thresholdIs16Point25Degrees() {
        sut.sensitivity = 0.25
        XCTAssertEqual(sut.slouchDeltaThresholdDegrees(), 16.25, accuracy: 0.001)
    }

    // MARK: - 監視有効フラグ

    func testDefaultMonitoringEnabled_isFalse() {
        // 初回起動時はfalseであるべき
        XCTAssertFalse(sut.isMonitoringEnabled)
    }

    func testSetMonitoringEnabled_storesValue() {
        sut.isMonitoringEnabled = true
        XCTAssertTrue(sut.isMonitoringEnabled)

        sut.isMonitoringEnabled = false
        XCTAssertFalse(sut.isMonitoringEnabled)
    }

    // MARK: - デフォルト感度

    func testDefaultSensitivity_isHalf() {
        // デフォルトの感度は0.5であるべき
        XCTAssertEqual(sut.sensitivity, 0.5, accuracy: 0.001)
    }
}