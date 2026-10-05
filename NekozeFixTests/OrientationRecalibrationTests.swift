import XCTest
@testable import NekozeFix

/// Task 13.3 / ios17-baseline 4.2: monitoring中の回転角変化で旧基準破棄→校正へ自動遷移し、
/// 再校正完了まで監視を停止する。calibrating中・idleの角変化は対象外。
/// トリガは新 `handleRotationAngleChange(preview:capture:)` への角度値の直接注入
/// （`DeviceRotationService` 変更配信の受口。購読結線自体は RotationWiringOrderTests が検証）。
/// テストは角度値と合成フレーム注入シームを直接駆動する。
@MainActor
final class OrientationRecalibrationTests: XCTestCase {
    var sut: PostureSessionManager!

    override func setUp() {
        super.setUp()
        sut = PostureSessionManager()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - ヘルパー

    /// 校正済み監視状態をシードする（基準: 角度10度・距離0.18・ロック側 .right）。
    private func seedCalibratedMonitoring() {
        sut.applyCalibrationCompletion(
            referenceNearAngleDegrees: 10.0,
            referenceDistance: 0.18,
            referenceSide: .right,
            referencePoints: []
        )
        XCTAssertEqual(sut.snapshot.phase, .monitoring)
    }

    /// 初期角（capture 0°＝ランドスケープ・実機規約）を確定させた上で回転角変化を起こす。
    /// 実機の購読は初期値で一度発火するため、テストでも同順序を再現する
    /// （初回確定は重複扱いで再校正しない。旧ハンドラと同一則）。
    /// preview 角は 90° のまま変えず、capture 角のみを変化させることで
    /// capture 角が自動再校正トリガの唯一の駆動源であることを示す。
    private func changeCaptureAngle(to capture: CGFloat) {
        sut.handleRotationAngleChange(preview: 90.0, capture: 0.0)
        sut.handleRotationAngleChange(preview: 90.0, capture: capture)
    }

    /// 監視中なら即 .slouch になる前出しフレーム（右距離0.21＝基準比116.7%）。
    private func slouchFrame() -> PoseFrame {
        PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.3, y: 0.5, confidence: 0.9),
            rightEar: Keypoint(x: 0.7, y: 0.6 - 0.21, confidence: 0.9),
            leftShoulder: Keypoint(x: 0.3, y: 0.6, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.7, y: 0.6, confidence: 0.9)
        )
    }

    // MARK: - monitoring中の回転角変化: 破棄→校正遷移

    /// 旧基準（角度・距離・ロック側）と猫背ゲートを破棄し calibrating へ遷移する。
    func testMonitoringCaptureAngleChange_discardsReferencesAndMovesToCalibrating() {
        seedCalibratedMonitoring()
        // ゲートを確定まで進める（破棄の検証用。実フレーム投入で実時間蓄積する）
        let deadline = Date().addingTimeInterval(10)
        while !sut.snapshot.slouchGate.isFired && Date() < deadline {
            sut.processDetection(.pose(slouchFrame()))
            usleep(20_000)
        }
        XCTAssertTrue(sut.snapshot.slouchGate.isFired, "前提: 猫背3秒連続で確定")

        changeCaptureAngle(to: 90.0)

        XCTAssertEqual(sut.snapshot.phase, .calibrating, "monitoring中の回転角変化で校正へ自動遷移")
        XCTAssertFalse(sut.snapshot.isLandscape, "capture 90°＝ポートレート（実機規約）")
        XCTAssertNil(sut.snapshot.referenceAngle, "旧基準角度を破棄")
        XCTAssertNil(sut.snapshot.referenceDistance, "旧基準距離を破棄")
        XCTAssertNil(sut.snapshot.referenceSide, "ロック側を破棄")
        XCTAssertEqual(sut.snapshot.slouchGate.accumulated, 0, "猫背ゲートを破棄")
        XCTAssertFalse(sut.snapshot.slouchGate.isFired)
        XCTAssertTrue(sut.motionService.isRunning, "再校正フローで Motion を継続")
    }

    // MARK: - 再校正完了まで監視を停止する

    /// 遷移後は監視判定が止まり（.slouch 表示なし）、再校正完了で監視に復帰する。
    func testMonitoringSuspendedUntilRecalibrationCompletes() {
        seedCalibratedMonitoring()
        changeCaptureAngle(to: 90.0)
        XCTAssertEqual(sut.snapshot.phase, .calibrating)

        // 猫背フレームを投入しても監視表示は動かない（校正 ingest のみ）
        for _ in 0..<5 {
            sut.processDetection(.pose(slouchFrame()))
        }
        XCTAssertNotEqual(sut.snapshot.displayedPosture, .slouch, "再校正完了まで監視は停止")

        // 再校正完了で監視に復帰する
        sut.applyCalibrationCompletion(
            referenceNearAngleDegrees: 12.0,
            referenceDistance: 0.19,
            referenceSide: .left,
            referencePoints: []
        )
        XCTAssertEqual(sut.snapshot.phase, .monitoring, "再校正完了で監視に復帰")
        XCTAssertEqual(sut.snapshot.referenceAngle, 12.0)
        XCTAssertEqual(sut.snapshot.referenceSide, .left)
        XCTAssertEqual(sut.snapshot.referenceDistance, 0.19)
    }

    // MARK: - 対象外: calibrating中・idle・同一角

    /// calibrating中の回転角変化は対象外（校正蓄積を妨げない）。
    func testCalibratingCaptureAngleChange_isIgnored() {
        sut.startCalibration()
        XCTAssertEqual(sut.snapshot.phase, .calibrating)

        changeCaptureAngle(to: 90.0)

        XCTAssertEqual(sut.snapshot.phase, .calibrating, "calibrating中の回転角変化は対象外")
    }

    /// idleの回転角変化は対象外（旧基準を保持し遷移しない）。
    func testIdleCaptureAngleChange_isIgnored() {
        seedCalibratedMonitoring()
        sut.stopMonitoring()
        XCTAssertEqual(sut.snapshot.phase, .idle)
        XCTAssertEqual(sut.snapshot.referenceAngle, 10.0)

        changeCaptureAngle(to: 90.0)

        XCTAssertEqual(sut.snapshot.phase, .idle, "idleの回転角変化は対象外")
        XCTAssertEqual(sut.snapshot.referenceAngle, 10.0, "旧基準を保持")
        XCTAssertEqual(sut.snapshot.referenceSide, .right)
        XCTAssertEqual(sut.snapshot.referenceDistance, 0.18)
    }

    /// 同一角の再通知では遷移しない（初期購読・重複発火の無視）。
    func testSameCaptureAngle_doesNotTriggerRecalibration() {
        seedCalibratedMonitoring()

        sut.handleRotationAngleChange(preview: 0.0, capture: 0.0)
        sut.handleRotationAngleChange(preview: 0.0, capture: 0.0)

        XCTAssertEqual(sut.snapshot.phase, .monitoring, "同一角では遷移しない")
        XCTAssertEqual(sut.snapshot.referenceAngle, 10.0)
        XCTAssertEqual(sut.snapshot.referenceSide, .right)
    }

    // MARK: - 基準解決元変化: 再校正しても Motion を継続する

    /// 重力基準で校正済みの監視中に重力が欠測すると代替源への変化で再校正へ遷移する。
    /// このとき Motion を停止してはならない。停止すると再校正中の重力が恒常nilになり
    /// 代替基準でしか完了できず、完了時の Motion 再開で重力が戻ると即座に再発火する
    /// 往復ループになり、基準角度が完了時点のライブ姿勢で書き換わり続ける。
    private func seedGravityCalibratedMonitoring() {
        sut.applyCalibrationCompletion(
            referenceNearAngleDegrees: 10.0,
            referenceDistance: 0.18,
            referenceSide: .right,
            referencePoints: [],
            referenceSource: .gravity
        )
        XCTAssertEqual(sut.snapshot.phase, .monitoring)
        XCTAssertTrue(sut.motionService.isRunning, "前提: 校正完了で Motion 開始")
    }

    /// 両肩そろいフレーム（重力nil時は肩直交代替に解決される）。
    private func bothShouldersFrame() -> PoseFrame {
        PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.3, y: 0.5, confidence: 0.9),
            rightEar: Keypoint(x: 0.7, y: 0.5, confidence: 0.9),
            leftShoulder: Keypoint(x: 0.3, y: 0.6, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.7, y: 0.6, confidence: 0.9)
        )
    }

    /// 解決元変化の再校正では基準破棄・遷移は行うが Motion は継続する。
    func testSourceChangedRecalibration_keepsMotionRunning() {
        seedGravityCalibratedMonitoring()

        // 重力欠測（平置き・センサー途絶の再現）。次フレームは肩直交代替に解決される。
        sut.motionService.latestGravityInKeypointSpace = nil
        sut.processDetection(.pose(bothShouldersFrame()))

        XCTAssertEqual(sut.snapshot.phase, .calibrating, "解決元変化で校正へ自動遷移")
        XCTAssertNil(sut.snapshot.referenceAngle, "旧基準角度を破棄")
        XCTAssertTrue(sut.motionService.isRunning, "再校正中も Motion を継続（重力再解決のため）")
        XCTAssertFalse(sut.settingsStore.isMonitoringEnabled, "監視フラグは落とす")
    }

    /// 重力回復後に再校正が重力基準で完了すれば、以後の重力フレームで再発火しない。
    /// （基準角度がライブ姿勢で書き換わり続ける往復ループの回帰網）
    func testGravityRecoveryAfterSourceChangedRecalibration_staysMonitoring() {
        seedGravityCalibratedMonitoring()

        sut.motionService.latestGravityInKeypointSpace = nil
        sut.processDetection(.pose(bothShouldersFrame()))
        XCTAssertEqual(sut.snapshot.phase, .calibrating)

        // 重力基準で再校正が完了した想定（校正完了＝監視開始で Motion 継続のはず）
        sut.applyCalibrationCompletion(
            referenceNearAngleDegrees: 11.0,
            referenceDistance: 0.18,
            referenceSide: .right,
            referencePoints: [],
            referenceSource: .gravity
        )
        XCTAssertEqual(sut.snapshot.phase, .monitoring)
        XCTAssertTrue(sut.motionService.isRunning)

        // 重力フレームが続いても解決元は一致するため再校正しない。基準角度を保持する。
        sut.motionService.latestGravityInKeypointSpace = SIMD2<Double>(0, 1)
        sut.processDetection(.pose(bothShouldersFrame()))

        XCTAssertEqual(sut.snapshot.phase, .monitoring, "解決元一致では再校正しない")
        XCTAssertEqual(sut.snapshot.referenceAngle, 11.0, "基準角度を保持")
    }
}
