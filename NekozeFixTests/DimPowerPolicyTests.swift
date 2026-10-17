import XCTest
@testable import NekozeFix

/// dim-mode-saving Task 2.3: 省電力段階方針の単体検証。
/// 段階遷移（通常→暗転→長時間不在）・人物再検出時の戻り・解除時の復帰・
/// 不在しきい値の境界動作をカメラなしで検証する。
/// Requirements 2.1, 2.2。
final class DimPowerPolicyTests: XCTestCase {

    /// 初期段階は通常。
    func testInitialStage_IsNormal() {
        XCTAssertEqual(DimPowerPolicy().stage, .normal)
    }

    /// 不正な閾値は既定値に倒す。
    func testInit_InvalidThreshold_FallsBackToDefault() {
        XCTAssertEqual(DimPowerPolicy(absentThreshold: .nan).absentThreshold, DimPowerPolicy.defaultAbsentThreshold)
        XCTAssertEqual(DimPowerPolicy(absentThreshold: -5).absentThreshold, DimPowerPolicy.defaultAbsentThreshold)
        XCTAssertEqual(DimPowerPolicy(absentThreshold: .infinity).absentThreshold, DimPowerPolicy.defaultAbsentThreshold)
    }

    /// 暗転移行で暗転段階へ進む。
    func testDimmed_FromNormal_AdvancesToDimmed() {
        var policy = DimPowerPolicy()
        XCTAssertEqual(policy.dimmed(), .dimmed)
        XCTAssertEqual(policy.stage, .dimmed)
    }

    /// 暗転解除で通常へ戻る（暗転・長時間不在のいずれからも）。
    func testRestored_FromDimmedAndAbsent_ReturnsToNormal() {
        var policy = DimPowerPolicy()
        _ = policy.dimmed()
        XCTAssertEqual(policy.restored(), .normal)
        _ = policy.dimmed()
        _ = policy.tick(isPersonDetected: false, now: 1000)
        _ = policy.tick(isPersonDetected: false, now: 1000 + DimPowerPolicy.defaultAbsentThreshold + 1)
        XCTAssertEqual(policy.stage, .dimmedAbsent)
        XCTAssertEqual(policy.restored(), .normal)
    }

    /// 通常段階の不在tickは段階を進めない（暗転操作なしでは長時間不在にならない）。
    func testTick_AbsentWhileNormal_StaysNormal() {
        var policy = DimPowerPolicy()
        XCTAssertEqual(policy.tick(isPersonDetected: false, now: 1000), .normal)
        XCTAssertEqual(policy.tick(isPersonDetected: false, now: 2000), .normal)
    }

    /// 暗転中の不在継続がしきい値を超えた場合のみ長時間不在へ進む。
    func testTick_AbsentBeyondThreshold_AdvancesToAbsent() {
        var policy = DimPowerPolicy(absentThreshold: 60)
        _ = policy.dimmed()
        XCTAssertEqual(policy.tick(isPersonDetected: false, now: 1000), .dimmed)
        XCTAssertEqual(policy.tick(isPersonDetected: false, now: 1059), .dimmed)
        XCTAssertEqual(policy.tick(isPersonDetected: false, now: 1060), .dimmed)
        XCTAssertEqual(policy.tick(isPersonDetected: false, now: 1060.1), .dimmedAbsent)
    }

    /// しきい値超過前の人物再検出は段階を進めず計測をやり直す。
    func testTick_PersonReturnsBeforeThreshold_StaysDimmedAndRestarts() {
        var policy = DimPowerPolicy(absentThreshold: 60)
        _ = policy.dimmed()
        _ = policy.tick(isPersonDetected: false, now: 1000)
        XCTAssertEqual(policy.tick(isPersonDetected: true, now: 1050), .dimmed)
        _ = policy.tick(isPersonDetected: false, now: 2000)
        XCTAssertEqual(policy.tick(isPersonDetected: false, now: 2059), .dimmed)
        XCTAssertEqual(policy.stage, .dimmed)
    }

    /// 長時間不在中の人物再検出は暗転段階へ戻す。
    func testTick_PersonReturnsFromAbsent_BackToDimmed() {
        var policy = DimPowerPolicy(absentThreshold: 60)
        _ = policy.dimmed()
        _ = policy.tick(isPersonDetected: false, now: 1000)
        _ = policy.tick(isPersonDetected: false, now: 1070)
        XCTAssertEqual(policy.stage, .dimmedAbsent)
        XCTAssertEqual(policy.tick(isPersonDetected: true, now: 1080), .dimmed)
    }

    /// 長時間不在中の不在継続は長時間不在を維持する（暗転への後退・再計測なし）。
    func testTick_AbsentWhileAbsent_StaysAbsent() {
        var policy = DimPowerPolicy(absentThreshold: 60)
        _ = policy.dimmed()
        _ = policy.tick(isPersonDetected: false, now: 1000)
        _ = policy.tick(isPersonDetected: false, now: 1070)
        XCTAssertEqual(policy.stage, .dimmedAbsent)
        XCTAssertEqual(policy.tick(isPersonDetected: false, now: 1080), .dimmedAbsent)
        XCTAssertEqual(policy.tick(isPersonDetected: false, now: 2000), .dimmedAbsent)
        XCTAssertEqual(policy.stage, .dimmedAbsent)
    }

    /// 無効時刻は遷移を見送り現段階を維持する。
    func testTick_InvalidTime_KeepsStage() {
        var policy = DimPowerPolicy()
        _ = policy.dimmed()
        XCTAssertEqual(policy.tick(isPersonDetected: false, now: .nan), .dimmed)
        XCTAssertEqual(policy.tick(isPersonDetected: false, now: -1), .dimmed)
        XCTAssertEqual(policy.tick(isPersonDetected: false, now: .infinity), .dimmed)
    }
}
