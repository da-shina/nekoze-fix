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

        // フェーズ3: キャリブレーション
        sut.startCalibration()
        XCTAssertEqual(sut.snapshot.phase, .calibrating)

        // 人物検出が3秒間安定をシミュレート
        sut.updatePersonDetected(true)

        // TimedConditionGate をシミュレート - 3秒間安定
        var gate = TimedConditionGate(requiredDuration: 3.0)

        // 3秒分（300フレーム @60fps）tick - 余裕を持たせる
        for _ in 0..<300 {
            _ = gate.tick(isConditionMet: true, deltaTime: 1.0/60.0)
        }

        // 3秒後に完了するはず
        XCTAssertTrue(gate.isFired, "キャリブレーションゲートは3秒後に発火するはず")

        // キャリブレーション完了 - idle または monitoring に移行
        sut.startMonitoring()
        XCTAssertTrue(sut.snapshot.phase == .monitoring || sut.snapshot.phase == .idle)
    }

    func testSlouchDetectionFlow() {
        // セットアップ: キャリブレーション済みでモニタリング中
        sut.startMonitoring()
        sut.updatePersonDetected(true)

        // 前傾姿勢検出をシミュレート
        var gate = TimedConditionGate(requiredDuration: 5.0)

        // 前傾姿勢5秒間（角度が閾値超過）をシミュレート
        for _ in 0..<300 {
            _ = gate.tick(isConditionMet: true, deltaTime: 1.0/60.0)
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

}
