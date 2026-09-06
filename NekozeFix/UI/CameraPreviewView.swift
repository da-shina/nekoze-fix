import SwiftUI
import AVFoundation

/// UI layer: AVCaptureVideoPreviewLayer SwiftUI wrapper.
/// See design.md "UI Components" - CameraPreviewView.

struct CameraPreviewView: UIViewRepresentable {
    // MARK: - Properties

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
        // Update preview layer frame if needed
        if let previewLayer = uiView.layer.sublayers?.first as? AVCaptureVideoPreviewLayer {
            previewLayer.frame = uiView.bounds
        }
    }
}

// MARK: - Preview

struct CameraPreviewView_Previews: PreviewProvider {
    static var previews: some View {
        CameraPreviewView(session: AVCaptureSession())
            .frame(width: 300, height: 400)
            .previewDisplayName("Camera Preview")
    }
}