import Foundation

/// Concrete domain struct for calibration logic.
/// Handles accumulation of stable posture angles and reference value management.
struct CalibrationLogic {
    // MARK: - State

    private var accumulatedAngles: [Double] = []
    private var isAccumulating = false
    private var personPresent = false
    private var lastAngle: Double = 0.0
    private var lastTime: TimeInterval = 0

    // MARK: - Public API

    /// Starts a new calibration session.
    /// Overwrites any previous reference.
    mutating func start() {
        accumulatedAngles = []
        isAccumulating = false
        personPresent = false
        lastAngle = 0.0
        lastTime = 0
    }

    /// Processes a posture sample and presence status.
    /// - Parameters:
    ///   - sample: The angle sample from PostureAnalyzer (may be nil if no valid angle)
    ///   - presence: Person detection status
    ///   - now: Current time interval
    /// - Returns: Calibration progress state
    mutating func ingest(sample: AngleSample?, presence: DetectionPresence, now: TimeInterval) -> CalibrationProgress {
        // Handle person missing - reset immediately
        if presence == .personMissing {
            accumulatedAngles = []
            isAccumulating = false
            return .waitingForPerson
        }

        // Update person presence status
        self.personPresent = presence == .personDetected

        // If person is not detected, wait for person
        if !personPresent {
            return .waitingForPerson
        }

        // Handle sample availability
        if let sample = sample {
            // If we have a valid angle sample and are not accumulating yet, start accumulating
            if !isAccumulating {
                // Start accumulation with first valid sample
                accumulatedAngles = [sample.nearAngleDegrees]
                isAccumulating = true
                lastAngle = sample.nearAngleDegrees
                lastTime = now
                return .accumulating(elapsed: 0)
            }

            // Continue accumulation with new samples
            let timeInterval = now - lastTime
            lastAngle = sample.nearAngleDegrees
            lastTime = now

            // Check for posture instability (angle delta > 5 degrees)
            let angleDelta = abs(sample.nearAngleDegrees - lastAngle)
            if angleDelta > 5.0 {
                // Reset accumulation on instability
                accumulatedAngles = [sample.nearAngleDegrees]
                lastAngle = sample.nearAngleDegrees
                lastTime = now
                return .accumulating(elapsed: 0)
            }

            // Add new angle to accumulation
            accumulatedAngles.append(sample.nearAngleDegrees)
        }

        // Check if we have accumulated enough for completion (3 seconds of stable posture)
        // At ~60fps, we need approximately 180 frames (5 seconds) for 3 seconds stability
        // But requirement is 3 seconds of stable detection
        if isAccumulating && accumulatedAngles.count >= 180 { // 3 seconds * 60 fps
            // Calculate average of accumulated angles
            let average = accumulatedAngles.reduce(0.0, +) / Double(accumulatedAngles.count)
            let completedProgress = .completed(referenceNearAngleDegrees: average)

            // Reset state after completion
            accumulatedAngles = []
            isAccumulating = false

            return completedProgress
        }

        // If accumulating but not yet completed
        if isAccumulating {
            let elapsed = now - lastTime
            return .accumulating(elapsed: elapsed)
        }

        // Default state
        return .waitingForPerson
    }
}