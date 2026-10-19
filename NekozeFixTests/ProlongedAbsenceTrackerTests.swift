import XCTest
@testable import NekozeFix

/// `ProlongedAbsenceTracker` の単体検証。
/// 不在計測・遷移・間引き判定・閾値境界・復帰・無効時刻無視を検証する。
final class ProlongedAbsenceTrackerTests: XCTestCase {

    // MARK: - 初期状態

    /// 初期状態では長時間不在でない。
    func testInitialState_isNotProlongedAbsence() {
        let tracker = ProlongedAbsenceTracker()
        XCTAssertFalse(tracker.isProlongedAbsence)
        XCTAssertEqual(tracker.snapshot().isProlongedAbsence, false)
    }

    // MARK: - 不正閾値・間隔のフォールバック

    /// 不正な閾値・間隔は既定値（60s / 5s）に倒される。
    func testInit_InvalidThresholds_FallBackToDefaults() {
        let cases: [(TimeInterval, TimeInterval)] = [
            (.nan, 5.0), (-1, 5.0), (.infinity, 5.0),
            (60.0, .nan), (60.0, -1), (60.0, .infinity),
        ]
        for (threshold, interval) in cases {
            let tracker = ProlongedAbsenceTracker(absentThreshold: threshold, faceFallbackThrottleInterval: interval)
            XCTAssertEqual(tracker.absentThreshold, DimPowerPolicy.defaultAbsentThreshold, "閾値 \(threshold) は既定値に倒される")
            XCTAssertEqual(tracker.faceFallbackThrottleInterval, 5.0, "間隔 \(interval) は既定値に倒される")
        }
    }

    // MARK: - 遷移: 通常 → 長時間不在 → 解除

    /// 人物不在継続がしきい値を超えると長時間不在へ遷移する。
    func testTick_AbsentBeyondThreshold_BecomesProlongedAbsence() {
        let tracker = ProlongedAbsenceTracker(absentThreshold: 60, faceFallbackThrottleInterval: 5.0)
        let start = 1000.0

        // しきい値未満では遷移しない
        XCTAssertFalse(tracker.tick(isPersonDetected: false, now: start))
        XCTAssertFalse(tracker.tick(isPersonDetected: false, now: start + 59.9))

        // しきい値超過で遷移
        XCTAssertTrue(tracker.tick(isPersonDetected: false, now: start + 60.1))
        XCTAssertTrue(tracker.isProlongedAbsence)
    }

    /// 人物再検出で長時間不在が解除される。
    func testTick_PersonDetected_ResetsProlongedAbsence() {
        let tracker = ProlongedAbsenceTracker(absentThreshold: 60, faceFallbackThrottleInterval: 5.0)
        let start = 1000.0

        // 長時間不在へ遷移
        _ = tracker.tick(isPersonDetected: false, now: start)
        _ = tracker.tick(isPersonDetected: false, now: start + 61)
        XCTAssertTrue(tracker.isProlongedAbsence)

        // 人物検出で解除
        XCTAssertFalse(tracker.tick(isPersonDetected: true, now: start + 62))
        XCTAssertFalse(tracker.isProlongedAbsence)
        XCTAssertNil(tracker.snapshot().absenceStart)
    }

    /// 人物再検出前の不在計測はリセットされ、再不在時はゼロから計測し直す。
    func testTick_PersonReturnsThenAbsentAgain_RestartsMeasurement() {
        let tracker = ProlongedAbsenceTracker(absentThreshold: 60, faceFallbackThrottleInterval: 5.0)
        let start = 1000.0

        _ = tracker.tick(isPersonDetected: false, now: start)
        _ = tracker.tick(isPersonDetected: false, now: start + 61)
        XCTAssertTrue(tracker.isProlongedAbsence)

        // 一度検出
        _ = tracker.tick(isPersonDetected: true, now: start + 62)
        XCTAssertFalse(tracker.isProlongedAbsence)

        // 再び不在 → 計測し直し
        XCTAssertFalse(tracker.tick(isPersonDetected: false, now: start + 100))
        XCTAssertFalse(tracker.tick(isPersonDetected: false, now: start + 159.9))
        XCTAssertTrue(tracker.tick(isPersonDetected: false, now: start + 160.1))
    }

    // MARK: - 閾値境界

    /// 59.9s / 60.0s / 60.1s の境界で遷移が正しく動作する。
    func testTick_ThresholdBoundary_TransitionsAtExactThreshold() {
        let tracker = ProlongedAbsenceTracker(absentThreshold: 60, faceFallbackThrottleInterval: 5.0)
        let base = 1000.0

        // 59.9s では未遷移
        XCTAssertFalse(tracker.tick(isPersonDetected: false, now: base))
        XCTAssertFalse(tracker.tick(isPersonDetected: false, now: base + 59.9))

        // 60.0s ちょうどでは未遷移（> で判定のため）
        XCTAssertFalse(tracker.tick(isPersonDetected: false, now: base + 60.0))

        // 60.1s で遷移
        XCTAssertTrue(tracker.tick(isPersonDetected: false, now: base + 60.1))
    }

    // MARK: - 間引き判定

    /// 長時間不在でなければ毎回実行可（true）。
    func testShouldExecuteAndRecordFaceFallback_NotProlonged_ReturnsTrue() {
        let tracker = ProlongedAbsenceTracker(absentThreshold: 60, faceFallbackThrottleInterval: 5.0)
        XCTAssertTrue(tracker.shouldExecuteAndRecordFaceFallback(now: 1000))
        XCTAssertTrue(tracker.shouldExecuteAndRecordFaceFallback(now: 1001))
    }

    /// 長時間不在中、間引き間隔未満では実行不可（false）。
    func testShouldExecuteAndRecordFaceFallback_WithinInterval_ReturnsFalse() {
        let tracker = ProlongedAbsenceTracker(absentThreshold: 60, faceFallbackThrottleInterval: 5.0)
        let base = 1000.0

        // 長時間不在へ遷移
        _ = tracker.tick(isPersonDetected: false, now: base)
        _ = tracker.tick(isPersonDetected: false, now: base + 61)
        XCTAssertTrue(tracker.isProlongedAbsence)

        // 最初の実行は可
        XCTAssertTrue(tracker.shouldExecuteAndRecordFaceFallback(now: base + 62))
        let firstExec = tracker.snapshot().lastFaceExecutionTime

        // 間隔内は不可
        XCTAssertFalse(tracker.shouldExecuteAndRecordFaceFallback(now: base + 62.5))
        XCTAssertFalse(tracker.shouldExecuteAndRecordFaceFallback(now: base + 66.9))

        // 間隔経過後は可
        XCTAssertTrue(tracker.shouldExecuteAndRecordFaceFallback(now: base + 67.0))
        XCTAssertNotEqual(tracker.snapshot().lastFaceExecutionTime, firstExec)
    }

    /// `shouldExecuteAndRecordFaceFallback` は判定と実行時刻記録をアトミックに行う。
    /// 顔検出時刻（lastFaceDetectedTime）はここでは更新しない。
    func testShouldExecuteAndRecordFaceFallback_Atomicity() {
        let tracker = ProlongedAbsenceTracker(absentThreshold: 60, faceFallbackThrottleInterval: 5.0)
        let base = 1000.0

        _ = tracker.tick(isPersonDetected: false, now: base)
        _ = tracker.tick(isPersonDetected: false, now: base + 61)

        // 実行可の直後は lastFaceExecutionTime が更新されている
        _ = tracker.shouldExecuteAndRecordFaceFallback(now: base + 62)
        let snap = tracker.snapshot()
        XCTAssertEqual(snap.lastFaceExecutionTime, base + 62, accuracy: 1e-9)
        // lastFaceDetectedTime は更新されない（recordFaceDetected で更新）
        XCTAssertNil(snap.lastFaceDetectedTime)
    }

    // MARK: - ホールド機構

    /// 顔実行後、間引き間隔内は `faceDetectedHoldActive(now:) == true`。
    func testFaceDetectedHoldActive_WithinInterval_IsTrue() {
        let tracker = ProlongedAbsenceTracker(absentThreshold: 60, faceFallbackThrottleInterval: 5.0)
        let base = 1000.0

        _ = tracker.tick(isPersonDetected: false, now: base)
        _ = tracker.tick(isPersonDetected: false, now: base + 61)

        // 顔実行を記録
        tracker.recordFaceDetected(now: base + 62)

        // 間隔内は true（時刻注入で確認）
        XCTAssertTrue(tracker.faceDetectedHoldActive(now: base + 63))
        XCTAssertTrue(tracker.faceDetectedHoldActive(now: base + 66.9))
    }

    /// 間引き間隔経過後は `faceDetectedHoldActive(now:) == false`。
    func testFaceDetectedHoldActive_AfterInterval_IsFalse() {
        let tracker = ProlongedAbsenceTracker(absentThreshold: 60, faceFallbackThrottleInterval: 5.0)
        let base = 1000.0

        _ = tracker.tick(isPersonDetected: false, now: base)
        _ = tracker.tick(isPersonDetected: false, now: base + 61)
        tracker.recordFaceDetected(now: base + 62)

        // 間隔経過後は false
        XCTAssertFalse(tracker.faceDetectedHoldActive(now: base + 67.0))
    }

    /// 長時間不在解除後は `faceDetectedHoldActive(now:) == false`。
    func testFaceDetectedHoldActive_AfterProlongedAbsenceEnds_IsFalse() {
        let tracker = ProlongedAbsenceTracker(absentThreshold: 60, faceFallbackThrottleInterval: 5.0)
        let base = 1000.0

        _ = tracker.tick(isPersonDetected: false, now: base)
        _ = tracker.tick(isPersonDetected: false, now: base + 61)
        tracker.recordFaceDetected(now: base + 62)

        // 人物検出で長時間不在解除
        _ = tracker.tick(isPersonDetected: true, now: base + 63)

        XCTAssertFalse(tracker.faceDetectedHoldActive(now: base + 63))
    }

    /// 非長時間不在時は `faceDetectedHoldActive(now:) == false`。
    func testFaceDetectedHoldActive_NotProlonged_IsFalse() {
        let tracker = ProlongedAbsenceTracker()
        tracker.recordFaceDetected(now: 1000)
        XCTAssertFalse(tracker.faceDetectedHoldActive(now: 1001))
    }

    // MARK: - リセット動作

    /// `reset()` で全状態が初期化される。
    func testReset_ClearsAllState() {
        let tracker = ProlongedAbsenceTracker(absentThreshold: 60, faceFallbackThrottleInterval: 5.0)
        let base = 1000.0

        _ = tracker.tick(isPersonDetected: false, now: base)
        _ = tracker.tick(isPersonDetected: false, now: base + 61)
        _ = tracker.shouldExecuteAndRecordFaceFallback(now: base + 62)
        tracker.recordFaceDetected(now: base + 62)

        tracker.reset()

        XCTAssertFalse(tracker.isProlongedAbsence)
        XCTAssertNil(tracker.snapshot().absenceStart)
        XCTAssertEqual(tracker.snapshot().lastFaceExecutionTime, -.infinity)
        XCTAssertNil(tracker.snapshot().lastFaceDetectedTime)
    }

    // MARK: - 無効時刻無視

    /// 無効時刻（NaN・負・無限大）は遷移を見送り現状維持。
    func testTick_InvalidTime_KeepsState() {
        let tracker = ProlongedAbsenceTracker(absentThreshold: 60, faceFallbackThrottleInterval: 5.0)
        let base = 1000.0

        _ = tracker.tick(isPersonDetected: false, now: base)
        _ = tracker.tick(isPersonDetected: false, now: base + 61)
        XCTAssertTrue(tracker.isProlongedAbsence)

        // 無効時刻では状態不変
        XCTAssertTrue(tracker.tick(isPersonDetected: false, now: .nan))
        XCTAssertTrue(tracker.tick(isPersonDetected: false, now: -1))
        XCTAssertTrue(tracker.tick(isPersonDetected: false, now: .infinity))
        XCTAssertTrue(tracker.isProlongedAbsence)
    }

    /// `shouldExecuteAndRecordFaceFallback` で無効時刻は実行可（true）に倒す。
    func testShouldExecuteAndRecordFaceFallback_InvalidTime_ReturnsTrue() {
        let tracker = ProlongedAbsenceTracker(absentThreshold: 60, faceFallbackThrottleInterval: 5.0)
        let base = 1000.0

        _ = tracker.tick(isPersonDetected: false, now: base)
        _ = tracker.tick(isPersonDetected: false, now: base + 61)

        XCTAssertTrue(tracker.shouldExecuteAndRecordFaceFallback(now: .nan))
        XCTAssertTrue(tracker.shouldExecuteAndRecordFaceFallback(now: -1))
        XCTAssertTrue(tracker.shouldExecuteAndRecordFaceFallback(now: .infinity))
    }

    /// `recordFaceDetected` で無効時刻は無視される。
    func testRecordFaceDetected_InvalidTime_IsIgnored() {
        let tracker = ProlongedAbsenceTracker(absentThreshold: 60, faceFallbackThrottleInterval: 5.0)
        let base = 1000.0

        _ = tracker.tick(isPersonDetected: false, now: base)
        _ = tracker.tick(isPersonDetected: false, now: base + 61)

        tracker.recordFaceDetected(now: .nan)
        tracker.recordFaceDetected(now: -1)

        // 時刻は更新されない（前回値維持）
        XCTAssertNil(tracker.snapshot().lastFaceDetectedTime)
    }

    // MARK: - スナップショット

    /// `snapshot()` で現在状態が正しく取得できる。
    func testSnapshot_ReflectsCurrentState() {
        let tracker = ProlongedAbsenceTracker(absentThreshold: 60, faceFallbackThrottleInterval: 5.0)
        let base = 1000.0

        let snap0 = tracker.snapshot()
        XCTAssertFalse(snap0.isProlongedAbsence)
        XCTAssertNil(snap0.absenceStart)

        _ = tracker.tick(isPersonDetected: false, now: base)
        _ = tracker.tick(isPersonDetected: false, now: base + 61)
        _ = tracker.shouldExecuteAndRecordFaceFallback(now: base + 62)
        tracker.recordFaceDetected(now: base + 62)

        let snap1 = tracker.snapshot()
        XCTAssertTrue(snap1.isProlongedAbsence)
        XCTAssertEqual(snap1.absenceStart!, base, accuracy: 1e-9)
        XCTAssertEqual(snap1.lastFaceExecutionTime, base + 62, accuracy: 1e-9)
        XCTAssertEqual(snap1.lastFaceDetectedTime!, base + 62, accuracy: 1e-9)
    }
}