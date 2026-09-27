import XCTest
@testable import NekozeFix

/// Task 8.5: 距離指標のセッション統合テスト。
/// 角度は閾値未満のまま、校正ロック側（右）の耳-肩距離だけが基準比閾値以上へ伸びる
/// 合成フレームを投入し、.slouch 表示 → 回復で .good を確認する（FQ6 OR 判定の E2E 経路）。
@MainActor
final class DistanceMetricIntegrationTests: XCTestCase {
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

    /// 左右とも耳が肩の真上（角度0度）で、ロック側（右）の耳-肩距離だけ dist のフレーム。
    private func frame(rightEarDistance: Double) -> PoseFrame {
        PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.3, y: 0.6 - 0.1, confidence: 0.9), // 近側・距離0.1
            rightEar: Keypoint(x: 0.7, y: 0.6 - rightEarDistance, confidence: 0.9),
            leftShoulder: Keypoint(x: 0.3, y: 0.6, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.7, y: 0.6, confidence: 0.9)
        )
    }

    /// 校正済み状態で監視を開始する。
    /// 基準: 角度0度・距離0.18（ロック側 .right）、角度閾値5度・距離閾値8%（デフォルト）。
    private func seedCalibratedMonitoring() {
        sut.applyCalibrationCompletion(
            referenceNearAngleDegrees: 0.0,
            referenceDistance: 0.18,
            referenceSide: .right,
            referencePoints: []
        )
    }

    // MARK: - 距離パス E2E

    /// ロック側距離が基準比 8% 超へ成長 → 3秒連続で .slouch → 回復で .good
    func testGrowingLockSideDistance_showsSlouchThenGood() throws {
        seedCalibratedMonitoring()
        XCTAssertEqual(sut.snapshot.phase, .monitoring)

        // 段階1: 静止（距離0.18 = 基準比100%）→ good
        for _ in 0..<5 {
            sut.processDetection(.pose(frame(rightEarDistance: 0.18)))
        }
        XCTAssertEqual(sut.snapshot.displayedPosture, .good, "基準比100%は良好")

        // 段階2: 前出し（距離0.21 = 基準比116.7% > 108%、角度は0度）→ slouchCandidate
        var slouchFrames = 0
        for _ in 0..<5 {
            sut.processDetection(.pose(frame(rightEarDistance: 0.21)))
            if sut.snapshot.displayedPosture == .slouch { slouchFrames += 1 }
        }
        XCTAssertGreaterThan(slouchFrames, 0, "距離OVERのフレームで .slouch 表示が出るはず（角度は0度でも）")

        // 段階3: 回復（距離0.18 に戻す）→ 角度も距離も UNDER → good
        for _ in 0..<5 {
            sut.processDetection(.pose(frame(rightEarDistance: 0.18)))
        }
        XCTAssertEqual(sut.snapshot.displayedPosture, .good, "全指標閾値未満で改善")
    }

    /// 回帰: distanceMetric 相当なし（校正前）でも角度判定は旧来通り動く
    func testAngleOnlyRegression_stillJudges() {
        sut.applyCalibrationCompletion(
            referenceNearAngleDegrees: 0.0,
            referenceDistance: 0.18,
            referenceSide: .right,
            referencePoints: []
        )
        // 角度OVER・距離UNDER（右距離0.18 = 基準比ちょうど100%、左耳を傾けて近側角度を作る）
        let frameAngleOver = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.32, y: 0.52, confidence: 0.9),  // 近側（左）の角度 ≈ 11度
            rightEar: Keypoint(x: 0.7, y: 0.42, confidence: 0.9),  // 距離0.18
            leftShoulder: Keypoint(x: 0.3, y: 0.6, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.7, y: 0.6, confidence: 0.9)
        )
        sut.processDetection(.pose(frameAngleOver))
        XCTAssertEqual(sut.snapshot.displayedPosture, .slouch, "角度OVERでも .slouch")
    }

    /// 距離閾値（SettingsStore 単一ソース）がフレーム毎の判定に反映される
    func testDistanceThresholdChange_affectsVerdictImmediately() {
        let suite = UserDefaults(suiteName: "DistanceMetricIntegrationTests")!
        suite.removePersistentDomain(forName: "DistanceMetricIntegrationTests")
        let store = SettingsStore(defaults: suite)
        let manager = PostureSessionManager(settingsStore: store)
        manager.applyCalibrationCompletion(
            referenceNearAngleDegrees: 0.0,
            referenceDistance: 0.18,
            referenceSide: .right,
            referencePoints: []
        )
        let shrunk = frame(rightEarDistance: 0.19) // 基準比 105.6%

        // デフォルト8%（>=108%でOVER）では good
        for _ in 0..<3 { manager.processDetection(.pose(shrunk)) }
        XCTAssertEqual(manager.snapshot.displayedPosture, .good)

        // 同一 store の閾値を5%（>=105%でOVER）へ変更 → 同一フレームで即 slouch
        store.slouchDistanceThresholdPercent = 5.0
        for _ in 0..<3 { manager.processDetection(.pose(shrunk)) }
        XCTAssertEqual(manager.snapshot.displayedPosture, .slouch, "閾値変更が次フレームから反映されるはず")

        suite.removePersistentDomain(forName: "DistanceMetricIntegrationTests")
    }
}
