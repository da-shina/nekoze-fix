import SwiftUI
import AVFoundation
import Combine

/// UI レイヤー: AVCaptureVideoPreviewLayer SwiftUI ラッパー。
/// design.md の "UI Components" - CameraPreviewView を参照。
///
/// Task 3.2: 端末姿勢の直接参照・通知購読を持たない。`DeviceRotationService` の
/// 同一インスタンス購読により preview 接続へ回転角を適用する（同一インスタンスの
/// 受け渡し結線は task 4.1。本タスクでは TestDouble で代用する）。
/// View は角度の取得・判断を持たず、配信値の適用のみ行う（表示専用）。
/// プレビュー層は Session が生成して注入するものを使用する（所有権は Session。
/// View 側で生成しない。注入結線は 4.1）。層出現時（`didMoveToWindow` 相当）は
/// ペイロードなしで Session へ通知し、Session が所有層で `recreate` する
/// （通知先の結線は 4.1。本ファイルではフック点のみ定義し、
/// `PostureSessionManager` の改修は行わない）。

/// 回転角サービスのシームは `DeviceRotationServiceProtocol`（Types）に一本化。

struct CameraPreviewView: UIViewRepresentable {
    // MARK: - プロパティ

    let session: AVCaptureSession

    /// Session が生成したプレビュー層（所有権は Session）。nil 時は従来通り
    /// session から自前生成する（既存 caller 互換。注入結線は task 4.1）。
    var injectedPreviewLayer: AVCaptureVideoPreviewLayer?

    /// preview 角の配信源。同一 Service インスタンスの受け渡しは task 4.1。
    /// 本タスクでは TestDouble を注入して分離検証する。nil 時は購読しない。
    var rotationSource: (any DeviceRotationServiceProtocol)?

    /// 層出現時（`didMoveToWindow` 相当）のペイロードなし通知フック。
    /// Session が所有層で `recreate` するための結線先（結線は task 4.1）。
    var onPreviewLayerAppeared: (() -> Void)?

    /// テスト注入用接続シーム。nil 時はプレビュー層の実接続を使う。
    /// `@testable` 経由でテストが Fake を注入する。
    var previewConnectionForTesting: (any VideoRotationConnection)?

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> CameraPreviewUIView {
        CameraPreviewUIView(
            session: session,
            previewLayer: injectedPreviewLayer,
            rotationSource: rotationSource,
            previewConnectionForTesting: previewConnectionForTesting,
            onPreviewLayerAppeared: onPreviewLayerAppeared
        )
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        // Session 結線時（task 4.1）の更新点。層・購読源は Session 所有の同一
        // インスタンスを使い回す。購読源が View 出現より後に結線された場合
        // （attach-after-appear）に備え、変化時のみ購読し直す。
        uiView.onPreviewLayerAppeared = onPreviewLayerAppeared
        uiView.resubscribeIfNeeded(to: rotationSource)
    }
}

/// プレビューレイヤーのフレーム管理と回転適用を担うカスタムUIView。
/// 角度の取得・判断を持たず、配信値の適用のみ行う（表示専用）。
/// 端末姿勢の直接参照・通知購読を持たない。data-output 接続には触らない
/// （`CameraSessionManager` が所有）。
internal class CameraPreviewUIView: UIView {
    /// Session 注入層または自前生成層。注入時は View 側で生成しない。
    private let previewLayer: AVCaptureVideoPreviewLayer

    /// テスト注入用接続シーム。nil 時はプレビュー層の実接続を使う。
    var previewConnectionForTesting: (any VideoRotationConnection)?

    /// 層出現時のペイロードなし通知フック（結線は task 4.1）。
    var onPreviewLayerAppeared: (() -> Void)?

    private var cancellables = Set<AnyCancellable>()

    /// 現在購読中の配信源（attach-after-appear の変化検出用）。
    private var subscribedSource: (any DeviceRotationServiceProtocol)?

    /// テスト用アクセサ：使用中のプレビュー層（注入層か自前層かの検証用）。
    internal var previewLayerForTesting: AVCaptureVideoPreviewLayer { previewLayer }

    init(
        session: AVCaptureSession,
        previewLayer: AVCaptureVideoPreviewLayer? = nil,
        rotationSource: (any DeviceRotationServiceProtocol)? = nil,
        previewConnectionForTesting: (any VideoRotationConnection)? = nil,
        onPreviewLayerAppeared: (() -> Void)? = nil
    ) {
        if let previewLayer {
            self.previewLayer = previewLayer
        } else {
            self.previewLayer = AVCaptureVideoPreviewLayer(session: session)
        }
        self.previewConnectionForTesting = previewConnectionForTesting
        self.onPreviewLayerAppeared = onPreviewLayerAppeared
        super.init(frame: .zero)

        self.previewLayer.videoGravity = .resizeAspect

        // レイヤーを追加
        self.layer.addSublayer(self.previewLayer)

        if let rotationSource {
            resubscribeIfNeeded(to: rotationSource)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = self.bounds
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // 層出現時にペイロードなしで Session へ通知する。Session が所有層で
        // `recreate` する（通知先の結線は task 4.1）。
        if self.window != nil {
            onPreviewLayerAppeared?()
        }
    }

    /// preview 接続へ回転角（度）を適用する（表示専用の適用のみ）。
    /// 対応可否を実行時判定し、非対応時・接続不在時は見送る（退行則）。
    internal func applyPreviewRotationAngle(_ degrees: CGFloat) {
        let connection: (any VideoRotationConnection)? =
            previewConnectionForTesting ?? previewLayer.connection
        guard let connection else { return }
        guard connection.isVideoRotationAngleSupported(degrees) else { return }
        connection.videoRotationAngle = degrees
    }

    /// 配信源の preview 角を購読し、配信値の適用のみ行う。
    /// Service 結線が View 出現より後になる場合（attach-after-appear）に備え、
    /// 同一インスタンスには再購読せず、変化時のみ購読し直す。
    /// nil 時は何もしない（3.2 の既定動作を維持）。
    func resubscribeIfNeeded(to source: (any DeviceRotationServiceProtocol)?) {
        guard let source else { return }
        if let subscribedSource, subscribedSource === source { return }
        cancellables.removeAll()
        subscribedSource = source
        source.previewRotationAnglePublisher
            .sink { [weak self] angle in
                self?.applyPreviewRotationAngle(angle)
            }
            .store(in: &cancellables)
    }
}

// MARK: - プレビュー

#Preview("カメラプレビュー") {
    CameraPreviewView(session: AVCaptureSession())
        .frame(width: 300, height: 400)
}