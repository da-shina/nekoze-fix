import XCTest
import AVFoundation
@testable import NekozeFix

/// Task 3.1: 撮影出力接続への回転適用改修の分離検証。
/// requirements.md 1.1, 2.1, 2.2, 3.1, 3.2。
/// design.md CameraSessionManager（改修）：`updateCaptureRotationAngle(_:)` 転送
/// インターフェース＋対応可否の実行時判定＋退行則（非対応時は見送り）。
///
/// 【TestDouble 方針】実転送結線は task 4.1。本ファイルでは分離検証のみ行う：
/// - 角度値は `FakeDeviceRotationService`（DeviceRotationTestDouble.swift）から注入する
///  （`FakeDeviceRotationServiceProtocol` の capture 角を駆動源にする）。
/// - 接続は共有 `FakeCaptureConnection`（DeviceRotationTestDouble.swift）へ注入する。
///   simulator には video デバイスが存在しないため実接続は使わない。
/// - preview 接続には触らない（`CameraPreviewView` が所有）。本マネージャは
///   data-output 接続（＝注入 Fake）のみを操作する。
/// - Vision バッファ向き `.up` 不変は `PostureSessionManager.captureOutput` 側であり、
///   本ファイルでは回転適用がバッファ向き前提を壊さないこと（例外なく見送る）を
///   退行則テストで担保する。
final class CameraSessionManagerRotationTests: XCTestCase {
    private func makeManager(with connection: FakeCaptureConnection) -> CameraSessionManager {
        let manager = CameraSessionManager()
        manager.rotationConnectionForTesting = connection
        return manager
    }

    // MARK: - capture 回転角の適用（前面／背面・新旧姿勢）

    /// ポートレート角（0°）が data-output 接続へ適用される。
    /// requirements.md 2.1（縦置きでの映像向き合わせ）。
    /// 角度値は Fake（TestDouble）から注入する。
    func testUpdateCaptureRotationAngle_appliesPortraitAngleFromFake() {
        let rotationSource = FakeDeviceRotationService(previewAngle: 0.0, captureAngle: 0.0)
        // 初期角を 90° にして 0° 適用の有無を判別可能にする（初期 0° では無適用でも通過するため）。
        let connection = FakeCaptureConnection(initialAngle: 90.0)
        let manager = makeManager(with: connection)

        manager.updateCaptureRotationAngle(rotationSource.captureRotationAngle)
        manager.flushRotationWorkForTesting()

        XCTAssertEqual(connection.videoRotationAngle, 0.0, "ポートレート角（0°）が適用される")
    }

    /// ランドスケープ角（90°）が適用される。requirements.md 2.1（横置き）。
    func testUpdateCaptureRotationAngle_appliesLandscapeAngleFromFake() {
        let rotationSource = FakeDeviceRotationService(previewAngle: 90.0, captureAngle: 90.0)
        let connection = FakeCaptureConnection()
        let manager = makeManager(with: connection)

        manager.updateCaptureRotationAngle(rotationSource.captureRotationAngle)
        manager.flushRotationWorkForTesting()

        XCTAssertEqual(connection.videoRotationAngle, 90.0, "ランドスケープ角（90°）が適用される")
    }

    /// 新旧デバイス姿勢でのバッファ向き：0°→180°→270° の遷移が正しく適用される。
    /// requirements.md 2.2（回転追従）、3.1（切替後の継続の角度側）。
    func testUpdateCaptureRotationAngle_appliesSequentialAnglesForOrientationChanges() {
        let connection = FakeCaptureConnection()
        let manager = makeManager(with: connection)
        let angles: [CGFloat] = [0, 90, 180, 270]

        for angle in angles {
            let source = FakeDeviceRotationService(previewAngle: angle, captureAngle: angle)
            manager.updateCaptureRotationAngle(source.captureRotationAngle)
            manager.flushRotationWorkForTesting()
            XCTAssertEqual(
                connection.videoRotationAngle, angle,
                "姿勢遷移角 \(angle)° が順次適用される"
            )
        }
    }

    // MARK: - 前面／背面ミラー

    /// 前面カメラではミラー有効、背面では無効になる（前面ミラー設定は維持）。
    /// requirements.md 3.1, 3.2。
    func testUpdateMirrorSetting_frontIsMirrored_backIsNot() {
        let connection = FakeCaptureConnection()
        let manager = makeManager(with: connection)

        manager.updateMirrorSetting(for: .front)
        manager.flushRotationWorkForTesting()
        XCTAssertTrue(connection.isVideoMirrored, "前面ではミラー有効")

        manager.updateMirrorSetting(for: .back)
        manager.flushRotationWorkForTesting()
        XCTAssertFalse(connection.isVideoMirrored, "背面ではミラー無効")
    }

    // MARK: - 対応可否の退行則

    /// 非対応時は適用を見送り、現行回転角で継続する（クラッシュさせない）。
    /// design.md Error Handling「回転角の適用非対応 → 見送り」、
    /// research.md「`isVideoRotationAngleSupported` と非対応時の退行則」。
    func testUpdateCaptureRotationAngle_skipsWhenUnsupported_fallbackRule() {
        // 45° は仕様上非対応（0/90/180/270 のみ対応。SDK ヘッダ参照）。
        // 初期 0° から 90° 適用の有無を判別可能にする（初期 90° では無適用でも通過するため）。
        let connection = FakeCaptureConnection(supportedAngles: [0, 90, 180, 270], initialAngle: 0.0)
        let manager = makeManager(with: connection)

        // 直前有効角として 90° を確定させる（Fake 注入角の適用）。
        let validSource = FakeDeviceRotationService(previewAngle: 90.0, captureAngle: 90.0)
        manager.updateCaptureRotationAngle(validSource.captureRotationAngle)
        manager.flushRotationWorkForTesting()
        XCTAssertEqual(connection.videoRotationAngle, 90.0, "前提：直前有効角 90° が適用済み")

        // 非対応角 45° は見送られ、直前有効角が維持される（例外なし）。
        manager.updateCaptureRotationAngle(45.0)
        manager.flushRotationWorkForTesting()
        XCTAssertEqual(
            connection.videoRotationAngle, 90.0,
            "非対応時は適用を見送り直前有効角を維持する（退行則）"
        )
    }

    /// 接続自体が回転非対応（空集合）の場合も例外なく見送る。
    func testUpdateCaptureRotationAngle_skipsWhenConnectionUnsupported_noCrash() {
        let connection = FakeCaptureConnection(supportedAngles: [], initialAngle: 0.0)
        let manager = makeManager(with: connection)

        let source = FakeDeviceRotationService(previewAngle: 90.0, captureAngle: 90.0)
        // 例外が投げられないこと（XCTAssertNoThrow 相当。落ちなければ成功）。
        manager.updateCaptureRotationAngle(source.captureRotationAngle)
        manager.flushRotationWorkForTesting()

        XCTAssertEqual(connection.videoRotationAngle, 0.0, "非対応接続では現行角を維持する")
    }
}
