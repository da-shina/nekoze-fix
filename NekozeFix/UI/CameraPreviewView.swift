import SwiftUI
import AVFoundation

/// UI レイヤー: AVCaptureVideoPreviewLayer SwiftUI ラッパー。
/// design.md の "UI Components" - CameraPreviewView を参照。

struct CameraPreviewView: UIViewRepresentable {
    // MARK: - プロパティ

    let session: AVCaptureSession

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.connection?.videoOrientation = .portrait
        previewLayer.frame = view.bounds

        view.layer.addSublayer(previewLayer)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // 必要に応じてプレビューレイヤーのフレームを更新
        if let previewLayer = uiView.layer.sublayers?.first as? AVCaptureVideoPreviewLayer {
            previewLayer.frame = uiView.bounds
        }
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