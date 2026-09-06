import AVFoundation
import UIKit

/// Front camera session management and permissions.
///
/// Manages AVCaptureSession with `.high` preset (720p),
/// serial capture queue, and async authorization.
///
/// Design ref: design.md "CameraSessionManager" section.
final class CameraSessionManager: NSObject, ObservableObject {
    // MARK: - Published Properties

    @Published private(set) var authorization: CameraAuthorization = .notDetermined

    // MARK: - Public Properties

    let captureSession = AVCaptureSession()

    // MARK: - Private Properties

    private let sessionQueue = DispatchQueue(label: "com.nekozefix.camera.session")
    private var videoOutput: AVCaptureVideoDataOutput?
    private var sampleBufferDelegate: AVCaptureVideoDataOutputSampleBufferDelegate?

    // MARK: - Authorization

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

    // MARK: - Session Management

    func start() async throws {
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
                    try self.configureSession()
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

    func applyVideoOrientation(_ orientation: AVCaptureVideoOrientation) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if let connection = self.videoOutput?.connection(with: .video) {
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = orientation
                }
            }
        }
    }

    // MARK: - Sample Buffer Delegate

    func setSampleBufferDelegate(_ delegate: AVCaptureVideoDataOutputSampleBufferDelegate) {
        sessionQueue.async { [weak self] in
            self?.sampleBufferDelegate = delegate
        }
    }

    // MARK: - Private Methods

    private func configureSession() throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        captureSession.sessionPreset = .high  // 720p

        // Remove existing inputs
        captureSession.inputs.forEach { captureSession.removeInput($0) }

        // Add front camera
        guard let frontCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw CameraError.cameraNotAvailable
        }

        do {
            let input = try AVCaptureDeviceInput(device: frontCamera)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            } else {
                throw CameraError.sessionConfigurationFailed
            }
        } catch {
            throw CameraError.sessionConfigurationFailed
        }

        // Configure video output
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(sampleBufferDelegate, queue: sessionQueue)

        // Remove existing outputs
        captureSession.outputs.forEach { captureSession.removeOutput($0) }

        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
            self.videoOutput = output

            // Set video orientation to portrait
            if let connection = output.connection(with: .video) {
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
                // Mirror front camera
                if connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = true
                }
            }
        } else {
            throw CameraError.sessionConfigurationFailed
        }
    }
}

// MARK: - Errors

enum CameraError: LocalizedError {
    case notAuthorized
    case cameraNotAvailable
    case sessionConfigurationFailed

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Camera not authorized"
        case .cameraNotAvailable:
            return "Camera not available"
        case .sessionConfigurationFailed:
            return "Failed to configure camera session"
        }
    }
}