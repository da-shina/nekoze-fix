import XCTest
import AVFoundation
import Combine
@testable import NekozeFix

/// Task 3.2: プレビュー接続への回転適用改修の分離検証。
/// requirements.md 2.1, 2.2。design.md CameraPreviewView（改修）。
///
/// 【TestDouble 方針】実結線（同一 Service インスタンスの受け渡し・Session 所有層の
/// 注入・層出現通知の結線）は task 4.1。本ファイルでは分離検証のみ行う：
/// - 角度値は `FakeDeviceRotationService`（DeviceRotationTestDouble.swift）から注入する。
/// - 接続は本ファイルの `FakePreviewConnection`（`PreviewVideoRotationConnection`
///   適合）へ注入する。simulator には video デバイスが存在しないため実接続は使わない。
/// - data-output 接続には触らない（`CameraSessionManager` が所有）。
/// - 不明時維持則の TestDouble 再現は行わない（design.md：「smoke のみ」）。
/// - View は配信値の適用のみ行い、角度の取得・判断を持たない（表示専用）。

/// Fake の production seam 適合のコンパイル保証。
/// 不適合があれば本 extension の行でコンパイルが失敗する。
extension FakeDeviceRotationService: PreviewRotationAngleSource {
    var previewRotationAnglePublisher: AnyPublisher<CGFloat, Never> {
        $previewRotationAngle.eraseToAnyPublisher()
    }
}

@MainActor
final class CameraPreviewRotationTests: XCTestCase {
    // MARK: - Fake

    /// `PreviewVideoRotationConnection` 適合の TestDouble。
    /// `supportedAngles` に含まれる角度のみ適用可能（実機の
    /// `isVideoRotationAngleSupported(_:)` に対応。可否判定の分離再現）。
    final class FakePreviewConnection: PreviewVideoRotationConnection {
        var supportedAngles: Set<CGFloat>
        var videoRotationAngle: CGFloat

        init(supportedAngles: Set<CGFloat> = [0, 90, 180, 270], initialAngle: CGFloat = 0.0) {
            self.supportedAngles = supportedAngles
            self.videoRotationAngle = initialAngle
        }

        func isVideoRotationAngleSupported(_ videoRotationAngle: CGFloat) -> Bool {
            supportedAngles.contains(videoRotationAngle)
        }
    }

    // MARK: - TestDouble 角度の preview 接続への適用

    /// TestDouble の preview 角が preview 接続へ適用される。
    /// requirements.md 2.1（縦置き・横置きでの映像向き合わせ）。
    func testApplyPreviewRotationAngle_appliesFakeAngleToPreviewConnection() {
        let rotationSource = FakeDeviceRotationService(previewAngle: 90.0, captureAngle: 90.0)
        let connection = FakePreviewConnection(initialAngle: 0.0)
        let view = CameraPreviewUIView(
            session: AVCaptureSession(),
            previewConnectionForTesting: connection
        )

        view.applyPreviewRotationAngle(rotationSource.previewRotationAngle)

        XCTAssertEqual(connection.videoRotationAngle, 90.0, "TestDouble の preview 角（90°）が preview 接続へ適用される")
    }

    /// TestDouble からの購読により 0°→90°→180°→270° の遷移が順次適用される。
    /// requirements.md 2.2（回転追従）。同一サービス購読の分離代用である。
    func testPreviewRotationSubscription_appliesInjectedAnglesSequentially() {
        let rotationSource = FakeDeviceRotationService(previewAngle: 0.0, captureAngle: 0.0)
        let connection = FakePreviewConnection(initialAngle: 0.0)
        // rotationSource を購読する結線（同一インスタンス受け渡しは task 4.1）。
        let view = CameraPreviewUIView(
            session: AVCaptureSession(),
            rotationSource: rotationSource,
            previewConnectionForTesting: connection
        )
        _ = view // 購読の保持（view が購読を所有する）

        for angle: CGFloat in [0, 90, 180, 270] {
            rotationSource.inject(preview: angle, capture: angle)
            XCTAssertEqual(
                connection.videoRotationAngle, angle,
                "購読による preview 角 \(angle)° が順次適用される"
            )
        }
    }

    // MARK: - 対応可否の退行則

    /// 非対応時は適用を見送り、現行回転角で継続する（クラッシュさせない）。
    /// design.md Error Handling「回転角の適用非対応 → 見送り」（3.1 と同一則）。
    func testApplyPreviewRotationAngle_skipsWhenUnsupported_fallbackRule() {
        let connection = FakePreviewConnection(supportedAngles: [0, 90, 180, 270], initialAngle: 0.0)
        let view = CameraPreviewUIView(
            session: AVCaptureSession(),
            previewConnectionForTesting: connection
        )

        // 直前有効角として 90° を確定させる（Fake 注入角の適用）。
        let validSource = FakeDeviceRotationService(previewAngle: 90.0, captureAngle: 90.0)
        view.applyPreviewRotationAngle(validSource.previewRotationAngle)
        XCTAssertEqual(connection.videoRotationAngle, 90.0, "前提：直前有効角 90° が適用済み")

        // 非対応角 45° は見送られ、直前有効角が維持される（例外なし）。
        view.applyPreviewRotationAngle(45.0)
        XCTAssertEqual(
            connection.videoRotationAngle, 90.0,
            "非対応時は適用を見送り直前有効角を維持する（退行則）"
        )
    }

    /// 接続自体が回転非対応（空集合）の場合も例外なく見送る。
    func testApplyPreviewRotationAngle_skipsWhenConnectionUnsupported_noCrash() {
        let connection = FakePreviewConnection(supportedAngles: [], initialAngle: 0.0)
        let view = CameraPreviewUIView(
            session: AVCaptureSession(),
            previewConnectionForTesting: connection
        )

        let source = FakeDeviceRotationService(previewAngle: 90.0, captureAngle: 90.0)
        view.applyPreviewRotationAngle(source.previewRotationAngle)

        XCTAssertEqual(connection.videoRotationAngle, 0.0, "非対応接続では現行角を維持する")
    }

    // MARK: - Session 所有層の注入シーム（所有権は Session。View 側で生成しない）

    /// 注入層がある場合は View が層を生成せず注入層を使う。
    /// 本結線（Session が生成して注入）は task 4.1。ここではシームの存在を検証する。
    func testInjectedPreviewLayerIsUsed_notCreatedByView() {
        let session = AVCaptureSession()
        let injected = AVCaptureVideoPreviewLayer(session: session)
        let view = CameraPreviewUIView(
            session: session,
            previewLayer: injected,
            previewConnectionForTesting: FakePreviewConnection()
        )

        XCTAssertTrue(view.previewLayerForTesting === injected, "注入層がある場合は View が新規生成せず注入層を使う")
    }

    /// 注入なしの既存 init 経路は従来通り自前層で動作する（現行 caller 互換）。
    func testDefaultInitKeepsCurrentLayerSourceBehavior() {
        let view = CameraPreviewUIView(
            session: AVCaptureSession(),
            previewConnectionForTesting: FakePreviewConnection()
        )

        let sublayers = view.layer.sublayers ?? []
        XCTAssertTrue(
            sublayers.contains(where: { $0 === view.previewLayerForTesting }),
            "注入なしでは View が生成した層をサブレイヤーとして保持する（既存動作）"
        )
    }

    // MARK: - 層出現通知フック（ペイロードなし。結線は task 4.1）

    /// 層出現時（didMoveToWindow 相当）にペイロードなしで通知するフック点。
    /// Session が所有層で recreate するための結線先であり、本タスクではフック点の
    /// 定義のみ行う（PostureSessionManager の改修は task 4.1 のため行わない）。
    func testDidMoveToWindow_notifiesPayloadFreeHook() {
        let view = CameraPreviewUIView(
            session: AVCaptureSession(),
            previewConnectionForTesting: FakePreviewConnection()
        )
        var callCount = 0
        view.onPreviewLayerAppeared = { callCount += 1 }

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.addSubview(view)

        XCTAssertEqual(callCount, 1, "層出現時にペイロードなしで Session へ通知する（結線は4.1）")
    }

    // MARK: - Wrapper の caller 互換（CalibrationView の session init が壊れない）

    /// 既存 caller（`CameraPreviewView(session:)`）が引き続きコンパイル・動作し、
    /// 注入シームが既定 nil（現行動作）である。同一インスタンス受け渡し結線は 4.1。
    func testWrapperKeepsSessionInitCompatibleWithInjectionDefaults() {
        let session = AVCaptureSession()
        let defaultView = CameraPreviewView(session: session)
        XCTAssertNil(defaultView.injectedPreviewLayer, "既定では注入層なし（現行動作）")
        XCTAssertNil(defaultView.rotationSource, "既定では購読なし（結線は4.1）")

        let layer = AVCaptureVideoPreviewLayer(session: session)
        let fake: any PreviewRotationAngleSource = FakeDeviceRotationService(previewAngle: 0.0, captureAngle: 0.0)
        let injected = CameraPreviewView(
            session: session,
            injectedPreviewLayer: layer,
            rotationSource: fake,
            onPreviewLayerAppeared: {}
        )
        XCTAssertTrue(injected.injectedPreviewLayer === layer, "注入層シームが保持される")
        XCTAssertNotNil(injected.onPreviewLayerAppeared, "出現通知フック点が保持される")
    }
}
