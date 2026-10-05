import XCTest
import AVFoundation
@testable import NekozeFix

/// 回転トリガの駆動源が capture 角のみであること、および
/// rotationService nil 時の再生成指示が安全であることの検証。
/// 製品: PostureSessionManager.handleRotationAngleChange/requestRotationRecreate。
/// preview 単独変化での再校正は仕様外であり、回転ファクトリ簡素化の際も
/// 本テストが振る舞いを固定する。
@MainActor
final class RotationPreviewOnlyAndNilServiceTests: XCTestCase {
    var sut: PostureSessionManager!

    override func setUp() {
        super.setUp()
        sut = PostureSessionManager()
        sut.settingsStore.cameraPosition = .front // adjusted==capture に固定
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
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

    private func anyCaptureDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(for: .video) ?? AVCaptureDevice.default(for: .audio)
    }

    // MARK: - preview 単独変化は再校正しない

    /// capture 不変・preview のみ変化では監視継続し旧基準を保持する。
    func testPreviewOnlyChange_doesNotTriggerRecalibration() {
        seedCalibratedMonitoring()
        sut.handleRotationAngleChange(preview: 0.0, capture: 0.0) // 基準確定

        sut.handleRotationAngleChange(preview: 90.0, capture: 0.0) // preview のみ変化

        XCTAssertEqual(sut.snapshot.phase, .monitoring, "preview 単独変化は再校正しない")
        XCTAssertEqual(sut.snapshot.referenceAngle, 10.0, "旧基準角度を保持")
        XCTAssertEqual(sut.snapshot.referenceSide, .right, "ロック側を保持")
        XCTAssertEqual(sut.snapshot.referenceDistance, 0.18, "旧基準距離を保持")
    }

    // MARK: - nil サービス時の安全

    /// rotationService nil でも再生成指示はクラッシュせず確定デバイスの記録は行う。
    /// optional chain は引数評価ごと短絡するため所有層は生成されない。
    /// デバイス記録は後付け結線(handlePreviewLayerAppeared)に必要なため固定する。
    func testRequestRotationRecreate_withNilService_recordsDeviceWithoutCrash() {
        guard let device = anyCaptureDevice() else {
            return // simulator にデバイスなし。意味的検証は実機に委ねる
        }
        sut.rotationService = nil

        XCTAssertNoThrow(sut.requestRotationRecreate(for: device))
        XCTAssertTrue(sut.lastFinalizedCameraDevice === device, "nil 時も確定デバイスの記録は行う")
    }

    /// 未確定 + nil サービスの層出現通知はなにもしない(クラッシュなし)。
    func testPreviewLayerAppeared_beforeFinalizeWithNilService_doesNothing() {
        sut.rotationService = nil

        XCTAssertNoThrow(sut.handlePreviewLayerAppeared())
        XCTAssertNil(sut.ownedPreviewLayer, "未確定時は層を生成しない")
    }
}
