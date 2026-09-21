import SwiftUI
import AVFoundation

/// UI レイヤー: AVCaptureVideoPreviewLayer SwiftUI ラッパー。
/// design.md の "UI Components" - CameraPreviewView を参照。

struct CameraPreviewView: UIViewRepresentable {
    // MARK: - プロパティ

    let session: AVCaptureSession

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> CameraPreviewUIView {
        return CameraPreviewUIView(session: session)
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        // 必要に応じてセッションを更新
    }
}

/// プレビューレイヤーのフレーム管理と向き更新を自動化するカスタムUIView。
internal class CameraPreviewUIView: UIView {
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        self.previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)

        previewLayer.videoGravity = .resizeAspect
        updatePreviewOrientation()

        // レイヤーを追加
        self.layer.addSublayer(previewLayer)

        // デバイス回転通知を監視
        NotificationCenter.default.addObserver(
            self, selector: #selector(orientationDidChange),
            name: UIDevice.orientationDidChangeNotification, object: nil
        )
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
        // ビューがウィンドウに追加されたタイミングで向きを確定
        // （init 時点では window が nil の場合がある）
        if self.window != nil {
            updatePreviewOrientation()
        }
    }

    @objc private func orientationDidChange() {
        updatePreviewOrientation()
    }

    private func updatePreviewOrientation() {
        guard let connection = previewLayer.connection,
              connection.isVideoOrientationSupported else { return }
        connection.videoOrientation = .fromDeviceOrientation(UIDevice.current.orientation, fallbackScene: self.window?.windowScene) ?? .portrait
    }
}

// MARK: - プレビュー

struct CameraPreviewView_Previews: PreviewProvider {
    static var previews: some View {
        CameraPreviewView(session: AVCaptureSession())
            .frame(width: 300, height: 400)
            .previewDisplayName("カメラプレビュー")
    }
}