import XCTest
@testable import NekozeFix

/// motion-frequency Task 4.1: 頻度設定・公開値更新抑制則・計測カウンタの新規検証。
/// 既存回帰（MotionServiceTests）は変更なしで全頻度条件の前提とする。
/// Requirements 1.1, 1.2, 1.3, 2.1, 2.3, 3.1, 3.2, 3.3, 3.4, 6.5, 7.4。
@MainActor
final class MotionFrequencyTests: XCTestCase {

    private var service: MotionService!

    override func setUp() {
        super.setUp()
        service = MotionService()
    }

    override func tearDown() {
        service.stop()
        service = nil
        super.tearDown()
    }

    // MARK: - Task 1: 値オブジェクト

    /// 取得頻度候補と取得間隔の対応。既定は毎秒15回。
    func testFrequency_Intervals_MatchCandidates() {
        XCTAssertEqual(MotionUpdateFrequency.thirtyHz.interval, 1.0 / 30.0, accuracy: 1e-12)
        XCTAssertEqual(MotionUpdateFrequency.fifteenHz.interval, 1.0 / 15.0, accuracy: 1e-12)
        XCTAssertEqual(MotionUpdateFrequency.tenHz.interval, 1.0 / 10.0, accuracy: 1e-12)
    }

    // MARK: - Task 2.1: 取得間隔の内部設定化

    /// 既定の取得頻度は毎秒15回（暫定採用）。
    func testDefaultFrequency_IsFifteenHz() {
        XCTAssertEqual(service.updateFrequency, .fifteenHz)
    }

    /// 設定は保持され、停止中は次回開始時まで取得に影響しない（isRunning不変）。
    func testSetFrequency_WhileStopped_StaysStoppedWithNewSetting() {
        service.setUpdateFrequency(.tenHz)
        XCTAssertEqual(service.updateFrequency, .tenHz)
        XCTAssertFalse(service.isRunning)
    }

    /// 動作中の設定変更は即時再開扱いでも起停状態を保つ（Q11）。
    func testSetFrequency_WhileRunning_KeepsRunningWithNewSetting() {
        service.start()
        service.setUpdateFrequency(.fifteenHz)
        XCTAssertEqual(service.updateFrequency, .fifteenHz)
        XCTAssertTrue(service.isRunning)
    }

    // MARK: - Task 2.2: 公開値更新抑制則（受動公開・pull）

    /// 実質同一の有効値は公開値の更新を抑制し、判定入力は不変。
    func testIngest_SameValue_SuppressesVisibleUpdate() {
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let v = SIMD2<Double>(0.6, 0.8)
        service.startMeasuring(note: "suppression")
        service.ingest(converted: v, now: t0)
        let first = service.latestGravityInKeypointSpace
        XCTAssertEqual(first, v)
        // 許容差内の微小差は抑制される。
        let near = SIMD2<Double>(0.6 + 1e-6, 0.8)
        service.ingest(converted: near, now: t0.addingTimeInterval(0.01))
        XCTAssertEqual(service.latestGravityInKeypointSpace, v)
        let m = service.stopMeasuring()
        XCTAssertEqual(m.dispatchCount, 1)
    }

    /// 値の変化時は必ず公開値を更新する。
    func testIngest_ChangedValue_UpdatesVisible() {
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        service.startMeasuring(note: "changed")
        service.ingest(converted: SIMD2<Double>(0.6, 0.8), now: t0)
        service.ingest(converted: SIMD2<Double>(-0.6, 0.8), now: t0.addingTimeInterval(0.01))
        XCTAssertEqual(service.latestGravityInKeypointSpace, SIMD2<Double>(-0.6, 0.8))
        let m = service.stopMeasuring()
        XCTAssertEqual(m.dispatchCount, 2)
    }

    /// 有効→無効の状態変化時は必ず公開値を更新する（ホールド超過でnil）。
    func testIngest_ValidToInvalidBeyondHold_UpdatesVisibleToNil() {
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        service.startMeasuring(note: "state-change")
        service.ingest(converted: SIMD2<Double>(0.6, 0.8), now: t0)
        service.ingest(converted: nil, now: t0.addingTimeInterval(0.6))
        XCTAssertNil(service.latestGravityInKeypointSpace)
        let m = service.stopMeasuring()
        XCTAssertEqual(m.dispatchCount, 2)
    }

    /// 実質同一判定の境界（許容差未満は同一、以上は変化）。
    func testIsEffectivelySame_Boundary() {
        let a = SIMD2<Double>(0.6, 0.8)
        XCTAssertTrue(MotionService.isEffectivelySame(a, a))
        let near = SIMD2<Double>(0.6 + 5e-5, 0.8)
        XCTAssertTrue(MotionService.isEffectivelySame(a, near))
        let far = SIMD2<Double>(0.6 + 1e-3, 0.8)
        XCTAssertFalse(MotionService.isEffectivelySame(a, far))
    }

    /// background一段目のhop要否則（初回・変化・同一・無効）。
    func testHopDecision_BasicRules() {
        let v = SIMD2<Double>(0.6, 0.8)
        var d = MotionService.hopDecision(converted: v, lastSent: nil)
        XCTAssertTrue(d.shouldHop)
        XCTAssertTrue(d.newLastSent == v)
        d = MotionService.hopDecision(converted: v, lastSent: v)
        XCTAssertFalse(d.shouldHop)
        XCTAssertTrue(d.newLastSent == v)
        let w = SIMD2<Double>(-0.6, 0.8)
        d = MotionService.hopDecision(converted: w, lastSent: v)
        XCTAssertTrue(d.shouldHop)
        XCTAssertTrue(d.newLastSent == w)
    }

    /// 無効区間（ホールド超過で公開値nil）の後に同一向きへ戻ると無条件hopする。
    /// 一段目で抑制されるとMainへ値が届かず公開値がnilのまま残る（PR #25 指摘2）。
    func testHopDecision_AfterInvalid_SameValueHops() {
        let v = SIMD2<Double>(0.6, 0.8)
        var last: SIMD2<Double>? = nil
        var d = MotionService.hopDecision(converted: v, lastSent: last)
        last = d.newLastSent
        XCTAssertTrue(d.shouldHop)
        d = MotionService.hopDecision(converted: nil, lastSent: last)
        last = d.newLastSent
        XCTAssertTrue(d.shouldHop)
        // 無効hop後は比較基準が破棄されるため、同一値でもhopする。
        d = MotionService.hopDecision(converted: v, lastSent: last)
        XCTAssertTrue(d.shouldHop)
        XCTAssertTrue(d.newLastSent == v)
    }

    // MARK: - Task 2.3 / Task 3: 区間計測と参照記録

    /// 受信・公開値更新・読取り・無効読取りを区間ごとに数え、条件注記を付す。
    func testMeasuring_CountsSamplesVisibleReadsAndInvalid() {
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        service.startMeasuring(note: "monitoring・portrait・5s")
        service.ingest(converted: SIMD2<Double>(0, 1), now: t0)
        service.noteConsumption(hasValue: true)
        service.noteConsumption(hasValue: true)
        service.noteConsumption(hasValue: false)
        let m = service.stopMeasuring()
        XCTAssertEqual(m.frequency, .fifteenHz)
        XCTAssertGreaterThanOrEqual(m.duration, 0)
        // sampleCountは端末到着のみ数えるため直接ingestでは増えない。
        XCTAssertEqual(m.sampleCount, 0)
        XCTAssertEqual(m.dispatchCount, 1)
        XCTAssertEqual(m.consumptionCount, 3)
        XCTAssertEqual(m.invalidCount, 1)
        XCTAssertEqual(m.conditionNote, "monitoring・portrait・5s")
    }

    /// 未開始の終了は空計測を返し取得・判定に影響しない。
    func testStopMeasuring_WithoutStart_ReturnsEmptyWithoutAffectingAcquisition() {
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        let m = service.stopMeasuring()
        XCTAssertEqual(m.sampleCount, 0)
        XCTAssertEqual(m.dispatchCount, 0)
        service.ingest(converted: SIMD2<Double>(0, 1), now: t0)
        XCTAssertEqual(service.latestGravityInKeypointSpace, SIMD2<Double>(0, 1))
    }

    /// 二重開始は区間を再開始する（計測のみに影響）。
    func testStartMeasuring_Twice_RestartsInterval() {
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        service.startMeasuring(note: "first")
        service.ingest(converted: SIMD2<Double>(0, 1), now: t0)
        service.startMeasuring(note: "second")
        let m = service.stopMeasuring()
        XCTAssertEqual(m.conditionNote, "second")
        XCTAssertEqual(m.dispatchCount, 0)
    }

    /// 計測状態は取得・判定の動作に影響しない（停止後もingest解決は不変）。
    func testMeasuring_DoesNotAffectHoldResolution() {
        let t0 = Date(timeIntervalSince1970: 3_000_000)
        service.startMeasuring(note: "hold")
        service.ingest(converted: SIMD2<Double>(0.6, 0.8), now: t0)
        service.ingest(converted: nil, now: t0.addingTimeInterval(0.3))
        XCTAssertEqual(service.latestGravityInKeypointSpace, SIMD2<Double>(0.6, 0.8))
        _ = service.stopMeasuring()
        service.ingest(converted: nil, now: t0.addingTimeInterval(0.6))
        XCTAssertNil(service.latestGravityInKeypointSpace)
    }
}
