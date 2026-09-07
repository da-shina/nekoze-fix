import XCTest
@testable import NekozeFix

@MainActor
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
        // フェーズ1: 許可確認
        XCTAssertEqual(sut.snapshot.phase, .awaitingPermission)

        // フェーズ2: Bootstrap（認証チェックをシミュレート）
        Task { @MainActor in
            await sut.bootstrap()
        }

        // フェーズ3: キャリブレーション
        sut.startCalibration()
        XCTAssertEqual(sut.snapshot.phase, .calibrating)

        // 人物検出が3秒間安定をシミュレート
        sut.updatePersonDetected(true)

        // TimedConditionGate をシミュレート - 3秒間安定
        var gate = TimedConditionGate(requiredDuration: 3.0)
        let startTime = CFAbsoluteTimeGetCurrent()

        for _ in 0..<60 {
            gate.tick(isConditionMet: true, deltaTime: 1.0/60.0)
            if gate.isFired { break }
        }

        // 3秒後に完了するはず
        if gate.isFired {
            // キャリブレーション完了 - idle または monitoring に移行
            let finalPhase = sut.snapshot.phase
            // キャリブレーションが完了し、モニタリングを開始可能
            sut.startMonitoring()
            XCTAssertTrue(sut.snapshot.phase == .monitoring || sut.snapshot.phase == .idle)
        } else {
            XCTFail("キャリブレーションゲートは3秒後に発火するはず")
        }
    }

    func testSlouchDetectionFlow() {
        // セットアップ: キャリブレーション済みでモニタリング中
        sut.startMonitoring()
        sut.updatePersonDetected(true)

        // 前傾姿勢検出をシミュレート
        var gate = TimedConditionGate(requiredDuration: 5.0)
        let startTime = CFAbsoluteTimeGetCurrent()

        // 前傾姿勢5秒間（角度が閾値超過）をシミュレート
        for _ in 0..<60 {
            gate.tick(isConditionMet: true, deltaTime: 1.0/60.0)
            if gate.isFired { break }
        }

        // 5秒以上の前傾姿勢の後、通知がトリガーされるはず
        // 確認された前傾姿勢は AlertPlayer.playOnce() をトリガー
        XCTAssertTrue(gate.isFired, "5秒の前傾姿勢でゲートが発火するはず")
    }

    func testDimModeToggle() {
        // 通常のモニタリングから開始
        sut.startMonitoring()
        XCTAssertFalse(sut.snapshot.isDimmed)

        // ダイムモードに入る
        sut.enterDimMode()
        XCTAssertTrue(sut.snapshot.isDimmed)

        // ダイムモードを終了
        sut.exitDimMode()
        XCTAssertFalse(sut.snapshot.isDimmed)
    }

    func testSensitivityMapping() {
        let store = SettingsStore()

        // sensitivity 0.0 → 20度
        store.sensitivity = 0.0
        XCTAssertEqual(store.slouchDeltaThresholdDegrees(), 20.0)

        // sensitivity 1.0 → 5度
        store.sensitivity = 1.0
        XCTAssertEqual(store.slouchDeltaThresholdDegrees(), 5.0)

        // sensitivity 0.5 → 12.5度
        store.sensitivity = 0.5
        XCTAssertEqual(store.slouchDeltaThresholdDegrees(), 12.5, accuracy: 0.001)
    }
}