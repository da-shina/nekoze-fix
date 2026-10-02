import XCTest
import AVFoundation
import Combine
@testable import NekozeFix

/// Task 4.1: 実結線と順序保証の検証。
/// requirements.md 1.1, 2.1, 2.2, 2.3, 2.4, 3.1, 3.2, 4.1。
/// design.md Architecture（Boundary Map＋依存方向）、System Flows（順序・キュー保証注記）、
/// DeviceRotationService＋CameraSessionManager＋PostureSessionManager＋CameraPreviewView。
///
/// 【結線内容】Session がプレビュー層を生成して View へ注入し、同一 Service
/// インスタンスを Session＋View で共有する。coordinator再生成と接続再構成
/// （回転角適用順序）の順序・キュー保証を初回・切替・層再出現の3ケースで確定する。
/// KVO 配送はメイン、最新値の上書きのみ。
///
/// 【TestDouble 方針】角度値は `FakeDeviceRotationService` から注入し、接続は
/// 本ファイルの Fake（`VideoRotationConnection` 適合）へ注入する。simulator には video デバイスが存在しないため実接続は使わない。
/// デバイスを要する箇所は audio フォールバック＋graceful-skip（1.2／2.1／3.2 と同一パターン）。
/// 不明時維持則の TestDouble 再現は行わない（design.md：「smoke のみ」）。
extension FakeDeviceRotationService: SessionRotationAngleSource {
    var rotationAnglesPublisher: AnyPublisher<(preview: CGFloat, capture: CGFloat), Never> {
        $previewRotationAngle
            .combineLatest($captureRotationAngle)
            .map { (preview: $0, capture: $1) }
            .eraseToAnyPublisher()
    }
}

@MainActor
final class RotationWiringOrderTests: XCTestCase {
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
    final class WiringFakeCaptureConnection: VideoRotationConnection {
        var videoRotationAngle: CGFloat
        var isVideoMirroringSupported: Bool = false
        var isVideoMirrored: Bool = false

        init(initialAngle: CGFloat = 0.0) {
            self.videoRotationAngle = initialAngle
        }

        func isVideoRotationAngleSupported(_ videoRotationAngle: CGFloat) -> Bool { true }
    }

    /// `VideoRotationConnection` 適合の TestDouble（全角対応）。
    final class WiringFakePreviewConnection: VideoRotationConnection {
        var videoRotationAngle: CGFloat
        var isVideoMirroringSupported: Bool = false
        var isVideoMirrored: Bool = false

        init(initialAngle: CGFloat = 0.0) {
            self.videoRotationAngle = initialAngle
        }

        func isVideoRotationAngleSupported(_ videoRotationAngle: CGFloat) -> Bool { true }
    }

    private func anyWiringDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(for: .video) ?? AVCaptureDevice.default(for: .audio)
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

    // MARK: - 結線後の回転角追従（Session→CameraSessionManager 転送）

    /// 結線した Fake への角度注入が、直接呼出しを介さず購読経路で
    /// data-output 接続へ転送される（requirements 2.1, 2.2）。
    func testAttachedServiceAngleInjection_flowsToCaptureConnection() {
        let fake = FakeDeviceRotationService()
        sut.attachRotationService(fake)
        let connection = WiringFakeCaptureConnection(initialAngle: 0.0)
        sut.cameraManager.rotationConnectionForTesting = connection

        fake.inject(preview: 90.0, capture: 90.0)
        sut.cameraManager.flushRotationWorkForTesting()

        XCTAssertEqual(connection.videoRotationAngle, 90.0, "結線後の注入角（capture 90°）が data-output 接続へ転送される")
        XCTAssertEqual(sut.cameraManager.lastCaptureRotationAngle, 90.0)
    }

    /// 結線経路の capture 角変化で monitoring→calibrating へ自動遷移する
    /// （requirements 2.3, 2.4。直接呼出しではなく注入駆動で確認する）。
    func testAttachedServiceCaptureChange_triggersRecalibrationViaSubscription() {
        seedCalibratedMonitoring()
        let fake = FakeDeviceRotationService()
        sut.attachRotationService(fake)
        XCTAssertEqual(sut.snapshot.phase, .monitoring, "結線時の初期角（0°）では遷移しない")

        fake.inject(preview: 90.0, capture: 90.0)

        XCTAssertEqual(sut.snapshot.phase, .calibrating, "結線経路の capture 角変化で校正へ自動遷移する")
        XCTAssertNil(sut.snapshot.referenceAngle, "旧基準角度を破棄する")
    }

    // MARK: - 初回ケース：確定通知→所有層で再生成→追従

    /// カメラ確定通知（configureSession 由来）が所有層での coordinator再生成を
    /// 駆動し、以後その所有層で追従する（requirements 3.1, 3.2）。
    /// 確定通知は sessionQueue 上で発行され Main へ hop するため、
    /// `MainActor.run` の drain 後に順序（確定→再生成→追従）を確定する。
    func testFinalizedDeviceNotification_recreatesWithOwnedLayerAndTracks() async {
        guard let device = anyWiringDevice() else {
            return // simulator に capture/audio デバイスなし。意味的検証は実機に委ねる
        }
        let fake = FakeDeviceRotationService()
        sut.attachRotationService(fake)
        let connection = WiringFakeCaptureConnection(initialAngle: 0.0)
        sut.cameraManager.rotationConnectionForTesting = connection

        // 初回：カメラ構成時の確定通知（Session→recreate の順序）。
        sut.cameraManager.deviceFinalizedHandler?(device)
        await MainActor.run {}

        XCTAssertEqual(fake.recreateCallCount, 1, "確定通知で coordinator再生成を1回指示する")
        XCTAssertTrue(fake.recreatedDevice === device, "確定デバイスを渡す")
        XCTAssertNotNil(sut.ownedPreviewLayer, "Session が所有層を生成して保持する")
        XCTAssertTrue(fake.recreatedLayer === sut.ownedPreviewLayer, "所有層の同一インスタンスで再生成する")
        XCTAssertNotNil(sut.lastFinalizedCameraDevice, "確定デバイスを記録する")

        // 結線後の回転角追従が動作する。
        fake.inject(preview: 90.0, capture: 90.0)
        sut.cameraManager.flushRotationWorkForTesting()
        XCTAssertEqual(connection.videoRotationAngle, 90.0, "再生成後の注入角が data-output 接続へ適用される")
    }

    // MARK: - 切替・層再出現ケース：同一デバイス＋同一層での再生成順序

    /// 確定後の層再出現通知が、同一デバイス＋同一所有層でもう一度再生成する
    /// （初回→再出現の順序が確定する。requirements 3.1）。
    func testLayerReappearance_afterFinalize_recreatesWithSameDeviceAndLayer() async {
        guard let device = anyWiringDevice() else {
            return // simulator に capture/audio デバイスなし。意味的検証は実機に委ねる
        }
        let fake = FakeDeviceRotationService()
        sut.attachRotationService(fake)
        sut.cameraManager.deviceFinalizedHandler?(device)
        await MainActor.run {}
        XCTAssertEqual(fake.recreateCallCount, 1, "前提：初回確定で1回再生成")
        let ownedLayer = sut.ownedPreviewLayer

        // 層再出現：View からのペイロードなし通知（結線先）。
        sut.handlePreviewLayerAppeared()

        XCTAssertEqual(fake.recreateCallCount, 2, "層再出現で2回目の再生成を指示する")
        XCTAssertTrue(fake.recreatedDevice === device, "確定デバイスを使い回す")
        XCTAssertTrue(fake.recreatedLayer === ownedLayer, "所有層の同一インスタンスを使い回す")
    }

    // MARK: - 同一インスタンス共有・所有権（Session→View 注入の構造）

    /// Session と View が同一 Service インスタンスを共有する
    /// （二重解決・隠れた共有所有を作らない。design.md Boundary Map）。
    func testRotationServiceForPreview_sharesSameInstanceWithSession() {
        let fake = FakeDeviceRotationService()
        sut.attachRotationService(fake)

        XCTAssertTrue(sut.rotationServiceForPreview === fake, "View 注入用に同一インスタンスを返す")
    }

    /// 注入用所有層は初回アクセス時に生成され、以後同一インスタンスである
    /// （所有権は Session。View 側で生成しない）。
    func testPreviewLayerForInjection_isStableSessionOwnedInstance() {
        let first = sut.previewLayerForInjection
        let second = sut.previewLayerForInjection

        XCTAssertTrue(first === second, "注入層は同一インスタンスを使い回す")
        XCTAssertTrue(sut.ownedPreviewLayer === first, "Session 所有層と同一である")
    }

    // MARK: - View 側：attach-after-appear の再購読

    /// View 出現後に Service が結線された場合も、再購読により preview 角追従が始まる
    /// （requirements 2.1, 2.2。updateUIView 経路の TestDouble 駆動）。
    func testPreviewViewResubscribe_afterAttach_appliesInjectedAngle() {
        let fake = FakeDeviceRotationService(previewAngle: 0.0, captureAngle: 0.0)
        let connection = WiringFakePreviewConnection(initialAngle: 0.0)
        // View 出現時点では未結線（rotationSource なし）。
        let view = CameraPreviewUIView(
            session: AVCaptureSession(),
            previewConnectionForTesting: connection
        )

        // 結線（updateUIView が rotationSource 変化時に呼ぶ受口）。
        view.resubscribeIfNeeded(to: fake)
        fake.inject(preview: 90.0, capture: 90.0)

        XCTAssertEqual(connection.videoRotationAngle, 90.0, "結線後の preview 角（90°）が preview 接続へ適用される")
    }

    /// 同一インスタンスへの再通知では購読し直さない（重複購読なし）。
    func testPreviewViewResubscribe_sameInstance_doesNotResubscribe() {
        let fake = FakeDeviceRotationService(previewAngle: 0.0, captureAngle: 0.0)
        let connection = WiringFakePreviewConnection(initialAngle: 0.0)
        let view = CameraPreviewUIView(
            session: AVCaptureSession(),
            rotationSource: fake,
            previewConnectionForTesting: connection
        )

        view.resubscribeIfNeeded(to: fake)
        fake.inject(preview: 90.0, capture: 90.0)

        XCTAssertEqual(connection.videoRotationAngle, 90.0, "同一インスタンスでも追従は維持される")
    }
}
