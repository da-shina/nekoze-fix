import XCTest
@testable import NekozeFix

final class MainHopGateTests: XCTestCase {
    func testGateSkeleton_compilesAndResets() {
        var gate = MainHopGate()
        gate.reset()
        XCTAssertEqual(gate.snapshot().submits, 0)
    }

    // MARK: - 2.1 受け渡し集約器

    /// 初回申請は配送（ゲート開放）。
    func testSubmit_firstSubmit_delivers() {
        var gate = MainHopGate(displayInterval: 0.1)
        XCTAssertEqual(
            gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.0),
            .deliver
        )
    }

    /// 定常 pose 連続は表示更新間隔で間引く（間隔未満は集約）。
    func testSubmit_steadyPoseWithinInterval_coalesces() {
        var gate = MainHopGate(displayInterval: 0.1)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.0), .deliver)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.05), .coalesce)
    }

    /// 間隔境界（ちょうど表示更新間隔）は配送する。
    func testSubmit_steadyPoseAtInterval_delivers() {
        var gate = MainHopGate(displayInterval: 0.1)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.0), .deliver)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.1), .deliver)
    }

    /// 集約は基準時刻を進めない（前回配送時刻からの間隔で判定する）。
    func testSubmit_coalescedFrame_doesNotAdvanceBaseline() {
        var gate = MainHopGate(displayInterval: 0.1)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.0), .deliver)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.05), .coalesce)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.1), .deliver)
    }

    /// 検出種別の遷移は間隔にかかわらず配送する。
    func testSubmit_kindTransition_deliversRegardlessOfInterval() {
        var gate = MainHopGate(displayInterval: 0.1)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.0), .deliver)
        XCTAssertEqual(gate.submit(kind: .absent, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.01), .deliver)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.02), .deliver)
    }

    /// 非 pose 結果は間隔にかかわらず配送する（連続でも全量配送）。
    func testSubmit_nonPoseResult_deliversRegardlessOfInterval() {
        var gate = MainHopGate(displayInterval: 0.1)
        XCTAssertEqual(gate.submit(kind: .personOnly, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.0), .deliver)
        XCTAssertEqual(gate.submit(kind: .personOnly, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.01), .deliver)
        XCTAssertEqual(gate.submit(kind: .absent, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.02), .deliver)
    }

    /// 校正フェーズ中は全量配送する。
    func testSubmit_calibrating_deliversAll() {
        var gate = MainHopGate(displayInterval: 0.1)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .calibrating, aspectRatio: 4.0 / 3.0, at: 100.0), .deliver)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .calibrating, aspectRatio: 4.0 / 3.0, at: 100.01), .deliver)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .calibrating, aspectRatio: 4.0 / 3.0, at: 100.02), .deliver)
    }

    /// 画面比率の変化時は間隔にかかわらず配送する。
    func testSubmit_aspectRatioChange_deliversRegardlessOfInterval() {
        var gate = MainHopGate(displayInterval: 0.1)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.0), .deliver)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 16.0 / 9.0, at: 100.01), .deliver)
    }

    /// 画面比率の微小差は不変とみなす（許容誤差内は間引き対象）。
    func testSubmit_aspectRatioTolerance_coalesces() {
        var gate = MainHopGate(displayInterval: 0.1)
        let base = CGFloat(4.0 / 3.0)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: base, at: 100.0), .deliver)
        XCTAssertEqual(
            gate.submit(kind: .pose, phase: .monitoring, aspectRatio: base + MainHopGate.aspectTolerance / 2, at: 100.05),
            .coalesce
        )
    }

    /// 無効時刻の申請は配送側に倒す（判定機会を保つ）。
    func testSubmit_invalidTime_failsOpen() {
        var gate = MainHopGate(displayInterval: 0.1)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.0), .deliver)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: Double.nan), .deliver)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: -1.0), .deliver)
    }

    /// 無効時刻の配送は基準時刻を進めない。
    func testSubmit_invalidTime_doesNotAdvanceBaseline() {
        var gate = MainHopGate(displayInterval: 0.1)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.0), .deliver)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: Double.nan), .deliver)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.05), .coalesce)
    }

    // MARK: - 2.2 受け渡し計測器

    /// 申請数・配送数・破棄数が判定点で取りこぼしなく進む。
    func testCounters_advanceAtDecisionPoint() {
        var gate = MainHopGate(displayInterval: 0.1)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.0), .deliver)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.05), .coalesce)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.2), .deliver)
        let metrics = gate.snapshot()
        XCTAssertEqual(metrics.submits, 3)
        XCTAssertEqual(metrics.delivers, 2)
        XCTAssertEqual(metrics.coalesced, 1)
    }

    /// 読出しは複写であり、計測の有無で配送挙動が変わらない。
    func testSnapshot_isCopyAndDoesNotAffectDecisions() {
        var gate = MainHopGate(displayInterval: 0.1)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.0), .deliver)
        let first = gate.snapshot()
        XCTAssertEqual(first.submits, 1)
        _ = gate.snapshot()
        _ = gate.snapshot()
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.05), .coalesce)
        XCTAssertEqual(gate.snapshot().submits, 2)
    }

    /// 初期化直後の判定が初期状態に戻る。
    func testReset_restoresInitialState() {
        var gate = MainHopGate(displayInterval: 0.1)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.0), .deliver)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.05), .coalesce)
        gate.reset()
        let metrics = gate.snapshot()
        XCTAssertEqual(metrics.submits, 0)
        XCTAssertEqual(metrics.delivers, 0)
        XCTAssertEqual(metrics.coalesced, 0)
        XCTAssertEqual(metrics.lastDrainWait, 0.0, accuracy: 1e-9)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.05), .deliver)
    }

    /// 集約を経た配送では、最終集約から排出までの待ち時間が記録される。
    func testDrainWait_recordsCoalesceToDeliverGap() {
        var gate = MainHopGate(displayInterval: 0.1)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.0), .deliver)
        XCTAssertEqual(gate.snapshot().lastDrainWait, 0.0, accuracy: 1e-9)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.05), .coalesce)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.08), .coalesce)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.2), .deliver)
        XCTAssertEqual(gate.snapshot().lastDrainWait, 0.12, accuracy: 1e-9)
    }

    /// 表示更新間隔は注入時に定まる（異なる間隔で境界が変わる）。
    func testCustomDisplayInterval_respected() {
        var gate = MainHopGate(displayInterval: 0.5)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.0), .deliver)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.2), .coalesce)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.5), .deliver)
    }

    /// 不正な表示更新間隔は既定値に倒す。
    func testInvalidDisplayInterval_fallsBackToDefault() {
        var gate = MainHopGate(displayInterval: -1.0)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.0), .deliver)
        XCTAssertEqual(
            gate.submit(
                kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0,
                at: 100.0 + MainHopGate.defaultDisplayInterval
            ),
            .deliver
        )
    }

    /// 読出し同士は独立した複写である（後の判定が既読値に影響しない）。
    func testSnapshots_areIndependentCopies() {
        var gate = MainHopGate(displayInterval: 0.1)
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.0), .deliver)
        let first = gate.snapshot()
        XCTAssertEqual(gate.submit(kind: .pose, phase: .monitoring, aspectRatio: 4.0 / 3.0, at: 100.05), .coalesce)
        let second = gate.snapshot()
        XCTAssertEqual(first.submits, 1)
        XCTAssertEqual(second.submits, 2)
        XCTAssertEqual(first.coalesced, 0)
        XCTAssertEqual(second.coalesced, 1)
    }
}
