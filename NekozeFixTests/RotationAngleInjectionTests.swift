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

    // MARK: - Task 2.2: 回転角サービスの単体テスト（requirements.md 2.1, 3.1, 4.1, 5.1）

    /// 両角配信：preview／capture の両チャネルが @Published で同時に配信され、
    /// 各チャネルが独立した角（divergent 値）を運ぶ。requirements.md 2.1。
    /// design.md Service Interface（preview／capture の両角 @Published 配信）。
    /// 既存 testInjectPreviewAndCaptureAngles（値の保持）と
    /// testInjectedAngles_areDeliveredViaPublished（preview 単チャネル配信）を
    /// 補完する両角同時配信の証明であり重複ではない。
    func testBothAngles_areDeliveredSimultaneouslyWithIndependentValues() {
        let fake = FakeDeviceRotationService()
        let previewDelivered = expectation(description: "preview angle published")
        let captureDelivered = expectation(description: "capture angle published")
        var receivedPreview: [CGFloat] = []
        var receivedCapture: [CGFloat] = []
        let previewCancellable = fake.$previewRotationAngle
            .dropFirst() // 購読直後の初期値（0°）を除外する
            .sink { angle in
                receivedPreview.append(angle)
                previewDelivered.fulfill()
            }
        let captureCancellable = fake.$captureRotationAngle
            .dropFirst() // 購読直後の初期値（0°）を除外する
            .sink { angle in
                receivedCapture.append(angle)
                captureDelivered.fulfill()
            }
        defer { _ = (previewCancellable, captureCancellable) }

        fake.inject(preview: 90.0, capture: 270.0)

        waitForExpectations(timeout: 1.0)
        XCTAssertEqual(receivedPreview, [90.0], "preview チャネルは preview 角のみを配信する")
        XCTAssertEqual(receivedCapture, [270.0], "capture チャネルは capture 角のみを配信する")
    }

    /// 切替再生成の simulator 実行可能スライス：Fake の recreate 機構が
    /// 新デバイスを記録し、fresh 角（0°）へリセットする。requirements.md 3.1。
    /// design.md Invariants「カメラ切替後は新デバイスの角度を返す」の機構側。
    /// video デバイス不在時は audio デバイスで機構のみ実行する（Fake は
    /// デバイス種別に依存しない記録＋リセットである）。全種不在時は
    /// graceful-skip（1.2／2.1 パターン）。前面→背面の意味的検証
    /// （新デバイスの実角採用）は HW-gated テストと 5.2 実機に委ねる。
    func testRecreateWithAvailableDevice_recordsDeviceAndResetsToFresh() {
        guard let device = AVCaptureDevice.default(for: .video) ?? AVCaptureDevice.default(for: .audio) else {
            return // simulator には capture デバイスがない。意味的検証は HW-gated テスト＋実機で行う
        }
        let fake = FakeDeviceRotationService()
        fake.inject(preview: 90.0, capture: 270.0)

        fake.recreate(for: device, previewLayer: nil)

        XCTAssertEqual(fake.recreateCallCount, 1, "再生成指示が1回記録される")
        XCTAssertTrue(fake.recreatedDevice === device, "新デバイスが記録される")
        XCTAssertNil(fake.recreatedLayer, "nil 層の再生成が受け付けられる")
        XCTAssertEqual(fake.previewRotationAngle, 0.0, "再生成後は fresh 状態（0°）から開始する")
        XCTAssertEqual(fake.captureRotationAngle, 0.0, "再生成後は fresh 状態（0°）から開始する")
    }

    /// 不明時維持の smoke 確認：無イベント時（stop 経路）に直前有効角を保持し、
    /// nil や推測角を流さない。requirements.md 4.1。
    /// design.md「デバイス姿勢不明時はイベントを発火せず直前の有効角を保持」、
    /// Error Handling「デバイス姿勢不明・平置き → 直前有効角を維持」。
    /// 不明事象の TestDouble 再現は行わない（design 明記）。真の不明事象は
    /// 5.2 の実機 smoke に委ねる。既存 testStartStop_tracksLifecycle
    /// （起停記録のみ）と本番型の HW-gated 保持テストを補完する
    /// simulator 実行可能な角度保持の証明であり重複ではない。
    func testStopHoldsLastValidAngles_smokeHoldRuleOnly() {
        let fake = FakeDeviceRotationService()
        fake.inject(preview: 90.0, capture: 270.0)
        fake.start()
        fake.stop()

        XCTAssertFalse(fake.isStarted)
        XCTAssertEqual(
            fake.previewRotationAngle, 90.0,
            "stop は preview 保持角を破棄しない（直前有効角の維持・nil 不可）"
        )
        XCTAssertEqual(
            fake.captureRotationAngle, 270.0,
            "stop は capture 保持角を破棄しない（直前有効角の維持・nil 不可）"
        )

        fake.start()
        XCTAssertEqual(
            fake.previewRotationAngle, 90.0,
            "再 start は保持角をリセットしない（最新値の上書きのみ）"
        )
        XCTAssertEqual(
            fake.captureRotationAngle, 270.0,
            "再 start は保持角をリセットしない（最新値の上書きのみ）"
        )
    }
}
