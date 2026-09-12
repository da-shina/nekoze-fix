import XCTest
@testable import NekozeFix

final class SettingsStoreTests: XCTestCase {
    private var suite: UserDefaults!
    private var sut: SettingsStore!

    override func setUp() {
        super.setUp()
        suite = UserDefaults(suiteName: "SettingsStoreTests")!
        suite.removePersistentDomain(forName: "SettingsStoreTests")
        sut = SettingsStore(defaults: suite)
    }

    override func tearDown() {
        sut = nil
        suite.removePersistentDomain(forName: "SettingsStoreTests")
        suite = nil
        super.tearDown()
    }

    // MARK: - 閾値（度数）

    func testDefaultThreshold_is8Degrees() {
        XCTAssertEqual(sut.slouchThresholdDegrees, 8.0, accuracy: 0.001)
    }

    func testThreshold_clampedToRange() {
        sut.slouchThresholdDegrees = 50.0
        XCTAssertEqual(sut.slouchThresholdDegrees, 20.0, accuracy: 0.001)

        sut.slouchThresholdDegrees = -10.0
        XCTAssertEqual(sut.slouchThresholdDegrees, 5.0, accuracy: 0.001)
    }

    func testThreshold_persistsAcrossInstances() {
        sut.slouchThresholdDegrees = 12.0
        let reloaded = SettingsStore(defaults: suite)
        XCTAssertEqual(reloaded.slouchThresholdDegrees, 12.0, accuracy: 0.001)
    }

    // MARK: - 旧感度キーからの移行

    func testMigration_newKeyWinsOverLegacy() {
        suite.set(0.0, forKey: "com.nekozefix.sensitivity") // 変換なら20度になる
        suite.set(7.0, forKey: "com.nekozefix.slouchThresholdDegrees")
        let store = SettingsStore(defaults: suite)
        XCTAssertEqual(store.slouchThresholdDegrees, 7.0, accuracy: 0.001)
    }

    func testMigration_convertsLegacySensitivityOnceAndDeletesKey() {
        // 新キーなし・旧キーのみ → 旧マッピング 20 - s*15（0.5 → 12.5度）
        suite.set(0.5, forKey: "com.nekozefix.sensitivity")
        let store = SettingsStore(defaults: suite)
        XCTAssertEqual(store.slouchThresholdDegrees, 12.5, accuracy: 0.001)
        // 旧キーは削除済み（以後の再読み込みで変換が二重適用されない）
        XCTAssertNil(suite.object(forKey: "com.nekozefix.sensitivity"))
    }

    // MARK: - 監視有効フラグ

    func testDefaultMonitoringEnabled_isFalse() {
        XCTAssertFalse(sut.isMonitoringEnabled)
    }

    func testSetMonitoringEnabled_storesValue() {
        sut.isMonitoringEnabled = true
        XCTAssertTrue(sut.isMonitoringEnabled)

        sut.isMonitoringEnabled = false
        XCTAssertFalse(sut.isMonitoringEnabled)
    }
}
