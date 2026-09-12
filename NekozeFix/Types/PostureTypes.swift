import Foundation
import AVFoundation

// 型層: 共通の値オブジェクトと列挙型。
// 完全な仕様は design.md "Types" セクション参照。

enum CameraPosition: String, Codable, Equatable {
    case front
    case back

    var avPosition: AVCaptureDevice.Position {
        switch self {
        case .front: return .front
        case .back: return .back
        }
    }
}

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

enum CalibrationProgress: Equatable {
    case waitingForPerson
    case accumulating(elapsed: TimeInterval)
    case completed(referenceNearAngleDegrees: Double, referencePoints: [CGPoint])
}

struct SessionSnapshot: Equatable {
    var phase: SessionPhase = .awaitingPermission
    var displayedPosture: DisplayedPosture = .good
    var isDimmed: Bool = false
    var isRotating: Bool = false
    var isPersonDetected: Bool = false
    var showGuideline: Bool = false
    var sensitivity: Double = 0.5
    var isMonitoringEnabled: Bool = false
    var slouchGate: TimedConditionGate = TimedConditionGate(requiredDuration: 3.0)
    var calibrationProgress: CalibrationProgress = .waitingForPerson
    var referenceAngle: Double? = nil
    var referencePoints: [CGPoint]? = nil
    var currentThreshold: Double = 0.0
    var visualizationPoints: [CGPoint] = []
    var nearSide: Side? = nil
}

/// キーポイントを解析に含めるための最低信頼度閾値。
// 設計仕様: confidence < 0.5 → 猫背検出から除外。
let minimumKeypointConfidence: Double = 0.5
