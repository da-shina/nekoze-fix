import UIKit
import AVFoundation

/// Services layer: device orientation monitoring and rotation detection.
/// See design.md "DeviceOrientationMonitor" section.

final class DeviceOrientationMonitor: ObservableObject {
    // MARK: - Published Properties

    @Published private(set) var currentVideoOrientation: AVCaptureVideoOrientation = .portrait
    @Published private(set) var isRotating = false

    // MARK: - Private Properties

    private var rotationTimer: Timer?
    private let notificationCenter = NotificationCenter.default

    // MARK: - Initialization

    init() {
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Public Methods

    /// Starts monitoring device orientation changes
    func startMonitoring() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        notificationCenter.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
        updateOrientation()
    }

    /// Stops monitoring device orientation changes
    func stopMonitoring() {
        notificationCenter.removeObserver(
            self,
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        rotationTimer?.invalidate()
        rotationTimer = nil
    }

    // MARK: - Private Methods

    @objc private func deviceOrientationDidChange() {
        // Cancel any existing rotation timer
        rotationTimer?.invalidate()

        // Mark as rotating
        isRotating = true

        // Update current orientation
        let orientationChanged = updateOrientation()

        // Start 5-second timer only when meaningful orientation changes occur
        // (not for face-up/face-down which return early)
        if orientationChanged {
            rotationTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.isRotating = false
                }
            }
        } else {
            // Face-up/face-down: rotation complete immediately
            isRotating = false
        }
    }

    private func updateOrientation() -> Bool {
        let deviceOrientation = UIDevice.current.orientation
        let newOrientation: AVCaptureVideoOrientation

        switch deviceOrientation {
        case .portrait:
            newOrientation = .portrait
        case .portraitUpsideDown:
            newOrientation = .portraitUpsideDown
        case .landscapeLeft:
            newOrientation = .landscapeRight
        case .landscapeRight:
            newOrientation = .landscapeLeft
        default:
            // For unknown orientations (face up/down), keep current and signal no change
            return false
        }

        currentVideoOrientation = newOrientation
        return true
    }
}