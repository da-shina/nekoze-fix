import XCTest
import AVFoundation
import Combine
@testable import NekozeFix

/// Task 2.1: 回転角取得サービス（DeviceRotationService）の単体テスト。
/// requirements.md 1.1, 2.1, 2.2, 3.1, 3.2, 4.1。
/// design.md「DeviceRotationService（新設）」の Service Interface／State Management に準拠する。
///
/// 本番型がテストシーム protocol の形状を満たすことは下記の extension で
/// コンパイル保証する（init は protocol 要件外のため、署名一致は hardware-gated
/// テストの直接参照 `DeviceRotationService(device:previewLayer:)` で保証する）。
/// 層引数型の絞り（`AVCaptureVideoPreviewLayer?`→coordinator への upcast）は
/// ソースのレビューで再確認すること（tasks.md Implementation Notes）。
///
/// 【simulator 制約（1.2 と同一パターン）】
/// iPhone 17 Pro simulator には video デバイスが存在しないため、device 結合を要する
/// テストは guard で早期復帰する。署名の一致はコンパイルで保証され、実行時の検証は
/// 実機レーン（tasks.md 5.2 の iPad 9th）で行う。
///
/// 【不明時維持則】
/// design.md の定めにより不明事象の TestDouble 再現は行わない（smoke のみ）。
/// 本ファイルでは検証可能な側面（無イベント時の保持＝stop 経路での角維持と
/// 非オプショナル型による nil 不可能性）のみを単体検証し、真の不明事象は
/// 5.2 の実機 smoke に委ねる。

/// 本番型の seam 形状適合のコンパイル保証は製品の適合宣言
/// （`DeviceRotationService` の extension）で行う。

@MainActor
final class DeviceRotationServiceTests: XCTestCase {
    // MARK: - hardware 不要（simulator で実行される）

    /// seam protocol への適合を runtime 上でも明示する（実体は上記 extension の
    /// コンパイル保証。不適合時はコンパイル自体が失敗するため本テストは到達しない）。
    func testProductionTypeSatisfiesSeamProtocolShape() {
        func requireConformance<T: DeviceRotationServiceProtocol>(_: T.Type) {}
        requireConformance(DeviceRotationService.self)
    }

    // MARK: - 本番署名・振る舞い（hardware 要。simulator では署名一致のコンパイル保証のみ）

    /// 初期角は coordinator の現在角（preview／capture の両角、度）が配信される。
    /// requirements.md 2.1, 2.2。simulator では早期復帰する。
    func testInitDeliversPreviewAndCaptureAnglesFromCoordinator() {
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .front
        ) else {
            return // simulator には video デバイスがない。署名の一致はコンパイルで保証される
        }
        let layer = AVCaptureVideoPreviewLayer(session: AVCaptureSession())
        let service = DeviceRotationService(device: device, previewLayer: layer)
        let expected = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        XCTAssertEqual(
            service.previewRotationAngle,
            expected.videoRotationAngleForHorizonLevelPreview,
            "preview 用回転角（度）が coordinator の現在角と一致する"
        )
        XCTAssertEqual(
            service.captureRotationAngle,
            expected.videoRotationAngleForHorizonLevelCapture,
            "capture 用回転角（度）が coordinator の現在角と一致する"
        )
    }

    /// カメラ切替時の `recreate(for:previewLayer:)` が新デバイスの coordinator を
    /// 所有し直し、新デバイスの角度を配信する。requirements.md 3.1, 3.2。
    /// simulator では早期復帰する。
    func testRecreateAdoptsNewDeviceCoordinatorAngles() {
        guard let front = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .front
        ),
            let back = AVCaptureDevice.default(
                .builtInWideAngleCamera, for: .video, position: .back
            )
        else {
            return // simulator には video デバイスがない。署名の一致はコンパイルで保証される
        }
        let service = DeviceRotationService(device: front, previewLayer: nil)
        service.start()

        service.recreate(for: back, previewLayer: nil)
        let expected = AVCaptureDevice.RotationCoordinator(device: back, previewLayer: nil)
        XCTAssertEqual(
            service.previewRotationAngle,
            expected.videoRotationAngleForHorizonLevelPreview,
            "再生成後は新デバイスの preview 角を返す"
        )
        XCTAssertEqual(
            service.captureRotationAngle,
            expected.videoRotationAngleForHorizonLevelCapture,
            "再生成後は新デバイスの capture 角を返す"
        )
    }

    /// start／stop のライフサイクル（Motion 起停と同一則）を駆動し、
    /// stop が保持角を破棄しない（無イベント＝直前有効角の保持）。
    /// requirements.md 4.1 の単体検証可能な側面。simulator では早期復帰する。
    func testStartStopLifecycleHoldsLastValidAngles() {
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .front
        ) else {
            return // simulator には video デバイスがない。署名の一致はコンパイルで保証される
        }
        let service = DeviceRotationService(device: device, previewLayer: nil)
        XCTAssertFalse(service.isStarted)

        service.start()
        XCTAssertTrue(service.isStarted)
        service.start() // 二重 start は無視される
        XCTAssertTrue(service.isStarted)

        let preview = service.previewRotationAngle
        let capture = service.captureRotationAngle

        service.stop()
        XCTAssertFalse(service.isStarted)
        XCTAssertEqual(
            service.previewRotationAngle, preview,
            "stop は preview 保持角を破棄しない（直前有効角の維持）"
        )
        XCTAssertEqual(
            service.captureRotationAngle, capture,
            "stop は capture 保持角を破棄しない（直前有効角の維持）"
        )
    }
}
