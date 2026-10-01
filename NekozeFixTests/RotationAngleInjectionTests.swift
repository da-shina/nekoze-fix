import XCTest
import AVFoundation
import Combine
@testable import NekozeFix

/// Task 1.2: 回転角注入テスト基盤の検証（requirements.md 1.1, 5.1）。
///
/// 角度値の直接注入が配信シーム（@Published preview／capture角）を駆動することを検証する。
/// 注入パターンは既存の合成フレーム注入シーム（OrientationRecalibrationTests が
/// `handleVideoOrientationChange`／`processDetection(.pose(frame))` を直接呼ぶ方式）と同一である。
///
/// simulator 制約（事前 probe で確認）：iPhone 17 Pro simulator には video デバイスが
/// 存在しない（front／back／any いずれも nil）。そのため hardware を要する署名
/// （`init(device:previewLayer:)`／`recreate(for:previewLayer:)`）のテストは
/// guard で早期復帰する。署名の一致はコンパイルで保証され、実行時検証は実機レーン
/// （iPad 9th、tasks.md 5.2）で行う。
@MainActor
final class RotationAngleInjectionTests: XCTestCase {
    // MARK: - 角度注入（hardware 不要。simulator で実行される）

    /// 初期角は horizon-level の 0°（fresh coordinator 相当）である。
    func testInitialAnglesAreZeroHorizon() {
        let fake = FakeDeviceRotationService()
        XCTAssertEqual(fake.previewRotationAngle, 0.0)
        XCTAssertEqual(fake.captureRotationAngle, 0.0)
    }

    /// 直接注入した角度値（度）が両チャネルに反映され、再注入で更新される。
    func testInjectPreviewAndCaptureAngles_updatesPublishedAngles() {
        let fake = FakeDeviceRotationService()
        fake.inject(preview: 90.0, capture: 270.0)
        XCTAssertEqual(fake.previewRotationAngle, 90.0, "preview チャネルに注入角が反映される")
        XCTAssertEqual(fake.captureRotationAngle, 270.0, "capture チャネルに注入角が反映される")

        fake.inject(preview: 0.0, capture: 180.0)
        XCTAssertEqual(fake.previewRotationAngle, 0.0, "再注入で preview 角が更新される")
        XCTAssertEqual(fake.captureRotationAngle, 180.0, "再注入で capture 角が更新される")
    }

    /// 注入角は @Published 経由で配信される（購読者が変更通知を受け取る）。
    func testInjectedAngles_areDeliveredViaPublished() {
        let fake = FakeDeviceRotationService()
        let delivered = expectation(description: "preview angle published")
        var received: [CGFloat] = []
        let cancellable = fake.$previewRotationAngle
            .dropFirst() // 購読直後の初期値（0°）を除外する
            .sink { angle in
                received.append(angle)
                delivered.fulfill()
            }
        defer { _ = cancellable }

        fake.inject(preview: 90.0, capture: 90.0)

        waitForExpectations(timeout: 1.0)
        XCTAssertEqual(received, [90.0])
    }

    /// start／stop の駆動が記録される（Motion 起停と同一則のテスト容易性）。
    func testStartStop_tracksLifecycle() {
        let fake = FakeDeviceRotationService()
        XCTAssertFalse(fake.isStarted)

        fake.start()
        XCTAssertTrue(fake.isStarted)
        XCTAssertEqual(fake.startCallCount, 1)

        fake.stop()
        XCTAssertFalse(fake.isStarted)
        XCTAssertEqual(fake.stopCallCount, 1)
    }

    // MARK: - 本番署名 mirror（hardware 要。simulator では署名一致のコンパイル保証のみ）

    /// design.md の本番 init 署名 `init(device:previewLayer: AVCaptureVideoPreviewLayer?)`
    /// が使用できる。simulator には device がないため早期復帰する。
    func testInitMirrorsProductionSignatureWhenHardwareExists() {
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .front
        ) else {
            return // simulator には video デバイスがない。署名の一致はコンパイルで保証される
        }
        let layer = AVCaptureVideoPreviewLayer(session: AVCaptureSession())
        let fake = FakeDeviceRotationService(device: device, previewLayer: layer)
        XCTAssertEqual(fake.previewRotationAngle, 0.0, "生成直後は fresh coordinator 状態（0°）")
        XCTAssertEqual(fake.captureRotationAngle, 0.0)
        XCTAssertTrue(fake.previewLayer === layer, "注入された preview 層を保持する")
    }

    /// カメラ切替時の `recreate(for:previewLayer:)` が新デバイスを受け付け、
    /// 角度を fresh 状態（0°）に戻す。simulator では早期復帰する。
    func testRecreateSwitchesDeviceWhenHardwareExists() {
        let fake = FakeDeviceRotationService()
        fake.inject(preview: 90.0, capture: 90.0)
        guard let front = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .front
        ),
            let back = AVCaptureDevice.default(
                .builtInWideAngleCamera, for: .video, position: .back
            )
        else {
            return // simulator には video デバイスがない。署名の一致はコンパイルで保証される
        }

        fake.recreate(for: front, previewLayer: nil)
        XCTAssertEqual(fake.recreateCallCount, 1)
        XCTAssertTrue(fake.recreatedDevice === front)
        XCTAssertNil(fake.recreatedLayer)
        XCTAssertEqual(fake.previewRotationAngle, 0.0, "再生成直後は fresh coordinator 状態（0°）")
        XCTAssertEqual(fake.captureRotationAngle, 0.0)

        fake.inject(preview: 270.0, capture: 270.0)
        fake.recreate(for: back, previewLayer: nil)
        XCTAssertEqual(fake.recreateCallCount, 2)
        XCTAssertTrue(fake.recreatedDevice === back)
        XCTAssertEqual(fake.previewRotationAngle, 0.0)
        XCTAssertEqual(fake.captureRotationAngle, 0.0)
    }
}
