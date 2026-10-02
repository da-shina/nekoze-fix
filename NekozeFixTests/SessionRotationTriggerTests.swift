import XCTest
import AVFoundation
@testable import NekozeFix

/// Task 3.3: 新トリガ `handleRotationAngleChange(preview:capture:)` の分離検証。
/// requirements.md 2.1, 2.2, 2.3, 2.4, 3.1, 3.2, 4.1。
/// design.md PostureSessionManager（改修）：新トリガ署名への移管、capture 角転送
/// （preview 非転送）、coordinator 再生成指示、Motion 起停と同一則の回転起停。
/// 旧向き通知ハンドラは削除済み（旧呼出し側の更新は task 4.2）。
/// 実購読結線・順序保証は task 4.1。本ファイルでは角度値の直接注入で駆動する
/// （OrientationRecalibrationTests の直接呼出し方式と同一パターン）。
///
/// simulator 制約：video デバイス不在時はデバイス要テストを graceful-skip する
/// （1.2／2.1／3.2 と同一パターン）。
extension FakeDeviceRotationService: SessionRotationService {}

@MainActor
final class SessionRotationTriggerTests: XCTestCase {
    var sut: PostureSessionManager!

    override func setUp() {
        super.setUp()
        sut = PostureSessionManager()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Fake

    /// `VideoRotationConnection` 適合の TestDouble（全角対応）。
    final class FakeSessionCaptureConnection: VideoRotationConnection {
        var videoRotationAngle: CGFloat
        var isVideoMirroringSupported: Bool = false
        var isVideoMirrored: Bool = false

        init(initialAngle: CGFloat = -999.0) {
            self.videoRotationAngle = initialAngle
        }

        func isVideoRotationAngleSupported(_ videoRotationAngle: CGFloat) -> Bool { true }
    }

    private func seedCalibratedMonitoring() {
        sut.applyCalibrationCompletion(
            referenceNearAngleDegrees: 10.0,
            referenceDistance: 0.18,
            referenceSide: .right,
            referencePoints: []
        )
        XCTAssertEqual(sut.snapshot.phase, .monitoring)
    }

    /// 初期購読相当の確定：初回は重複扱いで再校正しない（旧ハンドラと同一則）。
    private func establishBaseline(preview: CGFloat = 0.0, capture: CGFloat = 0.0) {
        sut.handleRotationAngleChange(preview: preview, capture: capture)
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

    private func anyCaptureDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(for: .video) ?? AVCaptureDevice.default(for: .audio)
    }

    // MARK: - capture 角の転送（preview 非転送）

    /// capture 角が data-output 接続へ転送される（requirements 2.1）。
    func testHandleRotationAngleChange_forwardsCaptureAngleToCameraManager() {
        let connection = FakeSessionCaptureConnection()
        sut.cameraManager.rotationConnectionForTesting = connection

        sut.handleRotationAngleChange(preview: 270.0, capture: 90.0)
        sut.cameraManager.flushRotationWorkForTesting()

        XCTAssertEqual(connection.videoRotationAngle, 90.0, "capture 角を転送する")
        XCTAssertEqual(sut.cameraManager.lastCaptureRotationAngle, 90.0)
    }

    /// preview 角は転送しない（View が Service を直接購読するため）。
    func testHandleRotationAngleChange_doesNotForwardPreviewAngle() {
        let connection = FakeSessionCaptureConnection()
        sut.cameraManager.rotationConnectionForTesting = connection

        sut.handleRotationAngleChange(preview: 270.0, capture: 0.0)
        sut.cameraManager.flushRotationWorkForTesting()

        XCTAssertEqual(connection.videoRotationAngle, 0.0, "preview 角は転送せず capture 角のみ適用する")
    }

    // MARK: - isLandscape 導出（意味不変。対応表化は 3.4）

    /// coordinator実機規約での基数角確認（portrait {90,270}＝false／landscape {0,180}＝true）。
    /// センサがランドスケープネイティブのためポートレートで90°を取る（WWDC23 10106）。
    func testHandleRotationAngleChange_updatesIsLandscapeFromCaptureAngle() {
        sut.handleRotationAngleChange(preview: 0.0, capture: 0.0)
        XCTAssertTrue(sut.snapshot.isLandscape, "capture 0°＝ランドスケープ")
        sut.handleRotationAngleChange(preview: 0.0, capture: 90.0)
        XCTAssertFalse(sut.snapshot.isLandscape, "capture 90°＝ポートレート")
        sut.handleRotationAngleChange(preview: 0.0, capture: 180.0)
        XCTAssertTrue(sut.snapshot.isLandscape, "capture 180°＝ランドスケープ")
        sut.handleRotationAngleChange(preview: 0.0, capture: 270.0)
        XCTAssertFalse(sut.snapshot.isLandscape, "capture 270°＝ポートレート")
    }

    // MARK: - isLandscape 対応表（task 3.4, requirements 2.1, 2.2）

    /// design.md PostureSessionManager の対応表を境界値で固定する。
    /// 90°±45°・270°±45° → portrait、0°±45°・180°±45° → landscape（実機規約）。
    /// 境界はランドスケープ側に含める（45°→true、135°→false、225°→true、315°→false）。
    /// 境界ヒステリシスなし。
    func testIsLandscapeTable_boundaries() {
        let cases: [(capture: CGFloat, expected: Bool, label: String)] = [
            (0.0, true, "0° landscape"),
            (44.9, true, "45°直前 landscape"),
            (45.0, false, "45°境界 portrait"),
            (90.0, false, "90° portrait"),
            (134.9, false, "135°直前 portrait"),
            (135.0, true, "135°境界 landscape"),
            (180.0, true, "180° landscape"),
            (224.9, true, "225°直前 landscape"),
            (225.0, false, "225°境界 portrait"),
            (270.0, false, "270° portrait"),
            (314.9, false, "315°直前 portrait"),
            (315.0, true, "315°境界 landscape"),
            (360.0, true, "360° wrap landscape"),
            (-90.0, false, "-90° wrap portrait"),
            (-45.0, true, "-45° wrap landscape"),
        ]
        for c in cases {
            sut.handleRotationAngleChange(preview: 0.0, capture: c.capture)
            XCTAssertEqual(sut.snapshot.isLandscape, c.expected, "capture \(c.label)")
        }
    }

    /// capture 角は Vision バッファと一致し軸方向のみを見るため、前面鏡の
    /// 影響を受けない。前面／背面の例値で同等性を smoke 確認する（行列なし）。
    func testIsLandscapeTable_frontBackSmokeEquivalence() {
        let originalPosition = sut.settingsStore.cameraPosition
        defer { sut.settingsStore.cameraPosition = originalPosition }
        for position in [CameraPosition.front, CameraPosition.back] {
            sut.settingsStore.cameraPosition = position
            sut.handleRotationAngleChange(preview: 0.0, capture: 90.0)
            XCTAssertFalse(sut.snapshot.isLandscape, "\(position) capture 90°＝portrait")
            sut.handleRotationAngleChange(preview: 0.0, capture: 0.0)
            XCTAssertTrue(sut.snapshot.isLandscape, "\(position) capture 0°＝landscape")
        }
    }

    // MARK: - 自動再校正トリガ（capture 角変化。requirements 2.3, 2.4）

    /// monitoring 中の capture 角変化で旧基準破棄→校正へ自動遷移する。
    func testCaptureChangeDuringMonitoring_discardsReferencesAndMovesToCalibrating() {
        seedCalibratedMonitoring()
        // ゲートを確定まで進める（破棄の検証用。実フレーム投入で実時間蓄積する）
        let deadline = Date().addingTimeInterval(10)
        while !sut.snapshot.slouchGate.isFired && Date() < deadline {
            sut.processDetection(.pose(slouchFrame()))
            usleep(20_000)
        }
        XCTAssertTrue(sut.snapshot.slouchGate.isFired, "前提: 猫背3秒連続で確定")

        establishBaseline()
        XCTAssertEqual(sut.snapshot.phase, .monitoring, "初回確定では遷移しない")
        sut.handleRotationAngleChange(preview: 0.0, capture: 90.0)

        XCTAssertEqual(sut.snapshot.phase, .calibrating, "capture 角変化で校正へ自動遷移")
        XCTAssertNil(sut.snapshot.referenceAngle, "旧基準角度を破棄")
        XCTAssertNil(sut.snapshot.referenceDistance, "旧基準距離を破棄")
        XCTAssertNil(sut.snapshot.referenceSide, "ロック側を破棄")
        XCTAssertEqual(sut.snapshot.slouchGate.accumulated, 0, "猫背ゲートを破棄")
        XCTAssertFalse(sut.snapshot.slouchGate.isFired)
        XCTAssertTrue(sut.motionService.isRunning, "再校正フローで Motion を継続")
    }

    /// 同一 capture 角の再通知では遷移しない（初期購読・重複発火の無視）。
    func testSameCaptureAngle_doesNotTriggerRecalibration() {
        seedCalibratedMonitoring()

        establishBaseline()
        sut.handleRotationAngleChange(preview: 0.0, capture: 0.0)

        XCTAssertEqual(sut.snapshot.phase, .monitoring, "同一角では遷移しない")
        XCTAssertEqual(sut.snapshot.referenceAngle, 10.0)
        XCTAssertEqual(sut.snapshot.referenceSide, .right)
    }

    /// calibrating 中の角変化は対象外（校正蓄積を妨げない）。
    func testCalibratingCaptureChange_isIgnored() {
        sut.startCalibration()
        XCTAssertEqual(sut.snapshot.phase, .calibrating)

        establishBaseline()
        sut.handleRotationAngleChange(preview: 0.0, capture: 90.0)

        XCTAssertEqual(sut.snapshot.phase, .calibrating, "calibrating 中の角変化は対象外")
    }

    /// idle の角変化は対象外（旧基準を保持し遷移しない）。
    func testIdleCaptureChange_isIgnored() {
        seedCalibratedMonitoring()
        sut.stopMonitoring()
        XCTAssertEqual(sut.snapshot.phase, .idle)
        XCTAssertEqual(sut.snapshot.referenceAngle, 10.0)

        establishBaseline()
        sut.handleRotationAngleChange(preview: 0.0, capture: 90.0)

        XCTAssertEqual(sut.snapshot.phase, .idle, "idle の角変化は対象外")
        XCTAssertEqual(sut.snapshot.referenceAngle, 10.0, "旧基準を保持")
        XCTAssertEqual(sut.snapshot.referenceSide, .right)
        XCTAssertEqual(sut.snapshot.referenceDistance, 0.18)
    }

    // MARK: - 回転起停（Motion 起停と完全同一箇所）

    /// 監視開始で回転開始（Motion 開始と同一箇所）。
    func testStartMonitoring_drivesRotationStartWithMotion() {
        let fake = FakeDeviceRotationService()
        sut.rotationService = fake

        sut.startMonitoring()

        XCTAssertTrue(sut.motionService.isRunning, "Motion 開始")
        XCTAssertEqual(fake.startCallCount, 1, "Motion 開始と同一箇所で回転開始")
    }

    /// 監視停止で回転停止（Motion 停止と同一箇所）。
    func testStopMonitoring_drivesRotationStopWithMotion() {
        let fake = FakeDeviceRotationService()
        sut.rotationService = fake
        sut.startMonitoring()
        XCTAssertEqual(fake.startCallCount, 1)

        sut.stopMonitoring()

        XCTAssertFalse(sut.motionService.isRunning, "Motion 停止")
        XCTAssertEqual(fake.stopCallCount, 1, "Motion 停止と同一箇所で回転停止")
    }

    /// 校正開始で回転開始（Motion 開始と同一箇所）。
    func testStartCalibration_drivesRotationStartWithMotion() {
        let fake = FakeDeviceRotationService()
        sut.rotationService = fake

        sut.startCalibration()

        XCTAssertTrue(sut.motionService.isRunning, "Motion 開始")
        XCTAssertEqual(fake.startCallCount, 1, "Motion 開始と同一箇所で回転開始")
    }

    /// 背景移行で回転停止（Motion 停止と同一箇所）。
    func testBackgroundTransition_drivesRotationStopWithMotion() {
        seedCalibratedMonitoring()
        let fake = FakeDeviceRotationService()
        sut.rotationService = fake

        sut.handleDidEnterBackground()

        XCTAssertFalse(sut.motionService.isRunning, "背景移行で Motion 停止")
        XCTAssertEqual(fake.stopCallCount, 1, "背景移行で Motion 停止と同一箇所で回転停止")
    }

    /// 校正完了で回転開始（Motion 開始と同一箇所）。
    func testCalibrationCompletion_drivesRotationStartWithMotion() {
        let fake = FakeDeviceRotationService()
        sut.rotationService = fake

        sut.applyCalibrationCompletion(
            referenceNearAngleDegrees: 10.0,
            referenceDistance: 0.18,
            referenceSide: .right,
            referencePoints: []
        )

        XCTAssertTrue(sut.motionService.isRunning, "Motion 開始")
        XCTAssertEqual(fake.startCallCount, 1, "Motion 開始と同一箇所で回転開始")
    }

    /// 暗転中は回転継続（Motion 継続と同一。停止しない）。
    func testDimMode_keepsRotationRunningWithMotion() {
        let fake = FakeDeviceRotationService()
        sut.rotationService = fake
        sut.startMonitoring()
        XCTAssertEqual(fake.startCallCount, 1)

        sut.enterDimMode()

        XCTAssertTrue(sut.motionService.isRunning, "暗転中も Motion 継続")
        XCTAssertEqual(fake.stopCallCount, 0, "暗転中は回転停止しない")
    }

    // MARK: - coordinator 再生成指示（実結線は 4.1）

    /// カメラ確定時に所有層で再生成を指示する。
    func testRequestRotationRecreate_forwardsDeviceAndOwnedLayer() {
        guard let device = anyCaptureDevice() else {
            return // simulator には capture デバイスがない。意味的検証は実機に委ねる
        }
        let fake = FakeDeviceRotationService()
        sut.rotationService = fake

        sut.requestRotationRecreate(for: device)

        XCTAssertEqual(fake.recreateCallCount, 1)
        XCTAssertTrue(fake.recreatedDevice === device, "確定デバイスを渡す")
        XCTAssertNotNil(fake.recreatedLayer, "Session 所有層を渡す")
        XCTAssertNotNil(sut.ownedPreviewLayer, "所有層を生成して保持する")
        XCTAssertTrue(fake.recreatedLayer === sut.ownedPreviewLayer, "所有層の同一インスタンスを使う")
    }

    /// 層出現時（未確定）は再生成しない（確定デバイスなしの見送り）。
    func testPreviewLayerAppeared_beforeFinalize_doesNothing() {
        let fake = FakeDeviceRotationService()
        sut.rotationService = fake

        sut.handlePreviewLayerAppeared()

        XCTAssertEqual(fake.recreateCallCount, 0, "確定デバイスなしでは再生成しない")
    }

    /// 層出現時（確定済み）は確定デバイス＋所有層で再生成する。
    func testPreviewLayerAppeared_afterFinalize_recreatesWithSameDeviceAndLayer() {
        guard let device = anyCaptureDevice() else {
            return // simulator には capture デバイスがない。意味的検証は実機に委ねる
        }
        let fake = FakeDeviceRotationService()
        sut.rotationService = fake
        sut.requestRotationRecreate(for: device)
        XCTAssertEqual(fake.recreateCallCount, 1)

        sut.handlePreviewLayerAppeared()

        XCTAssertEqual(fake.recreateCallCount, 2)
        XCTAssertTrue(fake.recreatedDevice === device, "確定デバイスを使い回す")
        XCTAssertTrue(fake.recreatedLayer === sut.ownedPreviewLayer, "所有層の同一インスタンスを使う")
    }
}
