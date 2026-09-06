import SwiftUI
import Combine

/// Session layer: posture monitoring session state machine.
/// See design.md "PostureSessionManager" section.

@MainActor
final class PostureSessionManager: ObservableObject {
    // MARK: - Published Properties

    @Published private(set) var snapshot: SessionSnapshot

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()
    private var authorizationChecked = false

    // MARK: - Initialization

    /// Initializes with a default snapshot
    init() {
        self.snapshot = SessionSnapshot()
        setupSubscriptions()
    }

    // MARK: - Public Methods

    /// Bootstraps the session: checks camera authorization and prepares services
    func bootstrap() async {
        // Authorization check happens via CameraSessionManager
        // This method exists for API compatibility with design
        authorizationChecked = true
    }

    /// Starts the calibration process
    func startCalibration() {
        snapshot.phase = .calibrating
        snapshot.calibrationProgress = .waitingForPerson
    }

    /// Recalibrates (called from CalibrationView)
    func recalibrate() {
        startCalibration()
    }

    /// Starts monitoring posture
    func startMonitoring() {
        snapshot.phase = .monitoring
        snapshot.isDimmed = false
        snapshot.isRotating = false
        // Reset gates when starting monitoring
        snapshot.slouchGate.reset()
    }

    /// Stops monitoring posture
    func stopMonitoring() {
        snapshot.phase = .idle
        snapshot.isDimmed = false
        snapshot.isRotating = false
    }

    /// Enters dim mode (black screen with wake lock)
    func enterDimMode() {
        snapshot.isDimmed = true
        // Note: Actual brightness/wake lock handling done in MonitorView
    }

    /// Exits dim mode (restore normal brightness)
    func exitDimMode() {
        snapshot.isDimmed = false
    }

    /// Updates sensitivity setting
    func updateSensitivity(_ value: Double) {
        snapshot.sensitivity = max(0.0, min(1.0, value))
    }

    // MARK: - Private Methods

    private func setupSubscriptions() {
        // Subscribe to our own snapshot changes if needed
        // For now, we rely on external components to update the snapshot
    }
}