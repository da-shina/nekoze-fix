import Foundation

// Types layer: shared value objects and enums.
// See design.md "Types" section for full contracts.

enum CameraAuthorization {
    case notDetermined
    case authorized
    case denied
}

enum DetectionPresence {
    case personDetected
    case personMissing
}

struct Keypoint: Equatable {
    var x: Double
    var y: Double
    var confidence: Double
}

struct PoseFrame: Equatable {
    var timestamp: TimeInterval
    var leftEar: Keypoint?
    var rightEar: Keypoint?
    var leftShoulder: Keypoint?
    var rightShoulder: Keypoint?
}

enum Side: Equatable {
    case left
    case right
}

struct AngleSample: Equatable {
    var nearSide: Side
    var nearAngleDegrees: Double
    var farSideDetected: Bool
}

enum PostureVerdict: Equatable {
    case good
    case slouchCandidate
    case insufficientKeypoints
}

enum SessionPhase: Equatable {
    case awaitingPermission
    case permissionDenied
    case calibrating
    case idle
    case monitoring
    case rotating
}

enum DisplayedPosture: Equatable {
    case good
    case slouch
    case personMissing
}

struct SessionSnapshot: Equatable {
    var phase: SessionPhase
    var displayedPosture: DisplayedPosture
    var isDimmed: Bool
    var isPersonDetected: Bool
    var sensitivity: Double
    var isMonitoringEnabled: Bool
}

/// Minimum confidence threshold for keypoint inclusion in analysis.
// Design spec: confidence < 0.5 → exclude from slouch detection.
let minimumKeypointConfidence: Double = 0.5
