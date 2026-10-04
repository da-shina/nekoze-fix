import XCTest
@testable import NekozeFix

/// personMissing猶予と肩欠測猶予が独立タイマであることの分離検証。
/// 製品: PostureSessionManager.processDetection/updateState。
/// personMissingGracePeriod と shoulderMissingGracePeriod は同値(0.5秒)だが
/// 別信号・別時刻(lastPersonSeenTime/lastShoulderSeenTime)であり、
/// 単一Debouncerへの一本化で混同してはならない。本ファイルが混同を検出する。
/// 時刻源は CACurrentMediaTime のため、猶予超過は実スリープ(0.65秒)で再現する。
@MainActor
final class SessionDebounceSeparationTests: XCTestCase {
    var sut: PostureSessionManager!

    override func setUp() {
        super.setUp()
        sut = PostureSessionManager()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    private func poseFrame() -> PoseFrame {
        PoseFrame(
            timestamp: 0,
            leftEar: Keypoint(x: 0.3, y: 0.4, confidence: 0.9),
            rightEar: Keypoint(x: 0.7, y: 0.4, confidence: 0.9),
            leftShoulder: Keypoint(x: 0.4, y: 0.7, confidence: 0.9),
            rightShoulder: Keypoint(x: 0.6, y: 0.7, confidence: 0.9)
        )
    }

    // MARK: - personMissing猶予 (updateState側)

    /// 初回から人物なし: 参照時刻なしでは即時personMissing(猶予なし)。
    func testAbsent_withoutPriorSeen_isImmediatelyPersonMissing() {
        sut.processDetection(.absent)
        XCTAssertFalse(sut.snapshot.isPersonDetected, "未検出継続中は猶予なく人物なし")
    }

    /// 猶予内欠測はノイズ扱いで検出中維持+可視化点保持。
    func testAbsent_withinGrace_holdsDetectedAndPoints() {
        sut.processDetection(.pose(poseFrame()))
        XCTAssertTrue(sut.snapshot.isPersonDetected)
        let held = sut.snapshot.visualizationPoints

        sut.processDetection(.absent)

        XCTAssertTrue(sut.snapshot.isPersonDetected, "0.5秒未満の欠測は保持する")
        XCTAssertEqual(sut.snapshot.visualizationPoints, held, "猶予内は可視化点を維持する")
    }

    /// 猶予超過の欠測は人物なし確定。
    func testAbsent_beyondGrace_becomesPersonMissing() {
        sut.processDetection(.pose(poseFrame()))
        Thread.sleep(forTimeInterval: 0.65)

        sut.processDetection(.absent)

        XCTAssertFalse(sut.snapshot.isPersonDetected, "0.5秒超過の欠測は人物なし確定")
    }

    // MARK: - 肩欠測猶予 (processDetection .personOnly側)

    /// 初回から顔のみ: 参照時刻なしでは即時肩欠測。
    func testPersonOnly_withoutPriorShoulders_isImmediatelyShoulderMissing() {
        sut.processDetection(.personOnly)
        XCTAssertTrue(sut.snapshot.isShoulderMissing, "肩未検出継続中は猶予なく欠測確定")
        XCTAssertTrue(sut.snapshot.isPersonDetected, "顔のみでも人物は検出中")
    }

    /// 猶予内の顔のみは欠測にしない(チラつき防止)。
    func testPersonOnly_withinGrace_holdsNotMissing() {
        sut.processDetection(.pose(poseFrame()))

        sut.processDetection(.personOnly)

        XCTAssertFalse(sut.snapshot.isShoulderMissing, "0.5秒未満の肩脱落は保持する")
        XCTAssertTrue(sut.snapshot.isPersonDetected)
    }

    /// 猶予超過の顔のみは肩欠測確定。
    func testPersonOnly_beyondGrace_becomesShoulderMissing() {
        sut.processDetection(.pose(poseFrame()))
        Thread.sleep(forTimeInterval: 0.65)

        sut.processDetection(.personOnly)

        XCTAssertTrue(sut.snapshot.isShoulderMissing, "0.5秒超過の肩脱落は欠測確定")
        XCTAssertTrue(sut.snapshot.isPersonDetected, "肩欠測でも人物は検出中")
    }

    // MARK: - 独立性 (混同検出の本命)

    /// .absent が肩タイマをリセットしないこと。
    /// 単一タイマへの誤った一本化(欠測種別で時刻共有)は本テストを落とす。
    func testAbsent_doesNotResetShoulderTimer() {
        sut.processDetection(.pose(poseFrame()))
        sut.processDetection(.absent) // 人物猶予内: 保持されるが肩時刻に触らないはず

        sut.processDetection(.personOnly)

        XCTAssertFalse(
            sut.snapshot.isShoulderMissing,
            ".absent は肩欠測タイマと無関係のはず"
        )
    }
}
