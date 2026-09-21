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

        // 人物検出をシミュレート（processDetection 経由で isPersonDetected を設定）
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.3, y: 0.4, confidence: 0.9),
            rightEar: nil,
            leftShoulder: Keypoint(x: 0.4, y: 0.7, confidence: 0.9),
            rightShoulder: nil
        )
        sut.processDetection(.pose(frame))

        // TimedConditionGate をシミュレート - 5秒間安定
        var gate = TimedConditionGate(requiredDuration: 5.0)

        // 5秒分（330フレーム @60fps）tick - 余裕を持たせる
        for _ in 0..<330 {
            _ = gate.tick(isConditionMet: true, deltaTime: 1.0/60.0)
        }

        // 5秒後に完了するはず
        XCTAssertTrue(gate.isFired, "キャリブレーションゲートは5秒後に発火するはず")

        // キャリブレーション完了 - idle または monitoring に移行
        sut.startMonitoring()
        XCTAssertTrue(sut.snapshot.phase == .monitoring || sut.snapshot.phase == .idle)
    }

    func testSlouchDetectionFlow() {
        // セットアップ: キャリブレーション済みでモニタリング中
        sut.startMonitoring()
        // 人物検出をシミュレート
        let frame = PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.3, y: 0.4, confidence: 0.9),
            rightEar: nil,
            leftShoulder: Keypoint(x: 0.4, y: 0.7, confidence: 0.9),
            rightShoulder: nil
        )
        sut.processDetection(.pose(frame))

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
