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

    // MARK: - Initialization

    /// Initializes with a default snapshot
    init() {
        self.snapshot = SessionSnapshot()
    }

    // MARK: - Public Methods

    /// Bootstraps the session: checks camera authorization
    func bootstrap() async {
        // Phase transitions handled externally via CameraSessionManager
    }

    /// Transitions to calibrating phase
    func startCalibration() {
        snapshot.phase = .calibrating
    }

    /// Recalibrates from idle
    func recalibrate() {
        snapshot.phase = .calibrating
    }

    /// Starts posture monitoring
    func startMonitoring() {
        snapshot.phase = .monitoring
        snapshot.isDimmed = false
    }

    /// Stops posture monitoring
    func stopMonitoring() {
        snapshot.phase = .idle
        snapshot.isDimmed = false
    }

    /// Enters dim mode (black screen with wake lock)
    func enterDimMode() {
        snapshot.isDimmed = true
    }

    /// Exits dim mode
    func exitDimMode() {
        snapshot.isDimmed = false
    }

    /// Updates sensitivity setting
    func updateSensitivity(_ value: Double) {
        snapshot.sensitivity = max(0.0, min(1.0, value))
    }

    /// Updates displayed posture state
    func updatePosture(_ posture: DisplayedPosture) {
        snapshot.displayedPosture = posture
    }

    /// Updates person detection state
    func updatePersonDetected(_ detected: Bool) {
        snapshot.isPersonDetected = detected
    }

    /// Updates phase (for external state machine control)
    func updatePhase(_ phase: SessionPhase) {
        snapshot.phase = phase
    }

    /// Updates monitoring enabled flag
    func updateMonitoringEnabled(_ enabled: Bool) {
        snapshot.isMonitoringEnabled = enabled
    }
}
