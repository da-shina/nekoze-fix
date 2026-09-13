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
    /// 閾値適用前のキーポイント信頼度（-1 = 観測内で未取得）。
    /// DEBUG 診断用（なで肩の実測切り分け）。
    var rawLeftShoulderConfidence: Double = -1
    var rawRightShoulderConfidence: Double = -1
    var rawLeftEarConfidence: Double = -1
    var rawRightEarConfidence: Double = -1
    /// 閾値適用前のキーポイント位置（nil = 観測内で未取得）。DEBUG 診断用。
    var rawLeftShoulderPoint: CGPoint?
    var rawRightShoulderPoint: CGPoint?
    var rawLeftEarPoint: CGPoint?
    var rawRightEarPoint: CGPoint?
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
    /// 人物は映っているが肩のキーポイントが読めない状態（顔のみ検出）。
    /// 校正中の「肩が映っていません」案内に使用。
    var isShoulderMissing: Bool = false
    var showGuideline: Bool = false
    var isMonitoringEnabled: Bool = false
    var slouchGate: TimedConditionGate = TimedConditionGate(requiredDuration: 3.0)
    var calibrationProgress: CalibrationProgress = .waitingForPerson
    var referenceAngle: Double? = nil
    var referencePoints: [CGPoint]? = nil
    var visualizationPoints: [CGPoint] = []
    /// キャプチャ画像のアスペクト比（バッファ実寸から算出）。可視化のクロップ補正に使用。
    var videoAspectRatio: CGFloat = 4.0 / 3.0
    var nearSide: Side? = nil
    /// DEBUG 診断: raw キーポイント位置（順序: 左肩, 右肩, 左耳, 右耳。.zero = 未取得）
    var debugRawPoints: [CGPoint] = []
    #if DEBUG
    /// DEBUG 診断: 採用前のキーポイント confidence（nil = Body Pose 観測そのものが無い）
    var debugLeftShoulderConfidence: Double? = nil
    var debugRightShoulderConfidence: Double? = nil
    var debugLeftEarConfidence: Double? = nil
    var debugRightEarConfidence: Double? = nil
    #endif
}

/// キーポイントを解析に含めるための最低信頼度閾値。
// 設計仕様: confidence < 0.3 → 猫背検出から除外（なで肩等の低信頼度帯を救うため 0.5 → 0.3 に改訂）。
let minimumKeypointConfidence: Double = 0.3
