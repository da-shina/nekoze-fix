import AVFoundation
import Combine
@testable import NekozeFix

/// Task 1.2: 回転角注入テスト基盤（TestDouble）。requirements.md 1.1, 5.1。
///
/// design.md「DeviceRotationService Service Interface」の可観測形状を写す seam であり、
/// 製品の `DeviceRotationServiceProtocol`（Types）へ適合する。
/// 角度値の直接注入は既存の合成フレーム注入シームと同一パターンである
/// （OrientationRecalibrationTests が旧トリガ／
/// `processDetection(.pose(frame))` を直接呼んだ方式）。
///
/// 【coordinator 初期化 API 署名の確定（SDK 対照済み）】
/// iOS 17 SDK ヘッダ（Xcode同梱 iPhoneOS.sdk、
/// `AVFoundation.framework/Headers/AVCaptureDevice.h` の
/// `AVCaptureDeviceRotationCoordinator` 宣言）における署名は次の通り：
///   - (instancetype)initWithDevice:(AVCaptureDevice *)device
///                        previewLayer:(nullable CALayer *)previewLayer;
/// すなわち Swift では
///   `AVCaptureDevice.RotationCoordinator(device: AVCaptureDevice, previewLayer: CALayer?)`
/// であり、previewLayer 引数の SDK 上の型は `CALayer?` である（`nil` 可。
/// `nil` 時は horizon-level preview 角として 0° を返す。ヘッダの discussion 参照）。
/// 本サービスの init／recreate が取る `previewLayer: AVCaptureVideoPreviewLayer?` は
/// design.md の所有権規律（Session が層を生成して View へ注入する。View 側で生成しない）
/// による絞り込みであり、SDK と矛盾しない：
/// `AVCaptureVideoPreviewLayer` は `CALayer` のサブクラスなので coordinator 初期化子への
/// そのままの受け渡し（upcast）がコンパイルできることは typecheck で確認済みである。
/// 汎用の `CALayer?` を本サービスの公開 API 型にはしない（design.md の注記通り）。
///
/// 【simulator 制約】
/// iPhone 17 Pro simulator には video デバイスが存在しない
/// （`AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, ...)` の
/// front／back／any いずれも nil。task 1.2 の probe で確認）。
/// そのため本 Fake は hardware 不要の `init(previewAngle:captureAngle:)` を持ち、
/// simulator 上の角度注入テストはすべて本 init で構築する。
/// 本番 mirror の `init(device:previewLayer:)` は配線用であり、実行時の検証は
/// 実機レーン（tasks.md 5.2 の iPad 9th）で行う。
///
/// 不明時維持則の TestDouble 再現は行わない（design.md：「smoke のみ」）。
/// 本ファイルは非推奨 API を使用しない（requirements.md 1.1）。
/// 角度の単位は度である（design.md Service Interface）。

/// DeviceRotationService のテスト用 seam。
/// 製品の `DeviceRotationServiceProtocol`（Types）に適合する。
/// init は配線（wiring）であって振る舞いではないため protocol 要件に含めない。
final class FakeDeviceRotationService: DeviceRotationServiceProtocol, ObservableObject {
    @Published private(set) var previewRotationAngle: CGFloat
    @Published private(set) var captureRotationAngle: CGFloat

    private(set) weak var device: AVCaptureDevice?
    private(set) weak var previewLayer: AVCaptureVideoPreviewLayer?

    private(set) var recreateCallCount = 0
    private(set) weak var recreatedDevice: AVCaptureDevice?
    private(set) weak var recreatedLayer: AVCaptureVideoPreviewLayer?

    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private(set) var isStarted = false

    /// 本番 mirror init（design.md の Service Interface と同一署名）。
    /// 初期角は fresh coordinator 相当の 0° である。
    init(device: AVCaptureDevice, previewLayer: AVCaptureVideoPreviewLayer?) {
        self.device = device
        self.previewLayer = previewLayer
        self.previewRotationAngle = 0.0
        self.captureRotationAngle = 0.0
    }

    /// hardware 不要の test seam init。simulator 上のテストは本 init を使う。
    init(previewAngle: CGFloat = 0.0, captureAngle: CGFloat = 0.0) {
        self.device = nil
        self.previewLayer = nil
        self.previewRotationAngle = previewAngle
        self.captureRotationAngle = captureAngle
    }

    /// 角度値（度）の直接注入。@Published の両チャネルを実際に更新する。
    func inject(preview: CGFloat, capture: CGFloat) {
        previewRotationAngle = preview
        captureRotationAngle = capture
    }

    func recreate(for device: AVCaptureDevice, previewLayer: AVCaptureVideoPreviewLayer?) {
        recreateCallCount += 1
        recreatedDevice = device
        recreatedLayer = previewLayer
        self.device = device
        self.previewLayer = previewLayer
        // fresh coordinator 相当：直前角を捨て 0° から開始する。
        previewRotationAngle = 0.0
        captureRotationAngle = 0.0
    }

    func start() {
        startCallCount += 1
        isStarted = true
    }

    func stop() {
        stopCallCount += 1
        isStarted = false
    }
}

extension FakeDeviceRotationService {
    /// preview 角の配信。製品の同名配信口と同一形状。
    var previewRotationAnglePublisher: AnyPublisher<CGFloat, Never> {
        $previewRotationAngle.eraseToAnyPublisher()
    }

    /// capture 角の配信。製品の同名配信口と同一形状。
    var captureRotationAnglePublisher: AnyPublisher<CGFloat, Never> {
        $captureRotationAngle.eraseToAnyPublisher()
    }
}

/// `VideoRotationConnection` 適合の共有 TestDouble。
/// 対応角集合（nil＝全角対応）・初期角・ミラー対応可否を設定可能。
/// 回転適用テスト4ファイルで個別定義されていた Fake を統一したもの。
final class FakeCaptureConnection: VideoRotationConnection {
    var supportedAngles: Set<CGFloat>?
    var videoRotationAngle: CGFloat
    var isVideoMirroringSupported: Bool
    var isVideoMirrored: Bool = false

    init(supportedAngles: Set<CGFloat>? = nil, initialAngle: CGFloat = 0.0, mirroringSupported: Bool = true) {
        self.supportedAngles = supportedAngles
        self.videoRotationAngle = initialAngle
        self.isVideoMirroringSupported = mirroringSupported
    }

    func isVideoRotationAngleSupported(_ videoRotationAngle: CGFloat) -> Bool {
        supportedAngles?.contains(videoRotationAngle) ?? true
    }
}
