import AVFoundation
import UIKit

extension AVCaptureVideoOrientation {
    /// UIDevice.Orientation から変換。unknown/face-up/face-down は fallbackScene から推定。
    static func fromDeviceOrientation(_ orientation: UIDeviceOrientation, fallbackScene: UIWindowScene? = nil) -> AVCaptureVideoOrientation? {
        switch orientation {
        case .portrait:           return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft:     return .landscapeRight
        case .landscapeRight:    return .landscapeLeft
        default:
            guard let scene = fallbackScene else { return nil }
            return AVCaptureVideoOrientation(rawValue: scene.interfaceOrientation.rawValue)
        }
    }

    /// ランドスケープ向きか
    var isLandscape: Bool { self == .landscapeLeft || self == .landscapeRight }
}

/// フロントカメラのセッション管理とパーミッション。
///
/// `.high` プリセット (720p)、シリアルキャプチャキュー、
/// 非同期認証による AVCaptureSession の管理。
///
/// 設計参照: design.md の "CameraSessionManager" セクション。
final class CameraSessionManager: NSObject, ObservableObject, @unchecked Sendable {
    // MARK: - 公開プロパティ

    @Published private(set) var authorization: CameraAuthorization = .notDetermined

    // MARK: - パブリックプロパティ

    let captureSession = AVCaptureSession()

    func updateVideoOrientation(_ orientation: AVCaptureVideoOrientation) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if let connection = self.videoOutput?.connection(with: .video) {
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = orientation
                }
            }
        }
    }

    // MARK: - プライベートプロパティ

    private let sessionQueue = DispatchQueue(label: "com.nekozefix.camera.session")
    private var videoOutput: AVCaptureVideoDataOutput?
    private var sampleBufferDelegate: AVCaptureVideoDataOutputSampleBufferDelegate?

    // MARK: - 認証

    func requestAuthorization() async -> CameraAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            await MainActor.run {
                self.authorization = granted ? .authorized : .denied
            }
            return authorization
        case .authorized:
            await MainActor.run {
                self.authorization = .authorized
            }
            return .authorized
        case .denied, .restricted:
            await MainActor.run {
                self.authorization = .denied
            }
            return .denied
        @unknown default:
            await MainActor.run {
                self.authorization = .denied
            }
            return .denied
        }
    }

    // MARK: - セッション管理

    func start(position: AVCaptureDevice.Position = .front) async throws {
        guard authorization == .authorized else {
            throw CameraError.notAuthorized
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: CameraError.sessionConfigurationFailed)
                    return
                }

                do {
                    try self.configureSession(position: position)
                    self.captureSession.startRunning()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            self?.captureSession.stopRunning()
        }
    }

    // MARK: - ヘルパー

    /// 現在のデバイス向きから AVCaptureVideoOrientation を推定する。
    /// UIDevice.orientation が .unknown の場合は windowScene からフォールバック。
    private func currentDeviceVideoOrientation() -> AVCaptureVideoOrientation {
        let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        return .fromDeviceOrientation(UIDevice.current.orientation, fallbackScene: scene) ?? .portrait
    }

    // MARK: - サンプルバッファデリゲート

    func setSampleBufferDelegate(_ delegate: AVCaptureVideoDataOutputSampleBufferDelegate) {
        sessionQueue.async { [weak self] in
            self?.sampleBufferDelegate = delegate
        }
    }

    // MARK: - プライベートメソッド

    private func configureSession(position: AVCaptureDevice.Position) throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        captureSession.sessionPreset = .high  // 720p

        // 既存の入力を削除
        captureSession.inputs.forEach { captureSession.removeInput($0) }

        // 指定された位置のカメラを追加
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw CameraError.cameraNotAvailable
        }

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            } else {
                throw CameraError.sessionConfigurationFailed
            }
        } catch {
            throw CameraError.sessionConfigurationFailed
        }

        // ビデオ出力の設定
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(sampleBufferDelegate, queue: sessionQueue)

        // 既存の出力を削除
        captureSession.outputs.forEach { captureSession.removeOutput($0) }

        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
            self.videoOutput = output

            // ビデオ向きを現在のデバイス向きに設定
            if let connection = output.connection(with: .video) {
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = currentDeviceVideoOrientation()
                }
                // 前面カメラの時のみミラー処理を有効にする
                if connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = (position == .front)
                }
            }
        } else {
            throw CameraError.sessionConfigurationFailed
        }
    }
}

// MARK: - エラー

enum CameraError: LocalizedError {
    case notAuthorized
    case cameraNotAvailable
    case sessionConfigurationFailed

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "カメラが許可されていません"
        case .cameraNotAvailable:
            return "カメラが利用できません"
        case .sessionConfigurationFailed:
            return "カメラセッションの構成に失敗しました"
        }
    }
}
